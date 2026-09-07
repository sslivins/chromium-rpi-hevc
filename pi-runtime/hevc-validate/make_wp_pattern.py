#!/usr/bin/env python3
"""Render frames for the weighted-prediction (pred_weight_table) test clip.

Purpose
-------
Issue #14 item 2: patch 0008 derives the chroma weighted-prediction offset
from the hardcoded 8-bit constant

    constexpr int kWpOffsetHalfRangeC = 128;   // 1 << (BitDepthC - 1)

HEVC eq. (7-56) requires ``1 << (BitDepthC - 1)``, i.e. 512 for Main 10.
The bug is therefore only observable on 10-bit content whose slices carry a
*chroma* pred_weight_table -- which in practice means a fade, since that is
what makes an encoder decide weighted prediction is worth the bits.

The standard validation pattern (make_pattern.py) is deliberately static in
its analysis band, so it never triggers weighted prediction at all and scores
a clean pass over the broken path. This generator exists to produce the
opposite: content whose every inter frame is a global illumination *and*
chroma shift.

Design
------
The frame cross-fades between two chromatically opposed saturated colours.
Fading between, say, red-orange and blue swings both chroma planes hard in
opposite directions, which is what forces non-trivial per-plane weights *and*
offsets rather than a luma-only weight.

A small static patch is kept in the corner. It does not prevent frame-level
weighting (the weights are global), but it gives the analyser a region whose
correct value is known a priori and which must stay constant across the fade.

Usage:
    make_wp_pattern.py --frames 96 --outdir wpframes
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

WIDTH = 1920
HEIGHT = 1080

# Chromatically opposed endpoints: the fade drives U and V in opposite
# directions at once, so a chroma-offset bug cannot cancel out.
COLOUR_A = (255, 40, 0)
COLOUR_B = (0, 80, 255)

# Static reference patch (top-left). Mid grey is chroma-neutral, so any
# chroma error shows up here as a colour cast on what must stay neutral.
REF_XY = (0, 0)
REF_WH = (240, 135)
REF_RGB = (128, 128, 128)


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def fade_frame(t: float) -> Image.Image:
    """t in [0,1]: 0 -> COLOUR_A, 1 -> COLOUR_B."""
    colour = tuple(lerp(COLOUR_A[i], COLOUR_B[i], t) for i in range(3))
    img = Image.new("RGB", (WIDTH, HEIGHT), colour)
    ref = Image.new("RGB", REF_WH, REF_RGB)
    img.paste(ref, REF_XY)
    return img


def triangle(i: int, n: int) -> float:
    """Ping-pong 0->1->0 so the clip loops seamlessly."""
    half = n / 2.0
    return i / half if i < half else 2.0 - i / half


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=96)
    ap.add_argument("--outdir", default="wpframes")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    for i in range(args.frames):
        fade_frame(triangle(i, args.frames)).save(outdir / f"f{i:04d}.png")

    print(f"{args.frames} fade frames -> {outdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
