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
check 'procd finished init' yes "$(grep -aq 'init complete' "$serial" && echo yes || echo no)"

echo "== 网络"
tcp_open() { lan timeout 5 bash -c "echo > /dev/tcp/$LAN_ROUTER/$1" 2> /dev/null && echo open || echo closed; }
check 'ping the LAN address' ok "$(lan ping -c 3 -W 2 "$LAN_ROUTER" > /dev/null 2>&1 && echo ok || echo failed)"
check 'SSH port from the LAN' open "$(tcp_open 22)"
check 'no web interface in the stock image' closed "$(tcp_open 80)"
