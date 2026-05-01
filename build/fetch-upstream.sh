#!/bin/bash
# Fetch the chromium upstream source tarball from Google's persistent
# commondatastorage bucket, verify its SHA256 against a pinned constant,
# and cache it locally.
#
# This is the long-term-reproducible source of the chromium .orig.tar.xz.
# The raspberrypi.com archive only retains the *current* +rpt1 source, so
# re-fetching from there is unreliable. Google's bucket retains every
# released tarball indefinitely.
#
# Outputs:
#   /build/upstream/chromium-${CHROMIUM_VERSION}.tar.xz   (cached, sha256-verified)
#
# Bump procedure for a new chromium version (e.g. 147.0.7727.116):
#   1. Download the new .hashes file:
#        curl -fsSL https://commondatastorage.googleapis.com/chromium-browser-official/chromium-147.0.7727.116.tar.xz.hashes
#   2. Update CHROMIUM_VERSION + EXPECTED_SHA256 below.
#   3. Update vendor/rpi-distro-chromium submodule to the corresponding
#      RPi-Distro tag (e.g. pios/1%147.0.7727.116-1_deb13u1+rpt1).
#   4. Rebuild and verify our quilt patches still apply.
set -euo pipefail

CHROMIUM_VERSION="147.0.7727.101"
EXPECTED_SHA256="8430437ccb9756c9e8fa179e1899e49fceeac28cd2dee433a514a4a8ab22611b"

CACHE_DIR="${CACHE_DIR:-/build/upstream}"
TARBALL="chromium-${CHROMIUM_VERSION}.tar.xz"
URL="https://commondatastorage.googleapis.com/chromium-browser-official/${TARBALL}"

mkdir -p "$CACHE_DIR"
cd "$CACHE_DIR"

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: SHA256 mismatch on $file"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        return 1
    fi
    echo "SHA256 OK: $file"
    return 0
}

if [ -f "$TARBALL" ]; then
    echo "Found cached $TARBALL; verifying checksum..."
    if verify_sha256 "$TARBALL" "$EXPECTED_SHA256"; then
        echo "Cache hit: $CACHE_DIR/$TARBALL"
        exit 0
    fi
    echo "Cache file checksum mismatch; removing and re-downloading."
    rm -f "$TARBALL"
fi

echo "Fetching $URL (this is ~5.7 GB; expect 5-30 min depending on bandwidth)..."
# wget with --continue handles partial downloads cleanly across reruns.
wget --continue --progress=dot:giga "$URL"

echo "Verifying SHA256..."
verify_sha256 "$TARBALL" "$EXPECTED_SHA256"

echo "Cached at: $CACHE_DIR/$TARBALL"
