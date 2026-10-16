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
check 'LuCI over HTTPS' open "$(tcp_open 443)"

echo "== 存储与服务（串口控制台）"
check 'system timezone' CST-8 "$(console 'uci -q get system.@system[0].timezone')"
check 'system zone name' Asia/Shanghai "$(console 'uci -q get system.@system[0].zonename')"
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

echo "== WAN 侧管理"
# The first bytes SSH sends, or nothing when the connection is refused.
wan_ssh() {
    timeout 10 bash -c "exec 3<> /dev/tcp/127.0.0.1/$WAN_SSH && head -c 7 <&3" 2> /dev/null
}
# The HTTP status of a WAN-side request, 000 when the connection is refused.
wan_http() {
    curl -sk -o /dev/null -m 20 -w '%{http_code}' "$1" 2> /dev/null
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
    check "LuCI over HTTPS from the WAN side$1" "$3" "$(wan_http "https://127.0.0.1:$WAN_HTTPS/")"
    check "LuCI over HTTP from the WAN side$1" "$4" "$(wan_http "http://127.0.0.1:$WAN_HTTP/")"
    check "ttyd from the WAN side$1" "$5" "$(wan_http "http://127.0.0.1:$WAN_TTYD/")"
}
check 'WAN admin set after boot' 10.0.2.0/24 "$(wait_set 10.0.2.0/24)"
check 'WAN admin rule is IPv4 only' '1 0' \
    "$(console 'nft list chain inet fw4 input_wan | grep Allow-Admin | grep -c "ip saddr @wan_admin_subnet"; nft list chain inet fw4 input_wan | grep -c "ip6.*Allow-Admin"' | xargs)"
check 'ttyd from the LAN' 200 \
    "$(lan curl -s -o /dev/null -m 20 -w '%{http_code}' "http://$LAN_ROUTER:7681/")"
wan_access '' SSH-2.0 200 200 200
console 'ifdown wan' > /dev/null
check 'WAN admin set with the WAN down' '' "$(wait_set '')"
wan_access ' with the WAN down' '' 000 000 000
console 'ifup wan' > /dev/null
check 'WAN admin set restored by the WAN coming up' 10.0.2.0/24 "$(wait_set 10.0.2.0/24)"
wan_access ' after the WAN came up again' SSH-2.0 200 200 200
