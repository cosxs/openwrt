#!/usr/bin/env bash
# Runs inside the ImageBuilder container, started by verify-image.sh: extracts
# the root file system of /input/$IMAGE and checks it against the pinned build
# inputs in the environment and the resolved manifest /input/$MANIFEST.
set -euo pipefail

root=/tmp/rootfs
gzip -dc "/input/$IMAGE" > /tmp/rootfs.img
/builder/staging_dir/host/bin/unsquashfs4 -d "$root" /tmp/rootfs.img \
    > /tmp/unsquashfs.log

grep -qx "DISTRIB_RELEASE='$OPENWRT_VERSION'" "$root/etc/openwrt_release"
grep -qx "DISTRIB_TARGET='$OPENWRT_TARGET'" "$root/etc/openwrt_release"
echo "PASS: the image is OpenWrt $OPENWRT_VERSION for $OPENWRT_TARGET"

test -x "$root/sbin/init"
test -x "$root/sbin/procd"
test -x "$root/usr/sbin/dropbear"
echo "PASS: the image has init, procd and dropbear"

awk '/^P:/ {p = substr($0, 3)} /^V:/ {print p, "-", substr($0, 3)}' \
    "$root/lib/apk/db/installed" | LC_ALL=C sort > /tmp/installed.txt
grep -E '^[^ ]+ - [^ ]+$' "/input/$MANIFEST" | LC_ALL=C sort > /tmp/manifest.txt
diff /tmp/manifest.txt /tmp/installed.txt
echo "PASS: the installed packages are exactly the resolved manifest"

grep -Eqx "sing-box - $SINGBOX_VERSION(-r[0-9]+)?" /tmp/installed.txt
echo "PASS: the installed sing-box is the pinned $SINGBOX_VERSION"

grep -Eqx "hako - $HAKO_VERSION(-r[0-9]+)?" /tmp/installed.txt
grep -Eqx "luci-app-hako - $HAKO_VERSION(-r[0-9]+)?" /tmp/installed.txt
echo "PASS: the installed Hako is the pinned $HAKO_VERSION"
