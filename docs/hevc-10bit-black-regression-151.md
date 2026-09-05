# 10-bit HEVC black-video regression on Chromium 151 — root cause & fix

Status: **fixed on-device; patch `0021-hevc-10bit-external-sampler-sand-rec601.patch` on branch `fix/hevc-advertising-151`.**
Date: 2026-08-29

This is a **separate** regression from the `canPlayType`/advertising one in
`hevc-advertising-regression-151.md` (patch 0020). That one stopped HEVC
being *offered*; this one let 10-bit HEVC decode but render as **solid
black**.

## Symptom

After the 147 → 151 port, on Raspberry Pi 5 (Pi100, `192.168.1.100`):

- 8-bit HEVC (NV12) and AV1: play correctly.
- **All 10-bit HEVC (Main10) play as uniform black** — both 10-bit SDR
  (BT.709) *and* 10-bit HDR (BT.2020/PQ). Audio is unaffected; the decoder
  runs, frames are produced, only the sampled image is black.

The earlier working premise ("BT.709 10-bit works, only BT.2020/HDR is
black") was **false** — it was never HDR-specific. Every 10-bit clip was
black; 8-bit was the only thing that ever rendered.

## How it was isolated

Overlay delegation is disabled on the kiosk (`--disable-features=
WaylandOverlayDelegation`), so Chromium composites the video itself via
SkiaRenderer/ANGLE and sway just scans out Chromium's RGB surface. That
means the black is **internal to Chromium**, not a compositor/sway issue
(sway on the Pi is 1.10.1, which predates `wp-color-management`, so the
compositor was never in the color path).

A `grim` screenshot oracle made this measurable without human eyes: a solid
black frame PNG is ~6 KB; real content is >100 KB. See
`scripts/validate-hevc.sh`.

During playback the GPU process flooded, once per plane per frame:

```
native_pixmap_egl_binding.cc: Unable to initialize binding from pixmap
eglCreateImage failed 0x300C (EGL_BAD_PARAMETER)   # 10-bit "Unknown dma_buf format"
ProduceSkiaGanesh failed / yuv promise sk image failed
```

(The `skia_renderer.cc:795 Failed to create the promise sk image` error is
**benign** — it floods for working 8-bit clips too; do not chase it.)

## Root cause

On the Pi 5 the V4L2 stateless HEVC decoder emits **BROADCOM SAND128**
column-tiled buffers. 10-bit content is packed as **P030** (three 10-bit
samples per 32-bit word). Mesa v3d can only sample these correctly through a
**single combined multi-plane EGLImage bound to an OES external sampler**
with a YUV color-space hint. This is exactly the path Chromium **147** used.

Patch `0015-no-external-sampler-on-linux-v4l2.patch` disabled
`PrefersExternalSampler` for **all** Linux multi-plane formats — a
legitimate fix for an unrelated **8-bit NV12 "solid green"** bug on kernel
≥ 6.18. But it also forced **10-bit** onto the per-plane import path, and
**Mesa v3d cannot sample SAND128 P030 per-plane**:

| 10-bit import attempt                                   | eglCreateImage | v3d sample |
|---------------------------------------------------------|:--------------:|:----------:|
| per-plane R16 / GR1616 (upstream 151 default)           | succeeds       | **black**  |
| per-plane, whole P030 fourcc + 1 plane fd (old 0021)    | **BAD_PARAMETER** | — (black) |
| **combined P030 + external sampler + REC601 (this fix)**| succeeds       | **content**|

So the old `0021-holder-keep-p010-format-for-sand-perplane.patch` was
chasing the wrong path entirely (and was actively broken — it fed a 2-plane
P030 fourcc to a single-plane import → `EGL_BAD_PARAMETER`). It is
**removed** by this change.

There is a second, independent v3d quirk: SAND128 P030 renders **black under
the REC2020 YUV hint**. So even on the combined external-sampler path, the
BT.2020/HDR frames must be imported with the **REC601** hint (the DRM/KMS
overlay path already forces BT.601 limited range for these buffers).

## The fix — patch 0021

Two edits (both guarded to the Pi V4L2 case):

1. `media/gpu/chromeos/mailbox_video_frame_converter.cc` — re-enable
   `PrefersExternalSampler` on Linux for **10-bit `kP010` only**. 8-bit NV12
   stays on the per-plane path (patch 0015) to avoid its solid-green bug.

2. `ui/ozone/common/native_pixmap_egl_binding.cc` — when the P010→P030
   remap fires for a BROADCOM-modifier buffer, force the EGL YUV
   color-space hint to `EGL_ITU_REC601_EXT` (instead of REC2020 for
   BT.2020), so HDR frames sample correctly instead of black.

### Validated on-device (Pi100)

Stack: kernel `6.18.34`, Mesa `25.0.7`, sway `1.10.1`, Debian 13.

| clip                          | before (grim bytes) | after (grim bytes) |
|-------------------------------|:-------------------:|:------------------:|
| 10-bit SDR (`main10_sdr_test`)| 6121 (black)        | 379423 (content)   |
| 10-bit HDR (`hdr10_main10`)   | 6121 (black)        | 223457 (content)   |
| AV1 8-bit (`gears_AV1`)       | ~1.6 MB (content)   | ~1.6 MB (content)  |

Per-frame EGL import failure count: **254 → 0**. Both 10-bit frames visually
confirmed as full color-bar test content (timestamp + moving gradient), not
green/garbage.

**No OS/driver update was required** — the same Pi stack sampled these
buffers fine on 147. 151 merely routed 10-bit down the wrong import path.

## Maintainability — surviving future RPi/upstream churn

Same philosophy as the advertising fix: own the decision, fail loud, test
cheap.

1. **Own the format→sampler decision in a project patch (0021).** If a
   future RPi/Chromium rebase reworks `mailbox_video_frame_converter.cc` or
   `native_pixmap_egl_binding.cc` enough that 0021 no longer applies, the
   build **fails at patch-apply** rather than silently shipping black
   10-bit.

2. **`scripts/validate-hevc.sh` is the regression tripwire.** It uses the
   `grim` byte-size oracle to assert every test clip renders >100 KB of real
   content. Run it after every version bump / OTA on a real Pi. This is what
   turns "10-bit is black again" from a multi-day hunt into a one-line CI/
   boot failure.

3. **Keep the seams small and marked.** All edits carry an
   `AGORA_PATCH_0021` marker and are confined to the format-selection /
   EGL-import seam, not spread through shared logic — so a rebase conflict
   surfaces exactly where the decision lives.

4. **Longer-term: a dedicated `rpi_hevc` sampler seam.** The ideal is a
   one-line hook in the shared file that dispatches to a project-owned file
   holding the "SAND128 P030 → combined external sampler + REC601" policy,
   so upstream can churn the shared file without touching our logic. Tracked
   as a follow-up; 0021 keeps the seam minimal in the meantime.

## Relationship to other patches

- `0015` (no-external-sampler-on-linux) is **kept** — it fixes the 8-bit
  green bug and 0021 only carves out the 10-bit exception on top of it.
- `0011`/`0012` (gbm/EGL P010→P030 remap) remain load-bearing: 0021's REC601
  hint keys off the same BROADCOM-modifier remap they perform.
- `0021-holder-keep-p010-format-for-sand-perplane.patch` is **removed** —
  superseded by this fix (it targeted the unworkable per-plane path).
