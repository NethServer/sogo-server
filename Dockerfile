# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later

ARG VERSION=5.12.7
ARG LIBWBXML_VERSION=0.11.10

# ─── Stage 1: builder ─────────────────────────────────────────────────────────
# Full Debian Trixie with build tools. Compiles libwbxml, SOPE and SOGo into
# /staging so the runtime stage can copy only the compiled artefacts.
FROM debian:trixie AS builder
ARG VERSION
ARG LIBWBXML_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
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
RUN git clone --depth 1 --branch libwbxml-${LIBWBXML_VERSION} \
        https://github.com/libwbxml/libwbxml.git /build/libwbxml \
    && mkdir /build/libwbxml/build \
    && cmake -S /build/libwbxml -B /build/libwbxml/build \
        -DCMAKE_INSTALL_PREFIX=/usr -DENABLE_UNIT_TEST=OFF \
    && make -C /build/libwbxml/build -j$(nproc) \
    && make -C /build/libwbxml/build install DESTDIR=/staging \
    && make -C /build/libwbxml/build install \
    && ldconfig \
    && rm -rf /build/libwbxml

# ── SOPE ──────────────────────────────────────────────────────────────────────
RUN git clone --depth 1 --branch SOPE-${VERSION} \
        https://github.com/Alinto/sope.git /build/sope \
    && sed 's@NSBIG5StringEncoding@NSBig5StringEncoding@g' -i /build/sope/sope-mime/NGMime/NGMimeType.m \
    && sed 's@NSGB2312StringEncoding@NSHZ_GB_2312StringEncoding@g' -i /build/sope/sope-mime/NGMime/NGMimeType.m \
    && . /usr/share/GNUstep/Makefiles/GNUstep.sh \
    && cd /build/sope && ./configure --with-gnustep --disable-strip --disable-debug \
    && make -j$(nproc) \
    && make install DESTDIR=/staging \
    && make install \
    && ldconfig \
    && rm -rf /build/sope

# ── SOGo ──────────────────────────────────────────────────────────────────────
RUN git clone --depth 1 --branch SOGo-${VERSION} \
        https://github.com/Alinto/sogo.git /build/sogo \
    && . /usr/share/GNUstep/Makefiles/GNUstep.sh \
    && cd /build/sogo \
    && ./configure \
        --prefix=$(gnustep-config --variable=GNUSTEP_SYSTEM_ROOT) \
        --disable-debug \
        --enable-mfa \
    && make -j$(nproc) messages=yes \
    && make install DESTDIR=/staging \
    && cd /build/sogo/ActiveSync \
    && make -j$(nproc) \
    && make install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM DESTDIR=/staging \
    && install -D -m 0644 /build/sogo/Apache/SOGo.conf \
        /staging/etc/apache2/conf-available/SOGo.conf \
    && sed -i 's|/usr/lib/GNUstep/SOGo/|/usr/local/lib/GNUstep/SOGo/|g' \
        /staging/etc/apache2/conf-available/SOGo.conf \
    && sed -i 's|#RedirectMatch \^/\$ .*|RedirectMatch ^/$ /SOGo/|' \
        /staging/etc/apache2/conf-available/SOGo.conf \
    && install -D -m 0640 /build/sogo/Scripts/sogo.conf \
        /staging/etc/sogo/sogo.conf \
    && mkdir -p /staging/usr/lib/sogo/scripts \
    && install -m 0755 /build/sogo/Scripts/sql-*.sh /staging/usr/lib/sogo/scripts/ \
    && install -m 0755 /build/sogo/Scripts/sogo-backup.sh /staging/usr/lib/sogo/scripts/ \
    && rm -rf /build/sogo

# ── Cleanup /staging: strip binaries, remove static libs, headers and docs ───
RUN find /staging -name '*.a' -delete \
    && find /staging -name '*.la' -delete \
    && rm -rf /staging/usr/include /staging/usr/local/include \
    && rm -rf /staging/usr/share/doc /staging/usr/share/man /staging/usr/share/info \
    && find /staging -type f \( -name '*.so*' -o -perm /0111 \) \
        ! -name '*.py' \
        -exec strip --strip-unneeded {} + 2>/dev/null || true

# ─── Stage 2: runtime ─────────────────────────────────────────────────────────
# Debian Trixie slim with only runtime dependencies.
FROM debian:trixie-slim
ARG VERSION
ARG LIBWBXML_VERSION

COPY --from=builder /staging/ /

RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man \
        /usr/share/locale /usr/share/info /var/cache/apt \
    && echo "/usr/local/lib/sogo" > /etc/ld.so.conf.d/sogo.conf \
    && ldconfig \
    && sed -i 's/^Listen 80$/Listen 20001/' /etc/apache2/ports.conf \
    && a2dissite 000-default \
    && a2enmod proxy proxy_http headers rewrite \
    && a2enconf SOGo \
    && mkdir -p /etc/supervisor.d \
    && useradd -r -d /var/lib/sogo sogo \
    && mkdir -p /var/lib/sogo && chown sogo:sogo /var/lib/sogo \
    && mkdir /var/run/sogo && chown sogo:sogo /var/run/sogo \
    && mkdir /var/spool/sogo && chown sogo:sogo /var/spool/sogo \
    && mkdir -p /var/log/sogo && chown sogo:sogo /var/log/sogo \
    && mkdir -p /etc/sogo && chown root:sogo /etc/sogo && chmod 750 /etc/sogo \
    && chown root:sogo /etc/sogo/sogo.conf

COPY supervisord.conf /etc/supervisord.conf
COPY event_listener.ini /etc/supervisor.d/event_listener.ini
COPY event_listener.sh /usr/local/bin/event_listener.sh
COPY sogod.ini /etc/supervisor.d/sogod.ini
COPY apache.ini /etc/supervisor.d/apache.ini
COPY cron.ini /etc/supervisor.d/cron.ini
COPY memcached.ini /etc/supervisor.d/memcached.ini
COPY cron-sogo /etc/cron.d/sogo

ENV VERSION=${VERSION}
ENV LIBWBXML_VERSION=${LIBWBXML_VERSION}

LABEL org.opencontainers.image.source="https://github.com/NethServer/sogo-server"
LABEL org.opencontainers.image.authors="Stephane de Labrusse <stephdl@de-labrusse.fr>"
LABEL org.opencontainers.image.title="SOGo based on Debian Trixie"
LABEL org.opencontainers.image.description="A sogo container based on Debian Trixie that provides apache2, sogo, memcached and cron"
LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"
LABEL org.opencontainers.image.url="https://github.com/NethServer/sogo-server"
LABEL org.opencontainers.image.vendor="NethServer"

EXPOSE 20000 20001
WORKDIR /
CMD ["/usr/bin/supervisord", "--nodaemon", "-c", "/etc/supervisord.conf"]
