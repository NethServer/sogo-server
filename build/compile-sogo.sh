#!/bin/bash
#
# Copyright (C) 2026 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builder-stage script: compile libwbxml -> SOPE -> SOGo directly from the
# upstream source tarballs (no AUR / no makepkg), with exact PKGBUILD parity
# (same seds, same ./configure flags, --enable-mfa). Installs both into / (so
# each component links against the previous one) and into /staging (the tree
# carried to the runtime stage). Kept as a COPY+RUN script because the CI
# buildah does not support Dockerfile heredocs.
#
# Expects these env vars (Dockerfile ARGs, exported into RUN):
#   LIBWBXML_VERSION LIBWBXML_URL SOPE_URL SOGO_VERSION SOGO_URL
set -ex

# Parallel compilation on all cores (parity with what the AUR got via makepkg.conf)
export MAKEFLAGS="-j$(nproc)"
mkdir -p /build /staging
# Load the GNUstep build environment (needed by SOPE and SOGo)
source "$(gnustep-config --variable=GNUSTEP_MAKEFILES)/GNUstep.sh"

# --- 1. libwbxml (cmake) ---------------------------------------------------
cd /build
curl -L -o libwbxml.tar.gz "${LIBWBXML_URL}"
tar xf libwbxml.tar.gz
cd "libwbxml-libwbxml-${LIBWBXML_VERSION}"
sed '/AUTHORS/d' -i CMakeLists.txt
mkdir -p build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr
make
make install                       # into / so SOPE/SOGo can link against it
make DESTDIR=/staging install      # staged tree carried to the runtime stage

# --- 2. SOPE ---------------------------------------------------------------
cd /build
curl -L -o sope.tar.gz "${SOPE_URL}"
tar xf sope.tar.gz
cd SOPE
sed 's@NSBIG5StringEncoding@NSBig5StringEncoding@g'         -i sope-mime/NGMime/NGMimeType.m
sed 's@NSGB2312StringEncoding@NSHZ_GB_2312StringEncoding@g' -i sope-mime/NGMime/NGMimeType.m
./configure --with-gnustep --disable-strip --disable-debug
make
make install                       # into / so SOGo can link against it
make install DESTDIR=/staging      # staged tree

# --- 3. SOGo ---------------------------------------------------------------
cd /build
curl -L -o sogo.tar.gz "${SOGO_URL}"
tar xf sogo.tar.gz
cd "SOGo-${SOGO_VERSION}"
./configure --prefix="$(gnustep-config --variable=GNUSTEP_SYSTEM_ROOT)" \
            --disable-debug --enable-mfa
make
make install DESTDIR=/staging
( cd ActiveSync && make install DESTDIR=/staging GNU_SYSTEM_ADMIN_TOOLS=/usr/bin )

# Config files installed manually by the AUR sogo package (staged)
install -D -m 0600 Scripts/sogo.conf   /staging/etc/sogo/sogo.conf
install -D -m 0644 Apache/SOGo.conf    /staging/etc/httpd/conf/extra/SOGo.conf
# Activate the ActiveSync ProxyPass if upstream ships it commented out.
# Recent upstream versions already ship it uncommented; these seds are no-ops in that case.
sed -i -E \
    -e 's/^#(ProxyPass \/Microsoft-Server-ActiveSync)/\1/' \
    -e 's/^# (http:\/\/127\.0\.0\.1:20000\/SOGo\/Microsoft-Server-ActiveSync)/ \1/' \
    -e 's/^# (retry=[^ ]+ connectiontimeout=[^ ]+ timeout=[0-9]+)/ \1/' \
    /staging/etc/httpd/conf/extra/SOGo.conf
install -D -m 0644 Scripts/logrotate   /staging/etc/logrotate.d/sogo
install -d -m 0755                      /staging/usr/lib/sogo/scripts
install    -m 0755 Scripts/sql-*.sh    /staging/usr/lib/sogo/scripts/

# Backup script (kept from the previous build-images.sh)
curl -L -o /staging/usr/lib/sogo/scripts/sogo-backup.sh \
    https://raw.githubusercontent.com/Alinto/sogo/master/Scripts/sogo-backup.sh
chmod 755 /staging/usr/lib/sogo/scripts/sogo-backup.sh
