# shellcheck shell=bash
# Helpers sourced by the VM test scripts, which run as root. The router is
# reached from a LAN client in network namespace "lanc", with the firmware's
# documented initial password.
VM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VM_WORK=${VM_WORK:-/var/tmp/openwrt-vm}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
export SSHPASS=159357

vm() {
    ip netns exec lanc sshpass -e ssh -n -q -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@192.168.72.1 "$@"
}
vm_copy() {
    ip netns exec lanc sshpass -e scp -q -O -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$1" "root@192.168.72.1:$2"
}
lan() {
    ip netns exec lanc "$@"
}
fail_check() {
    echo "$1" >> "$VM_WORK/failures"
}
check() {
    local name=$1 expected=$2 actual=$3
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $name = $actual"
    else
        echo "FAIL: $name: expected [$expected], got [$actual]"
        fail_check "$name"
    fi
}
# Wait until the router answers SSH from the LAN, up to $1 seconds.
wait_for_router() {
    local limit=$1 start
    start=$(date +%s)
    while [ $(( $(date +%s) - start )) -lt "$limit" ]; do
        lan busybox udhcpc -i veth-c -n -q -t 3 -T 3 -s "$VM_DIR/lan-dhcp.sh" > /dev/null 2>&1 || true
        if vm true 2> /dev/null; then
            echo "router reachable after $(( $(date +%s) - start ))s"
            return 0
        fi
        sleep 10
    done
    echo "FAIL: router not reachable within ${limit}s"
    fail_check "router reachable within ${limit}s"
    return 1
}
