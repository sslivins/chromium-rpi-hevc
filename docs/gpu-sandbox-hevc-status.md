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

## Test results (2026-09-20, Pi100, chromium 153.0.8010.47-2)

Ran `hevc-validate/validate.py --drop-flag=--no-sandbox` (the harness runs as
root, so chromium is launched as root too). Result: **all 5 clips failed
instantly**, and not for a device-broker permission reason at all:

```
[ERROR] content/browser/zygote_host/zygote_host_impl_linux.cc:102
Running as root without --no-sandbox is not supported.
```

This is a separate, unconditional Chromium restriction (crbug.com/638180):
the zygote refuses to enable the sandbox when the browser process itself is
root, regardless of any GPU/device broker permissions. **PR #64's fix never
gets a chance to matter here** -- we never get past this earlier check.

Root cause: `agora-player.service` has no `User=` directive, so systemd runs
it (and everything it spawns: sway, chromium) as **root**. That is the actual
reason `--no-sandbox` is required today in `agora` -- not a missing V4L2
device-broker permission.

Follow-up probe: launched chromium as the unprivileged `agora` user instead
(keeping the harness/sway-start as root, for convenience) with `--no-sandbox`
dropped. `agora` already has the right group memberships (`video`, `render`)
for `/dev/dri/*`, `/dev/video19`, `/dev/media2`. But sway itself failed to
start as `agora`:

```
[wlr] [libseat] Could not open target tty: Permission denied
[wlr] backend/backend.c: Timeout waiting session to become active
[wlr] backend/backend.c: Failed to start a DRM session
```

`seatd` is not installed/active on Pi100, and an SSH-spawned `agora` login
session has no seat assignment, so wlroots' `libseat` backend can't grant it
DRM master. Getting a non-root compositor+browser stack working needs either
`seatd` running (with the process launched from a session seatd will grant a
seat to) or a properly seat-assigned logind session -- orthogonal
infrastructure work, unrelated to the Chromium/HEVC patches themselves.

### Conclusion (updated below -- do not stop reading here)

Removing `--no-sandbox` from `agora` is **not just a Chromium/patch
question** -- it first requires making `agora-player` (and the sway
compositor it starts) run as a non-root user with real seat/DRM access.
That's a bigger, orthogonal change to `agora`'s process model (systemd
`User=`, `seatd`, group/permissions, possibly udev rules), not a
chromium-rpi-hevc patch.

## Follow-up test: non-root + seatd (2026-09-20, same session)

Installed `seatd` (`apt-get install seatd`; not present/active by default on
this Pi100 image) and started it, then re-ran sway + chromium as the
unprivileged `agora` user, **independent of `agora-player`** (harness/services
stopped, sway+chromium launched by hand via `runuser -u agora`), with
`--no-sandbox` dropped entirely:

- sway started fine as `agora` this time -- `seatd`'s socket
  (`/run/seatd.sock`, group `video`, which `agora` is already a member of)
  gave it the DRM/seat access it couldn't get before.
- chromium launched **with the sandbox enabled**, no `--no-sandbox` flag at
  all.
- The GPU process had **both `/dev/video19` and `/dev/media0` open** as file
  descriptors -- no `Permission denied` anywhere in the log.
- Verified live HEVC decode traffic in the log (`HEVC_DBG_SPS`/`_PPS`/slice
  parsing) and successful `AGORA_PERPLANE_IMPORT` GBM/EGL plane imports --
  i.e. actual hardware-decoded frames were being produced and imported for
  display, fully sandboxed.

**Conclusion: the already-vendored PR #64 broker fix is sufficient.** It
covers (or at least doesn't block) `/dev/media*` access in practice, not just
`/dev/video*` -- the theoretical gap this doc originally worried about did not
materialize. **No new chromium-rpi-hevc patch is needed.**

The only real blocker to dropping `--no-sandbox` in `agora` is that
`agora-player.service` runs as root. To ship this in production, `agora`
needs (as a separate, orthogonal change, out of scope for this repo):

1. `seatd` installed and enabled by default on the Pi OS image.
2. `agora-player.service` given a `User=`/`Group=` (a dedicated `agora`
   system user, or similar), with membership in `video`/`render` (and
   `input` if it needs raw input devices).
3. Re-validation that everything the player currently does as root (D-Bus,
   systemctl calls, file paths under `/opt/agora`, `/data`, etc.) still works
   unprivileged, or is delegated appropriately (polkit rules, sudoers, etc.).

That work belongs in the `agora` repo, not here.
