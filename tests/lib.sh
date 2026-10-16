# shellcheck shell=bash
# Helpers sourced by the verify-*.sh tests, which run an extracted image's
# real init tools in chroot copies of it, as root on x86-64 Linux. The input
# rootfs is never changed.
set -euo pipefail

[[ $# == 1 && -x $1/bin/config_generate ]] || {
    echo "usage: $0 extracted-rootfs" >&2
    exit 2
}
base=$(realpath "$1")
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Make $root a fresh copy of the rootfs named $1 with the overlay in files/,
# as on a new system: no board description, network or system configuration.
new_root() {
    root="$work/$1"
    mkdir -p "$root"
    cp -a "$base/." "$project_dir/files/." "$root/"
    rm -f "$root/etc/board.json" "$root/etc/config/network" "$root/etc/config/system"
    mkdir -p "$root/tmp/.uci" "$root/tmp/sysinfo" "$root/sys/class/net"
}
# A wired port with a driver, as board detection sees it, unplugged.
physical_port() {
    mkdir -p "$root/sys/class/net/$1/device"
    printf '1\n' > "$root/sys/class/net/$1/type"
    printf '0\n' > "$root/sys/class/net/$1/carrier"
}
# Fail unless UCI option $1 is $2; an absent option reads as empty.
expect() {
    local actual
    actual=$(chroot "$root" /sbin/uci -q get "$1" || true)
    [[ $actual == "$2" ]] || {
        echo "FAIL: ${root##*/}: $1 expected [$2], got [$actual]" >&2
        exit 1
    }
}
