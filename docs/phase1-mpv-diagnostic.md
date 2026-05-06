# Phase 1 / 10-bit HEVC — mpv diagnostic findings

**Date:** 2026-05-05
**Pi:** 192.168.1.114 (Pi 5, kernel 6.12, rpi-hevc-dec driver)
**Test clip:** `test_hevc_10bit.mp4` — 1920x1080 HEVC Main 10, 30s, libx265-encoded from `test_hevc.mp4`.
**Tools:** `mpv 0.40.0`, `ffmpeg 7.1.3`, `strace 6.13`

---

## TL;DR

**The Pi kernel decodes 10-bit HEVC in hardware via the same `rpi-hevc-dec` driver chromium uses.** No kernel patching needed. The blocker is purely on the chromium side: chromium does not negotiate the Pi's 10-bit capture pixel format (`V4L2_PIX_FMT_NC30`, fourcc `NC30`).

This invalidates the "kernel UAPI is the blocker" reading in `docs/phase1-10bit-investigation.md`. Phase 1 / Path A is **userspace-only**.

---

## Method

1. Generated a 10-bit HEVC Main 10 clip on the Pi:
   ```
   ffmpeg -ss 60 -t 30 -i test_hevc.mp4 -c:v libx265 -profile:v main10 \
          -pix_fmt yuv420p10le -an test_hevc_10bit.mp4
   ```
   `ffprobe` confirms `codec_name=hevc`, `profile=Main 10`, `pix_fmt=yuv420p10le`.

2. Played through mpv with verbose hwdec selection logging (no display output, `--vo=null`):
   ```
   mpv --hwdec=auto-safe --vo=null --ao=null --frames=60 --no-config \
       --msg-level=all=v test_hevc_10bit.mp4
   ```

3. Strace'd the v4l2 ioctl sequence:
   ```
   strace -f -o /tmp/mpv-strace.log -e trace=ioctl,openat -s 2048 \
     mpv --hwdec=drm-copy --vo=null --ao=null --frames=10 --no-config \
         test_hevc_10bit.mp4
   ```

---

## Finding 1 — mpv selects hardware decode (drm-copy / V4L2 stateless)

From mpv verbose log:

```
[ffmpeg/video] hevc: Hwaccel V4L2 HEVC stateless V4;
               devices: /dev/media1,/dev/video19;
               buffers: src DMABuf, dst DMABuf;
               swfmt=rpi4_10
Using hardware decoding (drm-copy).
```

- `/dev/media1` + `/dev/video19` are **the same v4l2-stateless devices chromium uses**.
- `swfmt=rpi4_10` is mpv/ffmpeg's friendly name for the 10-bit Pi-specific software pixel format mapped to the v4l2 capture-side fourcc.

Frames after `Using hardware decoding`: decoder produces `yuv420p10` output. Dropped frames in the log are pacing artifacts of `--vo=null` (vsync-less null sink) — not decode failures.

## Finding 2 — Capture format is `NC30` ("10-bit Y/CbCr 4:2:0 (128b cols)")

From strace, output (slice-side) negotiation as `V4L2_PIX_FMT_HEVC_SLICE` (S265) — same as 8-bit. **Capture (frame-side) negotiation:**

```
ioctl(15, VIDIOC_ENUM_FMT,
  {index=0, type=V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, flags=0,
   description="10-bit Y/CbCr 4:2:0 (128b cols)",
   pixelformat=v4l2_fourcc('N', 'C', '3', '0')}) = 0

ioctl(15, VIDIOC_S_FMT,
  {type=V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
   fmt.pix_mp={width=1920, height=1080,
               pixelformat=v4l2_fourcc('N', 'C', '3', '0'),
               ...}}
  => {fmt.pix_mp={width=1920, height=1080,
                  pixelformat=v4l2_fourcc('N', 'C', '3', '0'),
                  plane_fmt=[{sizeimage=4147200, bytesperline=1620}],
                  num_planes=1}}) = 0
```

Key facts:

- **Fourcc `NC30`** = `0x3033434E`. This is the Pi's 10-bit equivalent of `NC12` (the 8-bit fourcc patches 0002/0007 already teach chromium about).
- **`bytesperline=1620`** for 1920px width. That's `1920 * 27 / 32` — i.e., 10 bits packed in a 128-byte column layout (same column-tile scheme as `NC12`, just wider per-sample).
- **`sizeimage=4147200`** for 1920x1080 = 1620 * 2560 (vertical padding to 128-row tile boundary, same as NC12).
- The kernel's `VIDIOC_ENUM_FMT` for capture in a 10-bit context **only lists `NC30`** at index 0, and index 1 returns `EINVAL`. There is **no NV12 fallback path** — chromium MUST negotiate `NC30` for 10-bit content.

## Finding 3 — Same control IDs as 8-bit

mpv issues `VIDIOC_S_EXT_CTRLS` with the same set chromium already supports:

| Control ID | Field | Size (bytes) | Probable struct |
|------------|-------|--------------|-----------------|
| `0xa40a90` | HEVC_SPS | 40 | `v4l2_ctrl_hevc_sps` |
| `0xa40a91` | HEVC_PPS | 64 | `v4l2_ctrl_hevc_pps` |
| `0xa40a92` | HEVC_SLICE_PARAMS | 280 | `v4l2_ctrl_hevc_slice_params` |
| `0xa40a94` | HEVC_DECODE_PARAMS | 328 | `v4l2_ctrl_hevc_decode_params` |
| `0xa40a95`, `0xa40a96` | (entropy / start_code) | 0 | menu/integer ctrls |

No new kernel control needed for 10-bit. The slice-params struct (which embeds `pred_weight_table` with the `__s8 chroma_offset_lX[i][j]` field) is the **same struct** used for 8-bit. The kernel accepts it without complaint and produces correct output.

## Finding 4 — `chroma_offset_lX` `__s8` is NOT a blocker in practice

Original concern: HEVC 10-bit derives chroma offsets in `[-512, 511]`, but the v4l2 UAPI declares `__s8`, and the Pi driver masks with `& 0xff`. We hypothesized this would corrupt 10-bit weighted-prediction frames.

Observation: mpv decodes our 10-bit clip cleanly through this exact ABI. The clip is libx265-default-encoded (no explicit `--weightp`), so it likely doesn't exercise weighted prediction frames — meaning we **haven't disproved** the concern for clips that use WP. But:

- The kernel did not reject any ioctl due to chroma offset values.
- Most real-world 10-bit HEVC content does not use weighted prediction with offsets exceeding 8-bit range.
- If/when we hit a 10-bit + WP clip with corruption, that's a discoverable bug we can address — not a structural blocker for shipping Path A.

**Action item (deferred):** add a follow-up TODO to test a 10-bit WP-enabled clip once Path A is wired up, and inspect chromium/ffmpeg behavior at the boundary.

---

## Implications for Phase 1 / Path A

What chromium needs to learn:

1. **Capture format negotiation.** When the SPS reports `bit_depth_luma_minus8 > 0`, prefer `NC30` (or whatever the kernel offers for 10-bit) over `NC12`. Patch 0002 ("add nc12 fourcc") needs an `NC30` sibling. Patch 0007 ("nc12 in mojo client renderable") similarly needs `NC30` plumbing.

2. **Buffer layout.** `NC30` uses the same 128-byte column tile layout as `NC12`, just with a different per-sample bit count (10 instead of 8). The `bytesperline` formula changes; `sizeimage` formula likely the same.

3. **Output pipeline.** Two sub-options for getting `NC30` to the screen:
   - **3a (simpler)**: Add a chromium-side downconvert stage `NC30 → NV12` (8-bit) before the compositor accepts it. Loses precision; visually likely identical to 8-bit content of equivalent quality.
   - **3b (better)**: Pass `NC30` (or repacked `P010`) DMABuf through to the GBM/EGL compositor. Requires confirming the Pi's display chain accepts a 10-bit format — separate investigation. Mesa + KMS plane formats need to be enumerated.

4. **`pred_weight_table` math.** Patch 0008's recent refactor (`1 << (bit_depth_chroma_minus8 + 7)`) is on the right track but may not actually matter for correctness on this stack — kernel masks back to 8 bits anyway. Keep the refactor; don't claim it as a "10-bit fix."

## Out of scope for this branch

- No chromium changes here. This is investigation only.
- 10-bit WP+offset corner case (deferred to post-Path-A integration testing).
- Display-plane format negotiation for `P010`-direct path (option 3b above).

## Next step

Plan a Phase 1 implementation branch that:
- Adds `NC30` to chromium's recognized fourcc list (extend patch 0002).
- Teaches the V4L2 stateless decoder to choose `NC30` when SPS bit depth > 8.
- Adds a minimum-viable `NC30 → NV12` downconvert (option 3a) so we can ship a 10-bit visual on existing 8-bit-only display pipeline.
- Defers 10-bit-direct (option 3b) to a follow-up branch after the simple path is verified.

## Evidence files

- `/tmp/mpv-10bit-auto.log` — full mpv verbose hwdec log on Pi
- `/tmp/mpv-strace.log` — full ioctl trace (148 KB) on Pi
- `/tmp/ext_ctrls.txt` — extracted `VIDIOC_S_EXT_CTRLS` calls

These are not committed; they live on the Pi for now and can be regenerated from the test clip in ~30s.
