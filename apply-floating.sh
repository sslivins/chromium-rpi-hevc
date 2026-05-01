#!/bin/bash
# Apply floating-edits/*.patch on top of an already-patched
# Chromium 147.0.7727.101 source tree (i.e. after patches/0001-0004
# have been applied via dpkg-source --before-build).
#
# Usage:
#   apply-floating.sh /path/to/work/chromium-147.0.7727.101
#
# These edits are NOT part of the quilt series — they are raw
# `diff -u` output applied as in-tree edits. The build scripts in
# build/ do NOT apply them automatically; you must run this once
# after the source tree is patched, BEFORE the first ninja build.
set -euo pipefail

SRC="${1:?usage: apply-floating.sh <chromium-source-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FLOATING="$HERE/floating-edits"

if [ ! -d "$SRC/media/gpu/v4l2" ]; then
  echo "ERROR: $SRC does not look like a Chromium source tree" >&2
  exit 1
fi

cd "$SRC"
for p in 0005-h265-slice-params-and-bitsize.patch \
         0006-v4l2-utils-nc12-sand128.patch \
         0007-gbm-import-gate-fix.patch; do
  echo "==> Applying $p"
  patch -p1 --no-backup-if-mismatch --silent < "$FLOATING/$p"
done
echo "All floating edits applied."
