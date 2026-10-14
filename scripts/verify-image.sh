#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 && -f "$1" ]] || {
    echo "Usage: $0 path/to/*-squashfs-rootfs.img.gz" >&2
    exit 2
}
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$project_dir/profiles/build.env"
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
        test -n "$(find /tmp/inspect-root/lib/modules -name tcp_bbr.ko)"
        grep -qx "net.ipv4.tcp_congestion_control=bbr" \
            /tmp/inspect-root/etc/sysctl.d/12-tcp-bbr.conf
        echo "PASS: actual image contains the BBR module and selects it by default"
        test "$(chroot /tmp/inspect-root /sbin/uci -q get sing-box.main.enabled)" = 0
        singbox_version=$(chroot /tmp/inspect-root /usr/bin/sing-box version)
        grep -qx "sing-box version $SINGBOX_VERSION" <<< "$singbox_version"
        echo "PASS: actual image contains disabled sing-box $SINGBOX_VERSION"
        chroot /tmp/inspect-root /usr/bin/dockerd --version
        chroot /tmp/inspect-root /usr/bin/docker --version
        chroot /tmp/inspect-root /usr/bin/docker-compose version
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-dockerman.json
        test -L /tmp/inspect-root/etc/rc.d/S12dockerd-root-shared
        test -n "$(find /tmp/inspect-root/lib/modules -name nf_conntrack_netlink.ko)"
        echo "PASS: actual image contains Docker, Compose, conntrack netlink, the Docker LuCI page and the enabled data root propagation"
        for applet in mkswap swapon swapoff; do
            test "$(readlink /tmp/inspect-root/sbin/$applet)" = ../bin/busybox
        done
        test -x /tmp/inspect-root/etc/uci-defaults/97-dnsmasq-upstream
        test -x /tmp/inspect-root/etc/uci-defaults/98-swap-mount
        echo "PASS: actual image contains the swap tools, the swap mount default and the dnsmasq upstream default"
        test -x /tmp/inspect-root/usr/bin/ttyd
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-ttyd.json
        echo "PASS: actual image contains ttyd and its LuCI page"
        test -x /tmp/inspect-root/usr/lib/ddns/update_cloudflare_com_v4.sh
        test -f /tmp/inspect-root/usr/share/ddns/default/cloudflare.com-v4.json
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-ddns.json
        test "$(chroot /tmp/inspect-root /sbin/uci -q get ddns.global.upd_privateip)" = 0
        test -z "$(chroot /tmp/inspect-root /sbin/uci -q show ddns | grep "=service$")"
        echo "PASS: actual image contains DDNS with the Cloudflare provider, its LuCI page and no example services"
        grep -A1 -x "P:luci-theme-argon" /tmp/inspect-root/lib/apk/db/installed |
            grep -qx "V:$ARGON_VERSION"
        echo "PASS: actual image contains the Argon $ARGON_VERSION LuCI theme"
        for lmo in base firewall package-manager dockerman ttyd ddns; do
            test -f "/tmp/inspect-root/usr/lib/lua/luci/i18n/$lmo.zh-cn.lmo"
        done
        echo "PASS: actual image contains the Chinese translations of every LuCI page"
    ' 2>&1 | tee "$image_dir/verification.log"

