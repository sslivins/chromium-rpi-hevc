#!/usr/bin/env python3
"""Render the deterministic HEVC validation frames.

Layout (expressed as fractions of the frame so the analyser stays
resolution-agnostic when the capture is scaled):

  y 0.000 - 0.889   analysis band (identical in every frame)
      x 0.000 - 0.667   smooth horizontal grey gradient 0 -> 255
      x 0.667 - 1.000   eight stacked solid colour patches
  y 0.889 - 1.000   motion strip: a white bar sweeps left to right

The grey gradient is what exposes the SAND128 chroma bug: that regression
paints magenta/green bands with a ~128 px period, which shows up as a strong
autocorrelation peak at lag 128 in the per-column chroma residual.

The solid patches give an absolute colour-accuracy check. Keeping all motion
confined to the bottom strip means the colour and chroma checks are never
confounded by which frame the capture happened to land on.

The motion is baked into pre-rendered frames rather than produced by an
ffmpeg filter expression: drawbox evaluates its x/y/w/h expressions once at
configuration time, which silently yields a completely static clip.

Usage:
    make_pattern.py --frames 60 --outdir frames    # animated sequence
    make_pattern.py --still pattern.png            # single static frame
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

WIDTH = 1920
HEIGHT = 1080
ANALYSIS_H = 960
GRADIENT_W = 1280
BAR_W = 96

PATCHES = [
    (255, 0, 0),
    (0, 255, 0),
    (0, 0, 255),
    (255, 0, 255),
    (0, 255, 255),
    (255, 255, 0),
    (255, 255, 255),
    (128, 128, 128),
]


def base_frame() -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), (0, 0, 0))
    px = img.load()

    for x in range(GRADIENT_W):
        v = round(x * 255 / (GRADIENT_W - 1))
        for y in range(ANALYSIS_H):
            px[x, y] = (v, v, v)

    patch_h = ANALYSIS_H // len(PATCHES)
    for i, colour in enumerate(PATCHES):
        y0 = i * patch_h
        y1 = ANALYSIS_H if i == len(PATCHES) - 1 else y0 + patch_h
        for y in range(y0, y1):
            for x in range(GRADIENT_W, WIDTH):
                px[x, y] = colour

    return img


def with_bar(base: Image.Image, x: int) -> Image.Image:
    frame = base.copy()
    bar = Image.new("RGB", (BAR_W, HEIGHT - ANALYSIS_H), (255, 255, 255))
    frame.paste(bar, (x, ANALYSIS_H))
    if x + BAR_W > WIDTH:
        frame.paste(bar, (x - WIDTH, ANALYSIS_H))
    return frame


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--outdir", default="frames")
    ap.add_argument("--still", default="")
    args = ap.parse_args()

    base = base_frame()

    if args.still:
        base.save(args.still)
        print(args.still)
        return 0

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    step = WIDTH / args.frames
    for i in range(args.frames):
        with_bar(base, int(round(i * step))).save(outdir / f"f{i:04d}.png")
    print(f"{args.frames} frames -> {outdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
