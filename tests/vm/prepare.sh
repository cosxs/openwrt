#!/usr/bin/env bash
# Build a 16 GiB virtual NVMe disk the way a machine is installed (see the
# README): write the image, move the GPT backup header to the end, append a
# data partition with the remaining space and format it as ext4 labelled
# "data".
set -euo pipefail
. "$(dirname "$0")/lib.sh"
image=$1
disk=$VM_WORK/disk.raw

mkdir -p "$VM_WORK"
rm -f "$disk"
truncate -s 16G "$disk"
gzip -dc "$image" | dd of="$disk" bs=4M conv=notrunc,fsync status=none
sfdisk --relocate gpt-bak-std "$disk"
echo ',,L' | sfdisk --append --no-reread --quiet "$disk"
sfdisk --part-label "$disk" 3 data > /dev/null
loop=$(losetup --find --partscan --show "$disk")
trap 'losetup -d "$loop"' EXIT
mkfs.ext4 -q -L data "${loop}p3"
blkid "${loop}p3"
sfdisk --list "$disk"
cp "$OVMF_VARS" "$VM_WORK/ovmf_vars.fd"
