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

Source is pinned: `build.sh` fetches the three Debian source files
from this repo's `upstream-source-147.0.7727.116` GitHub Release and
SHA256-verifies them. See
[`docs/upstream-source-pinning.md`](docs/upstream-source-pinning.md)
for details and the bump procedure.

Build runs inside the `chromium-rpi-build` Docker image. Need an arm64
host with 32+ GB RAM and ~80 GB free disk. First build takes 6–10
hours; subsequent iterations via `build-fast.sh` are minutes (ccache).

```bash
docker build -t chromium-rpi-build build/

ROOT=$HOME/chromium-rpi-hevc-build
mkdir -p $ROOT/work $ROOT/out
cp -r patches $ROOT/patches

docker run --rm \
  -v "$ROOT/work:/build" \
  -v "$ROOT/patches:/patches:ro" \
  -v "$ROOT/out:/out" \
  chromium-rpi-build /build.sh
```

Output `.deb`s land in `$ROOT/out/`. For fast patch iteration use
`build/build-fast.sh` (skips `dpkg-buildpackage`, runs `ninja`
directly, produces just the binary).

> Build-script consolidation and ccache hardening is being tracked
> separately — current scripts work, but the next iteration will
> collapse `build.sh` and `build-fast.sh` into a single CLI.

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
build/        Dockerfile + build scripts
patches/      quilt-clean HEVC patches
pi-runtime/   sample compositor + launch scripts for the Pi
docs/         pinning procedure, upstream patch list, diagnostic notes
```
