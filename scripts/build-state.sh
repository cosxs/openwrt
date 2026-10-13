#!/usr/bin/env bash
# Print what the firmware is built from: a hash of the recipe files that shape
# the image (paths, modes and contents) and the resolved package manifest. A
# new release is only needed when this changes. Uses GNU find.
# Usage: scripts/build-state.sh path/to/manifest
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")

cd "$project_dir"
recipe=$(find profiles files scripts/build.sh scripts/imagebuilder.sh -type f -printf '%m %p\n' |
    LC_ALL=C sort -k 2 |
    while read -r mode path; do
        printf '%s %s %s\n' "$mode" "$(sha256sum < "$path" | cut -d ' ' -f 1)" "$path"
    done | sha256sum | cut -d ' ' -f 1)
echo "recipe=$recipe"
LC_ALL=C sort "$manifest"
