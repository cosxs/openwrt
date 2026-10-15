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
    --env "NEXTTRACE_VERSION=$NEXTTRACE_VERSION" \
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
        cp /work/docs/sing-box/config.json /tmp/inspect-root/tmp/sing-box-template.json
        chroot /tmp/inspect-root /usr/bin/sing-box check -c /tmp/sing-box-template.json
        echo "PASS: the sing-box template in docs passes sing-box check"
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
        test -z "$(chroot /tmp/inspect-root /sbin/uci -q get ttyd.@ttyd[0].interface)"
        test "$(chroot /tmp/inspect-root /sbin/uci -q get ttyd.@ttyd[0].command)" = /bin/login
        echo "PASS: actual image contains ttyd and its LuCI page, and ttyd is not bound to one interface"
        test -x /tmp/inspect-root/usr/lib/ddns/update_cloudflare_com_v4.sh
        test -f /tmp/inspect-root/usr/share/ddns/default/cloudflare.com-v4.json
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-ddns.json
        test "$(chroot /tmp/inspect-root /sbin/uci -q get ddns.global.upd_privateip)" = 0
        test -z "$(chroot /tmp/inspect-root /sbin/uci -q show ddns | grep "=service$")"
        echo "PASS: actual image contains DDNS with the Cloudflare provider, its LuCI page and no example services"
        test -x /tmp/inspect-root/usr/sbin/miniupnpd
        for nft in table-post chain-post/dstnat chain-post/forward chain-post/srcnat; do
            test -f "/tmp/inspect-root/usr/share/nftables.d/$nft/20-miniupnpd.nft"
        done
        test "$(chroot /tmp/inspect-root /sbin/uci -q get upnpd.config.enabled)" = 0
        test -f /tmp/inspect-root/usr/share/luci/menu.d/luci-app-upnp.json
        echo "PASS: actual image contains disabled miniupnpd for nftables and its LuCI page"
        test -x /tmp/inspect-root/usr/sbin/mtr
        test -x /tmp/inspect-root/usr/sbin/mtr-packet
        test -x /tmp/inspect-root/usr/bin/iperf3
        echo "PASS: actual image contains mtr and iperf3"
        test -x /tmp/inspect-root/usr/bin/nexttrace
        chroot /tmp/inspect-root /usr/bin/nexttrace --version | grep -q "$NEXTTRACE_VERSION"
        echo "PASS: actual image contains nexttrace $NEXTTRACE_VERSION"
        grep -qx "P:luci-theme-footstrap" /tmp/inspect-root/lib/apk/db/installed
        test -f /tmp/inspect-root/www/luci-static/footstrap/cascade.css
        echo "PASS: actual image contains the Footstrap LuCI theme from the official feed"
        for lmo in base firewall package-manager dockerman ttyd ddns upnp; do
            test -f "/tmp/inspect-root/usr/lib/lua/luci/i18n/$lmo.zh-cn.lmo"
        done
        echo "PASS: actual image contains the Chinese translations of every LuCI page"
    ' 2>&1 | tee "$image_dir/verification.log"

