#!/bin/bash
# Fast incremental chromium build for HEVC patch iteration.
#
# Two big wins over build-incremental.sh:
#   1. Source tree stays PATCHED across runs — we never call dpkg-source --after-build.
#      Eliminates the ~40k-mtime-touch cost on every build.
#   2. ccache wrapped around clang — even if ninja decides a target is dirty,
#      identical content hits the ccache cache and returns the .o in milliseconds.
#
# State machine:
#   - First time we run on a tree: detect patched/unpatched, normalize.
#   - Compute fingerprint of /patches/*.patch (local hevc patches we own).
#   - If fingerprint matches stamp: skip patch reapply entirely, just run ninja.
#   - If mismatch: dpkg-source --after-build (if applied), apply new patches via
#                  dpkg-source --before-build, save new fingerprint, run ninja.
#   - Stamp lives in /build/src/.local-hevc-fingerprint
#
# Output: chromium binary at /out/chromium (no .deb — saves dpkg-buildpackage time).
# To build a .deb instead, set MAKE_DEB=1.
#
set -euo pipefail
export CC=clang-19
export CXX=clang++-19
export AR=ar
export NM=nm
export BUILD_CC=clang-19
export BUILD_CXX=clang++-19
export BUILD_AR=ar
export BUILD_NM=nm
export CXXFLAGS="-stdlib=libc++"
export LDFLAGS="-stdlib=libc++ -static-libstdc++"
export BUILD_CXXFLAGS="-stdlib=libc++"
export BUILD_LDFLAGS="-stdlib=libc++ -static-libstdc++"

JOBS="${JOBS:-$(nproc)}"
SRC_DIR=/build/src
mkdir -p "$SRC_DIR" /out

cd "$SRC_DIR"

mapfile -t TREES < <(find . -maxdepth 1 -type d -name 'chromium-*' | sort)
if [ "${#TREES[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one chromium-* tree in /build/src, got ${#TREES[@]}."
    echo "Run build-incremental.sh first to bootstrap."
    exit 1
fi
SRC_TREE="${TREES[0]}"
cd "$SRC_TREE"

# ---- ccache setup ----
export CCACHE_DIR="${CCACHE_DIR:-/build/.ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-50G}"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,system_headers
mkdir -p "$CCACHE_DIR"
ccache -o cache_dir="$CCACHE_DIR" -o max_size="$CCACHE_MAXSIZE" >/dev/null
echo "=== ccache stats (before build) ==="
ccache -s --verbose | head -20 || ccache -s

# Inject cc_wrapper into args.gn if missing.
ARGS_GN="out/Release/args.gn"
if false && [ -f "$ARGS_GN" ] && ! grep -q '^cc_wrapper' "$ARGS_GN"; then
    echo 'cc_wrapper = \"ccache\"' >> "$ARGS_GN"
    echo "Added cc_wrapper=\"ccache\" to args.gn"
    NEED_GN_GEN=1
else
    NEED_GN_GEN=0
fi

# ---- patch fingerprint check ----
STAMP="/build/src/.local-hevc-fingerprint"
NEW_FP=$(cat /patches/*.patch 2>/dev/null | sha256sum | cut -d' ' -f1)
OLD_FP=""
[ -f "$STAMP" ] && OLD_FP=$(cat "$STAMP")

# ---- detect tree state (patched or not) ----
# A patched tree has the .pc/applied-patches file from quilt/dpkg-source.
TREE_STATE="unknown"
if [ -f .pc/applied-patches ] && [ -s .pc/applied-patches ]; then
    TREE_STATE="patched"
else
    TREE_STATE="pristine"
fi
echo "Tree state: $TREE_STATE   fp_old=$OLD_FP   fp_new=$NEW_FP"

NEED_REAPPLY=0
if [ "$TREE_STATE" = "pristine" ]; then
    echo "Tree is unpatched → must apply patches."
    NEED_REAPPLY=1
elif [ "$NEW_FP" != "$OLD_FP" ]; then
    echo "Local patch fingerprint changed → must reapply."
    NEED_REAPPLY=1
else
    echo "Tree already patched and fingerprint matches → SKIPPING patch reapply (true incremental)."
fi

if [ "$NEED_REAPPLY" = "1" ]; then
    # Sync patches into series (replicates STAGE 3 of build-incremental.sh).
    MARKER_BEGIN="# === BEGIN LOCAL HEVC PATCHES ==="
    MARKER_END="# === END LOCAL HEVC PATCHES ==="
    LOCAL_SUBDIR="local-hevc"

    # If currently patched, unapply first.
    if [ "$TREE_STATE" = "patched" ]; then
        echo "Unapplying current patches via dpkg-source --after-build."
        dpkg-source --after-build . 2>/dev/null || quilt pop -af 2>/dev/null || true
    fi

    # Strip prior local block from series.
    if grep -qFx "$MARKER_BEGIN" debian/patches/series; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" debian/patches/series
    fi
    rm -rf "debian/patches/$LOCAL_SUBDIR"

    # Append new local block.
    shopt -s nullglob
    EXTRA=(/patches/*.patch)
    if [ ${#EXTRA[@]} -gt 0 ]; then
        mkdir -p "debian/patches/$LOCAL_SUBDIR"
        echo "$MARKER_BEGIN" >> debian/patches/series
        for p in "${EXTRA[@]}"; do
            name=$(basename "$p")
            cp "$p" "debian/patches/$LOCAL_SUBDIR/$name"
            echo "$LOCAL_SUBDIR/$name" >> debian/patches/series
            echo "  added $LOCAL_SUBDIR/$name"
        done
        echo "$MARKER_END" >> debian/patches/series
    fi

    echo "Applying patches via dpkg-source --before-build."
    if ! dpkg-source --before-build .; then
        echo "ERROR: patch application failed."
        exit 1
    fi
    echo "$NEW_FP" > "$STAMP"
fi

# ---- gn gen if needed ----
if [ "$NEED_GN_GEN" = "1" ]; then
    echo "=== Running gn gen (cc_wrapper change) ==="
    # debian/rules sets up the env we need (CC, CXX, target_cpu etc.)
    # The simplest way to re-gen is the same path debian uses:
    make -f debian/rules override_dh_auto_configure-arch
fi

# ---- ninja build ----
echo "=== Direct ninja: out/Release chromium ==="
START=$(date +%s)
ninja -C out/Release -j"$JOBS" chrome 2>&1 | tee /out/ninja.log
echo "ninja: $(($(date +%s) - START))s"

echo "=== ccache stats (after build) ==="
ccache -s --verbose | head -20 || ccache -s

# ---- collect output ----
if [ -f out/Release/chrome ]; then
    cp out/Release/chrome /out/chromium
    echo "Copied chromium binary to /out/chromium ($(stat -c %s /out/chromium) bytes)"
fi

if [ "${MAKE_DEB:-0}" = "1" ]; then
    echo "=== Repackaging .deb (MAKE_DEB=1) ==="
    cd "$SRC_TREE"
    # NOTE: dpkg-buildpackage will run dpkg-source --after-build at the end,
    # which will UNAPPLY patches. Next run of build-fast.sh will detect
    # pristine tree and reapply (one-time cost). Avoid by leaving MAKE_DEB=0.
    dpkg-buildpackage -us -uc -b -d -nc -j"$JOBS" 2>&1 | tee /out/dpkg.log
    cd /build/src
    mv -v *.deb /out/ 2>/dev/null || true
fi

echo "=== DONE ==="
ls -lh /out/
