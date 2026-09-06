#!/usr/bin/env python3
"""Score grim captures of the HEVC validation pattern.

Usage:
    analyze.py --profile bt709 shot0.png shot1.png shot2.png

Emits a JSON report on stdout and exits non-zero if any check fails.

Checks
------
not_black          The static analysis band has real luminance and real
                   contrast. Catches the classic "black screen" failure.
motion             The bottom motion strip changes between captures. Catches
                   decode-first-frame-then-freeze.
static_stable      The static band does NOT change between captures. Catches
                   tearing, garbage, and flicker.
colour             The eight solid patches land on their expected colours
                   (bt709 profile) or at least keep the right hue ordering
                   and separation (hdr profile, where no display-referred
                   tone mapping is applied).
chroma_banding     No ~128 px periodic chroma structure in the grey gradient,
                   and no column-wise chroma spread inside the solid patches.
                   This is the SAND128 regression signature (docs/chroma-bug.md).

Geometry is expressed in fractions of the captured frame, so the analyser
works whatever resolution the Pi's display happens to be.
"""

from __future__ import annotations

import argparse
import json
import sys

import numpy as np
from PIL import Image

# Fractions matching make_pattern.py.
ANALYSIS_Y1 = 960 / 1080
GRADIENT_X1 = 1280 / 1920
MOTION_Y0 = 960 / 1080

EXPECTED_PATCHES = [
    (255, 0, 0),
    (0, 255, 0),
    (0, 0, 255),
    (255, 0, 255),
    (0, 255, 255),
    (255, 255, 0),
    (255, 255, 255),
    (128, 128, 128),
]

# Reference band period in the 1920-wide source.
SAND_PERIOD_SRC = 128
SAND_REF_WIDTH = 1920


def load(path: str) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"), dtype=np.float64)


def luma(rgb: np.ndarray) -> np.ndarray:
    return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]


def chroma(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    y = luma(rgb)
    return rgb[..., 2] - y, rgb[..., 0] - y


def regions(shape: tuple[int, int]) -> dict[str, tuple[int, int, int, int]]:
    h, w = shape
    ay1 = int(round(h * ANALYSIS_Y1))
    gx1 = int(round(w * GRADIENT_X1))
    my0 = int(round(h * MOTION_Y0))
    return {
        "analysis": (0, 0, ay1, w),
        "gradient": (0, 0, ay1, gx1),
        "patches": (0, gx1, ay1, w),
        "motion": (my0, 0, h, w),
    }


def crop(a: np.ndarray, box: tuple[int, int, int, int]) -> np.ndarray:
    y0, x0, y1, x1 = box
    return a[y0:y1, x0:x1]


def patch_means(rgb: np.ndarray, box: tuple[int, int, int, int]) -> list[np.ndarray]:
    band = crop(rgb, box)
    n = len(EXPECTED_PATCHES)
    ph = band.shape[0] / n
    out = []
    for i in range(n):
        # Inset by 20% vertically and 10% horizontally to stay clear of the
        # boundaries, which soften under chroma subsampling.
        y0 = int(round(i * ph + 0.2 * ph))
        y1 = int(round((i + 1) * ph - 0.2 * ph))
        x0 = int(round(band.shape[1] * 0.1))
        x1 = int(round(band.shape[1] * 0.9))
        out.append(band[y0:y1, x0:x1])
    return out


def check_not_black(shots: list[np.ndarray], reg) -> dict:
    means, stds = [], []
    for s in shots:
        band = luma(crop(s, reg["analysis"]))
        means.append(float(band.mean()))
        stds.append(float(band.std()))
    ok = min(means) > 20.0 and min(stds) > 25.0
    return {
        "pass": bool(ok),
        "mean_luma": [round(m, 2) for m in means],
        "stddev_luma": [round(s, 2) for s in stds],
        "thresholds": {"mean_luma_min": 20.0, "stddev_luma_min": 25.0},
    }


def check_motion(shots: list[np.ndarray], reg) -> dict:
    if len(shots) < 2:
        return {"pass": False, "reason": "need >= 2 captures"}
    strips = [luma(crop(s, reg["motion"])) for s in shots]
    diffs = [float(np.abs(strips[i + 1] - strips[i]).mean()) for i in range(len(strips) - 1)]
    ok = max(diffs) > 1.0
    return {
        "pass": bool(ok),
        "mean_abs_diff": [round(d, 3) for d in diffs],
        "thresholds": {"max_mean_abs_diff_min": 1.0},
    }


def check_static_stable(shots: list[np.ndarray], reg) -> dict:
    if len(shots) < 2:
        return {"pass": True, "reason": "single capture"}
    bands = [luma(crop(s, reg["analysis"])) for s in shots]
    diffs = [float(np.abs(bands[i + 1] - bands[i]).mean()) for i in range(len(bands) - 1)]
    ok = max(diffs) < 4.0
    return {
        "pass": bool(ok),
        "mean_abs_diff": [round(d, 3) for d in diffs],
        "thresholds": {"max_mean_abs_diff_max": 4.0},
    }


def check_colour(shots: list[np.ndarray], reg, profile: str) -> dict:
    rgb = shots[len(shots) // 2]
    got = [p.reshape(-1, 3).mean(axis=0) for p in patch_means(rgb, reg["patches"])]
    detail = []
    ok = True

    for i, (mean, want) in enumerate(zip(got, EXPECTED_PATCHES)):
        entry = {
            "index": i,
            "expected": list(want),
            "measured": [round(float(c), 1) for c in mean],
        }
        if profile == "bt709":
            err = float(np.abs(mean - np.array(want, dtype=np.float64)).max())
            entry["max_abs_error"] = round(err, 1)
            entry["pass"] = err <= 42.0
        else:
            # HDR content is not tone mapped for the display, so absolute
            # values drift. Require only that each channel that should be
            # bright is clearly brighter than each channel that should be
            # dark -- i.e. hue survives.
            want_arr = np.array(want, dtype=np.float64)
            hi = mean[want_arr >= 200]
            lo = mean[want_arr <= 50]
            if hi.size and lo.size:
                sep = float(hi.min() - lo.max())
                entry["separation"] = round(sep, 1)
                entry["pass"] = sep > 15.0
            else:
                # White / grey patches: just require non-black.
                entry["pass"] = bool(mean.mean() > 15.0)
        ok = ok and entry["pass"]
        detail.append(entry)

    return {"pass": bool(ok), "profile": profile, "patches": detail}


def _detrend(sig: np.ndarray, window: int) -> np.ndarray:
    if window % 2 == 0:
        window += 1
    if window >= sig.size:
        return sig - sig.mean()
    pad = window // 2
    padded = np.pad(sig, pad, mode="edge")
    kernel = np.ones(window) / window
    return sig - np.convolve(padded, kernel, mode="valid")


def _acf_at(sig: np.ndarray, lag: int) -> float:
    if lag <= 0 or lag >= sig.size:
        return 0.0
    a = sig[:-lag]
    b = sig[lag:]
    denom = np.sqrt((a * a).sum() * (b * b).sum())
    if denom <= 1e-9:
        return 0.0
    return float((a * b).sum() / denom)


def check_chroma_banding(shots: list[np.ndarray], reg) -> dict:
    rgb = shots[len(shots) // 2]
    width = rgb.shape[1]
    lag = max(2, int(round(SAND_PERIOD_SRC * width / SAND_REF_WIDTH)))

    grad = crop(rgb, reg["gradient"])
    u, v = chroma(grad)
    findings = {}
    banding = False
    for name, plane in (("u", u), ("v", v)):
        col = plane.mean(axis=0)
        resid = _detrend(col, 3 * lag)
        rms = float(np.sqrt((resid ** 2).mean()))
        acf = _acf_at(resid, lag)
        hit = rms > 1.5 and acf > 0.35
        banding = banding or hit
        findings[name] = {
            "residual_rms": round(rms, 3),
            "acf_at_period": round(acf, 3),
            "flagged": bool(hit),
        }

    # Solid patches must not show column-wise chroma spread.
    spreads = []
    for p in patch_means(rgb, reg["patches"]):
        pu, pv = chroma(p)
        spreads.append(
            max(float(pu.mean(axis=0).std()), float(pv.mean(axis=0).std()))
        )
    patch_spread = max(spreads)
    patch_hit = patch_spread > 6.0
    banding = banding or patch_hit

    return {
        "pass": not banding,
        "period_px": lag,
        "gradient": findings,
        "patch_column_chroma_spread_max": round(patch_spread, 3),
        "patch_spread_flagged": bool(patch_hit),
        "thresholds": {
            "gradient_residual_rms_max": 1.5,
            "gradient_acf_max": 0.35,
            "patch_spread_max": 6.0,
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", choices=["bt709", "hdr"], default="bt709")
    ap.add_argument("--label", default="")
    ap.add_argument("shots", nargs="+")
    args = ap.parse_args()

    shots = [load(p) for p in args.shots]
    if len({s.shape for s in shots}) != 1:
        print(json.dumps({"pass": False, "error": "captures differ in size"}))
        return 2

    reg = regions(shots[0].shape[:2])
    checks = {
        "not_black": check_not_black(shots, reg),
        "motion": check_motion(shots, reg),
        "static_stable": check_static_stable(shots, reg),
        "colour": check_colour(shots, reg, args.profile),
        "chroma_banding": check_chroma_banding(shots, reg),
    }
    report = {
        "label": args.label,
        "profile": args.profile,
        "capture_size": [int(shots[0].shape[1]), int(shots[0].shape[0])],
        "captures": args.shots,
        "checks": checks,
        "pass": all(c["pass"] for c in checks.values()),
    }
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
