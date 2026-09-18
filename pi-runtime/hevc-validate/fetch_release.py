#!/usr/bin/env python3
"""Download and verify the runtime debs of a chromium-rpi-hevc release.

    fetch_release.py --tag chromium-153.0.8010.47-2-rpt1-hevc1 \
        --dest /var/tmp/hevc-debs

Asset names are discovered from the GitHub API rather than reconstructed from
a version string, because GitHub rewrites '~' to '.' in asset filenames -- so
the published name never matches the Debian version verbatim.

If the release notes contain a "sha256  filename" block, every downloaded file
is checked against it and a mismatch is fatal. A release without that block is
downloaded anyway but reported as unverified, so the caller can decide.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO = "sslivins/chromium-rpi-hevc"

# The packages actually needed to run chromium on the Pi. Build byproducts
# (-driver, -shell, dbgsym, .buildinfo, .changes) are deliberately skipped.
RUNTIME_PREFIXES = ("chromium_", "chromium-common_", "chromium-sandbox_", "chromium-l10n_")

SHA_LINE = re.compile(r"^([0-9a-f]{64})\s+(\S+)\s*$", re.MULTILINE)


def api(url: str) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--repo", default=REPO)
    args = ap.parse_args()

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    rel = api(f"https://api.github.com/repos/{args.repo}/releases/tags/{args.tag}")
    expected = {name: digest for digest, name in SHA_LINE.findall(rel.get("body") or "")}

    wanted = [
        a for a in rel.get("assets", [])
        if a["name"].endswith(".deb") and a["name"].startswith(RUNTIME_PREFIXES)
    ]
    if not wanted:
        print(f"no runtime debs found in release {args.tag}", file=sys.stderr)
        return 2

    verified = 0
    for asset in sorted(wanted, key=lambda a: a["name"]):
        name = asset["name"]
        out = dest / name
        if not out.exists() or out.stat().st_size != asset["size"]:
            print(f"downloading {name} ({asset['size'] / 1e6:.1f} MB)")
            urllib.request.urlretrieve(asset["browser_download_url"], out)
        else:
            print(f"cached {name}")

        got = sha256(out)
        want = expected.get(name)
        if want is None:
            print(f"  sha256 {got}  (no digest published; UNVERIFIED)")
        elif want != got:
            print(f"  sha256 MISMATCH for {name}\n    expected {want}\n    got      {got}",
                  file=sys.stderr)
            return 1
        else:
            print(f"  sha256 {got}  verified")
            verified += 1

    print(f"{len(wanted)} deb(s) in {dest}; {verified} digest-verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
