#!/usr/bin/env python3
"""Self-test for analyze.py.

A validator that can only ever return PASS is worthless, so this synthesises
each failure mode and asserts that the corresponding check actually goes red
-- and that a clean render still goes green.

    python3 selftest.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from make_pattern import base_frame, with_bar  # noqa: E402

WIDTH = 1920
ANALYSIS_H = 960
GRADIENT_W = 1280
SAND_PERIOD = 128


def render(tmp: Path, name: str, arrays: list[np.ndarray]) -> list[str]:
    paths = []
    for i, arr in enumerate(arrays):
        p = tmp / f"{name}{i}.png"
        Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(p)
        paths.append(str(p))
    return paths


def clean_frames() -> list[np.ndarray]:
    base = base_frame()
    return [
        np.asarray(with_bar(base, x), dtype=np.float64)
        for x in (0, 640, 1280)
    ]


def run_analyzer(paths: list[str], profile: str = "bt709") -> dict:
    cp = subprocess.run(
        [sys.executable, str(HERE / "analyze.py"), "--profile", profile, *paths],
        capture_output=True,
        text=True,
    )
    return json.loads(cp.stdout)


def inject_banding(frames: list[np.ndarray]) -> list[np.ndarray]:
    """Reproduce the SAND128 signature: magenta/green bands every 128 px."""
    out = []
    x = np.arange(WIDTH)
    # Square wave with a 128 px period, +/- 1 across the gradient region.
    band = np.where((x // (SAND_PERIOD // 2)) % 2 == 0, 1.0, -1.0)
    for f in frames:
        g = f.copy()
        shift = band[None, :GRADIENT_W, None] * np.array([22.0, -22.0, 22.0])
        g[:ANALYSIS_H, :GRADIENT_W, :] += shift
        out.append(g)
    return out


CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn

    return deco


@case("clean render passes everything")
def _clean(tmp):
    rep = run_analyzer(render(tmp, "clean", clean_frames()))
    assert rep["pass"], json.dumps(rep["checks"], indent=2)
    return rep


@case("black screen fails not_black")
def _black(tmp):
    frames = [np.zeros_like(f) for f in clean_frames()]
    rep = run_analyzer(render(tmp, "black", frames))
    assert not rep["checks"]["not_black"]["pass"], rep["checks"]["not_black"]
    return rep


@case("frozen playback fails motion")
def _frozen(tmp):
    one = clean_frames()[0]
    rep = run_analyzer(render(tmp, "frozen", [one, one.copy(), one.copy()]))
    assert not rep["checks"]["motion"]["pass"], rep["checks"]["motion"]
    return rep


@case("garbage in the static band fails static_stable")
def _unstable(tmp):
    frames = clean_frames()
    rng = np.random.default_rng(7)
    for f in frames[1:]:
        f[:ANALYSIS_H, :, :] += rng.normal(0, 30, f[:ANALYSIS_H, :, :].shape)
    rep = run_analyzer(render(tmp, "unstable", frames))
    assert not rep["checks"]["static_stable"]["pass"], rep["checks"]["static_stable"]
    return rep


@case("swapped colour channels fail colour")
def _colour(tmp):
    frames = [f[:, :, ::-1].copy() for f in clean_frames()]
    rep = run_analyzer(render(tmp, "colour", frames))
    assert not rep["checks"]["colour"]["pass"], rep["checks"]["colour"]
    return rep


@case("SAND128 chroma banding fails chroma_banding")
def _banding(tmp):
    rep = run_analyzer(render(tmp, "band", inject_banding(clean_frames())))
    assert not rep["checks"]["chroma_banding"]["pass"], rep["checks"]["chroma_banding"]
    return rep


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, fn in CASES:
            try:
                fn(tmp)
                print(f"ok    {name}")
            except AssertionError as exc:
                failures += 1
                print(f"FAIL  {name}\n      {exc}")
    print(f"\n{len(CASES) - failures}/{len(CASES)} self-tests passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
