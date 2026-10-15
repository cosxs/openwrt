#!/usr/bin/env bash
# Runs inside the ImageBuilder container and builds the official profile with
# its default packages and no overlay. With MANIFEST_ONLY=1, prints the
# resolved package manifest on stdout instead of building the image.
set -euo pipefail

cd /builder
if [[ ! -d scripts ]]; then
    ./setup.sh >&2
fi

if ! grep -q '^CONFIG_SIGNATURE_CHECK=y$' .config; then
    echo 'The official ImageBuilder must have signature checking enabled.' >&2
    exit 1
fi

if [[ ${MANIFEST_ONLY:-} == 1 ]]; then
    make manifest PROFILE="$OPENWRT_PROFILE" | grep -E '^[^ ]+ - [^ ]+$'
    exit
fi

make info
make image PROFILE="$OPENWRT_PROFILE"
