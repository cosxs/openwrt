#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 && -f "$1" ]] || {
    echo "Usage: $0 path/to/*-squashfs-rootfs.img.gz" >&2
    exit 2
}
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$project_dir/profiles/n100.env"
image_dir=$(cd "$(dirname "$1")" && pwd)
image_name=$(basename "$1")

docker run --rm --platform linux/amd64 --user root --network none \
    --env "VERIFY_IMAGE=$image_name" \
    --env "SINGBOX_VERSION=$SINGBOX_VERSION" \
    --env "ARGON_VERSION=$ARGON_VERSION" \
    --mount "type=bind,source=$image_dir,target=/input,readonly" \
    --mount "type=bind,source=$project_dir,target=/work,readonly" \
    "$IMAGEBUILDER_IMAGE" /bin/bash -euo pipefail -c '
        gzip -dc "/input/$VERIFY_IMAGE" > /tmp/rootfs.img
        /builder/staging_dir/host/bin/unsquashfs4 \
            -d /tmp/inspect-root /tmp/rootfs.img > /tmp/unsquashfs.log
        test -x /tmp/inspect-root/etc/board.d/03-defaults
        sh /work/tests/verify-rootfs.sh /tmp/inspect-root
        test "$(chroot /tmp/inspect-root /sbin/uci -q get nikki.config.enabled)" = 0
        chroot /tmp/inspect-root /usr/libexec/mihomo -v
        echo "PASS: actual image contains disabled Nikki and stable Mihomo"
        test -n "$(find /tmp/inspect-root/lib/modules -name tcp_bbr.ko)"
        grep -qx "net.ipv4.tcp_congestion_control=bbr" \
            /tmp/inspect-root/etc/sysctl.d/12-tcp-bbr.conf
        echo "PASS: actual image contains the BBR module and selects it by default"
        test "$(chroot /tmp/inspect-root /sbin/uci -q get sing-box.main.enabled)" = 0
        singbox_version=$(chroot /tmp/inspect-root /usr/bin/sing-box version)
        grep -qx "sing-box version $SINGBOX_VERSION" <<< "$singbox_version"
        echo "PASS: actual image contains disabled sing-box $SINGBOX_VERSION"
        chroot /tmp/inspect-root /usr/sbin/tailscale version
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-tailscale-community.json
        echo "PASS: actual image contains Tailscale and its LuCI page"
        chroot /tmp/inspect-root /usr/bin/dockerd --version
        chroot /tmp/inspect-root /usr/bin/docker --version
        chroot /tmp/inspect-root /usr/bin/docker-compose version
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-dockerman.json
        echo "PASS: actual image contains Docker, Compose and the Docker LuCI page"
        test -x /tmp/inspect-root/usr/lib/ddns/update_cloudflare_com_v4.sh
        test -f /tmp/inspect-root/usr/share/ddns/default/cloudflare.com-v4.json
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-ddns.json
        echo "PASS: actual image contains DDNS with the Cloudflare provider and its LuCI page"
        grep -A1 -x "P:luci-theme-argon" /tmp/inspect-root/lib/apk/db/installed |
            grep -qx "V:$ARGON_VERSION"
        echo "PASS: actual image contains the Argon $ARGON_VERSION LuCI theme"
    ' 2>&1 | tee "$image_dir/verification.log"

