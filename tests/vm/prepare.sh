#!/usr/bin/env bash
# Write the image to a 16 GiB virtual NVMe disk, as a machine is installed
# (see the README). The firmware creates the data partition itself on first
# boot.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
image=$1
disk=$VM_WORK/disk.raw

mkdir -p "$VM_WORK"
rm -f "$disk"
truncate -s 16G "$disk"
gzip -dc "$image" | dd of="$disk" bs=4M conv=notrunc,fsync status=none
cp "$OVMF_VARS" "$VM_WORK/ovmf_vars.fd"
