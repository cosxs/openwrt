#!/usr/bin/env bash
# Check the contents of a built image: the extracted root file system must be
# the pinned OpenWrt release for the pinned target and carry exactly the
# packages of the resolved manifest.
# Usage: scripts/verify-image.sh path/to/*-squashfs-rootfs.img.gz
set -euo pipefail

[[ $# == 1 && -f "$1" ]] || {
    echo "Usage: $0 path/to/*-squashfs-rootfs.img.gz" >&2
    exit 2
}
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$project_dir/profiles/build.env"
image_dir=$(cd "$(dirname "$1")" && pwd)
image_name=$(basename "$1")
manifests=("$image_dir"/*.manifest)
[[ ${#manifests[@]} == 1 && -f ${manifests[0]} ]] || {
    echo "expected exactly one *.manifest next to the image" >&2
    exit 1
}

docker run --rm --platform linux/amd64 --user root --network none \
    --env "VERIFY_IMAGE=$image_name" \
    --env "OPENWRT_VERSION=$OPENWRT_VERSION" \
    --env "OPENWRT_TARGET=$OPENWRT_TARGET" \
    --env "MANIFEST=$(basename "${manifests[0]}")" \
    --mount "type=bind,source=$image_dir,target=/input,readonly" \
    "$IMAGEBUILDER_IMAGE" /bin/bash -euo pipefail -c '
        gzip -dc "/input/$VERIFY_IMAGE" > /tmp/rootfs.img
        /builder/staging_dir/host/bin/unsquashfs4 \
            -d /tmp/inspect-root /tmp/rootfs.img > /tmp/unsquashfs.log
        release=/tmp/inspect-root/etc/openwrt_release
        grep -qx "DISTRIB_RELEASE=.$OPENWRT_VERSION." "$release"
        grep -qx "DISTRIB_TARGET=.$OPENWRT_TARGET." "$release"
        echo "PASS: the image is OpenWrt $OPENWRT_VERSION for $OPENWRT_TARGET"
        test -x /tmp/inspect-root/sbin/init
        test -x /tmp/inspect-root/sbin/procd
        test -x /tmp/inspect-root/usr/sbin/dropbear
        echo "PASS: the image has init, procd and dropbear"
        awk "/^P:/ {p = substr(\$0, 3)} /^V:/ {print p, \"-\", substr(\$0, 3)}" \
            /tmp/inspect-root/lib/apk/db/installed | LC_ALL=C sort > /tmp/installed.txt
        grep -E "^[^ ]+ - [^ ]+$" "/input/$MANIFEST" | LC_ALL=C sort > /tmp/manifest.txt
        diff /tmp/manifest.txt /tmp/installed.txt
        echo "PASS: the installed packages are exactly the resolved manifest"
    ' 2>&1 | tee "$image_dir/verification.log"
