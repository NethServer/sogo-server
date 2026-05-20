#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Multi-stage build of SOGo directly from upstream sources (no AUR / no makepkg).
# Exact parity with the AUR PKGBUILDs: same seds, same ./configure flags
# (--enable-mfa included). Equivalent to build-images.sh.
#
# Bump versions here (single place): the tarball URLs and the runtime
# version-parity self-check all derive from these three ARGs.
ARG LIBWBXML_VERSION
ARG SOPE_VERSION
ARG SOGO_VERSION

# ============================================================================
# Stage 1: builder — compiles libwbxml -> SOPE -> SOGo, stages into /staging
# ============================================================================
FROM docker.io/library/archlinux:base-devel AS builder

ARG LIBWBXML_VERSION
ARG SOPE_VERSION
ARG SOGO_VERSION
ARG LIBWBXML_URL=https://github.com/libwbxml/libwbxml/archive/refs/tags/libwbxml-${LIBWBXML_VERSION}.tar.gz
ARG SOPE_URL=https://packages.sogo.nu/sources/SOPE-${SOPE_VERSION}.tar.gz
ARG SOGO_URL=https://packages.sogo.nu/sources/SOGo-${SOGO_VERSION}.tar.gz

# Build-time deps: toolchain + makedepends/depends from the AUR PKGBUILDs
RUN pacman --noconfirm --needed -Syu && \
    pacman --noconfirm --needed -S \
        base-devel git curl cmake check expat \
        gnustep-make gnustep-base gcc-objc \
        libxml2 libxslt openssl libgcrypt openldap \
        postgresql-libs mariadb-libs libsodium libzip libytnef \
        libmemcached oath-toolkit && \
    yes | pacman -Sccq

WORKDIR /build

# Compile from upstream sources. The logic lives in a COPY+RUN script (not a
# Dockerfile heredoc) because the CI buildah does not support heredocs.
COPY build/compile-sogo.sh /tmp/compile-sogo.sh
RUN bash /tmp/compile-sogo.sh

# ============================================================================
# Stage 2: runtime — minimal archlinux, runtime deps only + staged artifacts
# ============================================================================
FROM docker.io/library/archlinux:base AS runtime

ARG SOGO_VERSION

# Runtime dependencies only (no base-devel / git / cmake / gnustep-make)
RUN pacman --noconfirm --needed -Syu && \
    pacman --noconfirm --needed -S \
        gnustep-base libxml2 libxslt openssl libgcrypt libgpg-error \
        openldap postgresql-libs mariadb-libs curl \
        libsodium libzip libytnef libmemcached oath-toolkit \
        memcached apache supervisor cronie zip inetutils tzdata ca-certificates && \
    rm -rf /var/cache/pacman/pkg/download-*/ && \
    yes | pacman -Sccq

# Bring the compiled artifacts from the builder
COPY --from=builder /staging /

# The AUR sogo .install hook is absent when building from source: create the
# system user and runtime directories manually.
RUN set -eux; \
    ldconfig; \
    (id -u sogo >/dev/null 2>&1 || useradd -r -d /etc/sogo sogo); \
    mkdir -p /var/log/sogo /var/run/sogo /var/spool/sogo; \
    chown -R sogo:sogo /etc/sogo /var/log/sogo /var/run/sogo /var/spool/sogo; \
    rm -rf /tmp/* /var/tmp/* /var/cache/pacman/pkg/*

# Supervisor / apache configuration
COPY httpd.conf /etc/httpd/conf/httpd.conf
COPY event_listener.ini /etc/supervisor.d/event_listener.ini
COPY event_listener.sh /usr/local/bin/event_listener.sh
RUN chmod +x /usr/local/bin/event_listener.sh
COPY sogod.ini /etc/supervisor.d/sogod.ini
COPY apache.ini /etc/supervisor.d/apache.ini
COPY cronie.ini /etc/supervisor.d/cronie.ini
COPY memcached.ini /etc/supervisor.d/memcached.ini

# Self-check before the image is usable: a broken image must never ship.
# Logic lives in a COPY+RUN script (not a Dockerfile heredoc) for CI buildah
# compatibility. SOGO_VERSION (ARG, exported into RUN) drives version parity.
COPY build/verify-image.sh /tmp/verify-image.sh
RUN bash /tmp/verify-image.sh && rm -f /tmp/verify-image.sh

ENV LD_PRELOAD=/usr/lib/libytnef.so
WORKDIR /
EXPOSE 20000/tcp 20001/tcp
CMD ["/usr/sbin/supervisord", "--nodaemon"]

LABEL org.opencontainers.image.source="https://github.com/NethServer/sogo-server" \
      org.opencontainers.image.authors="Stephane de Labrusse <stephdl@de-labrusse.fr>" \
      org.opencontainers.image.title="SOGo based on Archlinux" \
      org.opencontainers.image.description="A sogo container based on Archlinux that provides apache, sogo, memcached and cron" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.url="https://github.com/NethServer/sogo-server" \
      org.opencontainers.image.documentation="https://github.com/NethServer/sogo-server/blob/main/README.md" \
      org.opencontainers.image.vendor="NethServer"
