# Pi 5 hardware HEVC decode divergence (not a Chromium fault)

## Summary

Big Buck Bunny shows a burst of visible block corruption roughly 1 m 45 s in.
It is **not** caused by anything in this repository. The Pi 5 `rpi-hevc-dec`
kernel driver mis-decodes one frame, and the error then propagates through
every dependent frame until the next keyframe clears it.

Confirmed on Chromium **147, 151 and 152** alike, and reproduced with
**GStreamer only** — no Chromium in the loop at all.

## Evidence

Clip: `bbb_sunflower_1080p_30fps_normal.mp4` (HEVC Main, 1920x1080, **60 fps**
despite the filename), kernel `6.18.39+rpt-rpi-2712`, driver `rpi-hevc-dec`
6.18.39.

| Test | Result |
|---|---|
| Chromium 152, hardware decode | corruption visible |
| Chromium 147 (v0.2.9), hardware decode | corruption visible |
| ffmpeg full-file software decode | 0 errors |
| ffmpeg decoded stills over the region | clean |
| GStreamer `v4l2slh265dec` vs ffmpeg software, per-frame PSNR | **diverges** |

`hw_vs_sw.sh` over the GOP starting at 108.333 s:

```
  DIVERGES frames 91-250  t=109.833-112.483s  (160 frames, 2.67s)  worst=24.57 dB  mean=27.81 dB
frames_compared=273 mismatched=162
```

Frames 1-90 of the GOP are bit-identical to the software reference. Frame 91
diverges, and every frame after it stays wrong until **112.5 s**, which is
exactly the next keyframe (keyframes fall at 100.0, 104.17, 108.33, 112.5,
116.67 s — a 4.167 s GOP). Recovery landing precisely on the IDR is the
signature of reference-frame error propagation from a single bad frame.

Side-by-side PNGs of the same frame show the software output correct and the
hardware output smeared and blocky.

## Why the usual checks miss it

A decoder can consume a bitstream without reporting a single error and still
produce wrong pixels — the fault is a mismatch between what the bitstream
specifies and what the decoder computes. So neither `ffmpeg -err_detect
explode` nor `corruptedVideoFrames` detects this. Only comparing decoded
pixels against a reference decoder does.

## Reproducing

```bash
# on the Pi
pi-runtime/hevc-validate/hw_vs_sw.sh \
    /data/agora/assets/videos/bbb_sunflower_1080p_30fps_normal.mp4 108.333333 4.5
```

Start on a keyframe. Starting mid-GOP still finds the divergence but reports a
range that begins wherever the propagation became measurable.

Two traps that produce false positives:

* **Wrong frame rate on the raw pipe.** Feeding the hardware frames in at 30 fps
  when the clip is 60 fps makes ffmpeg resample and compare shifted pairs,
  yielding ~30 dB across nearly every frame. `hw_vs_sw.sh` reads the real rate
  from the stream.
* **Writing raw frames to disk.** 1080p I420 is ~3.1 MB/frame and fills the Pi
  rootfs within seconds, truncating the comparison. The script streams instead.

Also note Chromium cannot software-decode 1080p HEVC on a Pi 5 fast enough to
play, so `--disable-accelerated-video-decode` is not a usable A/B — the video
never reaches a playing state and the screen stays blank.

## Status

Not actionable in this repo; it belongs to the RPi kernel HEVC driver. Recorded
here so the artifact is not re-investigated as a Chromium port regression. The
small blocky strip along the very bottom edge of the frame is separate: it is
present in the software reference too, so it is baked into the source encode.
