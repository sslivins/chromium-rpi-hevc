# HEVC HW decode on Raspberry Pi 5 — Chromium 147 patches

End-to-end HEVC hardware decode on Raspberry Pi 5 via the upstream
**`rpi-hevc-dec`** stateless V4L2 driver (`/dev/video19`), in Chromium
147.0.7727.101 built for Debian Trixie (arm64).

## Status

- **Working end-to-end at 1920×1080 Main-profile HEVC.** Hardware
  decode via `/dev/video19`, NC12 frames imported into Wayland via
  `BROADCOM_SAND128` dmabuf modifier, displayed by `cage`.
- **Luma + chroma both correct.** The earlier SAND128 chroma offset
  bug (vertical magenta/green banding, see `docs/chroma-bug.md`) is
  fixed in `patches/0006-broadcom-sand128-modifier.patch` +
  `patches/0010-nc12-stride-derivation.patch`.
- **Verified runtime:** PICKFMT_DIAG `HIT NC12`, HEVC SPS streaming,
  no GPU process crashes, no chroma corruption.

## Source / version pin

- Upstream package: `chromium 1:147.0.7727.101-1~deb13u1+rpt1`
- Distribution: Debian Trixie (13) on Raspberry Pi
- Source obtained via: `apt-get source chromium` from
  `archive.raspberrypi.com/debian/ trixie main` inside the
  `chromium-rpi-build` container

The upstream `chromium` package already carries ~100 patches from
the Raspberry Pi packaging team — see
`docs/upstream-applied-patches.txt` for the full list applied
**before** any patch in this repo.

## What this repo fixes

This work fills the Chromium upstream gaps for stateless HEVC on
Pi 5:

| # | Gap | Patch |
| - | --- | --- |
| 0001 | Decoder probe didn't try `/dev/video19` for HEVC | `patches/0001-probe-video19-for-hevc.patch` |
| 0002 | `NC12` fourcc unknown to Chromium | `patches/0002-add-nc12-fourcc.patch` |
| 0003 | Stateless realloc on `EBUSY` was missing | `patches/0003-stateless-realloc-on-ebusy.patch` |
| 0004 | `NC12` not in renderable list (Chrome OS path) | `patches/0004-nc12-renderable.patch` |
| 0005 | H265 delegate didn't submit `V4L2_CID_STATELESS_HEVC_SLICE_PARAMS` (rpi-hevc-dec is slice-based) and `bit_size` was wrong | `patches/0005-h265-slice-params-and-bitsize.patch` |
| 0006 | NC12 fourcc not mapped to `BROADCOM_SAND128` dmabuf modifier | `patches/0006-broadcom-sand128-modifier.patch` |
| 0007 | `gbm_bo_import()` blocked by overly-strict `GetSupportedGbmFlags()!=0` gate | `patches/0007-gbm-import-gate-fix.patch` |
| 0008 | Diagnostic `LOG(WARNING)` traces in `VideoDecoderPipeline::PickDecoderOutputFormat` (kept in series — useful for future picker debugging) | `patches/0008-pickfmt-diag.patch` |
| 0009 | `NC12` not in renderable list (Linux/`gpu_mojo_media_client_linux.cc` path — what 0004 was trying to be) | `patches/0009-nc12-in-mojo-client-renderable.patch` |
| 0010 | `V4L2FormatToVideoFrameLayout` couldn't derive NC12 stride / chroma offset arithmetic for SAND128 | `patches/0010-nc12-stride-derivation.patch` |

All ten patches under `patches/` are quilt-clean and applied via
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
ROOT=$HOME/chromium-rpi-phase4
mkdir -p $ROOT/work $ROOT/out
cp -r patches $ROOT/patches
```

| Host                | Container path | Purpose |
| ------------------- | -------------- | ------- |
| `$ROOT/work`        | `/build`       | apt-get source tree, ccache, build state |
| `$ROOT/patches`     | `/patches`     | local HEVC patches (read-only) |
| `$ROOT/out`         | `/out`         | output: `chromium` binary, .debs, logs |

### First full build (`build.sh`)

This downloads ~3–5 GB of upstream source via `apt-get source`,
appends `/patches/*.patch` to `debian/patches/series`, and runs the
full Debian build via `dpkg-buildpackage`. Output is .debs in `/out`.

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
scp out/chromium*.deb agora@<pi-ip>:/tmp/

ssh agora@<pi-ip> 'sudo dpkg -i /tmp/chromium*.deb'
```

This installs `/usr/lib/chromium/chromium` and pulls in all support
files (locales, sandbox, driver). The known `en-US.pak` packaging
collision between `chromium-common` and `chromium-l10n` produces a
warning but both packages still install cleanly and runtime works.

### Option B — drop in just the binary (for fast dev iteration)

```bash
scp out/chromium agora@<pi-ip>:/tmp/chromium

# Push runtime helpers (one-time, or whenever they change)
scp pi-runtime/launch_hevc.sh agora@<pi-ip>:/tmp/launch_hevc.sh
scp pi-runtime/sway-hevc.conf agora@<pi-ip>:/tmp/sway-hevc.conf
scp pi-runtime/run_chromium.sh agora@<pi-ip>:/tmp/run_chromium.sh
scp pi-runtime/test_hevc_page.html agora@<pi-ip>:/home/agora/composer-proto/test_hevc_page.html

ssh agora@<pi-ip>
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
- `agora` user with password-less sudo (or adjust paths in `pi-runtime/launch_hevc.sh`)
- A 1920×1080 HEVC test asset (we used a public-domain panda clip)

## Test snapshot

```bash
ssh agora@<pi-ip>
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/tmp/sway-run grim /tmp/screen.png
scp /tmp/screen.png back-to-host:.
```

## Known limitations / next steps

- Tested only at 1920×1080 Main-profile HEVC so far. Other
  resolutions, Main10, tiles/WPP have not been exercised.
- `chromium-common` and `chromium-l10n` both ship
  `/usr/lib/chromium/locales/en-US.pak` — `dpkg -i` warns "trying to
  overwrite" but both still install. Should be fixed in
  `debian/rules` packaging logic.
- `plymouthd --mode=boot` can stay alive past boot and hold
  `/dev/dri/card1`, blocking `cage` from starting on the next reboot.
  Manual fix: `sudo plymouth quit; sudo pkill -9 plymouthd`. Tracked
  separately on `sslivins/agora`.
- Patch 0008 is a diagnostic patch (`LOG(WARNING)` only). It is
  intentionally kept in the series for future picker debugging — it
  can be removed with no behavioural impact.

## Repo layout

```
chromium-rpi-hevc/
├── README.md
├── LICENSE
├── .gitignore
├── build/
│   ├── Dockerfile
│   ├── build.sh                # full-build entrypoint
│   ├── build-fast.sh           # fingerprint-skip incremental
│   └── build-incremental.sh    # legacy, do not use
├── patches/                    # quilt-clean, applied by build scripts
│   ├── 0001-probe-video19-for-hevc.patch
│   ├── 0002-add-nc12-fourcc.patch
│   ├── 0003-stateless-realloc-on-ebusy.patch
│   ├── 0004-nc12-renderable.patch
│   ├── 0005-h265-slice-params-and-bitsize.patch
│   ├── 0006-broadcom-sand128-modifier.patch
│   ├── 0007-gbm-import-gate-fix.patch
│   ├── 0008-pickfmt-diag.patch
│   ├── 0009-nc12-in-mojo-client-renderable.patch
│   └── 0010-nc12-stride-derivation.patch
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

This work was done over several days against the Pi 5 / Debian
Trixie target. See PR `sslivins/agora-cms#486` for the original
issue thread. `docs/chroma-bug.md` documents the SAND128 chroma
offset bug that was fixed in patches 0006 + 0010.
