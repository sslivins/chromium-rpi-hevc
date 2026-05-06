# Chromium 147 with HEVC HW decode for Raspberry Pi 5

Patches the upstream Raspberry Pi `chromium 1:147.0.7727.116-1~deb13u1+rpt1`
package to enable hardware-accelerated HEVC decode (8-bit and 10-bit /
Main 10) via the Pi 5's stateless V4L2 decoder (`rpi-hevc-dec` on
`/dev/video19`).

## Status (v0.2.3)

- ✅ 8-bit Main HEVC at 1080p — including weighted prediction (fades / dissolves)
- ✅ 10-bit Main 10 HEVC at 1080p — NC30 / P030 zero-copy import via Mesa v3d
- ✅ NC12 (8-bit) and NC30 (10-bit) frames imported into Wayland with
  `BROADCOM_SAND128` dmabuf modifier; rendered by `cage` / `sway`
- ⚠️  HDR metadata is not yet handled (10-bit SDR only)

## Install (prebuilt debs)

Each tagged release on this repo ships full `arm64` debs.

```bash
gh release download v0.2.3 --repo sslivins/chromium-rpi-hevc -p '*.deb' -D /tmp/chromium-debs
sudo apt install /tmp/chromium-debs/chromium*.deb
```

`*-dbgsym_*.deb` packages are optional debug symbols (useful for `gdb`,
not required for normal use).

## Patches

12 quilt-clean patches in `patches/`, applied automatically by the
build scripts via `debian/patches/local-hevc/`.

| #    | Purpose |
| ---- | --- |
| 0001 | `v4l2_utils.cc`: probe `/dev/video19`, map NC12 to `BROADCOM_SAND128`, derive correct stride/chroma offset for SAND128-tiled NC12 |
| 0002 | Register `NC12` fourcc with chromium's format tables |
| 0003 | Re-allocate OUTPUT buffers when kernel rejects `S_FMT` with `EBUSY` (stateless decoders) |
| 0004 | Add `NC12` to the default preferred renderable fourcc list |
| 0005 | Submit `V4L2_CID_STATELESS_HEVC_SLICE_PARAMS` per slice with correct `bit_size` |
| 0006 | Weaken over-strict `gbm_wrapper.cc` gate so `gbm_bo_import()` accepts `BROADCOM_SAND128` |
| 0007 | Add `NC12` to `GetPreferredRenderableFourccs` in the Linux mojo media client |
| 0008 | Populate full `v4l2_hevc_pred_weight_table` (fixes weighted-prediction corruption on fades) |
| 0009 | Add `NC30` (10-bit) fourcc throughout chromium media stack |
| 0010 | NC30 stride derivation in V4L2 stateless decoder |
| 0011 | GBM `P030` import path for Mesa v3d driver |
| 0012 | EGL `P030` binding for compositor-side rendering |

The upstream Raspberry Pi chromium package already carries ~100
patches — see [`docs/upstream-applied-patches.txt`](docs/upstream-applied-patches.txt)
for the full list applied **before** any patch in this repo.

## Build

Source is pinned: `cli.sh fetch` downloads the three Debian source files
from this repo's `upstream-source-147.0.7727.116` GitHub Release and
SHA256-verifies them. See
[`docs/upstream-source-pinning.md`](docs/upstream-source-pinning.md)
for details and the bump procedure.

Build runs inside the `chromium-rpi-build` Docker image. Need an arm64
host with 32+ GB RAM and ~80 GB free disk. First build takes 6–10
hours; subsequent iterations via `fast` (skips `dpkg-buildpackage`,
runs `ninja` directly) are minutes thanks to ccache.

```bash
docker build -t chromium-rpi-build build/

ROOT=$HOME/chromium-rpi-hevc-build
mkdir -p $ROOT/work $ROOT/out

# Default CMD is `full`: fetch + patch + dpkg-buildpackage.
docker run --rm \
  -v "$ROOT/work:/build" \
  -v "$PWD/patches:/patches:ro" \
  -v "$ROOT/out:/out" \
  chromium-rpi-build
```

Output `.deb`s land in `$ROOT/out/`. The image's ENTRYPOINT is
`/usr/local/bin/chromium-rpi-hevc` (a single uber-script with
subcommands); pass any subcommand as the docker arg:

| Command | What it does |
| --- | --- |
| `full`      | fetch + patch + dpkg-buildpackage (full deb build, default) |
| `fast`      | patch + configure + ninja (fast iteration, no .deb) |
| `fetch`     | download + verify + extract pinned source only |
| `patch`     | apply local HEVC patches + en-US.pak fix |
| `doctor`    | preflight checks; nonzero exit if container is unhealthy |
| `status`    | print source tree state, stamps, ccache config |
| `shell`     | drop into a bash shell inside the container |
| `clean`     | remove source tree + outputs (NOT ccache) |

Useful global flags (must precede the subcommand): `--jobs N`,
`--no-ccache`, `-v` (shell trace).

```bash
# fast iteration loop after editing a patch:
docker run --rm -v "$ROOT/work:/build" -v "$PWD/patches:/patches:ro" \
  -v "$ROOT/out:/out" chromium-rpi-build fast
```

Legacy `build/build.sh` and `build/build-fast.sh` are kept as one-line
exec wrappers for backward compatibility; they will be removed in a
follow-up cleanup PR.

## Pi prerequisites

- Raspberry Pi 5 / CM5, Raspberry Pi OS or Debian Trixie (`arm64`)
- Kernel with `rpi-hevc-dec` (`/dev/video19` present, owned by `video` group)
- Mesa v3d driver with `DRM_FORMAT_MOD_BROADCOM_SAND128` modifier support
- A Wayland compositor for native gbm dmabuf import (`sway` / `cage`)

`pi-runtime/` contains a sample `cage` / `sway` launch wrapper used in
testing — adapt to your setup as needed.

## Known limitations

- HDR metadata not yet handled (10-bit SDR only)
- Tested at 1080p Main / Main 10. Other resolutions, tiles, and WPP
  configurations have not been exercised
- Plymouth can hold `/dev/dri/card1` past boot, blocking the
  compositor on next reboot. Workaround: `sudo plymouth quit; sudo pkill -9 plymouthd`
  (Pi-OS issue, not chromium)

## Repo layout

```
build/        Dockerfile + cli.sh (uber CLI) + legacy wrapper scripts
patches/      quilt-clean HEVC patches
pi-runtime/   sample compositor + launch scripts for the Pi
docs/         pinning procedure, upstream patch list, diagnostic notes
```
