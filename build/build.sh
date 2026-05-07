#!/bin/bash
# Backwards-compat wrapper. Replaced by build/cli.sh as of Tier 2.
# Kept as exec wrapper for one PR cycle as rollback safety.
# Will be deleted in a follow-up cleanup PR after VM validation.
exec /usr/local/bin/chromium-rpi-hevc full "$@"
