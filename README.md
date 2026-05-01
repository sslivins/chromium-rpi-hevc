# HEVC HW decode on Raspberry Pi 5 — Chromium 147 patches

End-to-end HEVC hardware decode on Raspberry Pi 5 via the upstream
**`rpi-hevc-dec`** stateless V4L2 driver (`/dev/video19`), in Chromium
147.0.7727.101 built for Debian Trixie (arm64).

## Status

- **Decode works.** 4928 unique POCs decoded continuously, no GPU
  process crashes, hevc-test service stable.
- **Luma displays correctly.** Picture content (e.g. test panda clip)
  is recognizable and motion is smooth.
- **Chroma is corrupt** — magenta/bright-green vertical banding at
  ~128 px column boundaries. Confirmed via `grim` snapshot
  (`docs/chroma-bug-screenshot.png`). This is the next bug to fix;
  see `docs/chroma-bug.md`.

## Source / version pin

- Upstream package: `chromium 1:147.0.7727.101-1~deb13u1+rpt1`
- Distribution: Debian Trixie (13) on Raspberry Pi
- Source obtained via: `apt-get source chromium=1:147.0.7727.101-1~deb13u1+rpt1`
  inside the `chromium-rpi:trixie` build container

The upstream `chromium` package already carries ~100 patches from
the Raspberry Pi packaging team — see
`docs/upstream-applied-patches.txt` for the full list applied
**before** any patch in this repo.

## What this repo fixes

This work fills three Chromium upstream gaps for stateless HEVC on
Pi 5:

| Gap | Patch |
| --- | --- |
| Decoder probe didn't try `/dev/video19` for HEVC | `patches/0001-probe-video19-for-hevc.patch` |
| `NC12` fourcc unknown to Chromium | `patches/0002-add-nc12-fourcc.patch` |
| Stateless realloc on `EBUSY` was missing | `patches/0003-stateless-realloc-on-ebusy.patch` |
| `NC12` not in renderable list (default fourcc rejected) | `patches/0004-nc12-renderable.patch` |
| H265 delegate didn't submit `V4L2_CID_STATELESS_HEVC_SLICE_PARAMS` (rpi-hevc-dec is slice-based) and `bit_size` was wrong | `floating-edits/0005-h265-slice-params-and-bitsize.patch` |
| `V4L2FormatToVideoFrameLayout` couldn't derive NC12 stride / SAND128 modifier missing | `floating-edits/0006-v4l2-utils-nc12-sand128.patch` |
| `gbm_bo_import()` blocked by overly-strict `GetSupportedGbmFlags()!=0` gate | `floating-edits/0007-gbm-import-gate-fix.patch` |

Patches `0001-0004` are quilt-clean and applied via
`dpkg-source --before-build` (i.e. they go through `debian/patches`).

The three diffs in `floating-edits/` are raw unified-diffs against
the in-tree files. They need to be re-formalized as proper quilt
patches before any clean merge / dpkg ship.

> ⚠️ **The build scripts in `build/` only apply `patches/*.patch`.**
> The floating edits in `floating-edits/` must be applied **manually**
> after the source is patched via the helper:
>
> ```bash
> ./apply-floating.sh /path/to/work/chromium-147.0.7727.101
> ```
>
> If you skip this step, the build will succeed but produce a
> binary that does **not** decode HEVC.

## How to build

Build is performed inside the `chromium-rpi:trixie` Docker image on
a big VM (32+ GB RAM, fast disk strongly recommended). The first
build takes 6–10 hours; subsequent builds via `build-fast.sh` are
~3–5 min thanks to fingerprint-skip + ccache (50 GB).

```bash
# 1) Build the build container (one-time)
docker build -t chromium-rpi:trixie build/

# 2) Set up the build root layout. The scripts assume:
#    $ROOT/work/                       # build state, sources, .ccache
#    $ROOT/patches/                    # mounted as /patches inside container
#    $ROOT/out/                        # output binaries
mkdir -p work out
cp patches/*.patch /tmp/  # build-fast.sh expects them at /patches inside the container

# 3) First full build (downloads source via apt-get source, applies
#    patches, gn gen, ninja, packages .deb if MAKE_DEB=1)
docker run --rm \
  -v "$PWD/work:/build" \
  -v "$PWD/patches:/patches:ro" \
  -v "$PWD/out:/out" \
  -e MAKE_DEB=0 \
  chromium-rpi:trixie /build/build.sh

# 4) Apply floating edits (one-time, after source tree exists)
./apply-floating.sh "$PWD/work/chromium-147.0.7727.101"

# 5) Fast incremental builds
docker run --rm \
  -v "$PWD/work:/build" \
  -v "$PWD/patches:/patches:ro" \
  -v "$PWD/out:/out" \
  -e MAKE_DEB=0 \
  chromium-rpi:trixie /build/build-fast.sh
```

`build-fast.sh` hashes `/patches/*.patch`, stores a fingerprint, and
skips the entire `dpkg-source --before-build` reapply if the
fingerprint matches. ccache absorbs source mtime touches via
content-hash compile caching.

The output binary is `out/chromium` (~412 MB, stripped, no
.deb unless `MAKE_DEB=1`).

For reference, the `args.gn` used by `build.sh` is captured at
`docs/args.gn.reference`.

## How to deploy to a Pi

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

- **SAND128 chroma offset bug** — luma clean, chroma garbled.
  See `docs/chroma-bug.md` for hypothesis, evidence, and the
  recommended investigation order (read Mesa v3d SAND import code
  before changing anything).
- Floating edits need quilt formalization before this can be
  cleanly upstreamed or shipped via dpkg.
- Tested only at 1920×1080 Main-profile HEVC so far. Other
  resolutions, Main10, tiles/WPP have not been exercised.
- The Pi binary in this state is **not** safe to ship to end users
  (chroma corruption is visually obvious).

## Repo layout

```
chromium-rpi-hevc/
├── README.md
├── LICENSE
├── apply-floating.sh           # apply floating-edits/ on top of src
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
│   └── 0004-nc12-renderable.patch
├── floating-edits/             # NOT auto-applied, run apply-floating.sh
│   ├── 0005-h265-slice-params-and-bitsize.patch
│   ├── 0006-v4l2-utils-nc12-sand128.patch
│   └── 0007-gbm-import-gate-fix.patch
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
issue thread and `docs/chroma-bug.md` for the next debug step.
