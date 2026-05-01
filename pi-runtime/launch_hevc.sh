#!/bin/bash
mkdir -p /tmp/sway-run && chmod 700 /tmp/sway-run
export XDG_RUNTIME_DIR=/tmp/sway-run
export HOME=/root
export WLR_NO_HARDWARE_CURSORS=1
exec /usr/bin/sway -c /tmp/sway-hevc.conf
