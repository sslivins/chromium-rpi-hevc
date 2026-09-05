#!/usr/bin/env python3
"""Automated on-device validation of the HEVC-patched chromium build.

Run as root on the Pi:

    sudo python3 validate.py --report /tmp/hevc-report.json

What it does, per clip (8-bit / 10-bit / HDR):

1.  Stops the agora signage stack so it can own the display, then brings up a
    private sway compositor.
2.  Launches the patched chromium on `test_page.html`, which republishes
    HTMLVideoElement telemetry into the window title. The title is read back
    over the sway IPC socket, so no devtools/websocket dependency is needed.
3.  Waits for `st=playing`, then takes several `grim` captures ~1 s apart.
4.  Proves *hardware* decode two ways: chromium having an open file descriptor
    on a `/dev/video*` node, and V4L2 decoder chatter in chromium's stderr.
    A purely visual check cannot distinguish HW decode from a software
    fallback that happens to look perfect, which is why this matters.
5.  Scores the captures with `analyze.py` (black screen, freeze, tearing,
    colour accuracy, SAND128 chroma banding).

The agora services are always restored, including on failure.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

AGORA_SERVICES = ["agora-watchdog", "agora-player"]

CLIPS = [
    ("8bit", "hevc_8bit.mp4", "bt709"),
    ("10bit", "hevc_10bit.mp4", "bt709"),
    ("hdr", "hevc_hdr.mp4", "hdr"),
]

CHROMIUM = "/usr/lib/chromium/chromium"

SWAY_CONF = """output * bg #000000 solid_color
default_border none
default_floating_border none
hide_edge_borders --i3 both
"""

V4L2_HINT = re.compile(r"v4l2", re.IGNORECASE)
V4L2_DECODER_HINT = re.compile(
    r"V4L2(Stateless)?VideoDecoder|v4l2_(stateless_)?video_decoder", re.IGNORECASE
)
SOFTWARE_HINT = re.compile(r"FFmpegVideoDecoder|falling back to software", re.IGNORECASE)


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# --------------------------------------------------------------------------
# agora stack


def service_active(name: str) -> bool:
    return run(["systemctl", "is-active", "--quiet", name]).returncode == 0


def kill_stale_sessions() -> None:
    """Reap sway/chromium survivors from an earlier run.

    A leftover compositor keeps the DRM master, so our sway comes up without a
    real output and every clip fails to reach `playing` -- which looks exactly
    like a codec regression. Clearing them first is the difference between a
    trustworthy result and a day of chasing the wrong bug.
    """
    victims = []
    for name in ("chromium", "swaybg", "sway"):
        out = run(["pgrep", "-x", name]).stdout.split()
        victims += [(name, int(p)) for p in out if p.isdigit()]
    if not victims:
        return
    log(f"killing {len(victims)} stale process(es) from a previous run")
    for _, pid in victims:
        run(["kill", "-9", str(pid)])
    time.sleep(2)


def stop_agora() -> list[str]:
    stopped = []
    for svc in AGORA_SERVICES:
        if service_active(svc):
            log(f"stopping {svc}")
            run(["systemctl", "stop", svc])
            stopped.append(svc)
    # The player owns sway; give the compositor time to release the DRM master.
    time.sleep(3)
    kill_stale_sessions()
    return stopped


def start_agora(stopped: list[str]) -> None:
    for svc in reversed(stopped):
        log(f"restarting {svc}")
        run(["systemctl", "start", svc])


# --------------------------------------------------------------------------
# sway


class Sway:
    def __init__(self, runtime_dir: Path):
        self.runtime_dir = runtime_dir
        self.proc: subprocess.Popen | None = None
        self.sock: str | None = None
        self.env: dict[str, str] = {}

    def start(self) -> None:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        self.runtime_dir.chmod(0o700)
        conf = self.runtime_dir / "sway.conf"
        conf.write_text(SWAY_CONF)

        env = dict(os.environ)
        env.update(
            {
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
                "HOME": "/root",
                "WLR_NO_HARDWARE_CURSORS": "1",
                "XDG_SESSION_TYPE": "wayland",
            }
        )
        log("starting sway")
        self.proc = subprocess.Popen(
            ["/usr/bin/sway", "-c", str(conf)],
            env=env,
            stdout=open(self.runtime_dir / "sway.out", "wb"),
            stderr=open(self.runtime_dir / "sway.err", "wb"),
            preexec_fn=os.setsid,
        )

        deadline = time.time() + 30
        while time.time() < deadline:
            socks = glob.glob(str(self.runtime_dir / "sway-ipc.*.sock"))
            waylands = glob.glob(str(self.runtime_dir / "wayland-*"))
            waylands = [w for w in waylands if not w.endswith(".lock")]
            if socks and waylands:
                self.sock = socks[0]
                env["SWAYSOCK"] = self.sock
                env["WAYLAND_DISPLAY"] = os.path.basename(waylands[0])
                self.env = env
                log(f"sway up (WAYLAND_DISPLAY={env['WAYLAND_DISPLAY']})")
                return
            if self.proc.poll() is not None:
                raise RuntimeError(
                    "sway exited early:\n"
                    + (self.runtime_dir / "sway.err").read_text()[-2000:]
                )
            time.sleep(0.5)
        raise RuntimeError("timed out waiting for sway IPC socket")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            log("stopping sway")
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
                self.proc.wait(timeout=10)
            except Exception:
                try:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
                except Exception:
                    pass

    def titles(self) -> list[str]:
        if not self.sock:
            return []
        cp = run(["swaymsg", "-s", self.sock, "-t", "get_tree", "-r"])
        if cp.returncode != 0:
            return []
        try:
            tree = json.loads(cp.stdout)
        except json.JSONDecodeError:
            return []
        out: list[str] = []

        def walk(node):
            name = node.get("name")
            if isinstance(name, str):
                out.append(name)
            for key in ("nodes", "floating_nodes"):
                for child in node.get(key, []) or []:
                    walk(child)

        walk(tree)
        return out

    def outputs(self) -> list[str]:
        if not self.sock:
            return []
        cp = run(["swaymsg", "-s", self.sock, "-t", "get_outputs", "-r"])
        if cp.returncode != 0:
            return []
        try:
            return [o["name"] for o in json.loads(cp.stdout)]
        except Exception:
            return []


# --------------------------------------------------------------------------
# telemetry helpers


def parse_title(titles: list[str]) -> dict[str, str] | None:
    for t in titles:
        if t.startswith("HEVCVAL "):
            fields = {}
            for tok in t.split()[1:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    fields[k] = v
            return fields
    return None


def chromium_pids() -> list[int]:
    pids = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            exe = os.readlink(entry / "exe")
        except OSError:
            continue
        if "chromium" in exe:
            pids.append(int(entry.name))
    return pids


def open_video_nodes(pids: list[int]) -> list[str]:
    found = set()
    for pid in pids:
        fd_dir = Path(f"/proc/{pid}/fd")
        try:
            entries = list(fd_dir.iterdir())
        except OSError:
            continue
        for fd in entries:
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target.startswith("/dev/video") or target.startswith("/dev/media"):
                found.add(target)
    return sorted(found)


# --------------------------------------------------------------------------
# per-clip run


def run_clip(
    sway: Sway,
    label: str,
    clip: str,
    profile: str,
    clip_dir: Path,
    workdir: Path,
    shots: int,
    settle: float,
    extra_flags: list[str] | None = None,
    drop_flags: list[str] | None = None,
    start: float | None = None,
    end: float | None = None,
) -> dict:
    out_dir = workdir / label
    out_dir.mkdir(parents=True, exist_ok=True)
    stderr_path = out_dir / "chromium.err"
    profile_dir = out_dir / "cr-profile"
    if profile_dir.exists():
        shutil.rmtree(profile_dir, ignore_errors=True)

    url = f"file://{clip_dir}/test_page.html?clip={clip}"
    if start is not None:
        url += f"&start={start}"
        if end is not None:
            url += f"&end={end}"
    cmd = [
        CHROMIUM,
        "--no-sandbox",
        "--no-first-run",
        "--disable-session-crashed-bubble",
        "--disable-restore-session-state",
        "--kiosk",
        "--noerrdialogs",
        "--ozone-platform=wayland",
        "--enable-features=UseOzonePlatform,PlatformHEVCDecoderSupport",
        "--disable-features=UseChromeOSDirectVideoDecoder",
        "--allow-file-access-from-files",
        "--autoplay-policy=no-user-gesture-required",
        "--disable-zero-copy",
        "--disable-gpu-memory-buffer-video-frames",
        f"--user-data-dir={profile_dir}",
        "--enable-logging=stderr",
        "--v=1",
        "--vmodule=*v4l2*=2,*media*=1,*video_decoder*=2",
        url,
    ]

    # --drop-flag lets a caller remove a baked-in switch by prefix, so the
    # decoder path can be A/B'd without editing this file. --extra-flag then
    # appends replacements. Both are recorded in the report.
    for prefix in drop_flags or []:
        cmd = [c for c in cmd if not c.startswith(prefix)]
    if extra_flags:
        cmd = cmd[:-1] + list(extra_flags) + [cmd[-1]]

    log(f"[{label}] launching chromium")
    with open(stderr_path, "wb") as errf:
        proc = subprocess.Popen(
            cmd,
            env=sway.env,
            stdout=subprocess.DEVNULL,
            stderr=errf,
            preexec_fn=os.setsid,
        )

    result: dict = {"label": label, "clip": clip, "profile": profile}
    if extra_flags or drop_flags:
        result["flag_overrides"] = {"extra": extra_flags or [], "dropped": drop_flags or []}
    captures: list[str] = []
    try:
        deadline = time.time() + 60
        fields = None
        while time.time() < deadline:
            fields = parse_title(sway.titles())
            if fields and fields.get("st") == "playing" and float(fields.get("t", 0)) > 0:
                break
            if fields and fields.get("st") in ("error", "playfail"):
                break
            if proc.poll() is not None:
                break
            time.sleep(0.5)

        result["title_on_start"] = fields
        if not fields or fields.get("st") != "playing":
            result["error"] = "video never reached playing state"
            return result

        log(f"[{label}] playing; settling {settle}s")
        time.sleep(settle)

        outputs = sway.outputs()
        target = outputs[0] if outputs else None
        t_start = float(parse_title(sway.titles()).get("t", 0))
        for i in range(shots):
            shot = out_dir / f"shot{i}.png"
            grim_cmd = ["grim"]
            if target:
                grim_cmd += ["-o", target]
            grim_cmd.append(str(shot))
            cp = run(grim_cmd, env=sway.env)
            if cp.returncode != 0:
                result["error"] = f"grim failed: {cp.stderr.strip()}"
                return result
            captures.append(str(shot))
            if i < shots - 1:
                time.sleep(1.0)

        end_fields = parse_title(sway.titles()) or {}
        result["title_on_end"] = end_fields
        t_end = float(end_fields.get("t", 0))

        pids = chromium_pids()
        video_nodes = open_video_nodes(pids)

        result["captures"] = captures
        result["playback"] = {
            "advanced_seconds": round(t_end - t_start, 3),
            "total_video_frames": int(end_fields.get("tvf", 0)),
            "dropped_video_frames": int(end_fields.get("dvf", 0)),
            "corrupted_video_frames": int(end_fields.get("cvf", 0)),
            "video_size": [int(end_fields.get("w", 0)), int(end_fields.get("h", 0))],
            "media_error": end_fields.get("err", "-"),
        }
    finally:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            proc.wait(timeout=10)
        except Exception:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:
                pass
        time.sleep(1.5)

    stderr_text = stderr_path.read_text(errors="replace")
    result["hw_decode"] = {
        "open_v4l2_nodes": video_nodes,
        "v4l2_log_lines": len(V4L2_HINT.findall(stderr_text)),
        "v4l2_decoder_log_lines": len(V4L2_DECODER_HINT.findall(stderr_text)),
        "software_fallback_hits": len(SOFTWARE_HINT.findall(stderr_text)),
        "pass": bool(video_nodes) or bool(V4L2_DECODER_HINT.search(stderr_text)),
    }

    pb = result["playback"]
    result["playback"]["pass"] = bool(
        pb["advanced_seconds"] > 0.5
        and pb["total_video_frames"] > 10
        and pb["media_error"] == "-"
        and pb["video_size"] == [1920, 1080]
    )

    log(f"[{label}] analysing {len(captures)} captures")
    cp = run(
        [
            sys.executable,
            str(HERE / "analyze.py"),
            "--profile",
            profile,
            "--label",
            label,
            *captures,
        ]
    )
    try:
        result["image"] = json.loads(cp.stdout)
    except json.JSONDecodeError:
        result["image"] = {"pass": False, "error": cp.stdout + cp.stderr}

    result["pass"] = bool(
        result["hw_decode"]["pass"]
        and result["playback"]["pass"]
        and result["image"].get("pass")
    )
    return result


# --------------------------------------------------------------------------


def preflight(clip_dir: Path) -> list[str]:
    problems = []
    for tool in ("grim", "swaymsg", "sway"):
        if shutil.which(tool) is None:
            problems.append(f"missing tool: {tool}")
    if not Path(CHROMIUM).exists():
        problems.append(f"missing chromium at {CHROMIUM}")
    if not (clip_dir / "test_page.html").exists():
        problems.append(f"missing test_page.html in {clip_dir}")
    for _, clip, _ in CLIPS:
        if not (clip_dir / clip).exists():
            problems.append(f"missing clip {clip} in {clip_dir} (run make_clips.sh)")
    try:
        import numpy  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError as exc:
        problems.append(f"missing python dep: {exc.name}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip-dir", default=str(Path.home() / "hevc-test"))
    ap.add_argument("--workdir", default="/tmp/hevc-validate")
    ap.add_argument("--report", default="/tmp/hevc-validate/report.json")
    ap.add_argument("--shots", type=int, default=3)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--only", default="", help="comma-separated labels to run")
    ap.add_argument("--keep-agora-down", action="store_true")
    ap.add_argument(
        "--start", type=float, default=None,
        help="seek to this offset (seconds) and replay from there",
    )
    ap.add_argument(
        "--end", type=float, default=None,
        help="with --start, loop back to --start once past this offset",
    )
    ap.add_argument(
        "--extra-flag",
        action="append",
        default=[],
        help="extra chromium switch (repeatable)",
    )
    ap.add_argument(
        "--drop-flag",
        action="append",
        default=[],
        help="drop any baked-in chromium switch starting with this prefix (repeatable)",
    )
    args = ap.parse_args()

    if os.geteuid() != 0:
        log("must run as root (needs systemctl, DRM master, /proc fd inspection)")
        return 2

    clip_dir = Path(args.clip_dir).resolve()
    workdir = Path(args.workdir)
    shutil.rmtree(workdir, ignore_errors=True)
    workdir.mkdir(parents=True, exist_ok=True)

    problems = preflight(clip_dir)
    if problems:
        for p in problems:
            log(f"PREFLIGHT: {p}")
        return 2

    wanted = {s.strip() for s in args.only.split(",") if s.strip()}
    clips = [c for c in CLIPS if not wanted or c[0] in wanted]

    chromium_version = run(["dpkg-query", "-W", "-f=${Version}", "chromium"]).stdout.strip()
    report = {
        "chromium_version": chromium_version,
        "kernel": run(["uname", "-r"]).stdout.strip(),
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "results": [],
    }

    stopped = stop_agora()
    sway = Sway(Path("/tmp/hevc-validate-sway"))
    try:
        sway.start()
        for label, clip, profile in clips:
            report["results"].append(
                run_clip(
                    sway, label, clip, profile, clip_dir, workdir,
                    args.shots, args.settle,
                    extra_flags=args.extra_flag,
                    drop_flags=args.drop_flag,
                    start=args.start,
                    end=args.end,
                )
            )
    except Exception as exc:  # noqa: BLE001
        report["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        sway.stop()
        time.sleep(2)
        if not args.keep_agora_down:
            start_agora(stopped)

    report["pass"] = bool(
        report["results"]
        and all(r.get("pass") for r in report["results"])
        and "error" not in report
    )

    Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    Path(args.report).write_text(json.dumps(report, indent=2))

    log("=" * 60)
    for r in report["results"]:
        verdict = "PASS" if r.get("pass") else "FAIL"
        log(f"{verdict}  {r['label']:6s}  {r.get('error', '')}")
        if not r.get("pass"):
            for name, chk in (r.get("image", {}).get("checks") or {}).items():
                if not chk.get("pass"):
                    log(f"        image check failed: {name} -> {json.dumps(chk)[:300]}")
            if not r.get("hw_decode", {}).get("pass", True):
                log(f"        hw decode: {json.dumps(r['hw_decode'])[:300]}")
            if not r.get("playback", {}).get("pass", True):
                log(f"        playback: {json.dumps(r['playback'])[:300]}")
    log("=" * 60)
    log(f"OVERALL: {'PASS' if report['pass'] else 'FAIL'}  (report: {args.report})")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
