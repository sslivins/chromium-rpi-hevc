# Chromium with HEVC hardware decoding for Raspberry Pi 5

Patches the upstream Raspberry Pi Chromium package to enable
hardware-accelerated H.265 / HEVC decoding on Raspberry Pi 5 and CM5.
Supports 8-bit Main and 10-bit Main 10 through the Pi's stateless V4L2
decoder, with a Wayland/Mesa rendering path.

See the [latest release](https://github.com/sslivins/chromium-rpi-hevc/releases/latest)
for the current Chromium version, packages, tested configurations, and known
issues. Version-specific changes belong in the
[release notes](https://github.com/sslivins/chromium-rpi-hevc/releases).

## Requirements

- Raspberry Pi 5 or CM5 with an `arm64` OS compatible with the release packages.
- A kernel with the `rpi-hevc-dec` driver and access to the video/render devices.
- Mesa v3d with Broadcom SAND128 buffer support and a Wayland compositor.

## Install

Download the runtime `.deb` packages from the latest release, or use the
[GitHub CLI](https://cli.github.com/) on the Pi:

```bash
deb_dir="$(mktemp -d)"
gh release download --repo sslivins/chromium-rpi-hevc \
  -p 'chromium_*.deb' -p 'chromium-common_*.deb' \
  -p 'chromium-sandbox_*.deb' -p 'chromium-l10n_*.deb' \
  -D "$deb_dir" &&
sudo apt install "$deb_dir"/*.deb
```

Omitting the release tag downloads the latest release. Use packages from the
same release and check its OS requirements and published checksums before
installing. Debug-symbol, driver, and shell packages are not needed for normal
browser use.

## Usage and compatibility

Run Chromium as a normal, non-root user with sandboxing enabled. Some
[test launchers](pi-runtime/) use `--no-sandbox` for root-run diagnostics;
that is a runtime flag, not a property of the build, and should not be copied
into an everyday browsing setup.

Hardware codec support does not guarantee that a streaming service will select
HEVC. Websites can apply their own platform and codec restrictions. HDR output
also depends on the display and graphics stack, not just decoder support.

## Build

Use an `arm64` Linux build host with Docker, substantial RAM, and ample disk
space. Building Chromium is resource-intensive.

From the repository root:

```bash
docker build -t chromium-rpi-build build/

ROOT="$HOME/chromium-rpi-hevc-build"
mkdir -p "$ROOT/work" "$ROOT/out"

docker run --rm \
  -v "$ROOT/work:/build" \
  -v "$PWD/patches:/patches:ro" \
  -v "$ROOT/out:/out" \
  chromium-rpi-build full
```

Packages are written to `$ROOT/out/`; retain the mounted directories for
incremental builds and compiler caching. The build downloads pinned upstream
source, verifies its SHA256 checksums, and applies the local patches.
The pin is maintained in [`build/cli.sh`](build/cli.sh); see
[upstream source pinning](docs/upstream-source-pinning.md) for the update process.

For available build commands and options:

```bash
docker run --rm chromium-rpi-build help
```

## Diagnostics and development

- [HEVC validation harness](pi-runtime/hevc-validate/README.md): on-device codec,
  hardware-decoder, and rendered-output checks. These tests take over the display.
- [Local patches](patches/): the current patch set and descriptions of each change.
- [Technical notes](docs/): decoder/rendering investigations and release procedures.

When reporting a problem, include the installed Chromium/package version,
Pi model, OS, kernel/Mesa versions, launch flags, and reproduction steps.
For playback issues, include the decoder reported by `chrome://media-internals/`
or `chrome://webrtc-internals/`, as appropriate.
