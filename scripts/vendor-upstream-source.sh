#!/bin/bash
set -euo pipefail

POOL_URL_DEFAULT="https://archive.raspberrypi.com/debian/pool/main/c/chromium"

usage() {
    cat <<'EOF'
Usage: vendor-upstream-source.sh [--publish] VERSION

Download and verify every source component declared by the Raspberry Pi
Chromium .dsc. VERSION is the full Debian version without the epoch, for
example:

  153.0.8010.47-2~deb13u1+rpt1

Options:
  --publish     Create/update the upstream-source-<chromium-version> GitHub
                release and upload the verified source files.
  --write-pins  Rewrite the version/URL/SHA256 pins in build/cli.sh and the
                CHROMIUM_BUILD_DEPS_VERSION default in build/Dockerfile.

Environment:
  POOL_URL                 Override the Raspberry Pi package pool URL.
  VENDOR_DIR               Override the output directory.
  GITHUB_REPOSITORY        Override the release repository.
  UPSTREAM_RELEASE_TARGET  Git ref used when creating a release (default: main).
EOF
}

publish=0
write_pins=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --publish) publish=1; shift ;;
        --write-pins) write_pins=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) break ;;
    esac
done

[ "$#" -eq 1 ] || {
    usage >&2
    exit 2
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$publish" -eq 1 ]; then
    command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || {
        printf 'gh is missing or not authenticated (export GH_TOKEN); --publish would fail after the download\n' >&2
        exit 1
    }
fi

version_full="$1"
case "$version_full" in
    [0-9]*-*"~deb13u1+rpt"[0-9]*) ;;
    *)
        printf 'Invalid Chromium Debian version: %s\n' "$version_full" >&2
        exit 2
        ;;
esac

version_upstream="${version_full%%-*}"
pool_url="${POOL_URL:-$POOL_URL_DEFAULT}"
vendor_dir="${VENDOR_DIR:-$repo_root/vendor/upstream-source-$version_upstream}"
dsc="chromium_${version_full}.dsc"
release_version="${version_full//\~/-}"
release_version="${release_version//+/-}"
release_tag="upstream-source-$release_version"
github_repository="${GITHUB_REPOSITORY:-sslivins/chromium-rpi-hevc}"

mkdir -p "$vendor_dir"
cd "$vendor_dir"

fetch() {
    local name="$1"
    if [ -f "$name" ]; then
        printf 'cached: %s\n' "$name"
        return
    fi
    printf 'fetching: %s\n' "$name"
    curl --fail --location --retry 3 --retry-all-errors \
        --output "$name" "$pool_url/$name"
}

fetch "$dsc"

checksum_file=".source-components.sha256"
awk '
    /^Checksums-Sha256:$/ { in_checksums = 1; next }
    in_checksums && /^ [0-9a-f]{64} [0-9]+ / {
        print $1 "  " $3
        next
    }
    in_checksums { exit }
' "$dsc" >"$checksum_file"

[ -s "$checksum_file" ] || {
    printf 'No Checksums-Sha256 source components found in %s\n' "$dsc" >&2
    exit 1
}

while read -r _ name; do
    fetch "$name"
done <"$checksum_file"

sha256sum --check "$checksum_file"

dsc_sha256="$(sha256sum "$dsc" | awk '{print $1}')"
orig_sha256="$(awk '$2 ~ /\.orig\.tar\./ { print $1 }' "$checksum_file")"
orig_pregen_sha256="$(awk '$2 ~ /\.orig-pre-gen\.tar\./ { print $1 }' "$checksum_file")"
debian_sha256="$(awk '$2 ~ /\.debian\.tar\./ { print $1 }' "$checksum_file")"

cat <<EOF

Verified Chromium source pin:
  CHROMIUM_VERSION_FULL="$version_full"
  CHROMIUM_VERSION_UPSTREAM="$version_upstream"
  UPSTREAM_RELEASE_URL_DEFAULT="https://github.com/sslivins/chromium-rpi-hevc/releases/download/$release_tag"
  SHA256_ORIG="$orig_sha256"
  SHA256_ORIG_PREGEN="$orig_pregen_sha256"
  SHA256_DEBIAN="$debian_sha256"
  SHA256_DSC="$dsc_sha256"
EOF

for v in "$orig_sha256" "$orig_pregen_sha256" "$debian_sha256" "$dsc_sha256"; do
    [[ "$v" =~ ^[0-9a-f]{64}$ ]] || {
        printf 'Refusing to continue: bad SHA256 %q\n' "$v" >&2
        exit 1
    }
done

if [ "$write_pins" -eq 1 ]; then
    cli="$repo_root/build/cli.sh"
    dockerfile="$repo_root/build/Dockerfile"
    release_url="https://github.com/sslivins/chromium-rpi-hevc/releases/download/$release_tag"
    set_pin() {
        local name="$1" value="$2"
        grep -q "^readonly $name=\"" "$cli" || {
            printf 'pin %s not found in %s\n' "$name" "$cli" >&2
            exit 1
        }
        sed -i "s|^readonly $name=\".*\"\$|readonly $name=\"$value\"|" "$cli"
        grep -qxF "readonly $name=\"$value\"" "$cli" || {
            printf 'failed to write pin %s\n' "$name" >&2
            exit 1
        }
    }
    set_pin CHROMIUM_VERSION_FULL "$version_full"
    set_pin CHROMIUM_VERSION_UPSTREAM "$version_upstream"
    set_pin UPSTREAM_RELEASE_URL_DEFAULT "$release_url"
    set_pin SHA256_ORIG "$orig_sha256"
    set_pin SHA256_ORIG_PREGEN "$orig_pregen_sha256"
    set_pin SHA256_DEBIAN "$debian_sha256"
    set_pin SHA256_DSC "$dsc_sha256"
    sed -i "s|^ARG CHROMIUM_BUILD_DEPS_VERSION=.*\$|ARG CHROMIUM_BUILD_DEPS_VERSION=$version_full|" "$dockerfile"
    grep -qxF "ARG CHROMIUM_BUILD_DEPS_VERSION=$version_full" "$dockerfile" || {
        printf 'failed to write CHROMIUM_BUILD_DEPS_VERSION in %s\n' "$dockerfile" >&2
        exit 1
    }
    printf '\nWrote pins to build/cli.sh and build/Dockerfile.\n'
fi

if [ "$publish" -eq 0 ]; then
    exit 0
fi

command -v gh >/dev/null || {
    printf 'gh is required with --publish\n' >&2
    exit 1
}

notes_file="$(mktemp)"
trap 'rm -f "$notes_file"' EXIT
{
    printf 'Pinned Raspberry Pi Chromium source artifacts for `%s`.\n\n' "$version_full"
    printf 'SHA256:\n\n```text\n'
    cat "$checksum_file"
    printf '%s  %s\n' "$dsc_sha256" "$dsc"
    printf '```\n'
} >"$notes_file"

if ! gh release view "$release_tag" \
    --repo "$github_repository" >/dev/null 2>&1; then
    gh release create "$release_tag" \
        --repo "$github_repository" \
        --target "${UPSTREAM_RELEASE_TARGET:-main}" \
        --title "$release_tag" \
        --notes-file "$notes_file"
fi

assets=("$dsc")
while read -r _ name; do
    assets+=("$name")
done <"$checksum_file"
gh release upload "$release_tag" \
    --repo "$github_repository" --clobber "${assets[@]}"

printf 'Published %s with %d verified assets.\n' \
    "$release_tag" "${#assets[@]}"
