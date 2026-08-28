#!/usr/bin/env bash
#
# validate-hevc.sh — on-device HEVC decode/render validation for the
# custom chromium-rpi-hevc build on a Pi5 kiosk.
#
# Runs the release-validation matrix (docs/release-validation-checklist.md)
# against the *currently installed* /usr/lib/chromium/chromium, driving the
# real kiosk player, and checks every device-side signal that can be
# machine-verified:
#
#   1. no DEMUXER_ERROR_NO_SUPPORTED_STREAMS   (stream was accepted)
#   2. gpu-process holds /dev/video19 with mmap (HW decoder live)
#   3. /opt/agora/state/current.json  error == null
#   +  10-bit only: PATCH_EGL_NC30 P010->P030 remap fires (the tripwire
#      for the 151 black-Main10 regression — if this is silent on a 10-bit
#      clip the NC30->P030 import path is broken and the frame will be black)
#
# Signal 4 (real moving picture on the panel) CANNOT be auto-verified: a
# hardware video overlay is invisible to wlr-screencopy/grim. This script
# pauses on each 10-bit row so a human confirms the screen, and prints a
# clear reminder. Do not sign off a release on the machine signals alone.
#
# Usage:
#   sudo ./validate-hevc.sh                 # full matrix, interactive
#   sudo ./validate-hevc.sh --no-pause      # CI/unattended: skip human prompts
#   sudo ./validate-hevc.sh --only main10_sdr_test.mp4   # single clip
#
# Safe to re-run; restores the normal kiosk image + agora-cms-client on exit.

set -u

ASSET_DIR="/opt/agora/assets/videos"
STATE_DIR="/opt/agora/state"
DECODER="/dev/video19"
NORMAL_IMAGE="Goodwill_Mens.png"
SETTLE_SECS=12
PAUSE=1
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) PAUSE=0 ;;
    --only) shift; ONLY="${1:-}" ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" != "0" ]; then
  echo "must run as root (sudo)" >&2; exit 2
fi

# clip -> "profile|bitdepth|expect_remap(0/1)"
# expect_remap=1 means it is a 10-bit Main10 path that MUST fire the
# P010->P030 EGL remap; a 10-bit clip that does not remap renders black.
declare -A CLIPS=(
  ["gears_AV1.mp4"]="HEVC Main 8-bit SDR|8|0"
  ["main10_sdr_test.mp4"]="HEVC Main10 10-bit SDR|10|1"
  ["hdr10_main10_test.mp4"]="HEVC Main10 10-bit HDR10|10|1"
)
ORDER=("gears_AV1.mp4" "main10_sdr_test.mp4" "hdr10_main10_test.mp4")

PASS_COUNT=0
FAIL_COUNT=0
declare -A RESULT

log()  { printf '%s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------\n'; }

ensure_clip() {
  local name="$1" path="$ASSET_DIR/$name"
  [ -f "$path" ] && return 0
  log "  clip $name missing — generating with ffmpeg..."
  command -v ffmpeg >/dev/null 2>&1 || { log "  ERROR: ffmpeg not installed, cannot generate $name"; return 1; }
  case "$name" in
    main10_sdr_test.mp4)
      ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=6" \
        -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=6" \
        -vf "format=yuv420p10le" \
        -c:v libx265 -profile:v main10 -pix_fmt yuv420p10le \
        -x265-params "colorprim=bt709:transfer=bt709:colormatrix=bt709:repeat-headers=1:info=0" \
        -c:a aac -b:a 128k -tag:v hvc1 -movflags +faststart "$path" >/dev/null 2>&1 ;;
    hdr10_main10_test.mp4)
      ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=6" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
        -vf "format=yuv420p10le" \
        -c:v libx265 -profile:v main10 -pix_fmt yuv420p10le \
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:hdr10-opt=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:repeat-headers=1:info=0" \
        -c:a aac -b:a 128k -tag:v hvc1 -movflags +faststart "$path" >/dev/null 2>&1 ;;
    *)
      log "  ERROR: no generator recipe for $name (expected pre-installed)"; return 1 ;;
  esac
  [ -f "$path" ] && log "  generated $name" || { log "  ERROR: generation failed for $name"; return 1; }
}

play_clip() {
  local name="$1"
  systemctl stop agora-cms-client 2>/dev/null
  printf '{"mode":"play","asset":"%s","loop":true}\n' "$name" > "$STATE_DIR/desired.json"
  chown agora:agora "$STATE_DIR/desired.json" 2>/dev/null
  systemctl restart agora-player 2>/dev/null
}

check_clip() {
  local name="$1" meta="$2"
  local desc bitdepth expect_remap
  desc="${meta%%|*}"; local rest="${meta#*|}"; bitdepth="${rest%%|*}"; expect_remap="${rest##*|}"

  hr
  log "ROW: $name  [$desc]"
  ensure_clip "$name" || { RESULT[$name]="FAIL(no-clip)"; FAIL_COUNT=$((FAIL_COUNT+1)); return; }

  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  play_clip "$name"
  log "  playing; settling ${SETTLE_SECS}s..."
  sleep "$SETTLE_SECS"

  # signal 1: demuxer errors
  local demux
  demux=$(journalctl --since "$since" --no-pager -o cat 2>/dev/null | grep -acE 'DEMUXER_ERROR_NO_SUPPORTED_STREAMS')
  # signal 2: decoder held with mmap by chromium
  local held="no"
  fuser -v "$DECODER" 2>&1 | grep -qE 'chromium' && held="yes"
  # signal 3: current.json error==null
  local errstate
  errstate=$(python3 -c "import json;print(json.load(open('$STATE_DIR/current.json')).get('error'))" 2>/dev/null)
  # signal +: 10-bit remap fires
  local remap
  remap=$(journalctl --since "$since" --no-pager -o cat 2>/dev/null | grep -acE 'PATCH_EGL_NC30')

  log "  [1] demuxer errors : $demux   (want 0)"
  log "  [2] decoder held   : $held  (want yes)"
  log "  [3] current error  : ${errstate:-<none>}  (want None/null)"
  log "  [+] P010->P030 remap fires : $remap  (10-bit wants >0; 8-bit wants 0)"

  local ok=1
  [ "$demux" = "0" ] || ok=0
  [ "$held" = "yes" ] || ok=0
  case "${errstate:-None}" in None|null|"") : ;; *) ok=0 ;; esac
  if [ "$expect_remap" = "1" ] && [ "$remap" -eq 0 ]; then ok=0; fi

  if [ "$ok" = "1" ]; then
    RESULT[$name]="PASS(machine)"; PASS_COUNT=$((PASS_COUNT+1))
    log "  => machine signals PASS"
  else
    RESULT[$name]="FAIL"; FAIL_COUNT=$((FAIL_COUNT+1))
    log "  => machine signals FAIL"
  fi

  # signal 4 reminder / human gate
  if [ "$bitdepth" = "10" ]; then
    if [ "$name" = "hdr10_main10_test.mp4" ]; then
      log "  [4] HUMAN: HDR10/PQ on an SDR panel looks DARK by design —"
      log "      confirm a DIM but MOVING test pattern (not frozen black)."
    else
      log "  [4] HUMAN: confirm a clear MOVING test pattern on the panel"
      log "      (this is the gate the machine signals cannot cover)."
    fi
    if [ "$PAUSE" = "1" ]; then read -r -p "  press Enter once you've eyeballed the screen... " _; fi
  fi
}

restore() {
  hr
  log "restoring normal kiosk state..."
  printf '{"mode":"image","asset":"%s"}\n' "$NORMAL_IMAGE" > "$STATE_DIR/desired.json"
  chown agora:agora "$STATE_DIR/desired.json" 2>/dev/null
  systemctl start agora-cms-client 2>/dev/null
  systemctl restart agora-player 2>/dev/null
  log "restored: image=$NORMAL_IMAGE, agora-cms-client started."
}
trap restore EXIT

log "chromium-rpi-hevc device validation"
log "chromium: $(readlink -f /usr/lib/chromium/chromium 2>/dev/null || echo /usr/lib/chromium/chromium)"
log "decoder : $DECODER"
log "started : $(date)"

for name in "${ORDER[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  check_clip "$name" "${CLIPS[$name]}"
done

hr
log "SUMMARY (machine signals; signal 4 = human eyeball, see above):"
for name in "${ORDER[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  printf '  %-28s %s\n' "$name" "${RESULT[$name]:-SKIPPED}"
done
log "pass=$PASS_COUNT fail=$FAIL_COUNT"
hr
log "NOTE: machine PASS != release sign-off. A 10-bit row can pass signals"
log "1-3 while the screen is black — the P010->P030 remap check catches the"
log "known 151 regression, but a human must still confirm real picture."

[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
