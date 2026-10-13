#!/usr/bin/env bash
# Move the pinned build inputs in profiles/ to the latest upstream releases:
# the newest OpenWrt point release of the pinned series with its ImageBuilder
# digest, Nikki, sing-box and the Argon theme. Each new asset is downloaded
# and hashed, and checked against the digest GitHub publishes for it.
#
# Prints "KEY: old -> new" per change. Lines starting with "notice:" need a
# person: a newer OpenWrt release series, which needs a manual review, or an
# asset replaced upstream without a new version, which stays pinned.
# Needs curl and jq; GH_TOKEN, when set, authenticates GitHub API requests.
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_file="$project_dir/profiles/build.env"
apks_file="$project_dir/profiles/nikki-apks.txt"
source "$env_file"
series=${OPENWRT_VERSION%.*}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

hash_file() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
fetch() {
    curl --fail --silent --show-error --location --retry 3 "$@"
}
github_release() {
    local auth=()
    [[ -z ${GH_TOKEN:-} ]] || auth=(-H "Authorization: Bearer $GH_TOKEN")
    fetch -H 'Accept: application/vnd.github+json' ${auth[@]+"${auth[@]}"} \
        "https://api.github.com/repos/$1/releases/latest"
}
asset_field() {
    jq -r --arg n "$2" ".assets[] | select(.name == \$n) | $3 // empty" <<< "$1"
}
# Download a release asset, check the digest GitHub publishes for it when
# there is one, and print its SHA256.
fetch_asset() {
    local release=$1 name=$2 url digest sha256
    url=$(asset_field "$release" "$name" .browser_download_url)
    [[ -n $url ]] || { echo "release asset $name not found" >&2; exit 1; }
    fetch -o "$work/$name" "$url"
    sha256=$(hash_file "$work/$name")
    digest=$(asset_field "$release" "$name" .digest)
    [[ -z $digest || $digest == "sha256:$sha256" ]] || {
        echo "$name does not match its published digest $digest" >&2
        exit 1
    }
    echo "$sha256"
}
# Report an asset whose published digest no longer matches the pin.
check_unchanged() {
    local release=$1 name=$2 pinned=$3 digest
    digest=$(asset_field "$release" "$name" .digest)
    [[ -z $digest || $digest == "sha256:$pinned" ]] ||
        echo "notice: $name was replaced upstream without a new version; the pinned SHA256 is kept"
}
set_var() {
    local key=$1 value=$2 old
    old=$(sed -n "s/^$key=//p" "$env_file")
    [[ $old != "$value" ]] || return 0
    sed "s|^$key=.*|$key=$value|" "$env_file" > "$work/env"
    cat "$work/env" > "$env_file"
    echo "$key: $old -> $value"
}

# OpenWrt point release and its ImageBuilder image.
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

# Nikki: the archive for this OpenWrt series and the APKs taken from it.
release=$(github_release nikkinikki-org/OpenWrt-nikki)
version=$(jq -r .tag_name <<< "$release")
version=${version#v}
asset="nikki_x86_64-openwrt-$series.tar.gz"
if [[ $version != "$NIKKI_VERSION" ]]; then
    sha256=$(fetch_asset "$release" "$asset")
    tar -tzf "$work/$asset" | sed 's|^\./||' > "$work/nikki-files"
    # Keep the file's order: core, service, LuCI app, translation.
    for prefix in mihomo-meta nikki luci-app-nikki luci-i18n-nikki-zh-cn; do
        matches=$(grep -E "^$prefix-[0-9][^/]*\.apk$" "$work/nikki-files" || true)
        [[ $(grep -c . <<< "$matches") == 1 ]] || {
            echo "expected one $prefix APK in $asset, found: ${matches:-none}" >&2
            exit 1
        }
        echo "$matches"
    done > "$work/nikki-apks"
    if ! cmp -s "$work/nikki-apks" "$apks_file"; then
        cat "$work/nikki-apks" > "$apks_file"
        echo "nikki-apks.txt: $(xargs < "$work/nikki-apks")"
    fi
    set_var NIKKI_VERSION "$version"
    set_var NIKKI_ARCHIVE_URL "$(asset_field "$release" "$asset" .browser_download_url)"
    set_var NIKKI_ARCHIVE_SHA256 "$sha256"
else
    check_unchanged "$release" "$asset" "$NIKKI_ARCHIVE_SHA256"
fi

# sing-box OpenWrt APK.
release=$(github_release SagerNet/sing-box)
version=$(jq -r .tag_name <<< "$release")
version=${version#v}
asset="sing-box_${version}_openwrt_x86_64.apk"
if [[ $version != "$SINGBOX_VERSION" ]]; then
    sha256=$(fetch_asset "$release" "$asset")
    set_var SINGBOX_VERSION "$version"
    set_var SINGBOX_APK_URL "$(asset_field "$release" "$asset" .browser_download_url)"
    set_var SINGBOX_APK_SHA256 "$sha256"
else
    check_unchanged "$release" "$asset" "$SINGBOX_APK_SHA256"
fi

# Argon theme APK; its file name carries the package version.
release=$(github_release jerrykuku/luci-theme-argon)
asset=$(jq -r '[.assets[].name | select(test("^luci-theme-argon-[0-9][^/]*\\.apk$"))]
    | if length == 1 then .[0] else empty end' <<< "$release")
[[ -n $asset ]] || { echo 'expected one luci-theme-argon APK in the Argon release' >&2; exit 1; }
version=${asset#luci-theme-argon-}
version=${version%.apk}
if [[ $version != "$ARGON_VERSION" ]]; then
    sha256=$(fetch_asset "$release" "$asset")
    set_var ARGON_VERSION "$version"
    set_var ARGON_APK_URL "$(asset_field "$release" "$asset" .browser_download_url)"
    set_var ARGON_APK_SHA256 "$sha256"
else
    check_unchanged "$release" "$asset" "$ARGON_APK_SHA256"
fi
