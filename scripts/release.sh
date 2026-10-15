#!/usr/bin/env bash
# Publish a tested build as a GitHub release. Pin updates in profiles/ are
# committed and pushed first, so the release tag points at the recipe that was
# built. The release carries the disk image, its records and notes listing the
# changes since the previous release.
# Usage: scripts/release.sh ARTIFACT_DIR [PIN_CHANGES_FILE] [--dry-run]
# Needs gh authenticated (GH_TOKEN) with permission to push and release;
# --dry-run only prints the notes.
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir=$(cd "$1" && pwd)
pins=${2:-}
dry_run=${3:-}

source "$dir/build.env"
run_id=$(basename "$dir")
tag="$OPENWRT_VERSION-$run_id"
image=$(ls "$dir"/*-squashfs-combined-efi.img.gz)
manifest=$(ls "$dir"/*.manifest)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$project_dir/scripts/build-state.sh" "$manifest" > "$dir/build-state.txt"
files=("$image" "$manifest" "$dir/build-info.txt" "$dir/build.env" "$dir/build-state.txt"
    "$dir/verification.log" "$dir/vm-test.log")
(cd "$dir" && sha256sum "${files[@]##*/}") > "$dir/SHA256SUMS"
files+=("$dir/SHA256SUMS")

previous=$(gh release list --limit 1 --exclude-drafts --json tagName --jq '.[0].tagName // empty')
if [[ -n $previous ]]; then
    gh release download "$previous" --pattern '*.manifest' --output "$work/previous.manifest" ||
        : > "$work/previous.manifest"
fi
pin_changes=''
if [[ -n $pins && -f $pins ]]; then
    pin_changes=$(grep -v '^notice:' "$pins" || true)
fi

notes="$dir/release-notes.md"
{
    echo "x86-64 官方默认包固件，OpenWrt $OPENWRT_VERSION（ImageBuilder \`${IMAGEBUILDER_IMAGE#*@}\`）。"
    echo
    echo "写盘用 \`${image##*/}\`："
    echo
    echo '```'
    echo "$(sha256sum < "$image" | cut -d ' ' -f 1)  ${image##*/}"
    echo '```'
    echo
    echo '## 配方更新'
    echo
    if [[ -n $pin_changes ]]; then
        sed 's/^/- /' <<< "$pin_changes"
    else
        echo '无'
    fi
    echo
    if [[ -s $work/previous.manifest ]]; then
        echo "## 软件包变化（相对 $previous）"
        echo
        changes=$(awk 'NR == FNR { old[$1] = $3; next }
            { new[$1] = $3 }
            END {
                for (p in new)
                    if (!(p in old)) printf "| %s | — | %s |\n", p, new[p]
                    else if (old[p] != new[p]) printf "| %s | %s | %s |\n", p, old[p], new[p]
                for (p in old)
                    if (!(p in new)) printf "| %s | %s | — |\n", p, old[p]
            }' "$work/previous.manifest" "$manifest" | LC_ALL=C sort)
        if [[ -n $changes ]]; then
            echo '| 包 | 之前 | 现在 |'
            echo '|---|---|---|'
            echo "$changes"
        else
            echo '无'
        fi
    else
        echo '## 软件包'
        echo
        echo "共 $(grep -c . "$manifest") 个，清单见附件 \`${manifest##*/}\`。"
    fi
    echo
    echo '## 测试'
    echo
    echo '镜像内容检查和虚拟机启动测试均已通过，日志见附件 `verification.log` 和 `vm-test.log`。'
} > "$notes"

if [[ $dry_run == --dry-run ]]; then
    cat "$notes"
    exit
fi

cd "$project_dir"
if ! git diff --quiet -- profiles; then
    branch=${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}
    git add profiles
    git -c user.name='github-actions[bot]' \
        -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -q -m 'Update pinned upstream versions' -m "$pin_changes"
    git pull -q --rebase origin "$branch"
    git push -q origin "HEAD:$branch"
fi
gh release create "$tag" "${files[@]}" --target "$(git rev-parse HEAD)" \
    --title "OpenWrt $OPENWRT_VERSION x86-64 · ${run_id:0:4}-${run_id:4:2}-${run_id:6:2}" \
    --notes-file "$notes"
