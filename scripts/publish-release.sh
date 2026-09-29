#!/bin/bash
# Publish the validated runtime .debs from a build root as a GitHub release.
#
# Usage: scripts/publish-release.sh [--rev N] [--notes-file FILE] [--dry-run] ROOT
#
#   ROOT          Build root used with scripts/vm-run.sh (debs are in ROOT/out).
#   --rev N       HEVC patchset revision for the tag suffix (default: 1).
#   --notes-file  Human-written release notes; the sha256 block is appended.
#   --dry-run     Print the tag, notes and assets without publishing.
#
# The tag is chromium-<upstream>-<debian-rev>-rpt<N>-hevc<rev>, e.g.
# chromium-154.0.8037.57-1-rpt1-hevc1, created on this checkout's HEAD (which
# must be pushed and must have clean build/ and patches/ dirs so the release
# points at exactly what was built). The sha256 block uses the
# "<sha256>  <filename>" format that pi-runtime/hevc-validate/fetch_release.py
# verifies downloads against.
set -euo pipefail

rev=1
notes_in=""
dry_run=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rev) rev="$2"; shift 2 ;;
        --notes-file) notes_in="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ "$#" -eq 1 ] || { echo "usage: $0 [--rev N] [--notes-file FILE] [--dry-run] ROOT" >&2; exit 2; }
out="$(realpath "$1")/out"

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
full="$(sed -n 's/^readonly CHROMIUM_VERSION_FULL="\(.*\)"$/\1/p' build/cli.sh)"
upstream="${full%%-*}"
debrev="${full#*-}"; debrev="${debrev%%~*}"
rpt="${full##*+}"
tag="chromium-${upstream}-${debrev}-${rpt}-hevc${rev}"
[[ "$tag" =~ ^chromium-[0-9.]+-[0-9]+-rpt[0-9]+-hevc[0-9]+$ ]] || { echo "bad tag derived: $tag" >&2; exit 1; }

debs=("chromium_${full}_arm64.deb" "chromium-common_${full}_arm64.deb"
      "chromium-l10n_${full}_all.deb" "chromium-sandbox_${full}_arm64.deb")
for d in "${debs[@]}"; do
    [ -f "$out/$d" ] || { echo "missing $out/$d (run debs first)" >&2; exit 1; }
done

if ! git diff --quiet HEAD -- build patches; then
    echo "build/ or patches/ has uncommitted changes; commit and push first" >&2
    exit 1
fi
head="$(git rev-parse HEAD)"
git fetch -q origin
if [ -z "$(git branch -r --contains "$head")" ]; then
    echo "HEAD $head is not pushed to origin" >&2
    exit 1
fi
if gh release view "$tag" >/dev/null 2>&1; then
    echo "release $tag already exists (bump --rev?)" >&2
    exit 1
fi

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
{
    if [ -n "$notes_in" ]; then cat "$notes_in"; echo; fi
    echo '```'
    (cd "$out" && sha256sum "${debs[@]}")
    echo '```'
} >"$notes"

echo "tag:    $tag"
echo "target: $head"
echo "--- notes ---"; cat "$notes"
if [ "$dry_run" -eq 1 ]; then
    echo "(dry run; nothing published)"
    exit 0
fi

gh release create "$tag" --target "$head" --title "$tag" --notes-file "$notes" \
    "${debs[@]/#/$out/}"
gh release view "$tag" --json assets --jq '.assets[].name'
