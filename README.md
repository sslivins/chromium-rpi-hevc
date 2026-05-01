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

- Upstream package version: `chromium 1:147.0.7727.101-1~deb13u1+rpt1`
- Distribution: Debian Trixie (13) on Raspberry Pi
- Pinned reproducibility recipe (Phase 4):
  - **Upstream chromium source**: fetched from Google's persistent
    `commondatastorage.googleapis.com/chromium-browser-official/`
    bucket, SHA256-verified. Pinned in `build/fetch-upstream.sh`.
  - **RPi-Distro packaging**: vendored as a git submodule at
    `vendor/rpi-distro-chromium/`, pinned to tag
    `pios/1%147.0.7727.101-1_deb13u1+rpt1` on
    [`RPi-Distro/chromium`](https://github.com/RPi-Distro/chromium).
  - Our HEVC patches are layered on top via
    `debian/patches/local-hevc/` (see `patches/`).

Why not `apt-get source chromium`? The Raspberry Pi archive only retains
the *current* version of chromium. Once RPi-Distro publishes a newer
build, the source package for our pinned version is evicted and the
build is no longer reproducible. Vendoring the packaging + pinning the
upstream tarball at a content-addressed URL solves that.

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
| H265 delegate didn't submit `V4L2_CID_STATELESS_HEVC_SLICE_PARAMS` (rpi-hevc-dec is slice-based) and `bit_size` was wrong | `patches/0005-h265-slice-params-and-bitsize.patch` |
| `V4L2FormatToVideoFrameLayout` couldn't derive NC12 stride / SAND128 modifier missing | `patches/0006-v4l2-utils-nc12-sand128.patch` |
| `gbm_bo_import()` blocked by overly-strict `GetSupportedGbmFlags()!=0` gate | `patches/0007-gbm-import-gate-fix.patch` |

All seven patches under `patches/` are quilt-clean and applied via
`dpkg-source --before-build` (they go through `debian/patches/local-hevc/`).
The build scripts pick them up automatically — there is no separate
manual apply step.

## How to build

Build runs inside a Docker image (`chromium-rpi-build:trixie`) on a big
arm64 host (32+ GB RAM, fast disk strongly recommended). The first
build takes 6–10 hours; subsequent builds via `build-fast.sh` are
~3–5 min thanks to fingerprint-skip + ccache (50 GB).

The build context for the Dockerfile is the **repo root** (not
`build/`), so the Dockerfile can `COPY` the vendored RPi-Distro
packaging into the image.

```bash
# 0) Initialize the vendored RPi-Distro packaging submodule.
git submodule update --init --recursive

# 1) Build the build container (one-time, or whenever Dockerfile /
#    vendored debian/control / fetch-upstream.sh change).
docker build -f build/Dockerfile -t chromium-rpi-build:trixie .

# 2) Set up persistent state on the host:
#    out/         — produced .deb files land here
#    work/        — extracted source tree, ccache, upstream tarball cache
mkdir -p work out

# 3) First full build. Downloads + verifies the upstream chromium tarball
#    (~5.7 GB) on first run, caches it in work/upstream/. Then extracts,
#    overlays the vendored RPi-Distro debian/, applies patches/*.patch,
#    runs ninja + dpkg-buildpackage, and drops .deb files in out/.
docker run --rm \
  -v "$PWD/work:/build" \
  -v "$PWD/patches:/patches:ro" \
  -v "$PWD/out:/out" \
  chromium-rpi-build:trixie /build.sh

# 4) Fast incremental rebuild after patch tweaks (no .deb produced —
#    drops a raw chromium binary at out/chromium).
docker run --rm \
  -v "$PWD/work:/build" \
  -v "$PWD/patches:/patches:ro" \
  -v "$PWD/out:/out" \
  chromium-rpi-build:trixie /build-fast.sh
```

`build-fast.sh` hashes `/patches/*.patch`, stores a fingerprint, and
skips the entire `dpkg-source --before-build` reapply if the
fingerprint matches. ccache absorbs source mtime touches via
content-hash compile caching.

For reference, the `args.gn` used by `build.sh` is captured at
`docs/args.gn.reference`.

### Bumping the chromium version

To re-pin against a newer chromium release:

1. Update `CHROMIUM_VERSION` and `EXPECTED_SHA256` in
   `build/fetch-upstream.sh`. The expected SHA256 is published by
   Google at the same URL with a `.hashes` suffix.
2. Update `CHROMIUM_VERSION` in `build/build.sh` (and same in
   `build/build-incremental.sh`) to match.
3. Bump the submodule:
   `git -C vendor/rpi-distro-chromium fetch && git -C vendor/rpi-distro-chromium checkout <new-tag>`.
   Tags follow the pattern `pios/1%<version>-1_deb13u1+rpt1`.
4. Rebuild the docker image (`docker build -f build/Dockerfile ...`) so
   the vendored packaging is re-baked.
5. Re-run a full build, fix any patch refresh fallout, and cut a new
   release.

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
- Tested only at 1920×1080 Main-profile HEVC so far. Other
  resolutions, Main10, tiles/WPP have not been exercised.
- The Pi binary in this state is **not** safe to ship to end users
  (chroma corruption is visually obvious).

## Repo layout

```
chromium-rpi-hevc/
├── README.md
├── LICENSE
├── .gitignore
├── build/
│   ├── Dockerfile              # build context = repo root, not build/
│   ├── fetch-upstream.sh       # downloads + SHA256-verifies upstream tarball
│   ├── build.sh                # cold-build entrypoint (assemble + dpkg-buildpackage)
│   ├── build-incremental.sh    # full-build with incremental detection
│   └── build-fast.sh           # fingerprint-skip ninja-only iteration loop
├── vendor/
│   └── rpi-distro-chromium/    # submodule: pinned RPi-Distro packaging
├── patches/                    # quilt-clean, applied by build scripts
│   ├── 0001-probe-video19-for-hevc.patch
│   ├── 0002-add-nc12-fourcc.patch
│   ├── 0003-stateless-realloc-on-ebusy.patch
│   ├── 0004-nc12-renderable.patch
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
