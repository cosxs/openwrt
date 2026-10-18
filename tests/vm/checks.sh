#!/usr/bin/env bash
# First-boot checks of the baseline image, driven from the LAN client. Failed
# checks are recorded in $VM_WORK/failures.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
serial=$VM_WORK/serial.log
wait_for_router "${1:-600}" || exit 1

echo "== 启动"
check 'kernel panic in the serial log' 0 "$(grep -aci 'kernel panic' "$serial")"
check 'booted from UEFI' yes "$(grep -aq 'EFI v' "$serial" && echo yes || echo no)"
check 'userspace init started' yes "$(grep -aq 'init: Console is alive' "$serial" && echo yes || echo no)"

echo "== 网络"
# The web server and its first-boot certificate can lag behind SSH: retry for
# up to a minute.
tcp_open() {
    for _ in $(seq 12); do
        lan timeout 5 bash -c "echo > /dev/tcp/$LAN_ROUTER/$1" 2> /dev/null && { echo open; return; }
        sleep 5
    done
    echo closed
}
check 'ping the LAN address' ok "$(lan ping -c 3 -W 2 "$LAN_ROUTER" > /dev/null 2>&1 && echo ok || echo failed)"
check 'SSH port from the LAN' open "$(tcp_open 22)"
check 'LuCI over HTTP' open "$(tcp_open 80)"
# Without a certificate generator, uhttpd leaves HTTPS off; uhttpd is up by now.
check 'no HTTPS on the LAN' closed \
    "$(lan timeout 5 bash -c "echo > /dev/tcp/$LAN_ROUTER/443" 2> /dev/null && echo open || echo closed)"

echo "== 存储与服务（串口控制台）"
check 'system timezone' CST-8 "$(console 'uci -q get system.@system[0].timezone')"
check 'system zone name' Asia/Shanghai "$(console 'uci -q get system.@system[0].zonename')"
check 'time servers' 'ntp.aliyun.com ntp.tencent.com ntp.tuna.tsinghua.edu.cn time.ustc.edu.cn' \
    "$(console 'uci -q get system.ntp.server')"
check 'ntpd uses the first time server' 1 "$(console 'ps w | grep -c "[n]tpd .*-p ntp.aliyun.com"')"
check 'WAN device' eth0 "$(console 'uci -q get network.wan.device')"
check 'WAN protocol' dhcp "$(console 'uci -q get network.wan.proto')"
check 'LAN device' br-lan "$(console 'uci -q get network.lan.device')"
check 'LAN bridge ports' eth1 "$(console 'uci -q get network.@device[0].ports')"
check 'LAN DHCP server' server "$(console 'uci -q get dhcp.lan.dhcpv4')"
check 'flow offloading' 1 "$(console 'uci -q get firewall.@defaults[0].flow_offloading')"
check 'flow table in the ruleset' 1 "$(console 'nft list flowtables inet | grep -c "flowtable ft"')"
check 'no SYN rate limit on the input chain' 0 \
    "$(console 'nft list chain inet fw4 input | grep -c syn_flood')"
check 'root password initialized' set \
    "$(console 'grep -Eq "^root:[$]6[$]" /etc/shadow && echo set || echo unset')"
check '/data mounted from the data partition' '/dev/nvme0n1p4 ext4' \
    "$(console "awk '\$2 == \"/data\" {print \$1, \$3}' /proc/mounts")"
check 'swap in use' '/dev/nvme0n1p3 partition' \
    "$(console "awk 'NR == 2 {print \$1, \$2}' /proc/swaps")"
check 'sing-box enabled in UCI' 0 "$(console 'uci -q get sing-box.main.enabled')"
check 'sing-box running' no "$(console 'pidof sing-box > /dev/null && echo yes || echo no')"
check 'DDNS sections' global \
    "$(console "uci -q show ddns | sed -n 's/^ddns\\.\\([^.=]*\\)=.*/\\1/p' | xargs")"
check 'DDNS service enabled' yes "$(console '/etc/init.d/ddns enabled && echo yes || echo no')"
check 'Cloudflare DDNS provider' yes \
    "$(console '[ -f /usr/share/ddns/default/cloudflare.com-v4.json ] && echo yes || echo no')"
tcp_keys=(net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_notsent_lowat net.core.netdev_max_backlog
    net.ipv4.tcp_congestion_control)
check 'TCP tuning in effect' \
    '33554432 23298048 4096 131072 33554432 4096 16384 23298048 0 1 4096 4000 bbr' \
    "$(console "sysctl -n ${tcp_keys[*]}" | xargs)"

echo "== WAN 侧管理"
# The first bytes SSH sends, or nothing when the connection is refused.
wan_ssh() {
    timeout 10 bash -c "exec 3<> /dev/tcp/127.0.0.1/$WAN_SSH && head -c 7 <&3" 2> /dev/null
}
# The HTTP status of a WAN-side request, 000 when the connection is refused.
wan_http() {
    curl -s -o /dev/null -m 20 -w '%{http_code}' "$1" 2> /dev/null
}
wan_set() {
    console 'nft list set inet fw4 wan_admin_subnet' | sed -n 's/.*elements = { \(.*\) }.*/\1/p'
}
# Wait up to a minute for the set to hold $1.
wait_set() {
    local set
    for _ in $(seq 12); do
        set=$(wan_set)
        [ "$set" = "$1" ] && break
        sleep 5
    done
    echo "$set"
}
wan_access() {
    check "SSH from the WAN side$1" "$2" "$(wan_ssh)"
    check "LuCI from the WAN side$1" "$3" "$(wan_http "http://127.0.0.1:$WAN_HTTP/")"
    check "ttyd from the WAN side$1" "$4" "$(wan_http "http://127.0.0.1:$WAN_TTYD/")"
}
check 'WAN admin set after boot' 10.0.2.0/24 "$(wait_set 10.0.2.0/24)"
check 'WAN admin rule is IPv4 only' '1 0' \
    "$(console 'nft list chain inet fw4 input_wan | grep Allow-Admin | grep -c "ip saddr @wan_admin_subnet"; nft list chain inet fw4 input_wan | grep -c "ip6.*Allow-Admin"' | xargs)"
check 'ttyd from the LAN' 200 \
    "$(lan curl -s -o /dev/null -m 20 -w '%{http_code}' "http://$LAN_ROUTER:7681/")"
wan_access '' SSH-2.0 200 200
console 'ifdown wan' > /dev/null
check 'WAN admin set with the WAN down' '' "$(wait_set '')"
wan_access ' with the WAN down' '' 000 000
console 'ifup wan' > /dev/null
check 'WAN admin set restored by the WAN coming up' 10.0.2.0/24 "$(wait_set 10.0.2.0/24)"
wan_access ' after the WAN came up again' SSH-2.0 200 200

echo "== WireGuard"
check 'WireGuard interface address' 10.66.66.1/24 "$(console 'ip -c=never -4 -o addr show dev wireguard' | awk '{print $4}')"
check 'WireGuard listening port' 51820 "$(console 'wg show wireguard listen-port')"
# A client in network namespace "wgc" reaches the router's "wireguard"
# interface through QEMU's forward of host UDP $WAN_WG to the WAN. The client
# interface is made in the host namespace, where its UDP socket stays, and
# then moved to wgc, which holds its routes.
client_key=$(wg genkey)
router_key=$(console 'wg show wireguard public-key')
console "uci set network.vmtest=wireguard_wireguard && uci set network.vmtest.public_key='$(wg pubkey <<< "$client_key")' && uci add_list network.vmtest.allowed_ips=10.66.66.2/32 && uci commit network && ifup wireguard" > /dev/null
ip netns add wgc 2> /dev/null || true
ip -n wgc link del wg-vm 2> /dev/null || true
ip link del wg-vm 2> /dev/null || true
ip link add wg-vm type wireguard
wg set wg-vm private-key <(echo "$client_key") peer "$router_key" \
    endpoint "127.0.0.1:$WAN_WG" allowed-ips 10.66.66.1/32,192.168.72.0/24 persistent-keepalive 5
ip link set wg-vm netns wgc
ip -n wgc address add 10.66.66.2/32 dev wg-vm
ip -n wgc link set wg-vm up
ip -n wgc route add 10.66.66.1/32 dev wg-vm
ip -n wgc route add 192.168.72.0/24 dev wg-vm
wgc() {
    ip netns exec wgc "$@"
}
check 'ping the router through the tunnel' ok \
    "$(wgc ping -c 3 -W 3 10.66.66.1 > /dev/null 2>&1 && echo ok || echo failed)"
check 'SSH on the LAN address through the tunnel' SSH-2.0 \
    "$(wgc timeout 10 bash -c "exec 3<> /dev/tcp/$LAN_ROUTER/22 && head -c 7 <&3" 2> /dev/null)"
check 'LuCI on the LAN address through the tunnel' 200 \
    "$(wgc curl -s -o /dev/null -m 20 -w '%{http_code}' "http://$LAN_ROUTER/")"
check 'router saw a handshake from the client' 10.0.2.2 \
    "$(console 'wg show wireguard endpoints' | awk '$2 != "(none)" {split($2, a, ":"); print a[1]}')"

