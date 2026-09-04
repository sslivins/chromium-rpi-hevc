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
set -euo pipefail

OUT_DIR="${1:-$HOME/hevc-test}"
DURATION="${DURATION:-10}"
FPS="${FPS:-30}"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f pattern.png ]; then
  python3 "$HERE/make_pattern.py" pattern.png
fi

# Bar sweeps the full width every 5 s, confined to the bottom motion strip.
BAR="drawbox=x='mod(t*384\,1920)':y=960:w=96:h=120:color=white:t=fill"

common_in=(-loop 1 -framerate "$FPS" -i pattern.png -t "$DURATION")

echo "== 8-bit Main =="
ffmpeg -y -hide_banner -loglevel error "${common_in[@]}" \
  -vf "$BAR,format=yuv420p" \
  -c:v libx265 -preset medium -crf 20 -tag:v hvc1 \
  -x265-params "keyint=30:min-keyint=30:scenecut=0" \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  hevc_8bit.mp4

echo "== 10-bit Main10 =="
ffmpeg -y -hide_banner -loglevel error "${common_in[@]}" \
  -vf "$BAR,format=yuv420p10le" \
  -c:v libx265 -preset medium -crf 20 -tag:v hvc1 \
  -profile:v main10 -pix_fmt yuv420p10le \
  -x265-params "keyint=30:min-keyint=30:scenecut=0" \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  hevc_10bit.mp4

echo "== 10-bit HDR10 (BT.2020 / PQ) =="
ffmpeg -y -hide_banner -loglevel error "${common_in[@]}" \
  -vf "$BAR,format=yuv420p10le" \
  -c:v libx265 -preset medium -crf 20 -tag:v hvc1 \
  -profile:v main10 -pix_fmt yuv420p10le \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params "keyint=30:min-keyint=30:scenecut=0:hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
  hevc_hdr.mp4

ls -l hevc_8bit.mp4 hevc_10bit.mp4 hevc_hdr.mp4
echo "clips written to $OUT_DIR"
