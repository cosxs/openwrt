#!/usr/bin/env bash
# Runs inside the ImageBuilder container. With MANIFEST_ONLY=1, prints the
# resolved package manifest on stdout instead of building the image.
set -euo pipefail

cd /builder
if [[ ! -d scripts ]]; then
    ./setup.sh >&2
fi

if ! grep -q '^CONFIG_SIGNATURE_CHECK=y$' .config; then
    echo 'The official ImageBuilder must have signature checking enabled.' >&2
    exit 1
fi

archive="/work/.build/downloads/nikki-${NIKKI_VERSION}-x86_64-openwrt-${OPENWRT_VERSION%.*}.tar.gz"
echo "$NIKKI_ARCHIVE_SHA256  $archive" | sha256sum --check --status
mkdir -p packages

# Import only selected APK files. ImageBuilder generates and signs its own
# local index; the upstream index and conflicting alpha core are not imported.
while IFS= read -r apk; do
    [[ -n "$apk" ]] || continue
    tar -xzf "$archive" -C packages "./$apk"
done < /work/profiles/nikki-apks.txt

singbox_apk="/work/.build/downloads/sing-box_${SINGBOX_VERSION}_openwrt_x86_64.apk"
echo "$SINGBOX_APK_SHA256  $singbox_apk" | sha256sum --check --status
# apk finds local packages as <name>-<version>.apk; the upstream asset name
# differs, and its package version is ${SINGBOX_VERSION}-r0.
cp "$singbox_apk" "packages/sing-box-${SINGBOX_VERSION}-r0.apk"

argon_apk="/work/.build/downloads/luci-theme-argon-${ARGON_VERSION}.apk"
echo "$ARGON_APK_SHA256  $argon_apk" | sha256sum --check --status
cp "$argon_apk" packages/

packages=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' \
    /work/profiles/packages.txt | tr '\n' ' ')

if [[ ${MANIFEST_ONLY:-} == 1 ]]; then
    make manifest PROFILE="$OPENWRT_PROFILE" PACKAGES="$packages" |
        grep -E '^[^ ]+ - [^ ]+$'
    exit
fi

# make image forwards only ROOTFS_PARTSIZE to the image build (it unsets
# MAKEFLAGS); the boot partition size is read from .config.
sed -i "s/^CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=$KERNEL_PARTSIZE/" .config
grep -qx "CONFIG_TARGET_KERNEL_PARTSIZE=$KERNEL_PARTSIZE" .config
# Build only the squashfs EFI disk image and its rootfs image. The ext4,
# BIOS and tarball variants are unused, and each disk variant writes and
# compresses another image of the full partition size.
sed -i -e 's/^\(CONFIG_TARGET_ROOTFS_EXT4FS\)=y$/# \1 is not set/' \
    -e 's/^\(CONFIG_TARGET_ROOTFS_TARGZ\)=y$/# \1 is not set/' \
    -e 's/^\(CONFIG_GRUB_IMAGES\)=y$/# \1 is not set/' .config
grep -qx 'CONFIG_TARGET_ROOTFS_SQUASHFS=y' .config
grep -qx 'CONFIG_GRUB_EFI_IMAGES=y' .config

make info
make image \
    PROFILE="$OPENWRT_PROFILE" \
    PACKAGES="$packages" \
    FILES=/work/files \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"
