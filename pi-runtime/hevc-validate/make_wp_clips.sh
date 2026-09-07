#!/bin/bash
# Generate the weighted-prediction HEVC test clips (issue #14 item 2).
#
#   hevc_wp_8bit.mp4    Main   profile, yuv420p      -- control
#   hevc_wp_10bit.mp4   Main10 profile, yuv420p10le  -- the case under test
#
# Both carry identical picture content: a global cross-fade between two
# chromatically opposed colours, which is what makes x265 emit a chroma
# pred_weight_table. The 8-bit clip is the control -- patch 0008's hardcoded
# kWpOffsetHalfRangeC == 128 is *correct* for 8-bit, so any divergence that
# appears on the 10-bit clip but not the 8-bit one isolates the bug to the
# bit-depth-dependent offset derivation rather than to weighted prediction
# generally.
#
# A clip that does not actually contain chroma weighting would make the whole
# test vacuous -- it would "pass" against broken code. This script therefore
# parses x265's own summary and FAILS if the UV weighting percentage is zero.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT_DIR="${1:-$HOME/hevc-test}"
LOOPS="${LOOPS:-3}"
FRAMES="${FRAMES:-96}"
FPS="${FPS:-30}"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

if [ ! -f wpframes/f0000.png ]; then
  echo "== rendering $FRAMES fade frames =="
  python3 "$HERE/make_wp_pattern.py" --frames "$FRAMES" --outdir wpframes
fi

common_in=(-stream_loop "$LOOPS" -framerate "$FPS" -i wpframes/f%04d.png)

# weightp/weightb: explicitly on -- these are what emit pred_weight_table.
# scenecut=0 + a long keyint keep the fade from being cut into I-frames,
# which would leave few inter frames to carry weights.
# bframes=4 exercises the B-slice (weightb) path as well as P.
x265_wp="keyint=120:min-keyint=120:scenecut=0:weightp=1:weightb=1:bframes=4:log-level=info"

encode() {
  local out="$1" pixfmt="$2" prof="$3" log="$4"
  # x265's summary goes to stderr; keep it so the weighting can be verified.
  ffmpeg -y -hide_banner -loglevel info "${common_in[@]}" \
    -vf "format=$pixfmt" \
    -c:v libx265 -preset medium -crf 20 -tag:v hvc1 \
    -profile:v "$prof" -pix_fmt "$pixfmt" \
    -x265-params "$x265_wp" \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    "$out" 2> "$log"
}

echo "== 8-bit Main (weighted prediction, control) =="
encode hevc_wp_8bit.mp4 yuv420p main x265_wp_8bit.log

echo "== 10-bit Main10 (weighted prediction, under test) =="
encode hevc_wp_10bit.mp4 yuv420p10le main10 x265_wp_10bit.log

# ---------------------------------------------------------------------------
# Verify the clips actually contain chroma weighted prediction.
#
# x265 prints a summary line of the form:
#   Weighted P-Frames: Y:12.5% UV:12.5%
# UV must be non-zero or the chroma pred_weight_table -- the only thing that
# exercises kWpOffsetHalfRangeC -- is simply absent from the bitstream.
# ---------------------------------------------------------------------------
check_weighting() {
  local log="$1" name="$2" line uv
  line="$(grep -o 'Weighted [PB]-Frames:[^\\]*' "$log" | head -2 | tr '\n' ' ' || true)"
  if [ -z "$line" ]; then
    echo "FAIL: $name -- x265 reported no weighted-prediction summary at all"
    echo "      (encoder log: $log)"
    return 1
  fi
  echo "  $name: $line"
  uv="$(printf '%s' "$line" | grep -o 'UV:[0-9.]*' | grep -o '[0-9.]*' | head -1)"
  if [ -z "$uv" ] || [ "${uv%%.*}" = "0" ] && [ "${uv#*.}" = "0" ]; then
    echo "FAIL: $name -- UV weighting is 0%; clip carries no chroma pred_weight_table"
    return 1
  fi
  return 0
}

echo
echo "== verifying pred_weight_table presence =="
rc=0
check_weighting x265_wp_8bit.log  hevc_wp_8bit.mp4  || rc=1
check_weighting x265_wp_10bit.log hevc_wp_10bit.mp4 || rc=1
if [ "$rc" -ne 0 ]; then
  echo
  echo "The clips are NOT usable for the issue #14 weighted-prediction test."
  echo "Without chroma weights the 10-bit offset bug cannot be observed and"
  echo "the test would pass against broken code."
  exit 1
fi

echo
ls -l hevc_wp_8bit.mp4 hevc_wp_10bit.mp4
echo "weighted-prediction clips written to $OUT_DIR"
