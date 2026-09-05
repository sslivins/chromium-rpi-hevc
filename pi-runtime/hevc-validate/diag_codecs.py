#!/usr/bin/env python3
"""Report what codecs chromium actually advertises, on real GPU/Wayland.

`validate.py` tells you a clip failed; this tells you whether the browser ever
believed it could decode it. HEVC on Linux is gated on the GPU process
reporting hardware decode support, so a headless or software-GL probe answers a
different question than the one that matters. This drives a real sway session,
the same way validate.py does, and reads results back out of the window title.

Run as root:
    python3 diag_codecs.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate import (  # noqa: E402
    CHROMIUM, Sway, kill_stale_sessions, log, run, stop_agora,
)

CODECS = [
    ("hevc_main", 'video/mp4; codecs="hvc1.1.6.L93.B0"'),
    ("hevc_main10", 'video/mp4; codecs="hvc1.2.4.L120.B0"'),
    ("hev1_main", 'video/mp4; codecs="hev1.1.6.L93.B0"'),
    ("h264", 'video/mp4; codecs="avc1.42E01E"'),
    ("vp9", 'video/mp4; codecs="vp09.00.10.08"'),
    ("av1", 'video/mp4; codecs="av01.0.04M.08"'),
]

PAGE = """<!doctype html><html><body><script>
const codecs = %s;
const v = document.createElement('video');
// GPUInfo arrives asynchronously, and HEVC support on Linux is derived from
// it, so an immediate probe can report "no" purely because the GPU process
// has not answered yet. Re-probe for a while and publish the last state.
let round = 0;
function probe() {
  round++;
  const parts = [];
  for (const [name, mime] of codecs) {
    parts.push(name + '=' + (v.canPlayType(mime) || 'no'));
  }
  const mc = [];
  const probes = codecs.map(([name, mime]) =>
    (navigator.mediaCapabilities ? navigator.mediaCapabilities.decodingInfo({
      type: 'file',
      video: {contentType: mime, width: 1920, height: 1080,
              bitrate: 5000000, framerate: 30}
    }).then(r => mc.push(name + '=' +
        (r.supported ? (r.powerEfficient ? 'hw' : 'sw') : 'no'))
     ).catch(() => mc.push(name + '=err')) : Promise.resolve())
  );
  Promise.all(probes).then(() => {
    document.title = 'CODECPROBE r=' + round +
                     ' canPlayType[' + parts.join(',') +
                     '] decodingInfo[' + mc.join(',') + ']';
  });
}
probe();
setInterval(probe, 1000);
</script></body></html>
"""


def main() -> int:
    if os.geteuid() != 0:
        log("must run as root (needs DRM master)")
        return 2

    workdir = Path("/tmp/hevc-codec-probe")
    if workdir.exists():
        shutil.rmtree(workdir, ignore_errors=True)
    workdir.mkdir(parents=True)
    page = workdir / "probe.html"
    page.write_text(PAGE % json.dumps(CODECS))

    stop_agora()
    kill_stale_sessions()
    sway = Sway(Path("/tmp/hevc-codec-probe-sway"))
    title = None
    try:
        sway.start()
        cmd = [
            CHROMIUM,
            "--no-sandbox",
            "--no-first-run",
            "--kiosk",
            "--noerrdialogs",
            "--ozone-platform=wayland",
            "--enable-features=UseOzonePlatform",
            "--allow-file-access-from-files",
            f"--user-data-dir={workdir / 'cr-profile'}",
            "--enable-logging=stderr",
            "--v=1",
            "--vmodule=*v4l2*=2,*video_decoder*=2,*gpu_video*=2,*supported*=2",
            f"file://{page}",
        ]
        extra = os.environ.get("DIAG_EXTRA_FLAGS", "").split()
        if extra:
            log(f"extra flags: {' '.join(extra)}")
            cmd[-1:-1] = extra
        # Which /dev/video* nodes the GPU process opens tells us which
        # #ifdef branch of GetSupportedV4L2DecoderConfigs() was compiled in:
        # the Pi branch probes video10/video19 by name, the generic one
        # sweeps video0..video255.
        strace_log = workdir / "strace.log"
        if os.environ.get("DIAG_STRACE") == "1":
            cmd = ["strace", "-f", "-qq", "-e", "trace=openat,ioctl",
                   "-o", str(strace_log)] + cmd
        with open(workdir / "chromium.err", "wb") as errf:
            proc = subprocess.Popen(
                cmd, env=sway.env, stdout=subprocess.DEVNULL,
                stderr=errf, preexec_fn=os.setsid,
            )
        deadline = time.time() + 20
        while time.time() < deadline:
            for t in sway.titles():
                if t.startswith("CODECPROBE"):
                    title = t
            if proc.poll() is not None:
                break
            time.sleep(0.5)
        try:
            os.killpg(os.getpgid(proc.pid), 15)
        except Exception:
            pass
    finally:
        sway.stop()

    err = (workdir / "chromium.err").read_text(errors="replace")
    version = run(["dpkg-query", "-W", "-f=${Version}", "chromium"]).stdout.strip()
    keep = ("v4l2", "supportedvideodecoderconfigs", "getsupportedconfigs",
            "hevc", "h265", "videodecoderpipeline", "gpu_mojo",
            "agora_getbinding", "decoder_type", "vaapi")
    hits = [ln for ln in err.splitlines()
            if any(k in ln.lower() for k in keep)]
    (workdir / "interesting.log").write_text("\n".join(hits))
    print("=" * 60)
    print("chromium :", version)
    print("result   :", title or "NO RESULT (page never reported)")
    print("v4l2 log lines      :", err.lower().count("v4l2"))
    print("video_decoder lines :", err.lower().count("video_decoder"))
    print(f"interesting lines   : {len(hits)} -> {workdir / 'interesting.log'}")
    strace_log = workdir / "strace.log"
    if strace_log.exists():
        vid = [ln for ln in strace_log.read_text(errors="replace").splitlines()
               if "/dev/video" in ln]
        names = sorted({ln.split('"')[1] for ln in vid if '"' in ln})
        print(f"/dev/video opens    : {len(vid)} call(s), "
              f"{len(names)} distinct node(s)")
        print("  nodes:", ", ".join(names) if names else "(none)")
    for ln in hits[:40]:
        print("  |", ln[:200])
    print("=" * 60)
    return 0 if title else 1


if __name__ == "__main__":
    raise SystemExit(main())
