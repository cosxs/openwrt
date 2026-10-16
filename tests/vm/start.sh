#!/usr/bin/env bash
# Start the firmware under QEMU with UEFI, an NVMe disk and two Intel e1000e
# NICs: eth0 = WAN via user-mode NAT, eth1 = LAN bridged to a client in
# network namespace "lanc". Uses KVM when the host offers it.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ip netns add lanc 2> /dev/null || true
ip link show br-lantest > /dev/null 2>&1 || ip link add br-lantest type bridge
ip link set br-lantest up
ip link show tap-owrt > /dev/null 2>&1 || ip tuntap add dev tap-owrt mode tap
ip link set tap-owrt master br-lantest up
if ! ip link show veth-h > /dev/null 2>&1; then
    ip link add veth-h type veth peer name veth-c
    ip link set veth-c netns lanc
fi
ip link set veth-h master br-lantest up
ip netns exec lanc ip link set lo up
ip netns exec lanc ip link set veth-c address 52:54:00:00:01:01 up
# The dedicated test namespace may remain from a previous baseline run.
ip netns exec lanc ip -4 addr flush dev veth-c
ip netns exec lanc ip addr add 192.168.72.2/24 dev veth-c

if [ -w /dev/kvm ]; then
    accel=(-accel kvm -cpu host)
else
    # shellcheck disable=SC2054 # the commas belong to the QEMU option
    accel=(-accel tcg,thread=multi -cpu max)
fi
rm -f "$VM_WORK/serial.log" "$VM_WORK/console.sock"
wan=user,id=wan
for forward in "$WAN_SSH:22" "$WAN_HTTP:80" "$WAN_TTYD:7681"; do
    wan+=",hostfwd=tcp:127.0.0.1:${forward%:*}-:${forward#*:}"
done
wan+=",hostfwd=udp:127.0.0.1:$WAN_WG-:51820"
qemu-system-x86_64 -machine q35 "${accel[@]}" -smp 2 -m 2048 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VM_WORK/ovmf_vars.fd" \
    -drive file="$VM_WORK/disk.raw",if=none,id=nvm,format=raw \
    -device nvme,serial=VMTEST,drive=nvm \
    -netdev "$wan" \
    -device e1000e,netdev=wan,mac=52:54:00:00:00:10 \
    -netdev tap,id=lan,ifname=tap-owrt,script=no,downscript=no \
    -device e1000e,netdev=lan,mac=52:54:00:00:00:11 \
    -display none \
    -chardev socket,id=console,path="$VM_WORK/console.sock",server=on,wait=off,logfile="$VM_WORK/serial.log" \
    -serial chardev:console \
    -daemonize -pidfile "$VM_WORK/qemu.pid"
echo "qemu pid $(cat "$VM_WORK/qemu.pid") (${accel[1]%%,*})"
