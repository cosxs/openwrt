#!/usr/bin/env bash
# Print what the firmware is built from: a hash of the recipe files that shape
# the image (names, modes and contents) and the resolved package manifest. A
# new release is only needed when this changes. Uses GNU tar.
# Usage: scripts/build-state.sh path/to/manifest
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=$(tar -C "$project_dir" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf - profiles files scripts/build.sh scripts/imagebuilder.sh | sha256sum)
echo "recipe=${recipe%% *}"
LC_ALL=C sort "$1"
