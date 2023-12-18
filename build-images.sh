#!/bin/bash

#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

# Terminate on error
set -e
archlinux_version=latest
#visit URL to get the sha
#https://aur.archlinux.org/packages/sogo/
#https://aur.archlinux.org/packages/sope/
#https://aur.archlinux.org/packages/libwbxml
# target is 5.9.0
sogo_sha=8ddd1c71533f467d96ffb40de505f6b4f92e6b73
sope_sha=eda96a978808a9035eeeaf0bfd7ec6d4cf6c2bdc
libwbxml_sha=68fd1910beae7e866815dbeafda7fbd76feab44d 
# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/nethserver}"

#Create sogo-server container
reponame="sogo-server"
container=$(buildah from docker.io/library/archlinux:${archlinux_version})
buildah config --env SOGO_SHA=${sogo_sha} --env SOPE_SHA=${sope_sha} --env LIBWBXML_SHA=${libwbxml_sha} "${container}"
buildah run "${container}" /bin/sh <<'EOF'
set -e
pacman --noconfirm --needed -Syu && \
    pacman --noconfirm --needed -S base-devel git supervisor apache zip inetutils libsodium libzip libytnef cronie && yes | pacman -Sccq && \
    sed 's/.*MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' -i /etc/makepkg.conf && \
    sed 's/^# \(%wheel.*NOPASSWD.*\)/\1/' -i /etc/sudoers &&  \
    useradd -r build -G wheel && \
    mkdir /build
(
    cd /build
    git clone https://aur.archlinux.org/libwbxml.git
    cd /build/libwbxml
    git checkout -b ns8-build ${LIBWBXML_SHA}
    chown -R build /build/libwbxml
    sudo -u build makepkg -is --noconfirm && rm -rf /build/libwbxml && yes | pacman -Sccq
)
(
    cd /build
    git clone https://aur.archlinux.org/sope.git
    cd /build/sope
    git checkout -b ns8-build ${SOPE_SHA}
    chown -R build /build/sope
    sudo -u build makepkg -is --noconfirm && rm -rf /build/sope && yes | pacman -Sccq
)
(
    cd /build
    git clone https://aur.archlinux.org/sogo.git
    cd /build/sogo
    git checkout -b ns8-build ${SOGO_SHA}
    chown -R build /build/sogo
    sudo -u build makepkg -is --noconfirm && rm -rf /build/sogo && yes | pacman -Sccq
)
mkdir /var/run/sogo && chown sogo:sogo /var/run/sogo
mkdir /var/spool/sogo && chown sogo:sogo /var/spool/sogo

# download backup script
curl -o /usr/lib/sogo/scripts/sogo-backup.sh https://raw.githubusercontent.com/Alinto/sogo/master/Scripts/sogo-backup.sh
chmod 755 /usr/lib/sogo/scripts/sogo-backup.sh

# clean up
pacman --noconfirm -Rcns base-devel git && yes | pacman -Sccq && rm -rf /tmp/* /var/tmp/* /var/cache/pacman/* /build
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
