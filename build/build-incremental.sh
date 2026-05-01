#!/bin/bash
# Build chromium .debs with our local HEVC patches stacked on RPi-Distro's series.
# Smart: detects existing source tree and runs incrementally if so.
#
# Inputs:  /patches/*.patch   (added to debian/patches/series under local-hevc/)
#          /build-tools/rpi-distro-chromium/debian/  (vendored RPi-Distro packaging)
#          /build-tools/fetch-upstream.sh             (fetches + verifies upstream tarball)
# Outputs: /out/*.deb
#
# First run:    ~3-4 hr (download upstream tarball + extract + full ninja build)
# Incremental:  ~5-15 min (only changed objects relink)
#
# Incremental works because:
#   - extracted source tree is preserved on bind-mounted /build/src
#   - We explicitly drive ninja in out/Release rather than relying on dh stamps
#   - dpkg-buildpackage -nc skips clean and packages whatever ninja produced
#   - Local patches live under debian/patches/local-hevc/ (subdir) to avoid
#     basename collisions with Debian/RPi patches
set -euo pipefail

JOBS="${JOBS:-12}"
SRC_DIR=/build/src
mkdir -p "$SRC_DIR" /out
cd "$SRC_DIR"

MARKER_BEGIN="# === BEGIN LOCAL HEVC PATCHES ==="
MARKER_END="# === END LOCAL HEVC PATCHES ==="
LOCAL_SUBDIR="local-hevc"

# ---- detect prior source tree ----
mapfile -t TREES < <(find . -maxdepth 1 -type d -name 'chromium-*' | sort)
INCREMENTAL=0
SRC_TREE=""

if [ "${#TREES[@]}" -gt 1 ]; then
    echo "ERROR: multiple chromium-* source trees in /build/src; refusing to guess:"
    printf '  %s\n' "${TREES[@]}"
    echo "Delete the wrong one and rerun."
    exit 1
fi

if [ "${#TREES[@]}" -eq 1 ] && [ -f "${TREES[0]}/debian/patches/series" ]; then
    SRC_TREE="${TREES[0]}"
    INCREMENTAL=1
    echo "=== INCREMENTAL BUILD (source tree: $SRC_TREE) ==="
fi

if [ "$INCREMENTAL" = "0" ]; then
    echo "=== STAGE 0: vendored RPi-Distro debian/ ==="
    RPI_DEBIAN=/build-tools/rpi-distro-chromium/debian
    if [ ! -f "${RPI_DEBIAN}/changelog" ]; then
        echo "ERROR: ${RPI_DEBIAN}/changelog not found (submodule not baked into image)."
        echo "       Did you forget 'git submodule update --init' before docker build?"
        exit 1
    fi
    head -1 "${RPI_DEBIAN}/changelog"

    echo "=== STAGE 1: fetch+verify upstream tarball, extract, overlay debian/ ==="
    # Pinned chromium version — must match build/fetch-upstream.sh.
    CHROMIUM_VERSION="147.0.7727.101"
    TARBALL="/build/upstream/chromium-${CHROMIUM_VERSION}.tar.xz"
    EXPECTED_TREE="${SRC_DIR}/chromium-${CHROMIUM_VERSION}"

    /build-tools/fetch-upstream.sh
    if [ ! -f "$TARBALL" ]; then
        echo "ERROR: expected $TARBALL after fetch-upstream.sh"
        exit 1
    fi

    if [ ! -d "$EXPECTED_TREE" ]; then
        echo "Extracting $TARBALL into $SRC_DIR (~5.7 GB unpacked, takes a few minutes)..."
        tar -xf "$TARBALL" -C "$SRC_DIR"
        if [ ! -d "$EXPECTED_TREE" ]; then
            echo "ERROR: tarball did not produce expected directory $EXPECTED_TREE"
            ls -la "$SRC_DIR"
            exit 1
        fi
        echo "Overlaying RPi-Distro debian/ into source tree..."
        cp -a "${RPI_DEBIAN}" "${EXPECTED_TREE}/debian"
    fi

    SRC_TREE="$EXPECTED_TREE"
    echo "Source tree: $SRC_TREE"
fi

cd "$SRC_TREE"
export QUILT_PATCHES=debian/patches

# ---- recover from any prior dirty state BEFORE mutating series ----
if [ "$INCREMENTAL" = "1" ]; then
    echo "=== STAGE 2a: normalize patch state (unapply anything still applied) ==="
    # dpkg-source --after-build is idempotent and unapplies everything in series.
    # Falls back to quilt if --after-build doesn't apply (e.g. tree never patched).
    dpkg-source --after-build . 2>/dev/null \
        || quilt pop -af 2>/dev/null \
        || echo "(no patches to unapply, or already clean)"
fi

echo "=== STAGE 2b: existing patch series (head + tail) ==="
head -3 debian/patches/series
echo "..."
tail -5 debian/patches/series

# ---- sync local extras into series ----
echo "=== STAGE 3: sync /patches/*.patch into debian/patches/$LOCAL_SUBDIR/ ==="

# Validate marker block balance before deletion (sed range to EOF is dangerous).
begin_count=$(grep -cFx "$MARKER_BEGIN" debian/patches/series || true)
end_count=$(grep -cFx "$MARKER_END" debian/patches/series || true)
if [ "$begin_count" != "$end_count" ]; then
    echo "ERROR: unbalanced local patch markers in series (begin=$begin_count end=$end_count). Aborting."
    exit 1
fi
if [ "$begin_count" -gt 1 ]; then
    echo "ERROR: multiple local marker blocks in series. Aborting."
    exit 1
fi

# Strip previous local block + delete the local subdir
if [ "$begin_count" = "1" ]; then
    sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" debian/patches/series
    echo "Stripped previous local block from series."
fi
rm -rf "debian/patches/$LOCAL_SUBDIR"

# Strip any bare-named legacy entries from series that conflict with /patches/*.patch
# (defensive: prior build flows may have left these behind)
shopt -s nullglob
for p in /patches/*.patch; do
    name=$(basename "$p")
    sed -i -E "/^${name//./\.}$/d" debian/patches/series
    rm -f "debian/patches/$name"
done

# Append fresh local block
shopt -s nullglob
EXTRA_PATCHES=(/patches/*.patch)
if [ ${#EXTRA_PATCHES[@]} -gt 0 ]; then
    mkdir -p "debian/patches/$LOCAL_SUBDIR"
    echo "$MARKER_BEGIN" >> debian/patches/series
    for p in "${EXTRA_PATCHES[@]}"; do
        name=$(basename "$p")
        cp "$p" "debian/patches/$LOCAL_SUBDIR/$name"
        echo "$LOCAL_SUBDIR/$name" >> debian/patches/series
        echo "  added $LOCAL_SUBDIR/$name"
    done
    echo "$MARKER_END" >> debian/patches/series
else
    echo "No extra patches in /patches; building stock RPi-Distro source."
fi

# ---- apply patches; rollback on failure ----
echo "=== STAGE 4: apply patches via dpkg-source --before-build ==="
if ! dpkg-source --before-build .; then
    echo "ERROR: patch application failed. Rolling back."
    dpkg-source --after-build . || true
    exit 1
fi

# ---- build ----
echo "=== STAGE 5: build ==="
export DEB_BUILD_OPTIONS="parallel=$JOBS nocheck"

if [ "$INCREMENTAL" = "1" ]; then
    if [ ! -d out/Release ]; then
        echo "WARN: incremental requested but out/Release missing — falling through to full build."
        INCREMENTAL=0
    fi
fi

if [ "$INCREMENTAL" = "1" ]; then
    echo "Incremental: invoking debian/rules override_dh_auto_build-arch (handles gn gen + ninja with proper env)."
    START=$(date +%s)
    # This re-runs gn gen each invocation but ninja's incremental nature handles caching.
    # Necessary because direct ninja invocation hits broken toolchain.ninja if gn was never run with CC/CXX env.
    make -f debian/rules override_dh_auto_build-arch
    echo "build: $(($(date +%s) - START))s"

    echo "Repackaging via dpkg-buildpackage -nc (no clean)."
    START=$(date +%s)
    dpkg-buildpackage -us -uc -b -d -nc -j"$JOBS" 2>&1 | tee /out/build.log
    echo "dpkg-buildpackage: $(($(date +%s) - START))s"
else
    echo "Full build via dpkg-buildpackage."
    dpkg-buildpackage -us -uc -b -d -j"$JOBS" 2>&1 | tee /out/build.log
fi

echo "=== STAGE 6: collect .debs ==="
cd /build/src
mv -v *.deb /out/ 2>/dev/null || echo "no .debs in /build/src"
mv -v *.changes *.buildinfo /out/ 2>/dev/null || true

echo "=== DONE ==="
ls -lh /out/
