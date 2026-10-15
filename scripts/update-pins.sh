#!/usr/bin/env bash
# Move the pinned OpenWrt version in profiles/build.env to the newest point
# release of the pinned series, together with its ImageBuilder digest.
#
# Prints "KEY: old -> new" per change. A line starting with "notice:" needs a
# person: a newer OpenWrt release series, which needs a manual review.
# Needs curl and jq.
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_file="$project_dir/profiles/build.env"
source "$env_file"
series=${OPENWRT_VERSION%.*}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() {
    curl --fail --silent --show-error --location --retry 3 "$@"
}
set_var() {
    local key=$1 value=$2 old
    old=$(sed -n "s/^$key=//p" "$env_file")
    [[ $old != "$value" ]] || return 0
    # ENVIRON passes the value literally, unlike sed replacements or awk -v.
    KEY=$key VALUE=$value awk -F = '$1 == ENVIRON["KEY"] { $0 = $1 "=" ENVIRON["VALUE"] } 1' \
        "$env_file" > "$work/env"
    cat "$work/env" > "$env_file"
    echo "$key: $old -> $value"
}

versions=$(fetch https://downloads.openwrt.org/.versions.json)
stable=$(jq -r .stable_version <<< "$versions")
if [[ $(printf '%s\n' "${stable%.*}" "$series" | sort -V | tail -1) != "$series" ]]; then
    echo "notice: OpenWrt $stable starts a newer release series than $series; moving to it needs a manual review"
fi
latest=$(jq -r '.versions_list[]' <<< "$versions" |
    grep -E "^${series//./\\.}\.[0-9]+$" | sort -V | tail -1 || true)
if [[ -n $latest && $latest != "$OPENWRT_VERSION" ]]; then
    tag="${OPENWRT_TARGET//\//-}-$latest"
    digest=$(fetch "https://hub.docker.com/v2/repositories/openwrt/imagebuilder/tags/$tag" |
        jq -r '.digest // empty') || digest=''
    if [[ $digest == sha256:* ]]; then
        set_var OPENWRT_VERSION "$latest"
        set_var IMAGEBUILDER_IMAGE "openwrt/imagebuilder@$digest"
    else
        echo "OpenWrt $latest has no ImageBuilder image $tag yet; keeping $OPENWRT_VERSION"
    fi
fi
