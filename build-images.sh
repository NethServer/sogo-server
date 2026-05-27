#!/bin/bash

#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Thin CI wrapper around the multi-stage Dockerfile. The actual build logic,
# the from-source compilation (no AUR) and the runtime self-check all live in
# ./Dockerfile, so the local `podman build` and this CI path are guaranteed
# equivalent (single source of truth). This script only adds the NethServer
# image naming and the GitHub Actions output contract.

# Terminate on error
set -e

# Upstream versions (single place to bump). Forwarded to the Dockerfile as
# build args; the tarball URLs and the runtime version-parity self-check all
# derive from these. Override via the environment if needed.
libwbxml_version="0.11.10"
sope_version="5.12.9"
sogo_version="5.12.9"

# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/nethserver}"
reponame="sogo-server"

# Build the image from the Dockerfile. The Dockerfile's RUN self-check aborts
# the build (non-zero exit) if any library, file, apache module/directive or
# version check fails, so a broken image can never be committed here.
buildah build \
    --build-arg LIBWBXML_VERSION="${libwbxml_version}" \
    --build-arg SOPE_VERSION="${sope_version}" \
    --build-arg SOGO_VERSION="${sogo_version}" \
    --tag "${repobase}/${reponame}" \
    --file Dockerfile \
    .

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
