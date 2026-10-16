#!/usr/bin/env bash
# Keep-settings sysupgrade with the same image: choices a user made after the
# first boot, the root password and the data partition must survive, while
# the first-boot defaults run again without overriding them. The router
# downloads the image from a local web server through QEMU's user-mode WAN,
# where 10.0.2.2 is the host. Failed checks are recorded in $VM_WORK/failures.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
image=$(realpath "$1")
serial=$VM_WORK/serial.log
port=28080
wait_for_router 300 || exit 1

echo "== 升级前：做出用户自己的选择"
console 'uci set system.@system[0].hostname=kept-host && uci commit system' > /dev/null
console "uci set firewall.@defaults[0].flow_offloading=0 && uci set firewall.@defaults[0].synflood_protect=1 && uci add_list firewall.wan_admin_subnet.entry=10.31.0.0/16 && uci commit firewall" > /dev/null
console "uci set 'ttyd.@ttyd[0].interface=@lan' && uci commit ttyd" > /dev/null
console "sed -i 's|^root:[^:]*:|root:kept-password-hash:|' /etc/shadow" > /dev/null
console 'echo kept > /data/marker' > /dev/null
wg_key_before=$(console 'wg show wireguard public-key')

echo "== 下载固件并执行保留配置的 sysupgrade"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "${image%/*}" > /dev/null 2>&1 &
server=$!
trap 'kill "$server" 2> /dev/null' EXIT
sleep 1
console "wget -q -O /tmp/fw.img.gz http://10.0.2.2:$port/${image##*/} && sysupgrade -T /tmp/fw.img.gz && echo image-ok"
lines_before=$(wc -l < "$serial")
boots_before=$(grep -ac 'Linux version' "$serial")
# The console shell ends with the old system, so run the upgrade detached.
console '{ (sleep 2; sysupgrade -v /tmp/fw.img.gz) > /dev/null 2>&1 & }' > /dev/null
for _ in $(seq 120); do
    [ "$(grep -ac 'Linux version' "$serial")" -gt "$boots_before" ] && break
    sleep 5
done
wait_for_router 900 || { tail -n +"$lines_before" "$serial" | tail -40; exit 1; }
echo "== 串口中的升级记录"
tail -n +"$lines_before" "$serial" | grep -aiE "upgrade|saving|restor|partition|Linux version" | head -12

echo "== 升级后"
check 'rebooted once' "$((boots_before + 1))" "$(grep -ac 'Linux version' "$serial")"
check 'downloaded image gone from /tmp' gone \
    "$(console '[ -e /tmp/fw.img.gz ] && echo present || echo gone')"
check 'first-boot defaults all ran' '' "$(console 'ls /etc/uci-defaults' | xargs)"
check 'hostname kept' kept-host "$(console 'uci -q get system.@system[0].hostname')"
check 'timezone kept' 'CST-8 Asia/Shanghai' \
    "$(console 'uci -q get system.@system[0].timezone; uci -q get system.@system[0].zonename' | xargs)"
check 'root password kept' kept-password-hash "$(console "grep '^root:' /etc/shadow | cut -d : -f 2")"
check 'LAN kept' '192.168.72.1/24 eth1' \
    "$(console 'uci -q get network.lan.ipaddr; uci -q get network.@device[0].ports' | xargs)"
check 'flow offloading kept off' 0 "$(console 'uci -q get firewall.@defaults[0].flow_offloading')"
check 'SYN rate limit kept on' 1 "$(console 'uci -q get firewall.@defaults[0].synflood_protect')"
check 'one WAN admin rule kept' 1 "$(console "uci -q show firewall | grep -c '^firewall\.wan_admin=rule'")"
check 'WAN admin set entry kept' 10.31.0.0/16 "$(console 'uci -q get firewall.wan_admin_subnet.entry')"
check 'WAN admin set holds the entry and the WAN subnet' '10.0.2.0/24 10.31.0.0/16' \
    "$(console 'nft list set inet fw4 wan_admin_subnet' | sed -n 's/.*elements = { \(.*\) }.*/\1/p' |
        tr -d , | xargs -n 1 | sort | xargs)"
check 'ttyd kept on the LAN only' @lan "$(console 'uci -q get ttyd.@ttyd[0].interface')"
check 'sing-box still off' 0 "$(console 'uci -q get sing-box.main.enabled')"
check 'fstab has one data mount and one swap' '1 1' \
    "$(console "uci -q show fstab | grep -c \"\.target='/data'\"; uci -q show fstab | grep -c \"\.label='swap'\"" | xargs)"
check 'data marker kept' kept "$(console 'cat /data/marker')"
check '/data mounted from the data partition' '/dev/nvme0n1p4 ext4' \
    "$(console "awk '\$2 == \"/data\" {print \$1, \$3}' /proc/mounts")"
check 'swap in use' '/dev/nvme0n1p3 partition' \
    "$(console "awk 'NR == 2 {print \$1, \$2}' /proc/swaps")"
check 'WireGuard key kept' "$wg_key_before" "$(console 'wg show wireguard public-key')"
check 'WireGuard peer kept' 10.66.66.2/32 "$(console 'uci -q get network.vmtest.allowed_ips')"
check 'ping the router through the tunnel after the upgrade' ok \
    "$(ip netns exec wgc ping -c 3 -W 3 10.66.66.1 > /dev/null 2>&1 && echo ok || echo failed)"
