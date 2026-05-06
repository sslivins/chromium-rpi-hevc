#!/bin/bash
# Build chromium .deb with our HEVC patches stacked on top of RPi-Distro's series.
# Runs inside the chromium-rpi-build container.
# Inputs:  /patches/*.patch   (any extra patches to add to debian/patches/series)
# Outputs: /out/*.deb
set -euo pipefail

JOBS="${JOBS:-$(nproc)}"
SRC_DIR=/build/src
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

# ---------------------------------------------------------------------------
# Pinned upstream source.
#
# We do NOT use `apt-get source chromium` because that fetches whatever version
# is currently in the RPi archive — which drifts. Instead we fetch a frozen
# mirror of the exact .dsc + tarballs we wrote our patches against, hosted as
# a GitHub Release on this repo, and verify SHA256.
#
# To bump to a new chromium version: rebuild patches against the new tree,
# vendor the new source files into a new GitHub Release, then update the four
# constants below. See docs/upstream-source-pinning.md for the full procedure.
# ---------------------------------------------------------------------------
CHROMIUM_VERSION_FULL="147.0.7727.116-1~deb13u1+rpt1"
CHROMIUM_VERSION_UPSTREAM="147.0.7727.116"
UPSTREAM_RELEASE_URL="${UPSTREAM_RELEASE_URL:-https://github.com/sslivins/chromium-rpi-hevc/releases/download/upstream-source-147.0.7727.116}"

# SHA256 of each source file as published by RPi-Distro and frozen in our release.
SHA256_ORIG="b808992f5a680372b8276466645183315326d8d0e66f080266883a07f36551c8"
SHA256_DEBIAN="a884500201313734ea3b185473b867df48c97dedb3915fcbd9b6e0ce411fd318"
SHA256_DSC="b0ac0f716b8bb04bac2a4c0d793146b456f39bbd3a4dbb1dd5d337704012ea54"

ORIG_TARBALL="chromium_${CHROMIUM_VERSION_UPSTREAM}.orig.tar.xz"
DEBIAN_TARBALL="chromium_${CHROMIUM_VERSION_FULL}.debian.tar.xz"
DSC_FILE="chromium_${CHROMIUM_VERSION_FULL}.dsc"

# GitHub Releases mangles `~` to `.` in asset filenames during upload, so the
# URL filenames differ from the canonical Debian filenames. The .dsc manifest
# requires the canonical names, so we download from the mangled URL and save
# under the canonical filename.
ORIG_URL_NAME="${ORIG_TARBALL}"
DEBIAN_URL_NAME="${DEBIAN_TARBALL//\~/.}"
DSC_URL_NAME="${DSC_FILE//\~/.}"

echo "=== STAGE 0: refresh apt lists (cleared in Dockerfile to slim layers) ==="
apt-get update

echo "=== STAGE 1: fetch pinned chromium source from our frozen mirror ==="
echo "Version: ${CHROMIUM_VERSION_FULL}"
echo "Release: ${UPSTREAM_RELEASE_URL}"

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: SHA256 mismatch for $file"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        return 1
    fi
    echo "  ok: $file ($expected)"
}

fetch_and_verify() {
    local local_name="$1"
    local url_name="$2"
    local expected_sha="$3"
    if [ -f "$local_name" ] && verify_sha256 "$local_name" "$expected_sha" >/dev/null 2>&1; then
        echo "  cached: $local_name"
        return 0
    fi
    echo "  fetching: $local_name (URL: $url_name)"
    rm -f "$local_name"
    curl -fL --retry 3 --retry-delay 5 -o "$local_name" "${UPSTREAM_RELEASE_URL}/${url_name}"
    verify_sha256 "$local_name" "$expected_sha"
}

fetch_and_verify "$ORIG_TARBALL"   "$ORIG_URL_NAME"   "$SHA256_ORIG"
fetch_and_verify "$DEBIAN_TARBALL" "$DEBIAN_URL_NAME" "$SHA256_DEBIAN"
fetch_and_verify "$DSC_FILE"       "$DSC_URL_NAME"    "$SHA256_DSC"

echo "All three source files present and SHA256-verified."

echo "=== STAGE 1b: extract source via dpkg-source ==="
# dpkg-source -x reads .dsc, validates checksums against orig+debian tarballs,
# and produces chromium-<UPSTREAM_VERSION>/ as the unpacked tree. With format
# 3.0 (quilt) it stops before applying debian/patches/series — exactly what
# we want, so STAGE 3 can append our patches.
dpkg-source -x "$DSC_FILE"

# dpkg-source extracts as chromium-VERSION/. Find it.
SRC_TREE=$(find . -maxdepth 1 -type d -name 'chromium-*' | head -1)
if [ -z "$SRC_TREE" ]; then
    echo "ERROR: no chromium-* source tree found after dpkg-source -x"
    ls -la
    exit 1
fi
echo "Source tree: $SRC_TREE"
cd "$SRC_TREE"

echo "=== STAGE 1c: patch debian/rules to drop en-US.pak from chromium-l10n ==="
# chromium-common.install ships out/Release/resources/en-US.pak into
# usr/lib/chromium/locales/, while chromium-l10n.install greedily ships the
# entire out/Release/locales/ tree (which also contains en-US.pak) into the
# same usr/lib/chromium directory. Upstream debian/rules tries to mitigate
# this with `rm -f locales/en-US.pak` in override_dh_auto_build-indep, but
# that fires during the parallel arch build and races: the arch build can
# rebuild en-US.pak in out/Release/locales/ before dh_install copies it.
#
# Robust fix: hook override_dh_install-indep, let dh_install run normally,
# then delete the stray copy from the chromium-l10n staging dir AFTER it
# has been populated. No race possible because dh_install is already done.
#
# We use a marker comment so re-runs are idempotent. We FAIL LOUD if upstream
# ever adds its own override_dh_install-indep without our marker — silently
# skipping would re-introduce the en-US.pak collision in a future release.
MARKER='# chromium-rpi-hevc: drop duplicate en-US.pak from chromium-l10n staging'
if grep -qF "$MARKER" debian/rules; then
    echo "  marker present in debian/rules — fix already applied, skipping."
elif grep -q '^override_dh_install-indep:' debian/rules; then
    echo "ERROR: upstream debian/rules has its own override_dh_install-indep" >&2
    echo "       (without our marker). The en-US.pak fix needs a manual merge" >&2
    echo "       — refusing to silently lose the fix." >&2
    exit 1
else
    cat >> debian/rules <<EOF

$MARKER
override_dh_install-indep:
	dh_install
	rm -f debian/chromium-l10n/usr/lib/chromium/locales/en-US.pak
EOF
    echo "  appended override_dh_install-indep target to debian/rules"
    tail -6 debian/rules
fi

# ---------------------------------------------------------------------------
# Inject ccache wrapper into the GN args debian/rules feeds to `gn gen`.
#
# debian/rules invokes `gn gen out/Release --args="$(defines)"` from inside
# override_dh_auto_build-{arch,indep}. `defines` is a Make variable built up
# by a stack of `defines+=...` lines. We append one more, with our marker so
# re-runs are idempotent and any future upstream change is detectable.
#
# This is part of the Tier 1 incremental-build-fragility fix: stop relying on
# external PATH tricks that get clobbered when args.gn is regenerated, and
# stop leaving the wiring up to chance.
# ---------------------------------------------------------------------------
CCACHE_MARKER='# chromium-rpi-hevc: enable ccache as cc_wrapper (Tier 1)'
if grep -qF "$CCACHE_MARKER" debian/rules; then
    echo "  ccache cc_wrapper marker present in debian/rules — skipping."
else
    cat >> debian/rules <<EOF

$CCACHE_MARKER
defines+=cc_wrapper=\\"ccache\\"
EOF
    echo "  appended cc_wrapper=\"ccache\" to defines in debian/rules"
fi

echo "=== STAGE 2: existing patch series ==="
ls debian/patches/series | head
echo "--- last 5 patches in series ---"
tail -5 debian/patches/series

echo "=== STAGE 3: apply our extra patches (if any) ==="
shopt -s nullglob
EXTRA_PATCHES=(/patches/*.patch)
if [ ${#EXTRA_PATCHES[@]} -gt 0 ]; then
    echo "Found ${#EXTRA_PATCHES[@]} extra patches in /patches:"
    printf '  - %s\n' "${EXTRA_PATCHES[@]}"
    for p in "${EXTRA_PATCHES[@]}"; do
        name=$(basename "$p")
        cp "$p" "debian/patches/$name"
        echo "$name" >> debian/patches/series
        echo "added $name to series"
    done
else
    echo "No extra patches in /patches; building stock RPi-Distro source."
fi

echo "=== STAGE 3b: ccache configuration ==="
# Tier 1 (incremental-build-fragility plan). Three mechanisms wire ccache:
#   1. cc_wrapper="ccache" appended to debian/rules `defines` above (primary)
#   2. PATH=/usr/lib/ccache:$PATH from Dockerfile ENV (backup)
#   3. Runtime tripwire below — kills the build early if both above fail
# CCACHE_DIR defaults to /out/.ccache so the cache persists across container
# runs via the existing -v ${PWD}/out:/out bind mount.
export CCACHE_DIR="${CCACHE_DIR:-/out/.ccache}"
mkdir -p "$CCACHE_DIR"
ccache -o cache_dir="$CCACHE_DIR" \
       -o max_size=100G \
       -o compression=true \
       -o compression_level=6 \
       -o compiler_check=content \
       -o sloppiness=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,system_headers \
       >/dev/null
ccache --zero-stats >/dev/null
echo "ccache configuration:"
ccache --show-config 2>/dev/null | grep -E '^\s*(cache_dir|max_size|compression|compiler_check|sloppiness)\b' || ccache -p 2>/dev/null || true
echo "PATH: $PATH"
echo "which clang-19: $(command -v clang-19 || echo MISSING)"
echo "ccache -V: $(ccache -V 2>/dev/null | head -1)"

echo "=== STAGE 4: dpkg-buildpackage (this is the long part, hours) ==="
echo "Using $JOBS parallel jobs."
# `terse` makes ninja print rule names ("[N/M] CXX obj/...") instead of full
# command lines, which gives the tripwire a stable signal to count.
export DEB_BUILD_OPTIONS="parallel=$JOBS nocheck terse"

BUILD_LOG=/out/build.log
TRIPWIRE_LOG=/out/ccache-tripwire.log
: > "$BUILD_LOG"
: > "$TRIPWIRE_LOG"

# Helper: total cacheable calls seen by ccache. Prefers the ccache 4.x
# machine-readable --print-stats; falls back to parsing -s.
get_ccache_calls() {
    local n
    n=$(ccache --print-stats 2>/dev/null | awk '$1=="called"{print $2; exit}')
    if [ -n "$n" ]; then
        echo "$n"
        return
    fi
    ccache -s 2>/dev/null | awk -F: '/[Cc]acheable calls|[Cc]ache hits|[Cc]ache misses/ {gsub(/[^0-9]/,"",$2); s+=$2} END {print s+0}'
}

# Run dpkg-buildpackage in its own process group so the tripwire can
# SIGTERM/SIGKILL the entire descendant tree (ninja, clang, etc.) on
# failure — `kill -TERM $PID` only hits dpkg-buildpackage itself.
# `set -m` (monitor/job-control mode) places each backgrounded pipeline
# in its own process group, with PGID == leader PID == $!.
set -m
dpkg-buildpackage -us -uc -b -d -j"$JOBS" > "$BUILD_LOG" 2>&1 &
BUILD_PID=$!
set +m

# Mirror build.log to stdout in real time. Stops automatically when build exits.
tail -F -n 0 "$BUILD_LOG" --pid="$BUILD_PID" &
TAIL_PID=$!

# Tripwire watchdog. Two checks (in priority order):
#   (a) args.gn assertion: as soon as gn has produced out/Release/args.gn,
#       grep for cc_wrapper. If missing -> wiring is broken, kill immediately.
#   (b) compile-stats assertion: once we see >=100 CXX ninja steps, sample
#       ccache `called`. If 0, wiring is broken (PATH didn't help either),
#       kill immediately.
# Wall-clock is informational only — never the sole basis for a kill, since
# dh_auto_configure (rollup/esbuild/gn gen) can legitimately consume 5-10 min
# before the first compile.
(
    START=$(date +%s)
    ARGS_CHECKED=0
    SRC_TREE_ABS="$(pwd)"
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        sleep 30
        kill -0 "$BUILD_PID" 2>/dev/null || break
        ELAPSED=$(( $(date +%s) - START ))

        # (a) args.gn check — one-shot.
        if [ "$ARGS_CHECKED" = "0" ]; then
            ARGS_GN="$SRC_TREE_ABS/out/Release/args.gn"
            if [ -f "$ARGS_GN" ]; then
                ARGS_CHECKED=1
                {
                    echo "=== args.gn check at T+${ELAPSED}s ==="
                    cat "$ARGS_GN"
                } >> "$TRIPWIRE_LOG"
                if ! grep -q '^cc_wrapper *= *"ccache"' "$ARGS_GN"; then
                    echo ""
                    echo "######################################################################"
                    echo "FATAL: args.gn does NOT contain cc_wrapper=\"ccache\" (T+${ELAPSED}s)."
                    echo "       defines+= override in debian/rules did not take effect."
                    echo "       Killing build to save VM time. See $TRIPWIRE_LOG."
                    echo "######################################################################"
                    kill -TERM -- "-$BUILD_PID" 2>/dev/null || kill -TERM "$BUILD_PID" 2>/dev/null || true
                    sleep 5
                    kill -KILL -- "-$BUILD_PID" 2>/dev/null || kill -KILL "$BUILD_PID" 2>/dev/null || true
                    exit 0
                fi
                echo "ccache tripwire (a): args.gn contains cc_wrapper=\"ccache\" — OK at T+${ELAPSED}s."
            fi
        fi

        # (b) compile-stats check.
        CXX=$(grep -cE '^\[[0-9]+/[0-9]+\] (CXX|CC|RUST_CC|RUST_BIN) ' "$BUILD_LOG" 2>/dev/null || true)
        CXX=${CXX:-0}
        if [ "$CXX" -ge 100 ]; then
            CALLS=$(get_ccache_calls)
            CALLS=${CALLS:-0}
            {
                echo "=== ccache stats check at T+${ELAPSED}s (cxx_actions=$CXX) ==="
                ccache --print-stats 2>&1 || ccache -s 2>&1
            } >> "$TRIPWIRE_LOG"
            if [ "$CALLS" -eq 0 ]; then
                echo ""
                echo "######################################################################"
                echo "FATAL: ccache TRIPWIRE — 0 calls after $CXX CXX actions (T+${ELAPSED}s)."
                echo "       cc_wrapper wiring is broken AND PATH wrapper is not engaged."
                echo "       Killing build to save VM time. See $TRIPWIRE_LOG."
                echo "######################################################################"
                kill -TERM -- "-$BUILD_PID" 2>/dev/null || kill -TERM "$BUILD_PID" 2>/dev/null || true
                sleep 5
                kill -KILL -- "-$BUILD_PID" 2>/dev/null || kill -KILL "$BUILD_PID" 2>/dev/null || true
                exit 0
            fi
            echo "ccache tripwire (b): $CALLS calls observed at $CXX CXX actions — OK. Watchdog disarming."
            exit 0
        fi

        # Status heartbeat every 5 minutes for visibility.
        if [ $((ELAPSED % 300)) -lt 30 ] && [ "$ELAPSED" -ge 300 ]; then
            CALLS_NOW=$(get_ccache_calls)
            echo "ccache tripwire heartbeat T+${ELAPSED}s: cxx_actions=$CXX ccache_called=${CALLS_NOW:-?} args_checked=$ARGS_CHECKED"
        fi
    done
) &
TRIPWIRE_PID=$!

set +e
wait "$BUILD_PID"
BUILD_RC=$?
set -e
kill "$TRIPWIRE_PID" 2>/dev/null || true
kill "$TAIL_PID" 2>/dev/null || true
wait 2>/dev/null || true

echo "=== ccache stats (post-build) ==="
ccache -s --verbose 2>/dev/null | head -30 || ccache -s
[ -s "$TRIPWIRE_LOG" ] && { echo "--- tripwire log ---"; cat "$TRIPWIRE_LOG"; }

if [ "$BUILD_RC" -ne 0 ]; then
    echo "ERROR: dpkg-buildpackage exited $BUILD_RC"
    exit "$BUILD_RC"
fi

echo "=== STAGE 5: collect .debs ==="
# dpkg-buildpackage emits artifacts to the *parent* of the source tree (i.e. /build/src/)
cd /build/src
mv -v *.deb /out/ 2>/dev/null || echo "no .debs in /build/src"
mv -v *.changes *.buildinfo /out/ 2>/dev/null || true

echo "=== STAGE 6: verify en-US.pak ownership invariant ==="
# Post-condition assertions for the STAGE 1c fix:
#   chromium-common owns usr/lib/chromium/locales/en-US.pak
#   chromium-l10n   does NOT contain it
# If either assertion fails, the build is broken — fail loud rather than
# shipping a .deb set that needs --force-overwrite.
COMMON_DEB=$(ls /out/chromium-common_*.deb 2>/dev/null | head -1 || true)
L10N_DEB=$(ls /out/chromium-l10n_*.deb 2>/dev/null | head -1 || true)
if [ -z "$COMMON_DEB" ] || [ -z "$L10N_DEB" ]; then
    echo "ERROR: chromium-common or chromium-l10n .deb missing in /out — cannot verify." >&2
    exit 1
fi
echo "  chromium-common: $COMMON_DEB"
echo "  chromium-l10n:   $L10N_DEB"
# NOTE: capture the listing into a variable rather than piping into `grep -q`.
# Under `set -o pipefail`, `grep -q` early-exits on the first match, which
# closes the pipe and makes `dpkg-deb -c` die with SIGPIPE (exit 141).
# pipefail then surfaces that as a script failure, falsely reporting the
# invariant as broken even when the .deb is correct. Reading the listing
# fully into memory eliminates the pipe and the race entirely.
COMMON_LISTING="$(dpkg-deb -c "$COMMON_DEB")"
L10N_LISTING="$(dpkg-deb -c "$L10N_DEB")"
if ! grep -qE ' \./usr/lib/chromium/locales/en-US\.pak$' <<< "$COMMON_LISTING"; then
    echo "ERROR: chromium-common is missing usr/lib/chromium/locales/en-US.pak" >&2
    exit 1
fi
echo "  ok: chromium-common contains en-US.pak"
if grep -qE ' \./usr/lib/chromium/locales/en-US\.pak$' <<< "$L10N_LISTING"; then
    echo "ERROR: chromium-l10n still contains usr/lib/chromium/locales/en-US.pak" >&2
    echo "       STAGE 1c en-US.pak fix did not take effect." >&2
    exit 1
fi
echo "  ok: chromium-l10n does NOT contain en-US.pak (collision fixed)"

echo "=== DONE ==="
ls -lh /out/
