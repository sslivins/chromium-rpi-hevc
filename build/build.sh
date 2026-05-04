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
if ! dpkg-deb -c "$COMMON_DEB" | grep -q ' \./usr/lib/chromium/locales/en-US\.pak$'; then
    echo "ERROR: chromium-common is missing usr/lib/chromium/locales/en-US.pak" >&2
    exit 1
fi
echo "  ok: chromium-common contains en-US.pak"
if dpkg-deb -c "$L10N_DEB" | grep -q ' \./usr/lib/chromium/locales/en-US\.pak$'; then
    echo "ERROR: chromium-l10n still contains usr/lib/chromium/locales/en-US.pak" >&2
    echo "       STAGE 1c en-US.pak fix did not take effect." >&2
    exit 1
fi
echo "  ok: chromium-l10n does NOT contain en-US.pak (collision fixed)"

echo "=== DONE ==="
ls -lh /out/
