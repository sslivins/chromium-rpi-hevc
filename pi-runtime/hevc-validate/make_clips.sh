#!/bin/bash
# Generate the three HEVC validation clips from the deterministic test
# pattern. Run once on the Pi; the clips are ~10 s each and are reused by
# every subsequent validation run.
#
#   hevc_8bit.mp4   Main   profile, yuv420p,     BT.709
#   hevc_10bit.mp4  Main10 profile, yuv420p10le, BT.709
#   hevc_hdr.mp4    Main10 profile, yuv420p10le, BT.2020 + PQ (SMPTE ST 2084)
#
# All three carry identical picture content so a single analyser can score
# them, and all three sweep a white bar across the bottom strip so the
# "is it actually advancing?" check has something to latch onto.
#
# The motion comes from a pre-rendered frame sequence, not an ffmpeg filter
# expression: drawbox evaluates its coordinate expressions once at filter
# configuration time, which silently produces a completely static clip.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT_DIR="${1:-$HOME/hevc-test}"
LOOPS="${LOOPS:-4}"      # 5 passes over the sequence == ~11.7 s at 30 fps
FRAMES="${FRAMES:-70}"   # one 2.333 s sweep; deliberately not a multiple of
                         # the validator's ~1 s capture interval, so captures
                         # can never repeatedly land on the same bar position
FPS="${FPS:-30}"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

if [ ! -f frames/f0000.png ]; then
  echo "== rendering $FRAMES pattern frames =="
  python3 "$HERE/make_pattern.py" --frames "$FRAMES" --outdir frames
fi

common_in=(-stream_loop "$LOOPS" -framerate "$FPS" -i frames/f%04d.png)
x265_common="keyint=30:min-keyint=30:scenecut=0"

echo "== 8-bit Main =="
ffmpeg -y -hide_banner -loglevel error "${common_in[@]}" \
  -vf format=yuv420p \
  -c:v libx265 -preset medium -crf 20 -tag:v hvc1 \
  -x265-params "$x265_common" \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  hevc_8bit.mp4

echo "== 10-bit Main10 =="
ffmpeg -y -hide_banner -loglevel error "${common_in[@]}" \
  -vf format=yuv420p10le \
  -c:v libx265 -preset medium -crf 20 -tag:v hvc1 \
  -profile:v main10 -pix_fmt yuv420p10le \
  -x265-params "$x265_common" \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  hevc_10bit.mp4

echo "== 10-bit HDR10 (BT.2020 / PQ) =="
ffmpeg -y -hide_banner -loglevel error "${common_in[@]}" \
  -vf format=yuv420p10le \
  -c:v libx265 -preset medium -crf 20 -tag:v hvc1 \
  -profile:v main10 -pix_fmt yuv420p10le \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params "$x265_common:hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
  hevc_hdr.mp4

ls -l hevc_8bit.mp4 hevc_10bit.mp4 hevc_hdr.mp4
echo "clips written to $OUT_DIR"
