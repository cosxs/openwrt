#!/usr/bin/env bash
# Build the firmware into artifacts/<version>/<UTC time>/. With
# --manifest-only FILE, only resolve the package set and write it to FILE.
set -euo pipefail

manifest_only=''
if [[ $# -gt 0 ]]; then
    [[ $# == 2 && $1 == --manifest-only ]] || {
        echo "usage: $0 [--manifest-only OUTPUT]" >&2
        exit 2
    }
    manifest_only=$2
fi

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile_file="$project_dir/profiles/build.env"
# This checked-in file contains public, fixed build inputs.
source "$profile_file"

command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl is required.' >&2; exit 1; }
docker info >/dev/null

download_dir="$project_dir/.build/downloads"
mkdir -p "$download_dir"

sha256() {
    sha256sum < "$1" | cut -d ' ' -f 1
}
# Download a pinned release asset unless a copy with its SHA256 is cached. A
# cached file that does not match, e.g. a stale pin, is downloaded again.
fetch_verified() {
    local url=$1 file=$2 sha256=$3
    [[ -f $file && $(sha256 "$file") == "$sha256" ]] && return
    curl --fail --location --retry 3 "$url" -o "$file.part"
    [[ $(sha256 "$file.part") == "$sha256" ]] || {
        rm -f "$file.part"
        echo "SHA256 mismatch: $url" >&2
        exit 1
    }
    mv "$file.part" "$file"
}

fetch_verified "$SINGBOX_APK_URL" \
    "$download_dir/sing-box_${SINGBOX_VERSION}_openwrt_x86_64.apk" \
    "$SINGBOX_APK_SHA256"

# fakeroot closes every possible descriptor on start; hosts whose containers
# inherit an unlimited nofile limit would make that loop appear to hang.
container_args=(--platform linux/amd64 --ulimit nofile=1024:524288
    --env-file "$profile_file"
    --mount "type=bind,source=$project_dir,target=/work,readonly")

if [[ -n $manifest_only ]]; then
    docker run --rm "${container_args[@]}" --env MANIFEST_ONLY=1 \
        "$IMAGEBUILDER_IMAGE" /bin/bash /work/scripts/imagebuilder.sh > "$manifest_only"
    exit
fi

run_id=$(date -u +%Y%m%dT%H%M%SZ)
output_dir="$project_dir/artifacts/$OPENWRT_VERSION/$run_id"
mkdir -p "$output_dir"
cp "$profile_file" "$output_dir/build.env"
printf 'recipe_revision=%s\nsingbox_apk_sha256=%s\n' \
    "$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || printf uncommitted)" \
    "$SINGBOX_APK_SHA256" > "$output_dir/build-info.txt"

container_id=''
cleanup() {
    if [[ -n "$container_id" ]]; then
        docker rm -fv "$container_id" >/dev/null
    fi
}
trap cleanup EXIT

container_id=$(docker create "${container_args[@]}" \
    "$IMAGEBUILDER_IMAGE" /bin/bash /work/scripts/imagebuilder.sh)

if docker start --attach "$container_id" 2>&1 | tee "$output_dir/build.log"; then
    docker cp "$container_id:/builder/bin/targets/$OPENWRT_TARGET/." "$output_dir/"
else
    echo "Build failed; log: $output_dir/build.log" >&2
    exit 1
fi

echo "Firmware and build records: $output_dir"
