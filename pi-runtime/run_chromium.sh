#!/bin/bash
exec /usr/lib/chromium/chromium \
  --no-sandbox --no-first-run \
  --disable-session-crashed-bubble --disable-restore-session-state \
  --window-position=0,0 --window-size=1920,1080 --start-maximized \
  --user-data-dir=/tmp/cr-hevc \
  --enable-logging=stderr --v=1 \
  --vmodule=*v4l2*=2,*media*=1,*video_decoder*=2,*gbm*=2,*shared_image*=2 \
  --enable-features=PlatformHEVCDecoderSupport \
  --disable-features=UseChromeOSDirectVideoDecoder \
  --disable-zero-copy \
  --disable-gpu-memory-buffer-video-frames \
  --autoplay-policy=no-user-gesture-required \
  file:///home/agora/composer-proto/test_hevc_page.html \
  >/tmp/chromium-hevc.out 2>/tmp/chromium-hevc.err
