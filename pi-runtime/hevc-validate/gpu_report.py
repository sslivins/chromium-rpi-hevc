#!/usr/bin/env python3
"""Dump chrome://gpu's rendered text via the DevTools protocol.

chrome://gpu is the only place that states, authoritatively, whether the GPU
process considers "Video Decode" enabled -- which is the switch that decides if
HEVC is advertised at all. `--dump-dom` is useless here because the page fills
itself in asynchronously, so we attach over CDP and read innerText after the
data has arrived.

Deliberately dependency-free: the Pi has no websocket-client, and installing one
on a device under test is a good way to change what you are measuring.

    sudo python3 gpu_report.py [--grep TEXT]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate import (  # noqa: E402
    CHROMIUM, Sway, kill_stale_sessions, log, run, stop_agora,
)

PORT = 9333

# chrome://gpu renders inside custom elements, and innerText does not descend
# into shadow roots, so walk them explicitly or the page reads as empty.
SHADOW_TEXT_JS = """
(function () {
  const out = [];
  function walk(root) {
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) { walk(el.shadowRoot); continue; }
      if (el.tagName === 'STYLE' || el.tagName === 'SCRIPT') { continue; }
      if (!el.children.length) {
        const t = (el.textContent || '').trim();
        if (t) out.push(t);
      }
    }
  }
  walk(document);
  return location.href + '\\n' + out.join('\\n');
})()
"""


class WS:
    """The ~60 lines of RFC 6455 needed to speak CDP, and nothing more."""

    def __init__(self, url: str) -> None:
        m = re.match(r"ws://([^:/]+):(\d+)(/.*)", url)
        if not m:
            raise ValueError(f"unparseable ws url: {url}")
        host, port, path = m.group(1), int(m.group(2)), m.group(3)
        self.sock = socket.create_connection((host, port), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            .encode()
        )
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("handshake closed early")
            buf += chunk
        if b"101" not in buf.split(b"\r\n")[0]:
            raise ConnectionError(f"handshake failed: {buf[:120]!r}")
        self.rest = buf.split(b"\r\n\r\n", 1)[1]

    def _recv(self, n: int) -> bytes:
        out = self.rest[:n]
        self.rest = self.rest[n:]
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                raise ConnectionError("socket closed")
            out += chunk
        return out

    def send(self, payload: dict) -> None:
        data = json.dumps(payload).encode()
        header = b"\x81"
        n = len(data)
        if n < 126:
            header += struct.pack("!B", 0x80 | n)
        elif n < (1 << 16):
            header += struct.pack("!BH", 0x80 | 126, n)
        else:
            header += struct.pack("!BQ", 0x80 | 127, n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(header + mask + masked)

    def recv(self) -> dict:
        while True:
            b0, b1 = struct.unpack("!BB", self._recv(2))
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._recv(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv(8))[0]
            if b1 & 0x80:
                self._recv(4)  # server frames are never masked in practice
            payload = self._recv(length)
            if (b0 & 0x0F) == 1:
                return json.loads(payload)

    def close(self) -> None:
        try:
            self.sock.close()
        except Exception:
            pass


def command(ws_url: str, method: str, params: dict | None = None) -> dict:
    ws = WS(ws_url)
    try:
        ws.send({"id": 1, "method": method, "params": params or {}})
        deadline = time.time() + 20
        while time.time() < deadline:
            msg = ws.recv()
            if msg.get("id") == 1:
                return msg
        return {}
    finally:
        ws.close()


def evaluate(ws_url: str, expression: str) -> str:
    ws = WS(ws_url)
    try:
        ws.send({"id": 1, "method": "Runtime.evaluate",
                 "params": {"expression": expression, "returnByValue": True}})
        deadline = time.time() + 20
        while time.time() < deadline:
            msg = ws.recv()
            if msg.get("id") == 1:
                res = msg.get("result", {}).get("result", {})
                if "value" in res:
                    return str(res["value"])
                return json.dumps(msg)[:500]
        return "(timed out waiting for Runtime.evaluate)"
    finally:
        ws.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--grep", default="", help="only print matching lines")
    ap.add_argument("--settle", type=float, default=10.0,
                    help="seconds to let chrome://gpu populate")
    args = ap.parse_args()

    if os.geteuid() != 0:
        log("must run as root")
        return 2

    kill_stale_sessions()
    workdir = Path("/tmp/gpu-report")
    shutil.rmtree(workdir, ignore_errors=True)
    workdir.mkdir(parents=True)

    # Headless falls back to SwiftShader, and SwiftShader reports video decode
    # as disabled -- which is the exact thing we are trying to measure. Drive a
    # real sway session so the GPU process sees the real V3D/DRM stack.
    stop_agora()
    sway = Sway(workdir / "sway")
    sway.start()
    env = dict(sway.env)
    cmd = [
        CHROMIUM, "--no-sandbox", "--no-first-run", "--noerrdialogs",
        "--ozone-platform=wayland", "--enable-features=UseOzonePlatform",
        f"--user-data-dir={workdir / 'p'}",
        f"--remote-debugging-port={PORT}",
        "--remote-allow-origins=*",
        "about:blank",
    ]
    with open(workdir / "err", "wb") as errf:
        proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL,
                                stderr=errf, preexec_fn=os.setsid)
    try:
        target = None
        last_err = ""
        deadline = time.time() + 30
        while time.time() < deadline and target is None:
            time.sleep(1)
            try:
                raw = urllib.request.urlopen(
                    f"http://127.0.0.1:{PORT}/json/list", timeout=5).read()
                targets = json.loads(raw)
                last_err = "targets: " + ", ".join(
                    f"{t.get('type')}:{t.get('url', '')[:40]}" for t in targets)
                for t in targets:
                    if t.get("type") == "page" and t.get(
                            "webSocketDebuggerUrl"):
                        target = t["webSocketDebuggerUrl"]
                        break
            except Exception as exc:
                last_err = repr(exc)
                continue
        if not target:
            log(f"never found a devtools page target ({last_err})")
            return 1
        # A renderer is not allowed to navigate itself to a WebUI URL, so the
        # navigation has to be browser-initiated via CDP.
        command(target, "Page.navigate", {"url": "chrome://gpu"})
        time.sleep(args.settle)
        # The WebUI navigation moves the page to a new renderer, which gets a
        # fresh debugger URL, so re-resolve rather than reusing the old one.
        raw = urllib.request.urlopen(
            f"http://127.0.0.1:{PORT}/json/list", timeout=5).read()
        for t in json.loads(raw):
            if "gpu" in t.get("url", "") and t.get("webSocketDebuggerUrl"):
                target = t["webSocketDebuggerUrl"]
                break
        text = evaluate(target, SHADOW_TEXT_JS)
    finally:
        try:
            os.killpg(os.getpgid(proc.pid), 15)
        except Exception:
            pass
        sway.stop()

    version = run(["dpkg-query", "-W", "-f=${Version}", "chromium"]).stdout.strip()
    print("chromium:", version)
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if args.grep and args.grep.lower() not in line.lower():
            continue
        print("  ", line[:200])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
