#!/usr/bin/env bash
# Check the contents of a built image in the ImageBuilder container: the
# extracted root file system must be the pinned OpenWrt release for the pinned
# target and carry exactly the packages of the resolved manifest.
# Usage: scripts/verify-image.sh path/to/*-squashfs-rootfs.img.gz
set -euo pipefail

[[ $# == 1 && -f "$1" ]] || {
    echo "Usage: $0 path/to/*-squashfs-rootfs.img.gz" >&2
    exit 2
}
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile_file="$project_dir/profiles/build.env"
source "$profile_file"
image_dir=$(cd "$(dirname "$1")" && pwd)
manifests=("$image_dir"/*.manifest)
[[ ${#manifests[@]} == 1 && -f ${manifests[0]} ]] || {
    echo "expected exactly one *.manifest next to the image" >&2
    exit 1
}

# unsquashfs needs root for the device nodes and file ownership of the rootfs.
docker run --rm --platform linux/amd64 --user root --network none \
    --env-file "$profile_file" \
    --env "IMAGE=$(basename "$1")" \
    --env "MANIFEST=$(basename "${manifests[0]}")" \
    --mount "type=bind,source=$image_dir,target=/input,readonly" \
    --mount "type=bind,source=$project_dir,target=/work,readonly" \
    "$IMAGEBUILDER_IMAGE" /bin/bash /work/scripts/verify-rootfs.sh \
    2>&1 | tee "$image_dir/verification.log"
