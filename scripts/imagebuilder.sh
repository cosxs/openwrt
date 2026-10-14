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

mkdir -p packages

# ImageBuilder generates and signs its own local index for these APK files.
# apk finds local packages as <name>-<version>.apk, whatever the release asset
# is called; both are read from the package metadata.
import_apk() {
    local file=$1 sha256=$2 name version
    echo "$sha256  $file" | sha256sum --check --status
    name=$(apk_field "$file" name)
    version=$(apk_field "$file" version)
    [[ -n $name && -n $version ]] || { echo "No package metadata in $file" >&2; exit 1; }
    cp "$file" "packages/$name-$version.apk"
}
apk_field() {
    staging_dir/host/bin/apk --allow-untrusted adbdump "$1" |
        sed -n "/^info:/,/^[a-z]/s/^  $2: //p"
}
import_apk "/work/.build/downloads/sing-box_${SINGBOX_VERSION}_openwrt_x86_64.apk" "$SINGBOX_APK_SHA256"

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
