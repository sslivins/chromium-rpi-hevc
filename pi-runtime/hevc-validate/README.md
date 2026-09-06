# Automated HEVC validation harness

Answers the question "did this chromium build actually decode HEVC correctly
on real hardware?" without a human looking at the screen.

A purely visual check is not enough on its own: a software fallback can look
perfect while delivering none of the hardware decode this repo exists to
provide. So the harness checks both what is on screen *and* what the decoder
is doing.

## What gets checked

| Check | Catches |
|---|---|
| `hw_decode` | chromium holds an fd on a `/dev/video*` node, and/or logs V4L2 decoder activity. Catches silent software fallback. |
| `playback` | `currentTime` advanced, frames were produced, no media error, resolution is 1920x1080. Catches "loads but never decodes". |
| `not_black` | The static band has real luminance and contrast. Catches the black-screen failure. |
| `motion` | The bottom strip changes between captures. Catches decode-first-frame-then-freeze. |
| `static_stable` | The static band does *not* change between captures. Catches tearing/garbage/flicker. |
| `colour` | Eight solid patches land on their expected colours. |
| `chroma_banding` | No ~128 px periodic chroma structure. This is the SAND128 regression signature — see `docs/chroma-bug.md`. |

Three clips are exercised: 8-bit Main, 10-bit Main10, and 10-bit HDR10
(BT.2020 / PQ).

## Design notes

* Playback telemetry is republished by `test_page.html` into the window
  title and read back over the sway IPC socket. That avoids needing devtools,
  a websocket client, or any extra Python dependency on the Pi.
* All motion is confined to the bottom 11 % of the frame, so the colour and
  chroma checks are never confounded by which frame the capture landed on.
* Geometry is expressed in fractions of the captured frame, so the analyser
  works at whatever resolution the attached display reports.

## One-time setup on the Pi

```bash
sudo apt-get install -y grim python3-numpy python3-pil ffmpeg
mkdir -p ~/hevc-test
# copy this directory to the Pi, then:
bash make_clips.sh ~/hevc-test      # ~1 min, encodes the three clips
cp test_page.html ~/hevc-test/
```

## Running

```bash
sudo python3 validate.py --report /tmp/hevc-report.json
```

Exit code is 0 only if every clip passes every check. The JSON report has the
full per-check numbers, and the captures are left in `/tmp/hevc-validate/`
for eyeballing when something fails.

The harness stops `agora-watchdog` and `agora-player` to take over the
display and **always restarts them**, including on failure. Pass
`--keep-agora-down` if you want to poke around afterwards.

Useful flags:

* `--only 8bit,hdr` — run a subset
* `--shots 5` — more captures per clip (spaced 1 s)
* `--settle 5` — wait longer after playback starts before capturing

## Self-test

A validator that can only ever return PASS is worthless, so `selftest.py`
synthesises each failure mode — black screen, frozen playback, unstable
static band, swapped colour channels, injected 128 px chroma banding — and
asserts the corresponding check actually goes red:

```bash
python3 selftest.py
```

Needs only `numpy` and `pillow`; no display, no chromium, no root.

## Reference result

Chromium `1:151.0.7922.173-1~deb13u1+rpt1` on a Pi 5 (`agora` image),
all three clips passing, shows the shape of a healthy run:

```
hw_decode  open_v4l2_nodes=["/dev/media2", "/dev/video19"]
           v4l2_decoder_log_lines=951  software_fallback_hits=0
playback   total_video_frames=173  dropped=0  corrupted=0  1920x1080
```

`/dev/video19` is the Pi 5 stateless HEVC decoder. If that node is absent
from `open_v4l2_nodes`, the build is decoding in software no matter how good
the picture looks.

