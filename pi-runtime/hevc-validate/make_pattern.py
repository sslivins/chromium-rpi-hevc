#!/usr/bin/env python3
"""Generate the deterministic HEVC validation test pattern (1920x1080 PNG).

Layout (expressed as fractions of the frame so the analyser stays
resolution-agnostic when the capture is scaled):

  y 0.000 - 0.889   analysis band (completely static)
      x 0.000 - 0.667   smooth horizontal grey gradient 0 -> 255
      x 0.667 - 1.000   eight stacked solid colour patches
  y 0.889 - 1.000   motion strip (black; ffmpeg sweeps a white bar over it)

The grey gradient is what exposes the SAND128 chroma bug: that regression
paints magenta/green bands with a ~128 px period, which shows up as a strong
autocorrelation peak at lag 128 in the per-column chroma residual.

The solid patches give an absolute colour-accuracy check, and keeping all
motion confined to the bottom strip means the colour checks are never
confounded by which frame we happened to capture.
"""

from __future__ import annotations

import sys

from PIL import Image

WIDTH = 1920
HEIGHT = 1080
ANALYSIS_H = 960
GRADIENT_W = 1280

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


def build() -> Image.Image:
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


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "pattern.png"
    build().save(out)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
