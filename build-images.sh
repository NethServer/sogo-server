#!/bin/bash

#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

# Terminate on error
set -e

# SOGo and SOPE always share the same version number — change one variable to bump both.
# To update: visit https://github.com/Alinto/sogo/tags
version=5.12.7
# libwbxml has its own independent release cycle.
# To update: visit https://github.com/libwbxml/libwbxml/tags
libwbxml_version=0.11.10
# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/nethserver}"
reponame="sogo-server"

# ─── Stage 1: builder ──────────────────────────────────────────────────────────
# Full Debian Trixie with build tools. Compiles libwbxml, SOPE and SOGo into
# /staging so the runtime stage can copy only the compiled artefacts.

builder=$(buildah from docker.io/library/debian:trixie)
container=$(buildah from docker.io/library/debian:trixie-slim)

# Clean up working containers on exit (success or failure)
trap 'buildah rm "${builder}" "${container}" 2>/dev/null || true' EXIT

buildah config --env VERSION=${version} --env LIBWBXML_VERSION=${libwbxml_version} "${builder}"
buildah run "${builder}" /bin/sh <<'EOF'
set -e

apt-get update && apt-get install -y --no-install-recommends \
    build-essential gobjc git curl cmake \
    gnustep-make gnustep-base-common libgnustep-base-dev \
    libmemcached-dev \
    liboath-dev \
    libmariadb-dev libmariadb-dev-compat \
    libpq-dev \
    libldap-dev \
    libxml2-dev \
    libsodium-dev \
    libzip-dev \
    libytnef0-dev \
    libexpat1-dev \
    pkg-config \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir /build /staging

# ── libwbxml ──────────────────────────────────────────────────────────────────
(
    cd /build
    git clone --depth 1 --branch libwbxml-${LIBWBXML_VERSION} \
        https://github.com/libwbxml/libwbxml.git
    mkdir -p /build/libwbxml/build
    cd /build/libwbxml/build
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DENABLE_UNIT_TEST=OFF
    make -j$(nproc)
    # Install into staging (for the runtime image) and into the builder itself
    # so SOPE and SOGo can find the library at compile time.
    make install DESTDIR=/staging
    make install
    ldconfig
    rm -rf /build/libwbxml
)

# ── SOPE ──────────────────────────────────────────────────────────────────────
(
    cd /build
    git clone --depth 1 --branch SOPE-${VERSION} \
        https://github.com/Alinto/sope.git
    cd /build/sope
    # Patch encoding constants for gnustep-base 1.31+
    sed 's@NSBIG5StringEncoding@NSBig5StringEncoding@g' -i sope-mime/NGMime/NGMimeType.m
    sed 's@NSGB2312StringEncoding@NSHZ_GB_2312StringEncoding@g' -i sope-mime/NGMime/NGMimeType.m
    . /usr/share/GNUstep/Makefiles/GNUstep.sh
    ./configure --with-gnustep --disable-strip --disable-debug
    make -j$(nproc)
    make install DESTDIR=/staging
    make install
    ldconfig
    rm -rf /build/sope
)

# ── SOGo ──────────────────────────────────────────────────────────────────────
(
    cd /build
    git clone --depth 1 --branch SOGo-${VERSION} \
        https://github.com/Alinto/sogo.git
    cd /build/sogo
    . /usr/share/GNUstep/Makefiles/GNUstep.sh
    ./configure \
        --prefix=$(gnustep-config --variable=GNUSTEP_SYSTEM_ROOT) \
        --disable-debug \
        --enable-mfa
    make -j$(nproc) messages=yes
    make install DESTDIR=/staging
    # ActiveSync is a separate sub-project not included in main SUBPROJECTS
    cd /build/sogo/ActiveSync
    make -j$(nproc)
    make install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM DESTDIR=/staging

    # Apache SOGo config — fix paths for Debian (GNUSTEP_SYSTEM_ROOT=/usr/local)
    install -D -m 0644 /build/sogo/Apache/SOGo.conf \
        /staging/etc/apache2/conf-available/SOGo.conf
    sed -i 's|/usr/lib/GNUstep/SOGo/|/usr/local/lib/GNUstep/SOGo/|g' \
        /staging/etc/apache2/conf-available/SOGo.conf
    # Enable redirect from / to /SOGo/
    sed -i 's|#RedirectMatch \^/\$ .*|RedirectMatch ^/$ /SOGo/|' \
        /staging/etc/apache2/conf-available/SOGo.conf
    # Default sogo.conf
    install -D -m 0640 /build/sogo/Scripts/sogo.conf \
        /staging/etc/sogo/sogo.conf
    # SQL update scripts and backup script (copy from cloned source)
    mkdir -p /staging/usr/lib/sogo/scripts
    install -m 0755 /build/sogo/Scripts/sql-*.sh \
        /staging/usr/lib/sogo/scripts/
    install -m 0755 /build/sogo/Scripts/sogo-backup.sh \
        /staging/usr/lib/sogo/scripts/
    rm -rf /build/sogo
)
EOF

# ─── Stage 2: runtime ──────────────────────────────────────────────────────────
# Debian Trixie slim with only runtime dependencies.

buildah config --env VERSION=${version} --env LIBWBXML_VERSION=${libwbxml_version} "${container}"

# Copy compiled artefacts from builder staging area into the runtime container
buildah copy --from="${builder}" "${container}" /staging/. /

buildah run "${container}" /bin/sh <<'EOF'
set -e

apt-get update && apt-get install -y --no-install-recommends \
    supervisor apache2 memcached cron curl zip inetutils-ping \
    gnustep-base-common libgnustep-base1.31 \
    libmemcached11t64 \
    liboath0t64 \
    libmariadb3 \
    libpq5 \
    libldap2 \
    libxml2 \
    libsodium23 \
    libzip5 \
    libytnef0 \
    && rm -rf /var/lib/apt/lists/*

# Register copied shared libraries (including SOGo libs in non-standard subdir)
echo "/usr/local/lib/sogo" > /etc/ld.so.conf.d/sogo.conf
ldconfig

# Apache: listen on port 20001, disable default site, enable SOGo
sed -i 's/^Listen 80$/Listen 20001/' /etc/apache2/ports.conf
a2dissite 000-default
a2enmod proxy proxy_http headers rewrite
a2enconf SOGo

# Create supervisor.d directory (Debian supervisor uses conf.d but we use our own config)
mkdir -p /etc/supervisor.d

# Create sogo user with a writable home (GNUstep writes defaults under $HOME/GNUstep/)
useradd -r -d /var/lib/sogo sogo
mkdir -p /var/lib/sogo && chown sogo:sogo /var/lib/sogo
mkdir /var/run/sogo && chown sogo:sogo /var/run/sogo
mkdir /var/spool/sogo && chown sogo:sogo /var/spool/sogo
mkdir -p /var/log/sogo && chown sogo:sogo /var/log/sogo
mkdir -p /etc/sogo && chown root:sogo /etc/sogo && chmod 750 /etc/sogo
chown root:sogo /etc/sogo/sogo.conf
EOF

buildah add "${container}" supervisord.conf /etc/supervisord.conf
buildah add "${container}" event_listener.ini /etc/supervisor.d/event_listener.ini
buildah add "${container}" event_listener.sh /usr/local/bin/event_listener.sh
buildah add "${container}" sogod.ini /etc/supervisor.d/sogod.ini
buildah add "${container}" apache.ini /etc/supervisor.d/apache.ini
buildah add "${container}" cron.ini /etc/supervisor.d/cron.ini
buildah add "${container}" memcached.ini /etc/supervisor.d/memcached.ini

buildah config --env LD_PRELOAD=libytnef.so.0 \
    --port 20001/tcp \
    --port 20000/tcp \
    --workingdir="/" \
    --cmd='["/usr/bin/supervisord", "--nodaemon", "-c", "/etc/supervisord.conf"]' \
    --label="org.opencontainers.image.source=https://github.com/NethServer/sogo-server" \
    --label="org.opencontainers.image.authors=Stephane de Labrusse <stephdl@de-labrusse.fr>" \
    --label="org.opencontainers.image.title=SOGo based on Debian Trixie" \
    --label="org.opencontainers.image.description=A sogo container based on Debian Trixie that provides apache2, sogo, memcached and cron" \
    --label="org.opencontainers.image.licenses=GPL-3.0-or-later" \
    --label="org.opencontainers.image.url=https://github.com/NethServer/sogo-server" \
    --label="org.opencontainers.image.documentation=https://github.com/NethServer/sogo-server/blob/main/README.md" \
    --label="org.opencontainers.image.vendor=NethServer" \
    "${container}"

# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

#
# Setup CI when pushing to Github.
# Warning! docker::// protocol expects lowercase letters (,,)
if [[ -n "${CI}" ]]; then
    # Set output value for Github Actions
    printf "images=%s\n" "${images[*],,}" >> "${GITHUB_OUTPUT}"
else
    # Just print info for manual push
    printf "Publish the images with:\n\n"
    for image in "${images[@],,}"; do printf "  buildah push %s docker://%s:%s\n" "${image}" "${image}" "${IMAGETAG:-latest}" ; done
    printf "\n"
fi
