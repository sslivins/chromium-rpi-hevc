#!/bin/bash
# Build chromium .deb with our HEVC patches stacked on top of RPi-Distro's series.
# Runs inside the chromium-rpi-build container.
# Inputs:  /patches/*.patch   (any extra patches to add to debian/patches/series)
# Outputs: /out/*.deb
set -euo pipefail

JOBS="${JOBS:-12}"
SRC_DIR=/build/src
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

echo "=== STAGE 0: refresh apt lists (cleared in Dockerfile to slim layers) ==="
apt-get update

echo "=== STAGE 1: apt source chromium (this downloads ~3-5GB) ==="
# Pin to the +rpt1 source from raspberrypi.com archive. apt-get source picks the
# highest-version source available; raspi archive's 147.0.7727.101-1~deb13u1+rpt1
# is the current one. If we want .55 specifically we'd snapshot.debian.org it,
# but for now newest-rpt1 is fine.
apt-get source chromium

# apt-get source extracts as chromium-VERSION/. Find it.
SRC_TREE=$(find . -maxdepth 1 -type d -name 'chromium-*' | head -1)
if [ -z "$SRC_TREE" ]; then
    echo "ERROR: no chromium-* source tree found after apt source"
    ls -la
    exit 1
fi
echo "Source tree: $SRC_TREE"
cd "$SRC_TREE"

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

echo "=== STAGE 4: dpkg-buildpackage (this is the long part, hours) ==="
echo "Using $JOBS parallel jobs."
export DEB_BUILD_OPTIONS="parallel=$JOBS nocheck"
# -us -uc: no signing
# -b: binary only
# -d: don't check build deps (they're already installed)
dpkg-buildpackage -us -uc -b -d -j"$JOBS" 2>&1 | tee /out/build.log

echo "=== STAGE 5: collect .debs ==="
# dpkg-buildpackage emits artifacts to the *parent* of the source tree (i.e. /build/src/)
cd /build/src
mv -v *.deb /out/ 2>/dev/null || echo "no .debs in /build/src"
mv -v *.changes *.buildinfo /out/ 2>/dev/null || true

echo "=== DONE ==="
ls -lh /out/
