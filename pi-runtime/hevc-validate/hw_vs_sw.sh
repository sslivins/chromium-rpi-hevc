#!/bin/bash
# hw_vs_sw.sh -- prove or disprove a hardware HEVC decode fault, objectively.
#
# Decodes the same segment twice: once through the kernel V4L2 stateless HEVC
# decoder (GStreamer v4l2slh265dec, no Chromium involved) and once through
# ffmpeg's software HEVC decoder, then compares them frame by frame.
#
# A conformant decoder is bit-identical to the reference, so every frame should
# report infinite PSNR. Any finite-PSNR frame is a real hardware decode
# mismatch -- the class of fault that parses without error yet renders wrong,
# which no error-scan or "ffmpeg reports no errors" check can detect.
#
# Because Chromium is entirely out of the loop, a mismatch here isolates the
# fault to the kernel driver or the hardware rather than to this repo's patches.
#
# usage: hw_vs_sw.sh <clip> [start_seconds] [duration_seconds]
#
# Prefer starting on a keyframe: a mis-decoded frame propagates through every
# dependent frame until the next IDR, so the reported range normally ends at a
# GOP boundary rather than where the fault occurred.
set -e

CLIP=${1:?usage: hw_vs_sw.sh <clip> [start] [duration]}
START=${2:-0}
DUR=${3:-10}
W=${WORKDIR:-/tmp/hw_vs_sw}

command -v gst-launch-1.0 >/dev/null || { echo "need gstreamer1.0-tools"; exit 1; }
gst-inspect-1.0 v4l2slh265dec >/dev/null 2>&1 || {
  echo "need gstreamer1.0-plugins-bad (v4l2slh265dec)"; exit 1; }

rm -rf "$W"; mkdir -p "$W"; cd "$W"

# Cut without re-encoding so both decoders consume byte-identical input.
ffmpeg -hide_banner -loglevel error -ss "$START" -t "$DUR" -i "$CLIP" \
  -an -c:v copy -f mp4 seg.mp4

PX_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 seg.mp4)
PX_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 seg.mp4)
# The raw pipe carries no timing, so it must be fed at the clip's true rate or
# ffmpeg resamples and ends up comparing shifted frame pairs -- which looks
# exactly like widespread corruption (~30 dB everywhere) but is an artefact of
# the measurement.
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 seg.mp4)
echo "segment ${START}s +${DUR}s  ${PX_W}x${PX_H} @ ${FPS}"

# Stream the hardware frames straight into ffmpeg; raw 1080p fills the rootfs
# in seconds if written to disk.
gst-launch-1.0 -q filesrc location=seg.mp4 ! qtdemux ! h265parse ! \
  v4l2slh265dec ! videoconvert ! \
  "video/x-raw,format=I420,width=$PX_W,height=$PX_H" ! \
  filesink location=/dev/stdout 2>/dev/null \
| ffmpeg -hide_banner -loglevel error \
    -f rawvideo -pix_fmt yuv420p -s "${PX_W}x${PX_H}" -r "$FPS" -i - \
    -i seg.mp4 -lavfi "[0:v][1:v]psnr=stats_file=psnr.log" \
    -fps_mode passthrough -f null - 2>&1 | grep -v monotonic || true

awk -v fps="$FPS" -v start="$START" '
BEGIN { split(fps, fr, "/"); rate = fr[2] ? fr[1]/fr[2] : fr[1] }
{
  for (i = 1; i <= NF; i++) { split($i, kv, ":"); if (kv[1]=="n") n=kv[2]; if (kv[1]=="psnr_avg") p=kv[2] }
  total++
  bad = (p != "inf")
  if (bad) { nbad++ }
  if (bad && !run) { run=1; s=n; worst=p; sum=0; cnt=0 }
  if (bad) { if (p+0 < worst+0) worst=p; sum+=p; cnt++; e=n }
  if (!bad && run) { emit(); run=0 }
}
function emit() {
  printf "  DIVERGES frames %s-%s  t=%.3f-%.3fs  (%d frames, %.2fs)  worst=%s dB  mean=%.2f dB\n",
         s, e, start+(s-1)/rate, start+(e-1)/rate, cnt, cnt/rate, worst, sum/cnt
}
END {
  if (run) emit()
  printf "frames_compared=%d mismatched=%d\n", total+0, nbad+0
  if (total == 0) { print "VERDICT: INCONCLUSIVE - no frames compared"; exit }
  if (nbad == 0)  { print "VERDICT: hardware decoder is bit-identical to the software reference"; exit }
  print  "VERDICT: hardware decoder DIVERGES from the software reference"
  print  "         (a trailing 1-2 frame range is usually just the segment flush boundary)"
}' psnr.log

rm -f seg.mp4
