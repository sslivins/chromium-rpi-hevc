#!/bin/bash
# Run a build/cli.sh subcommand in the build container on the build VM.
#
# Usage: scripts/vm-run.sh [--detach] ROOT SUBCOMMAND [ARGS...]
#
#   ROOT        Per-version work dir, e.g. ~/chromium154-57. Holds out/ (debs,
#               ccache, logs) and build-root/src (the chromium source tree).
#   --detach    Run in the background (survives the ssh session). Output goes
#               to ROOT/<subcommand>.log; follow with `tail -f` or
#               `scripts/vm-run.sh ROOT tail`.
#
# What this adds over a bare `docker run`:
#   - The image is tagged by the Dockerfile's CHROMIUM_BUILD_DEPS_VERSION and
#     built automatically when missing, so a version bump can't silently run
#     against the previous release's build-deps image.
#   - This checkout's build/cli.sh is bind-mounted over the copy baked into
#     the image, so script fixes never need an image rebuild and a stale image
#     can't run a stale cli.sh.
#   - Refuses to start while another container is using the same ROOT. (cli.sh
#     also holds a flock on the tree; this check just fails faster.)
#   - CHROMIUM_DEBS_CONFIRM is passed through for `debs`.
set -euo pipefail

detach=0
if [ "${1:-}" = "--detach" ]; then
    detach=1
    shift
fi
[ "$#" -ge 2 ] || { sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }

root="$(realpath -m "$1")"
sub="$2"
shift 2

repo="$(cd "$(dirname "$0")/.." && pwd)"
deps_version="$(sed -n 's/^ARG CHROMIUM_BUILD_DEPS_VERSION=//p' "$repo/build/Dockerfile")"
[ -n "$deps_version" ] || { echo "cannot read CHROMIUM_BUILD_DEPS_VERSION from build/Dockerfile" >&2; exit 1; }
pinned="$(sed -n 's/^readonly CHROMIUM_VERSION_FULL="\(.*\)"$/\1/p' "$repo/build/cli.sh")"
[ "$pinned" = "$deps_version" ] || {
    echo "pin mismatch: build/cli.sh=$pinned build/Dockerfile=$deps_version" >&2
    echo "(use scripts/vendor-upstream-source.sh --write-pins)" >&2
    exit 1
}
image="chromium-rpi-build:deps-$(printf '%s' "$deps_version" | tr '~+' '--')"

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "building $image ..."
    docker build -q -t "$image" \
        --build-arg "CHROMIUM_BUILD_DEPS_VERSION=$deps_version" "$repo/build"
fi

label="chromium-rpi-hevc.root=$root"
running="$(docker ps -q --filter "label=$label")"
if [ -n "$running" ]; then
    case "$sub" in
        status|logs|tail) ;;
        *)
            echo "a build container is already running on $root: $running" >&2
            docker ps --filter "label=$label" --format '  {{.ID}} {{.Command}} up {{.RunningFor}}' >&2
            exit 1
            ;;
    esac
fi

mkdir -p "$root/out" "$root/build-root/src"
args=(run --rm --label "$label"
    -v "$root/out:/out"
    -v "$root/build-root/src:/build/src"
    -v "$repo/patches:/patches:ro"
    -v "$repo/build/cli.sh:/usr/local/bin/chromium-rpi-hevc:ro")
[ -n "${CHROMIUM_DEBS_CONFIRM:-}" ] && args+=(-e "CHROMIUM_DEBS_CONFIRM=$CHROMIUM_DEBS_CONFIRM")
args+=("$image" "$sub" "$@")

if [ "$detach" -eq 1 ]; then
    log="$root/$sub.log"
    nohup docker "${args[@]}" >"$log" 2>&1 </dev/null &
    echo "started $sub on $root (pid $!, image $image); log: $log"
else
    exec docker "${args[@]}"
fi
