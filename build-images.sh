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

# ─── Build image ───────────────────────────────────────────────────────────────
# Uses the Dockerfile multi-stage build (podman layer cache speeds up local builds).
# podman and buildah share the same storage, so buildah push works on the result.
podman build \
    --build-arg VERSION=${version} \
    --build-arg LIBWBXML_VERSION=${libwbxml_version} \
    -t "${repobase}/${reponame}" .

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
