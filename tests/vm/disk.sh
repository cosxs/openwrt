#!/usr/bin/env bash
# Checks of the virtual disk after the first boot, read through a loop device
# with the VM stopped: no login is needed. Failed checks are recorded in
# $VM_WORK/failures.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
disk=$VM_WORK/disk.raw

loop=$(losetup -fP --show "$disk") || { fail_check 'loop device for the disk'; exit 1; }
trap 'losetup -d "$loop"' EXIT
for _ in $(seq 20); do
    [ -b "${loop}p4" ] && break
    sleep 1
done

# Field $2 of partition $1 from the partition table dump, in sectors.
field() {
    sfdisk -d "$loop" | sed -n "s|^${loop}p$1 : .*$2= *\([0-9]*\).*|\1|p"
}
part_name() { blkid -p -o value -s PART_ENTRY_NAME "${loop}p$1"; }
fs_type() { blkid -p -o value -s TYPE "${loop}p$1"; }
fs_label() { blkid -p -o value -s LABEL "${loop}p$1"; }
mib=2048   # sectors in 1 MiB
last_lba=$(sfdisk -d "$loop" | sed -n 's/^last-lba: *//p')

echo "== 磁盘分区"
sfdisk -d "$loop" | grep -E "^${loop}p"
check 'partitions' '1 2 3 4 128' \
    "$(sfdisk -d "$loop" | sed -n "s|^${loop}p\([0-9]*\) :.*|\1|p" | sort -n | xargs)"
check 'boot partition MiB' 128 "$(( $(field 1 size) / mib ))"
check 'system partition MiB' 4096 "$(( $(field 2 size) / mib ))"

echo "== swap 分区（p3）"
check 'swap partition name' swap "$(part_name 3)"
check 'swap filesystem' swap "$(fs_type 3)"
check 'swap label' swap "$(fs_label 3)"
check 'swap size MiB' 1024 "$(( $(field 3 size) / mib ))"
want=$(( ($(field 2 start) + $(field 2 size) + mib - 1) / mib * mib ))
check 'swap starts on the first 1 MiB boundary after the system partition' "$want" "$(field 3 start)"

echo "== 数据分区（p4）"
check 'data partition name' data "$(part_name 4)"
check 'data filesystem' ext4 "$(fs_type 4)"
check 'data label' data "$(fs_label 4)"
check 'data starts right after swap' "$(( $(field 3 start) + $(field 3 size) ))" "$(field 4 start)"
check 'data start is 1 MiB aligned' 0 "$(( $(field 4 start) % mib ))"
# parted aligns the end of the last partition down to a 1 MiB boundary, so
# less than 1 MiB may stay unused at the end of the disk.
check 'data leaves less than 1 MiB unused at the end of the disk' yes \
    "$([ $(( last_lba - ($(field 4 start) + $(field 4 size) - 1) )) -lt $mib ] && echo yes || echo no)"
