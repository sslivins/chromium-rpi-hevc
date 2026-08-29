#!/usr/bin/env bash
#
# validate-hevc.sh — on-device HEVC render validation for chromium-rpi-hevc.
#
# Runs on a Raspberry Pi 5 running the agora player stack. For each test clip
# it drives the player, captures the framebuffer with `grim`, and asserts the
# frame is real content and not a solid (black/green) sampling failure — the
# exact failure mode of the 147->151 10-bit black regression (see
# docs/hevc-10bit-black-regression-151.md).
#
# A solid-colour PNG compresses to a few KB; real video content is >100 KB.
# That byte-size delta is the oracle — no human eyes required.
#
# Usage (as root on the Pi):
#   sudo ./validate-hevc.sh
#
# Env overrides:
#   VIDEO_DIR   (default /opt/agora/assets/videos)
#   STATE_FILE  (default /opt/agora/state/desired.json)
#   MIN_BYTES   (default 100000)  minimum PNG size to count as "content"
#   SETTLE      (default 12)      seconds to wait after (re)starting playback
#   PARK_ASSET  (default Goodwill_Mens.png) asset to leave playing at the end
#
set -u

VIDEO_DIR="${VIDEO_DIR:-/opt/agora/assets/videos}"
STATE_FILE="${STATE_FILE:-/opt/agora/state/desired.json}"
MIN_BYTES="${MIN_BYTES:-100000}"
SETTLE="${SETTLE:-12}"
PARK_ASSET="${PARK_ASSET:-Goodwill_Mens.png}"
OUT_DIR="$(mktemp -d /tmp/hevc-validate-XXXXXX)"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/agora-sway-shell-run}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"

if ! command -v grim >/dev/null 2>&1; then
  echo "FATAL: grim not installed (needed for the render oracle)" >&2
  exit 3
fi

# Test matrix: "asset-filename : human label". Only clips present are tested;
# missing ones are reported as SKIP so the script is portable across devices.
CLIPS=(
  "main10_sdr_test.mp4:10-bit SDR HEVC (BT.709)"
  "hdr10_main10_test.mp4:10-bit HDR HEVC (BT.2020/PQ)"
  "gears_AV1.mp4:AV1 8-bit (control)"
)

play() {
  local asset="$1"
  printf '{"mode":"play","asset":"%s","loop":true}\n' "$asset" > "$STATE_FILE"
  chown agora:agora "$STATE_FILE" 2>/dev/null || true
  systemctl restart agora-player 2>/dev/null
  sleep "$SETTLE"
}

fail=0
tested=0
printf '\n%-34s %-28s %10s  %s\n' "ASSET" "LABEL" "BYTES" "RESULT"
printf '%s\n' "--------------------------------------------------------------------------------------"
for entry in "${CLIPS[@]}"; do
  asset="${entry%%:*}"
  label="${entry#*:}"
  if [[ ! -f "$VIDEO_DIR/$asset" ]]; then
    printf '%-34s %-28s %10s  %s\n' "$asset" "$label" "-" "SKIP (absent)"
    continue
  fi
  play "$asset"
  png="$OUT_DIR/${asset%.mp4}.png"
  grim -t png "$png" 2>/dev/null
  bytes=$(stat -c%s "$png" 2>/dev/null || echo 0)
  tested=$((tested+1))
  if (( bytes >= MIN_BYTES )); then
    printf '%-34s %-28s %10s  %s\n' "$asset" "$label" "$bytes" "PASS"
  else
    printf '%-34s %-28s %10s  %s\n' "$asset" "$label" "$bytes" "FAIL (solid frame)"
    fail=$((fail+1))
  fi
done
printf '%s\n' "--------------------------------------------------------------------------------------"

# Park on a safe still so we don't leave a test clip looping.
if [[ -f "$VIDEO_DIR/$PARK_ASSET" ]] || [[ "$PARK_ASSET" == *.png ]]; then
  printf '{"mode":"play","asset":"%s","loop":true}\n' "$PARK_ASSET" > "$STATE_FILE"
  chown agora:agora "$STATE_FILE" 2>/dev/null || true
  systemctl restart agora-player 2>/dev/null
fi

echo
if (( tested == 0 )); then
  echo "RESULT: no test clips present under $VIDEO_DIR — nothing validated." >&2
  rm -rf "$OUT_DIR"
  exit 2
fi
if (( fail > 0 )); then
  echo "RESULT: $fail/$tested clip(s) rendered a solid frame — HEVC sampling is BROKEN."
  echo "        Captured PNGs kept in $OUT_DIR for inspection."
  exit 1
fi
echo "RESULT: all $tested clip(s) rendered real content — HEVC OK."
rm -rf "$OUT_DIR"
exit 0
