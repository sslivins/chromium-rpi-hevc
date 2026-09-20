#!/bin/bash
# Test launcher: same as run_chromium.sh but WITHOUT --no-sandbox.
#
# Purpose: find out empirically whether the GPU sandbox broker permissions
# already carried in our vendored RPi-Distro source
# (debian/patches/rpi/v4l2-sandbox-allow-decoder-devices.patch, which grants
# broker access to whatever V4L2Device::GetDevicesForType(Type::kDecoder)
# reports) are sufficient for our *stateless* HEVC decoder path, or whether
# additional device nodes (notably /dev/media* used by the V4L2 Request API --
# see pi-runtime/hevc-validate/README.md's reference open_v4l2_nodes of
# ["/dev/media2", "/dev/video19"]) still need explicit broker permissions.
#
# Run this, then check /tmp/chromium-hevc-sandboxed.err for:
#   - "Permission denied" opening /dev/video19 or /dev/media*
#   - GPU process crashes/restarts (sandbox violation)
#   - chrome://gpu reporting video decode disabled
# A clean run with hardware decode working is the signal we can drop
# --no-sandbox from run_chromium.sh for real.
exec /usr/lib/chromium/chromium \
  --no-first-run \
  --disable-session-crashed-bubble --disable-restore-session-state \
  --window-position=0,0 --window-size=1920,1080 --start-maximized \
  --user-data-dir=/tmp/cr-hevc-sandboxed \
  --enable-logging=stderr --v=1 \
  --vmodule=*v4l2*=2,*media*=1,*video_decoder*=2,*gbm*=2,*shared_image*=2,*sandbox*=2,*broker*=2 \
  --enable-features=PlatformHEVCDecoderSupport \
  --disable-features=UseChromeOSDirectVideoDecoder \
  --disable-zero-copy \
  --disable-gpu-memory-buffer-video-frames \
  --autoplay-policy=no-user-gesture-required \
  file:///home/pi/hevc-test/test_hevc_page.html \
  >/tmp/chromium-hevc-sandboxed.out 2>/tmp/chromium-hevc-sandboxed.err
