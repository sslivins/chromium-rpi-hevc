# Chromium build release validation checklist

Status: **living document.** Update the matrix + baseline results on every
Chromium version bump.
Owner: agora / chromium-rpi-hevc
Last validated build: **151.0.7922.173** on Pi5 (Pi100, `192.168.1.100`),
2026-08-28.

## Why this exists

Our custom Chromium (`chromium-rpi-hevc`) carries ~20 local patches on top
of the RPi-Distro debian packaging to drive the Pi5 **stateless** V4L2 HEVC
decoder (`/dev/video19`). Every Chromium version bump re-applies those
patches onto a moving RPi + upstream base, and either side can silently
break a decode/render path that still *compiles and launches*. Two distinct
regressions have already shipped/been caught this way:

- **151 HEVC advertising** — RPi's new `v4l2-do-not-advertise-stateless-codecs.patch`
  skipped `/dev/video19`, so 8-bit HEVC stopped being advertised
  (`DEMUXER_ERROR_NO_SUPPORTED_STREAMS`). Fixed by `patches/0020-*`.
  See `docs/hevc-advertising-regression-151.md`.
- **151 10-bit Main10 render** — 8-bit HEVC plays, but 10-bit Main10 (the
  NC30 → P030 GBM/EGL import+sample path, patches `0009`–`0012`, `0017`)
  renders a **black frame with audio still playing**. Confirmed a clean
  151 regression: the identical clip renders correctly on the 147 build.
  **OPEN as of 2026-08-28.**

The lesson: "chromium launches and the logo shows" is **not** validation.
Every build must be run through the matrix below on real Pi5 hardware
before it is packaged (`build/cli.sh full`) and shipped to the fleet.

## What "pass" means — reliable device-side signals

A codec/profile path is **PASS** only if ALL of these hold while the clip is
playing through the real kiosk player (not headless):

1. **No `DEMUXER_ERROR_NO_SUPPORTED_STREAMS`** in the journal
   (advertising / demuxer accepted the stream).
2. **The GPU process holds `/dev/video19` open with an mmap** —
   `fuser -v /dev/video19` shows `chromium ... F...m` on the
   `--type=gpu-process` PID (the HW decoder instance is live, not just a
   probe).
3. **`/opt/agora/state/current.json` `"error": null`.**
4. **The video actually renders on the display** — a human (or a framebuffer
   capture) confirms real moving picture, *not* black / green / garbled.
   This is the step that catches the 10-bit render regression; signals 1–3
   all pass while the screen is black.

> Note on bit-depth probing: you **cannot** read Chromium's negotiated
> capture format with a separate `v4l2-ctl --get-fmt-video`. V4L2 M2M
> stateless decoders keep format state **per open file handle**, so
> `v4l2-ctl` sees the device default (`Nc12`), not Chromium's session. Use
> the on-screen result (signal 4) plus Chromium media logs, not `v4l2-ctl`.

## The validation matrix

Run every row on real Pi5 hardware for each new build. "147" column = the
last known-good baseline for regression comparison.

| # | Content | Codec / profile | Bit depth | Color | Container tag | 147 | 151 |
|---|---------|-----------------|-----------|-------|---------------|-----|-----|
| 1 | HEVC SD  | HEVC Main       | 8-bit  | SDR (bt709)          | hev1 | PASS | **PASS** (needs `0020`) |
| 2 | HEVC HD  | HEVC Main       | 8-bit  | SDR                  | hev1/hvc1 | PASS | **PASS** |
| 3 | HEVC HD  | HEVC **Main10** | 10-bit | SDR (bt709)          | hvc1 | PASS | **FAIL — black** |
| 4 | HEVC HD  | HEVC **Main10** | 10-bit | **HDR10** (bt2020/PQ)| hvc1 | PASS | **FAIL — black** |
| 5 | HEVC 4K  | HEVC Main / Main10 | 8/10 | SDR + HDR10        | hvc1 | TODO | TODO |
| 6 | H.264 HD | H.264 High      | 8-bit  | SDR                  | n/a  | PASS | verify |
| 7 | VP9 / AV1 (if enabled) | — | — | — | — | n/a | verify |

Also validate, for each build:

- **`canPlayType` matrix** returns non-empty for every profile we ship:
  - `video/mp4; codecs="hev1.1.6.L120.90"` (Main, 8-bit) → not `""`
  - `video/mp4; codecs="hev1.2.4.L120.90"` (Main10, 10-bit) → not `""`
  - `video/mp4; codecs="hvc1.1.6.L120.90"` and `hvc1.2.4.L120.90`
  (This is the cheapest regression tripwire — the 151 advertising bug would
  have been caught here in seconds.)
- **Audio**: audio track plays (a black-video-with-audio result still fails
  the row on signal 4, but confirms demux/audio are independent).
- **Playback stability**: clip loops cleanly for ≥2 loops, no decoder EBUSY /
  realloc storm in the journal (patch `0003` territory).
- **Kiosk basics**: chromium launches under wayland/ozone, no crash loop,
  cursor hidden, correct HDMI output.
- **HDR output mode** (row 4): if the panel/output is in HDR mode, PQ content
  is bright/correct; on an SDR output PQ content is *expected* to look dark —
  don't mistake PQ-on-SDR for a decode failure. Isolate with a 10-bit **SDR**
  clip (row 3) which must look normal regardless of output HDR mode.

## Test clips (deterministic, ffmpeg-generated on the Pi)

Generate these on the Pi (`ffmpeg` there has `libx265` with 10-bit). Keeping
them script-generated avoids committing binaries and keeps them reproducible.
`testsrc2` gives a moving pattern so a frozen/black frame is obvious.

- **8-bit Main SDR** (row 1/2) — already on device:
  `/opt/agora/assets/videos/gears_AV1.mp4` (HEVC Main, hev1; despite the
  name it is HEVC, not AV1), sha256 `89d624e2…`.
- **10-bit Main10 SDR** (row 3):
  ```bash
  ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=6" \
    -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=6" \
    -vf "format=yuv420p10le" \
    -c:v libx265 -profile:v main10 -pix_fmt yuv420p10le \
    -x265-params "colorprim=bt709:transfer=bt709:colormatrix=bt709:repeat-headers=1:info=0" \
    -c:a aac -b:a 128k -tag:v hvc1 -movflags +faststart main10_sdr_test.mp4
  ```
- **10-bit Main10 HDR10** (row 4):
  ```bash
  ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=6" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
    -vf "format=yuv420p10le" \
    -c:v libx265 -profile:v main10 -pix_fmt yuv420p10le \
    -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:hdr10-opt=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:repeat-headers=1:info=0" \
    -c:a aac -b:a 128k -tag:v hvc1 -movflags +faststart hdr10_main10_test.mp4
  ```
- **4K variants** (row 5): same as above with `size=3840x2160`.

## How to run a build on-device (fast iteration)

1. Build on the ARM VM: `build/cli.sh fast` produces
   `out/Release/chrome` (unstripped; larger than the packaged binary but
   runs). See `docs/…` + the `chromium-arm-builder` skill.
2. Push the raw binary and swap it in (keeps a backup, fully reversible):
   - back up `/usr/lib/chromium/chromium` → `chromium.stock-<ver>`
   - `install -o root -g root -m 0755 <new> /usr/lib/chromium/chromium`
   - a raw-binary swap only works when the **same Chromium version's
     resources** (`.pak`, `icudtl.dat`, `locales`) are already installed;
     for a cross-version test, swap the whole `/usr/lib/chromium` tree
     extracted from the `.deb`s (`dpkg-deb -x`) instead.
3. Drive playback by writing `/opt/agora/state/desired.json` (stop
   `agora-cms-client` first so it doesn't reconcile it away), then
   `systemctl restart agora-player`. Restore `desired.json` +
   `agora-cms-client` when done.
4. Regression-compare against 147 by swapping the whole
   `/usr/lib/chromium` tree from the archived 147 `.deb`s in
   `release-v0.2.9/` (binary **and** matching resources must move together).

## Sign-off gate before packaging + fleet release

Do **not** run `build/cli.sh full` / cut a release until:

- [ ] Rows 1–4 (min) PASS all four signals on real Pi5 hardware.
- [ ] `canPlayType` matrix returns non-empty for every shipped profile.
- [ ] RPi debian series diffed against the previous pinned tarball; any
      new decoder-affecting patch reviewed (this is how the 151 advertising
      patch should have been caught — see maintainability §4 in the
      advertising regression doc).
- [ ] Any FAIL row has a tracked fix or an explicit, documented decision to
      ship without that capability.

## Currently open

- **Row 3 & 4 (10-bit Main10 / HDR10) FAIL on 151** — black frame, audio
  OK, `/dev/video19` engaged, no demuxer error. Confirmed 151-only
  regression (renders on 147). Suspect the NC30 → P030 GBM import / EGL
  binding / per-plane modifier path (`0009`–`0012`, `0017`) as ported to
  151. Diagnostic patch `0016-diag-log-getbinding` already emits
  `AGORA_GETBINDING*` logs to pinpoint which import branch the 10-bit frame
  takes — enable Chromium stderr logging and compare the 8-bit (working) vs
  10-bit (black) branch.
