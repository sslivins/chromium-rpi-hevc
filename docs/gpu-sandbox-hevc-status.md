# GPU sandbox status for the stateless HEVC decoder path

## Context

RPi-Distro's own downstream Chromium already carries a sandbox fix, merged
2026-08-03: `debian/patches/rpi/v4l2-sandbox-allow-decoder-devices.patch`
(https://github.com/RPi-Distro/chromium/pull/64). It grants the GPU process's
sandbox broker `ReadWrite` access to whatever
`V4L2Device::GetDevicesForType(Type::kDecoder)` reports, plus preloads and
brokers Mesa's `dri_gbm.so` backend, so that the *stateful* V4L2 decoder
(`/dev/video10`) can be driven without `--no-sandbox`.

This patch is present in the RPi-Distro source we currently vendor
(153.0.8010.47-2~deb13u1+rpt1, tag `pios/1%153.0.8010.47-2_deb13u1+rpt1`,
commit `cc2b0e9`) -- confirmed by inspecting that tag's
`debian/patches/series` and the patch file itself. We did not have to add it;
it is already in the tree our local `patches/*.patch` apply on top of.

## Open question this doc tracks

Our stateless HEVC decoder path is architecturally different from the
stateful path that patch was written and validated against:

- The known-good reference run in `pi-runtime/hevc-validate/README.md` shows
  `open_v4l2_nodes=["/dev/media2", "/dev/video19"]` -- i.e. the stateless
  decoder needs **both** a `/dev/videoN` node (capture/output queues, likely
  already covered by the existing patch's device enumeration) **and** a
  `/dev/mediaN` node (used by the V4L2 Request API to allocate per-frame
  request file descriptors via `MEDIA_IOC_REQUEST_ALLOC`).
- `V4L2Device::GetDevicesForType()` is a `V4L2Device`-class enumeration and,
  as far as we can tell without reading the full source tree, only walks
  `/dev/video*` nodes queried via `VIDIOC_QUERYCAP`. It has no reason to know
  about `/dev/media*` at all -- that's a separate Linux media-controller API.
- If that's right, the existing broker permissions cover `/dev/video19` but
  **not** `/dev/media2`, and dropping `--no-sandbox` would still fail with a
  permission-denied opening the media-request device, even though the video
  node itself opens fine.

## How we're finding out

Rather than guess at the fix, `pi-runtime/run_chromium_sandboxed.sh` (added
alongside this doc) launches the exact same HEVC test page as
`run_chromium.sh` but **without** `--no-sandbox`, with V4L2/sandbox/broker
vlogging turned up. Test procedure:

1. Build and install a `.deb` from this branch.
2. Run `run_chromium_sandboxed.sh` instead of `run_chromium.sh`.
3. Inspect `/tmp/chromium-hevc-sandboxed.err` for `Permission denied` on
   `/dev/video19` and/or `/dev/media*`, and whether the GPU process
   crash-loops.
4. Cross-check with `pi-runtime/hevc-validate/validate.py` (still invoked
   with `--no-sandbox` internally today -- see `gpu_report.py`/`validate.py`)
   to confirm hardware decode still works at all with the sandbox on.

Depending on what that shows, the fix (if needed) is a small local patch
adding a `/dev/media*` broker-permission grant to
`content/common/gpu_pre_sandbox_hook_linux.cc`, following the same pattern as
the already-vendored `v4l2-sandbox-allow-decoder-devices.patch`. Results and
any resulting patch will be recorded here.
