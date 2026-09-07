#!/bin/bash
# One-command acceptance check for a chromium-rpi-hevc build.
#
#   sudo ./run-validation.sh --tag v0.4.0     # fetch, install, validate
#   sudo ./run-validation.sh                  # validate what is installed
#
# Answers a single question: is this chromium good or broken on this Pi?
# Exit status is the verdict -- 0 good, 1 broken, 2 could not test.
#
# Stages
#   0  deps        install anything the harness needs that the image lacks
#   1  install     download the release's runtime debs, verify sha256, dpkg -i
#   2  clips       generate the test clips if they are not already present
#   3  codecs      what chromium advertises (HEVC / Main10, hardware or not)
#   4  playback    decode each clip on-device and score the pixels
#   5  verdict     per-clip PASS/FAIL table + JSON report
#
# Stage 4 is the one that matters: it proves hardware decode is actually
# being used (open /dev/video fd + V4L2 decoder chatter) rather than a
# software fallback that happens to look correct.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TAG=""
DEB_DIR=""
CLIP_DIR=""
REPORT="/tmp/hevc-validate/report.json"
ONLY=""
REGEN=0

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)      TAG="$2"; shift 2 ;;
    --debs)     DEB_DIR="$2"; shift 2 ;;
    --clip-dir) CLIP_DIR="$2"; shift 2 ;;
    --report)   REPORT="$2"; shift 2 ;;
    --only)     ONLY="$2"; shift 2 ;;
    --regen-clips) REGEN=1; shift ;;
    -h|--help)  usage ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (needs dpkg, systemctl, DRM master)" >&2
  exit 2
fi

# Clips belong to the login user, not root, so that a later non-root run
# (and the ordinary hevc-test workflow) can still read them.
RUN_USER="${SUDO_USER:-agora}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
: "${CLIP_DIR:=${RUN_HOME:-/home/agora}/hevc-test}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; }
ok()   { printf '\033[32mok\033[0m   %s\n' "$*"; }

# ---------------------------------------------------------------- 0. deps
say "stage 0: dependencies"
need_pkgs=()
have() { command -v "$1" >/dev/null 2>&1; }
have ffmpeg   || need_pkgs+=(ffmpeg)
have grim     || need_pkgs+=(grim)
have sway     || need_pkgs+=(sway)
python3 -c 'import PIL'   2>/dev/null || need_pkgs+=(python3-pil)
python3 -c 'import numpy' 2>/dev/null || need_pkgs+=(python3-numpy)
if [ "${#need_pkgs[@]}" -gt 0 ]; then
  echo "installing: ${need_pkgs[*]}"
  apt-get update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${need_pkgs[@]}" >/dev/null || {
    fail "could not install: ${need_pkgs[*]}"; exit 2; }
fi
ok "toolchain present"

# ------------------------------------------------------------- 1. install
before_ver="$(dpkg-query -W -f='${Version}' chromium 2>/dev/null || echo none)"

if [ -n "$TAG" ] && [ -z "$DEB_DIR" ]; then
  say "stage 1: fetching release $TAG"
  DEB_DIR="/var/tmp/hevc-debs/$TAG"
  python3 "$HERE/fetch_release.py" --tag "$TAG" --dest "$DEB_DIR" || {
    fail "could not fetch/verify release $TAG"; exit 2; }
fi

if [ -n "$DEB_DIR" ]; then
  say "stage 1: installing debs from $DEB_DIR"
  # shellcheck disable=SC2086
  if ! dpkg -i "$DEB_DIR"/*.deb; then
    echo "resolving dependencies"
    DEBIAN_FRONTEND=noninteractive apt-get -f install -y || { fail "dpkg install failed"; exit 2; }
  fi
fi

after_ver="$(dpkg-query -W -f='${Version}' chromium 2>/dev/null || echo none)"
if [ "$after_ver" = "none" ]; then
  fail "no chromium package installed"; exit 2
fi
echo "chromium: $before_ver -> $after_ver"
ok "chromium $after_ver installed"

# ---------------------------------------------------------------- 2. clips
say "stage 2: test clips ($CLIP_DIR)"
if [ "$REGEN" -eq 1 ]; then
  rm -f "$CLIP_DIR"/hevc_*.mp4
fi
mkdir -p "$CLIP_DIR"
chown "$RUN_USER" "$CLIP_DIR" 2>/dev/null || true

gen() {
  local script="$1" probe="$2"
  if [ -f "$CLIP_DIR/$probe" ]; then
    ok "$probe present"
    return 0
  fi
  echo "generating via $script"
  # Encode as the login user so the clips are not left root-owned.
  sudo -u "$RUN_USER" env HOME="$RUN_HOME" bash "$HERE/$script" "$CLIP_DIR" >/dev/null || {
    fail "$script failed"; return 1; }
  ok "$probe generated"
}
gen make_clips.sh    hevc_8bit.mp4    || exit 2
gen make_wp_clips.sh hevc_wp_10bit.mp4 || exit 2

cp -f "$HERE/test_page.html" "$CLIP_DIR/test_page.html"

# --------------------------------------------------------------- 3. codecs
say "stage 3: advertised codecs"
codec_log="/tmp/hevc-validate/codecs.txt"
mkdir -p "$(dirname "$codec_log")"
python3 "$HERE/diag_codecs.py" >"$codec_log" 2>&1 || true
grep -viE 'VERBOSE1|AGORA_GETBINDING' "$codec_log" | tail -20

# ------------------------------------------------------------- 4. playback
say "stage 4: on-device decode and pixel scoring"
val_args=(--clip-dir "$CLIP_DIR" --report "$REPORT")
[ -n "$ONLY" ] && val_args+=(--only "$ONLY")
python3 "$HERE/validate.py" "${val_args[@]}"
val_rc=$?

# -------------------------------------------------------------- 5. verdict
say "stage 5: verdict"
python3 - "$REPORT" "$after_ver" <<'PY'
import json, sys
path, ver = sys.argv[1], sys.argv[2]
try:
    r = json.load(open(path))
except Exception as exc:
    print(f"could not read report {path}: {exc}")
    raise SystemExit(2)

# What each clip is actually here to prove, so a failure line is actionable
# without having to go and read the harness source.
MEANING = {
    "8bit":  "baseline 8-bit HEVC hardware decode",
    "10bit": "Main10 hardware decode (P030 path)",
    "hdr":   "HDR10 metadata and colour handling",
    "wp8":   "weighted prediction, 8-bit control",
    "wp10":  "weighted prediction, 10-bit (issue #14 chroma offset)",
}
print(f"chromium {ver}   kernel {r.get('kernel','?')}")
print("-" * 72)
for res in r.get("results", []):
    label = res.get("label", "?")
    verdict = "PASS" if res.get("pass") else "FAIL"
    print(f"{verdict:4s}  {label:6s}  {MEANING.get(label,'')}")
    if res.get("pass"):
        continue
    if res.get("error"):
        print(f"        {res['error']}")
    for name, chk in (res.get("image", {}).get("checks") or {}).items():
        if not chk.get("pass"):
            print(f"        {name}: {json.dumps(chk)[:220]}")
    for key in ("hw_decode", "playback"):
        if not res.get(key, {}).get("pass", True):
            print(f"        {key}: {json.dumps(res[key])[:220]}")
print("-" * 72)

results = {x.get("label"): bool(x.get("pass")) for x in r.get("results", [])}
if results.get("wp8") and results.get("wp10") is False:
    print("note: wp8 passes but wp10 fails -- failure is specific to 10-bit")
    print("      weighted prediction, i.e. the bit-depth-dependent chroma")
    print("      offset derivation (kWpOffsetHalfRangeC) in patch 0008.")

good = r.get("pass")
print(f"\nOVERALL: {'GOOD' if good else 'BROKEN'}     report: {path}")
raise SystemExit(0 if good else 1)
PY
verdict_rc=$?

exit $(( verdict_rc || val_rc ))
