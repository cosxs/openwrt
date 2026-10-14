#!/usr/bin/env bash
# Start the firmware under QEMU with UEFI, an NVMe disk and four Intel e1000e
# NICs: eth0 = WAN via user-mode NAT (SSH, HTTP and the ttyd terminal forwarded
# to 127.0.0.1:2222, 127.0.0.1:8081 and 127.0.0.1:8083), eth1 = LAN bridged to a client in network namespace
# "lanc", eth2/eth3 = idle LAN ports. The DMI system vendor and product are the
# placeholder "Default", the board fields carry a real name. Uses KVM when the
# host offers it.
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
mkdir -p /etc/netns/lanc
echo 'nameserver 192.168.72.1' > /etc/netns/lanc/resolv.conf
# With br_netfilter loaded (as Docker does), bridged frames traverse FORWARD.
for ipt in iptables ip6tables; do
    $ipt -C FORWARD -i br-lantest -o br-lantest -j ACCEPT 2> /dev/null ||
        $ipt -I FORWARD -i br-lantest -o br-lantest -j ACCEPT
done

if [ -w /dev/kvm ]; then
    accel=(-accel kvm -cpu host)
else
    # shellcheck disable=SC2054 # the commas belong to the QEMU option
    accel=(-accel tcg,thread=multi -cpu max)
fi
rm -f "$VM_WORK/serial.log"
qemu-system-x86_64 -machine q35 "${accel[@]}" -smp 4 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VM_WORK/ovmf_vars.fd" \
    -drive file="$VM_WORK/disk.raw",if=none,id=nvm,format=raw \
    -device nvme,serial=VMTEST,drive=nvm \
    -smbios type=1,manufacturer=Default,product=Default \
    -smbios 'type=2,manufacturer=Example Boards,product=EB-4L' \
    -netdev user,id=wan,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8081-:80,hostfwd=tcp:127.0.0.1:8083-:7681,hostfwd=tcp:127.0.0.1:8082-:30080 \
    -device e1000e,netdev=wan,mac=52:54:00:00:00:10 \
    -netdev tap,id=lan1,ifname=tap-owrt,script=no,downscript=no \
    -device e1000e,netdev=lan1,mac=52:54:00:00:00:11 \
    -netdev hubport,id=lan2,hubid=2 -device e1000e,netdev=lan2,mac=52:54:00:00:00:12 \
    -netdev hubport,id=lan3,hubid=3 -device e1000e,netdev=lan3,mac=52:54:00:00:00:13 \
    -display none -serial file:"$VM_WORK/serial.log" \
    -daemonize -pidfile "$VM_WORK/qemu.pid"
echo "qemu pid $(cat "$VM_WORK/qemu.pid") (${accel[1]%%,*})"
