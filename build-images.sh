#!/bin/bash

#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

# Terminate on error
set -e
archlinux_version=base-devel
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

#Create sogo-server container
reponame="sogo-server"
container=$(buildah from docker.io/library/archlinux:${archlinux_version})
buildah config --env VERSION=${version} --env LIBWBXML_VERSION=${libwbxml_version} "${container}"
buildah run "${container}" /bin/sh <<'EOF'
set -e
pacman --noconfirm --needed -Syu && \
    pacman --noconfirm --needed -S \
        base-devel git curl \
        supervisor apache zip inetutils cronie \
        libsodium libzip libytnef \
        gcc-objc gnustep-make gnustep-base \
        cmake \
        libmemcached-awesome memcached \
        oath-toolkit \
        mariadb-libs postgresql-libs \
        libldap libxml2 \
    && yes | pacman -Sccq && \
    mkdir /build

(
    cd /build
    git clone --depth 1 --branch libwbxml-${LIBWBXML_VERSION} \
        https://github.com/libwbxml/libwbxml.git
    mkdir -p /build/libwbxml/build
    cd /build/libwbxml/build
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DENABLE_UNIT_TEST=OFF
    make -j$(nproc)
    make install
    ldconfig
    rm -rf /build/libwbxml && yes | pacman -Sccq
)
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
    make install
    ldconfig
    rm -rf /build/sope && yes | pacman -Sccq
)
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
    make install
    # ActiveSync is a separate sub-project not included in main SUBPROJECTS
    cd /build/sogo/ActiveSync
    make -j$(nproc)
    make install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
    ldconfig
)

# Create sogo user and runtime directories (done by sogo.install in AUR)
useradd -r -d /etc/sogo sogo
mkdir /var/run/sogo && chown sogo:sogo /var/run/sogo
mkdir /var/spool/sogo && chown sogo:sogo /var/spool/sogo
mkdir -p /var/log/sogo && chown sogo:sogo /var/log/sogo
mkdir -p /etc/sogo && chown root:sogo /etc/sogo && chmod 750 /etc/sogo

# Install Apache SOGo config
install -D -m 0644 /build/sogo/Apache/SOGo.conf /etc/httpd/conf/extra/SOGo.conf

# Install default sogo.conf
install -D -m 0640 /build/sogo/Scripts/sogo.conf /etc/sogo/sogo.conf
chown root:sogo /etc/sogo/sogo.conf

# Install SQL update scripts
mkdir -p /usr/lib/sogo/scripts
install -m 0755 /build/sogo/Scripts/sql-*.sh /usr/lib/sogo/scripts/

rm -rf /build/sogo && yes | pacman -Sccq

# download backup script
curl -o /usr/lib/sogo/scripts/sogo-backup.sh https://raw.githubusercontent.com/Alinto/sogo/master/Scripts/sogo-backup.sh
chmod 755 /usr/lib/sogo/scripts/sogo-backup.sh

# clean up build tools (runtime deps like gnustep-base, mariadb-libs, etc. must stay)
pacman --noconfirm -Rcns base-devel git gcc-objc gnustep-make cmake && yes | pacman -Sccq && rm -rf /tmp/* /var/tmp/* /var/cache/pacman/* /build
EOF
buildah add "${container}" httpd.conf /etc/httpd/conf/httpd.conf
buildah add "${container}" event_listener.ini /etc/supervisor.d/event_listener.ini
buildah add "${container}" event_listener.sh /usr/local/bin/event_listener.sh
buildah add "${container}" sogod.ini /etc/supervisor.d/sogod.ini
buildah add "${container}" apache.ini /etc/supervisor.d/apache.ini
buildah add "${container}" cronie.ini /etc/supervisor.d/cronie.ini
buildah add "${container}" memcached.ini /etc/supervisor.d/memcached.ini


buildah config --env LD_PRELOAD=/usr/lib/libytnef.so \
    --port 20001/tcp \
    --port 20000/tcp \
    --workingdir="/" \
    --cmd='["/usr/sbin/supervisord", "--nodaemon"]' \
    --label="org.opencontainers.image.source=https://github.com/NethServer/sogo-server" \
    --label="org.opencontainers.image.authors=Stephane de Labrusse <stephdl@de-labrusse.fr>" \
    --label="org.opencontainers.image.title=SOGo based on Archlinux" \
    --label="org.opencontainers.image.description=A sogo container based on Archlinux that provides apache, sogo, memcached and cron" \
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
