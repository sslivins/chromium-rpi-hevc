#!/bin/bash
# Build chromium .deb with our HEVC patches stacked on RPi-Distro's series.
# Runs inside the chromium-rpi-build container.
#
# This script assembles a Debian-source-format tree from THREE pinned inputs,
# none of which depend on `apt source` or the raspberrypi.com archive being
# current:
#   1. /build-tools/fetch-upstream.sh — fetches and SHA256-verifies the
#      chromium upstream .orig.tar.xz from Google's persistent
#      commondatastorage bucket.
#   2. /build-tools/rpi-distro-chromium/debian/ — RPi-Distro's chromium
#      packaging, vendored as a git submodule pinned to the tag matching
#      our build (see vendor/rpi-distro-chromium in the source repo).
#   3. /patches/*.patch — our HEVC HW-decode patches (this repo).
#
# Inputs (mounted or baked in by the container):
#   /build-tools/fetch-upstream.sh
#   /build-tools/rpi-distro-chromium/debian/...
#   /patches/*.patch
#
# Outputs:
#   /out/*.deb
set -euo pipefail

JOBS="${JOBS:-$(nproc)}"
SRC_DIR=/build/src
TOOLS_DIR=/build-tools
RPI_DEBIAN="${TOOLS_DIR}/rpi-distro-chromium/debian"
FETCH_SCRIPT="${TOOLS_DIR}/fetch-upstream.sh"
UPSTREAM_CACHE="${UPSTREAM_CACHE:-/build/upstream}"

# Pinned constants — must match fetch-upstream.sh's CHROMIUM_VERSION.
# The build script doesn't re-verify the version; it trusts fetch-upstream.sh
# to have produced the right tarball at the right path.
CHROMIUM_VERSION="147.0.7727.101"
TARBALL="${UPSTREAM_CACHE}/chromium-${CHROMIUM_VERSION}.tar.xz"
SRC_TREE="${SRC_DIR}/chromium-${CHROMIUM_VERSION}"

mkdir -p "$SRC_DIR" /out "$UPSTREAM_CACHE"

# ---- sanity: vendored RPi-Distro packaging present ----
if [ ! -f "${RPI_DEBIAN}/changelog" ]; then
    echo "ERROR: ${RPI_DEBIAN}/changelog not found."
    echo "       The container expects RPi-Distro's chromium packaging at ${RPI_DEBIAN}."
    echo "       This is supposed to be baked in by the Dockerfile from"
    echo "       vendor/rpi-distro-chromium (a git submodule of this repo)."
    echo "       Did you forget 'git submodule update --init' before docker build?"
    exit 1
fi
echo "=== STAGE 0: vendored debian/ found, top of changelog: ==="
head -1 "${RPI_DEBIAN}/changelog"

# ---- stage 1: upstream tarball ----
echo "=== STAGE 1: fetch + verify upstream chromium tarball ==="
"$FETCH_SCRIPT"
if [ ! -f "$TARBALL" ]; then
    echo "ERROR: expected $TARBALL after running fetch-upstream.sh"
    exit 1
fi

# ---- stage 2: assemble source tree (extract + overlay debian/) ----
echo "=== STAGE 2: assemble source tree at $SRC_TREE ==="
if [ -d "$SRC_TREE" ] && [ -f "$SRC_TREE/debian/changelog" ]; then
    echo "Source tree already exists at $SRC_TREE; reusing (incremental-friendly)."
    echo "To force a full re-extract, delete $SRC_TREE before running."
else
    rm -rf "$SRC_TREE"
    cd "$SRC_DIR"
    echo "Extracting $TARBALL (this is ~5.7 GB unpacked, takes a few minutes)..."
    tar -xf "$TARBALL"
    if [ ! -d "$SRC_TREE" ]; then
        echo "ERROR: tarball did not produce expected directory $SRC_TREE"
        echo "Contents of $SRC_DIR:"
        ls -la "$SRC_DIR"
        exit 1
    fi
    echo "Overlaying RPi-Distro debian/ into source tree..."
    cp -a "${RPI_DEBIAN}" "${SRC_TREE}/debian"
fi

cd "$SRC_TREE"

# ---- stage 3: layer our HEVC patches into the local-hevc subdir ----
# Same series-marker pattern that build-incremental.sh and build-fast.sh use,
# so the three scripts are interoperable on a shared source tree.
echo "=== STAGE 3: sync /patches/*.patch into debian/patches/local-hevc/ ==="
MARKER_BEGIN="# === BEGIN LOCAL HEVC PATCHES ==="
MARKER_END="# === END LOCAL HEVC PATCHES ==="
LOCAL_SUBDIR="local-hevc"

# Strip any prior local block (keeps re-runs idempotent).
if grep -qFx "$MARKER_BEGIN" debian/patches/series; then
    sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" debian/patches/series
    echo "Stripped previous local block from series."
fi
rm -rf "debian/patches/$LOCAL_SUBDIR"

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

# ---- stage 4: apply patches (RPi-Distro series + ours) ----
echo "=== STAGE 4: dpkg-source --before-build (applies full quilt series) ==="
# If a prior aborted build left applied patches, normalize first.
if [ -d .pc ]; then
    dpkg-source --after-build . 2>/dev/null || quilt pop -af 2>/dev/null || true
fi
if ! dpkg-source --before-build .; then
    echo "ERROR: dpkg-source --before-build failed."
    echo "       This usually means one of our patches no longer applies cleanly"
    echo "       on top of RPi-Distro's series. Inspect debian/patches/series"
    echo "       and the .rej files in the source tree."
    exit 1
fi

# ---- stage 5: build ----
echo "=== STAGE 5: dpkg-buildpackage (this is the long part — hours from cold) ==="
echo "Using $JOBS parallel jobs."
export DEB_BUILD_OPTIONS="parallel=$JOBS nocheck"
# -us -uc: no signing
# -b:     binary only (skip source package)
# -d:     don't check build-deps (already installed in image)
dpkg-buildpackage -us -uc -b -d -j"$JOBS" 2>&1 | tee /out/build.log

# ---- stage 6: collect artifacts ----
echo "=== STAGE 6: collect .debs ==="
# dpkg-buildpackage emits artifacts to the *parent* of the source tree.
cd "$SRC_DIR"
mv -v *.deb /out/ 2>/dev/null || echo "no .debs in $SRC_DIR"
mv -v *.changes *.buildinfo /out/ 2>/dev/null || true

echo "=== DONE ==="
ls -lh /out/
