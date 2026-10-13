#!/usr/bin/env bash
# Full VM test of a combined EFI image, as root: fresh install and first-boot
# checks, then a keep-settings sysupgrade with the same image. Copies the
# serial console log to the optional log directory and exits non-zero when
# any check fails.
# Usage: sudo tests/vm/run.sh path/to/*-squashfs-combined-efi.img.gz [log-dir]
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$#" -ge 1 ] && [ -f "$1" ] || { echo "usage: $0 image.img.gz [log-dir]" >&2; exit 2; }
image=$(realpath "$1")
log_dir=${2:-}

stop_vm() {
    local pid
    [ -f "$VM_WORK/qemu.pid" ] || return 0
    pid=$(cat "$VM_WORK/qemu.pid")
    kill "$pid" 2> /dev/null
    while kill -0 "$pid" 2> /dev/null; do sleep 1; done
    rm -f "$VM_WORK/qemu.pid"
}
finish() {
    stop_vm
    # QEMU creates the serial log as 0640; the copy is for the unprivileged user.
    [ -z "$log_dir" ] || install -m 0644 "$VM_WORK/serial.log" "$log_dir/vm-serial.log" 2> /dev/null || true
}
trap finish EXIT

mkdir -p "$VM_WORK"
rm -f "$VM_WORK/failures"
stop_vm
echo "##### 全新写盘并启动"
"$VM_DIR/prepare.sh" "$image" || exit 1
"$VM_DIR/start.sh" || exit 1
echo "##### 首次启动检查"
"$VM_DIR/checks.sh" 1200
echo "##### 保留配置升级"
"$VM_DIR/upgrade.sh" "$image"

if [ -s "$VM_WORK/failures" ]; then
    echo "VM test failed:"
    sed 's/^/  /' "$VM_WORK/failures"
    exit 1
fi
echo "VM test passed"
