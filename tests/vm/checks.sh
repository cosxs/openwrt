#!/usr/bin/env bash
# First-boot checks of the stock image, driven from the LAN client. Failed
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
# The web server and its first-boot certificate can lag behind SSH: retry for up to a minute.
tcp_open() {
    local i
    for i in $(seq 12); do
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
check '/data mounted from the data partition' '/dev/nvme0n1p4 ext4' \
    "$(console "awk '\$2 == \"/data\" {print \$1, \$3}' /proc/mounts")"
check 'swap in use' '/dev/nvme0n1p3 partition' \
    "$(console "awk 'NR == 2 {print \$1, \$2}' /proc/swaps")"
check 'sing-box enabled in UCI' 0 "$(console 'uci -q get sing-box.main.enabled')"
check 'sing-box running' no "$(console 'pidof sing-box > /dev/null && echo yes || echo no')"
