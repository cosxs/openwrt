# shellcheck shell=bash disable=SC2034 # its variables serve the callers
# Helpers sourced by the VM test scripts, which run as root. The router is
# reached from a client in network namespace "lanc" on the default LAN
# address. The upstream ttylogin default leaves the serial console available
# as a root shell, independently of the root password used for network login.
VM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VM_WORK=${VM_WORK:-/var/tmp/openwrt-vm}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
LAN_ROUTER=192.168.72.1
# Host ports that QEMU forwards to the router's WAN address. The forwarded
# connections reach the router from 10.0.2.2, inside the WAN's own 10.0.2.0/24.
WAN_SSH=20022
WAN_HTTP=20080
WAN_TTYD=27681

# Run a command in the VM through the serial console and print its output.
console() {
    python3 "$VM_DIR/console.py" "$VM_WORK/console.sock" "$1"
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
# Wait until the router answers ping from the LAN client, up to $1 seconds.
wait_for_router() {
    local limit=$1 start
    start=$(date +%s)
    while [ $(( $(date +%s) - start )) -lt "$limit" ]; do
        if lan ping -c 1 -W 2 "$LAN_ROUTER" > /dev/null 2>&1; then
            echo "router reachable after $(( $(date +%s) - start ))s"
            return 0
        fi
        sleep 5
    done
    echo "FAIL: router not reachable within ${limit}s"
    fail_check "router reachable within ${limit}s"
    return 1
}
