# HEVC HW decode on Raspberry Pi 5 — Chromium 147 patches

End-to-end HEVC hardware decode on Raspberry Pi 5 via the upstream
**`rpi-hevc-dec`** stateless V4L2 driver (`/dev/video19`), in Chromium
147.0.7727.116 built for Debian Trixie (arm64).

## Status

- **Working end-to-end at 1920×1080 Main HEVC** including weighted-prediction scenes
  (fades, dissolves) which were corrupted in v0.2.0–v0.2.1 and fixed in v0.2.2.
- Hardware decode via `/dev/video19`. NC12 frames imported into Wayland via the
  `BROADCOM_SAND128` dmabuf modifier and displayed by `cage`. Luma + chroma both correct.
- 10-bit (Main 10) and HDR are not yet supported — see issue #14.

## Source / version pin

- Upstream package: `chromium 1:147.0.7727.116-1~deb13u1+rpt1`
- Distribution: Debian Trixie (13) on Raspberry Pi
- **Source is pinned and SHA256-verified.** `build.sh` fetches the
  three source files (`*.orig.tar.xz`, `*.debian.tar.xz`, `*.dsc`)
  from a frozen mirror published as a GitHub Release on this repo
  (tag `upstream-source-147.0.7727.116`). The base Docker image is
  pinned to a specific `debian:trixie` manifest digest. See
  [`docs/upstream-source-pinning.md`](docs/upstream-source-pinning.md)
  for details and the bump procedure.

The upstream `chromium` package already carries ~100 patches from
the Raspberry Pi packaging team — see
`docs/upstream-applied-patches.txt` for the full list applied
**before** any patch in this repo.

## What this repo fixes

The Pi 5 has a stateless V4L2 HEVC decoder (`/dev/video19`,
`rpi-hevc-dec`) that exposes hardware decode through the standard
`V4L2_PIX_FMT_HEVC_SLICE` controls. Chromium 147 has the framework to
talk to a stateless H.265 decoder, but several gaps prevent it from
finding `/dev/video19`, accepting the column-tiled `NC12` output
fourcc, importing those frames into Wayland with the
`BROADCOM_SAND128` modifier, and submitting all the slice parameters
the kernel needs. The eight patches in `patches/` close those gaps:

| # | Gap closed |
| - | --- |
| 0001 | `v4l2_utils.cc` rolled-up Pi 5 fixes: probe `/dev/video19` for HEVC, map NC12 to the `BROADCOM_SAND128` dmabuf modifier, derive correct stride / chroma offset for SAND128-tiled NC12 in `V4L2FormatToVideoFrameLayout`. |
| 0002 | Register the `NC12` fourcc with Chromium's format tables (was unknown). |
| 0003 | Re-allocate OUTPUT buffers when the kernel rejects `S_FMT` with `EBUSY` (stateless decoders need this). |
| 0004 | Add `NC12` to the default preferred renderable fourcc list (the Chrome-OS-flavoured path inside `VideoDecoderPipeline`). |
| 0005 | Submit `V4L2_CID_STATELESS_HEVC_SLICE_PARAMS` per slice (rpi-hevc-dec is slice-based, not frame-based) and use the correct `bit_size` (`end_off_in_frame * 8`). |
| 0006 | Weaken an over-strict gate in `gbm_wrapper.cc` so `gbm_bo_import()` can succeed for `BROADCOM_SAND128`. |
| 0007 | Add `NC12` to `GetPreferredRenderableFourccs` in the Linux mojo media client (the path Chrome actually uses on Pi). |
| 0008 | Populate the full `v4l2_hevc_pred_weight_table` so the kernel can reconstruct weighted-prediction samples correctly. Without this, scene fades to/from black turn into deterministic per-frame corruption. |

All patches under `patches/` are quilt-clean and applied via
`dpkg-source --before-build` (they go through
`debian/patches/local-hevc/`). The build scripts pick them up
automatically — there is no separate manual apply step.

## How to build

Build is performed inside the `chromium-rpi-build` Docker image on a
big arm64 host (32+ GB RAM, fast disk strongly recommended). The
first full build via `build.sh` takes 6–10 hours and produces
runtime + dbgsym .debs. Subsequent iterations via `build-fast.sh` are
~3–5 min thanks to a patch-fingerprint skip and ccache (50 GB).

`build-fast.sh` requires that `build.sh` has run at least once in the
same `/build` mount — it relies on the source tree, the gn-generated
`out/Release/`, and the ccache directory that `build.sh` populates.

### One-time: build the container

```bash
# From repo root
docker build -t chromium-rpi-build build/
```

### Set up host layout

The build scripts assume the following bind-mounts inside the
container. Pick a `$ROOT` with plenty of disk (~80 GB free).

```bash
ROOT=$HOME/chromium-rpi-hevc-build
mkdir -p $ROOT/work $ROOT/out
cp -r patches $ROOT/patches
```

| Host                | Container path | Purpose |
| ------------------- | -------------- | ------- |
| `$ROOT/work`        | `/build`       | apt-get source tree, ccache, build state |
| `$ROOT/patches`     | `/patches`     | local HEVC patches (read-only) |
| `$ROOT/out`         | `/out`         | output: `chromium` binary, .debs, logs |

### First full build (`build.sh`)

This downloads the pinned chromium source (~790 MB compressed) from
this repo's `upstream-source-147.0.7727.116` GitHub Release and
SHA256-verifies it, appends `/patches/*.patch` to
`debian/patches/series`, and runs the full Debian build via
`dpkg-buildpackage`. Output is .debs in `/out`.

```bash
docker run --rm \
  -v "$ROOT/work:/build" \
  -v "$ROOT/patches:/patches:ro" \
  -v "$ROOT/out:/out" \
  chromium-rpi-build /build.sh
```

Artifacts produced in `$ROOT/out/`:

- `chromium_*.deb`, `chromium-common_*.deb`, `chromium-driver_*.deb`,
  `chromium-l10n_*.deb`, `chromium-sandbox_*.deb` (runtime)
- `chromium-shell_*.deb`, `chromium-headless-shell_*.deb`
- Matching `*-dbgsym_*.deb` packages
- `*.buildinfo`, `*.changes`
- `build.log`

### Fast incremental rebuilds (`build-fast.sh`)

Use this for patch iteration. It hashes `/patches/*.patch`, skips
re-applying patches if the fingerprint matches, and runs `ninja`
directly against `out/Release` — bypassing `dpkg-buildpackage`.
Output is just `out/chromium`, not .debs (set `MAKE_DEB=1` to
repackage; this re-runs `dpkg-buildpackage -nc` which adds 5–10 min).

```bash
# Copy build-fast.sh into the running tree, then exec it.
docker run --rm \
  -v "$ROOT/work:/build" \
  -v "$ROOT/patches:/patches:ro" \
  -v "$ROOT/out:/out" \
  -v "$PWD/build/build-fast.sh:/usr/local/bin/build-fast.sh:ro" \
  chromium-rpi-build /usr/local/bin/build-fast.sh
```

The output binary is `$ROOT/out/chromium` (~412 MB unstripped, ~258
MB stripped). For reference, the `args.gn` used by `build.sh` is
captured at `docs/args.gn.reference`.

## How to deploy to a Pi

### Option A — install the .debs (recommended)

```bash
# Copy all 5 runtime .debs to the Pi
scp out/chromium*.deb <user>@<pi-ip>:/tmp/

ssh <user>@<pi-ip> 'sudo dpkg -i /tmp/chromium*.deb'
```

This installs `/usr/lib/chromium/chromium` and pulls in all support
files (locales, sandbox, driver). As of v0.2.1 the `en-US.pak`
packaging collision between `chromium-common` and `chromium-l10n` is
fixed (chromium-common is the sole owner) so `dpkg -i` installs
cleanly without `--force-overwrite`.

### Option B — drop in just the binary (for fast dev iteration)

```bash
scp out/chromium <user>@<pi-ip>:/tmp/chromium

# Push runtime helpers (one-time, or whenever they change)
scp pi-runtime/launch_hevc.sh <user>@<pi-ip>:/tmp/launch_hevc.sh
scp pi-runtime/sway-hevc.conf <user>@<pi-ip>:/tmp/sway-hevc.conf
scp pi-runtime/run_chromium.sh <user>@<pi-ip>:/tmp/run_chromium.sh
scp pi-runtime/test_hevc_page.html <user>@<pi-ip>:/home/<user>/hevc-test/test_hevc_page.html

ssh <user>@<pi-ip>
sudo systemctl stop hevc-test 2>/dev/null || true
sudo cp /tmp/chromium /usr/lib/chromium/chromium
sudo chmod +x /tmp/launch_hevc.sh /tmp/run_chromium.sh
sudo systemd-run --unit=hevc-test /tmp/launch_hevc.sh
journalctl -u hevc-test -f
```

The runtime runs Chromium inside a sway compositor (Wayland) for
native gbm import of the V4L2 dmabufs.

## Pi prerequisites

- Raspberry Pi OS / Debian 13 (Trixie) arm64
- Kernel with `rpi-hevc-dec` (`/dev/video19` present, owned by `video`)
- Mesa with v3d driver, `DRM_FORMAT_MOD_BROADCOM_SAND128` modifier supported
- A user with password-less sudo (default `pi` works; adjust paths in `pi-runtime/launch_hevc.sh` if different)
- A 1920×1080 HEVC test asset (we used a public-domain panda clip)

## Test snapshot

```bash
ssh <user>@<pi-ip>
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/tmp/sway-run grim /tmp/screen.png
scp /tmp/screen.png back-to-host:.
```

## Known limitations / next steps

- **No 10-bit / HDR yet.** Current patches handle Main profile (8-bit) only.
  10-bit (Main 10) and HDR support is tracked in issue #14 with a phased
  plan: Phase 1 forwards `bit_depth_*_minus8` from the SPS and downconverts
  to 8-bit on output (SDR); Phase 2 adds full 10-bit pass-through with
  `V4L2_PIX_FMT_NV12_10_COL128` / `P010` negotiation and a runtime monitor probe.
- **Tested only at 1920×1080 Main profile.** Other resolutions, tiles, and WPP have not been exercised.
- **Plymouth can hold `/dev/dri/card1`.** `plymouthd --mode=boot` sometimes stays
  alive past boot and blocks `cage` from starting on the next reboot. Manual fix:
  `sudo plymouth quit; sudo pkill -9 plymouthd`. This is a Pi-OS / system-level
  issue, not a Chromium one.

## Repo layout

```
chromium-rpi-hevc/
├── README.md
├── LICENSE
├── .gitignore
├── build/
│   ├── Dockerfile
│   ├── build.sh                # full-build entrypoint
│   └── build-fast.sh           # fingerprint-skip incremental
├── patches/                    # quilt-clean, applied by build scripts
│   ├── 0001-v4l2-utils-pi5.patch
│   ├── 0002-add-nc12-fourcc.patch
│   ├── 0003-stateless-realloc-on-ebusy.patch
│   ├── 0004-nc12-renderable.patch
│   ├── 0005-h265-slice-params-and-bitsize.patch
│   ├── 0006-gbm-import-gate-fix.patch
│   ├── 0007-nc12-in-mojo-client-renderable.patch
│   └── 0008-hevc-pred-weight-table.patch
├── pi-runtime/                 # systemd-run target on the Pi
│   ├── launch_hevc.sh
│   ├── sway-hevc.conf
│   ├── run_chromium.sh
│   └── test_hevc_page.html
└── docs/
    ├── chroma-bug.md
    ├── chroma-bug-screenshot.png
    ├── args.gn.reference
    └── upstream-applied-patches.txt
```

## History / context

The chroma SAND128 bug that produced vertical magenta/green banding
is documented in `docs/chroma-bug.md`. It was fixed in v0.2.0 by
deriving the chroma offset from `height * 128` (SAND128 column tile)
rather than `y_stride * height` (linear NV12). That fix lives in
`patches/0001-v4l2-utils-pi5.patch` today, alongside the Pi 5
`/dev/video19` HEVC probe and the `BROADCOM_SAND128` modifier
mapping (the three were consolidated into a single patch in v0.2.1
since they all touch `v4l2_utils.cc`).

The weighted-prediction (scene fade) corruption that appeared after
chroma was solved is documented in patch 0008's commit message and
in PR #13. It was fixed in v0.2.2.
