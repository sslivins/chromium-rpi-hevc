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
CHROMIUM_VERSION_FULL="147.0.7727.101-1~deb13u1+rpt1"
CHROMIUM_VERSION_UPSTREAM="147.0.7727.101"
UPSTREAM_RELEASE_URL="${UPSTREAM_RELEASE_URL:-https://github.com/sslivins/chromium-rpi-hevc/releases/download/upstream-source-147.0.7727.101}"

# SHA256 of each source file as published by RPi-Distro and frozen in our release.
SHA256_ORIG="d4a5f648100232a67b3134a1fa6f6d1d8a07cc4c55b024480073b40c47b2a601"
SHA256_DEBIAN="6ed6ea4fe608e48747e29496e115d8c18b8c592fe339314fbc2619f4d7040452"
SHA256_DSC="ab18d58436f692f92da916920443335a038603ce66c75804481fb098474e1455"

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
