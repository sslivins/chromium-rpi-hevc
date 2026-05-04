# Upstream source pinning

This repo's build is **fully pinned** to a single Chromium upstream
version: `1:147.0.7727.116-1~deb13u1+rpt1`. The patches under
`patches/` were written and tested against this exact source tree;
applying them to a different version is not guaranteed to work.

This document explains how the pin works, why it exists, and how to
move it forward when the time comes.

## What is pinned

Three independently-drifting inputs feed our build. All three are
locked.

| Input | What it is | Where the pin lives |
|---|---|---|
| Chromium source (`*.orig.tar.xz`, ~787 MB) | Google's chromium tarball as repackaged by RPi-Distro | This repo's GitHub Release `upstream-source-147.0.7727.116`, with SHA256 in `build/build.sh` |
| RPi debian/ overlay (`*.debian.tar.xz`, ~500 KB) | RPi-Distro's `debian/` packaging directory: `debian/rules`, ~100 packaging patches, etc. | Same release, same SHA256 enforcement |
| Base Docker image | `debian:trixie` userland | Multi-arch manifest digest in `build/Dockerfile`'s `FROM` line |

The build dependency packages (`apt-get build-dep chromium`) are
**not** pinned individually — they're whatever's current in the RPi
archive when the Docker image is built. In practice these drift slowly
and are backwards-compatible. If we ever need to pin them too, the
right move is to snapshot the resolved package list at image-build
time and check it in.

## Why pin

Without a pin, `apt-get source chromium` returns whatever version
the RPi archive currently advertises. That version moves whenever
RPi-Distro releases a security update, which has happened multiple
times in the lifetime of these patches. When upstream moves, our
patches no longer apply cleanly — silent build break.

Pinning means:

1. Anyone who clones this repo at a given tag and runs the build
   gets the exact same bytes we got, regardless of how much time has
   passed since the tag was cut.
2. SHA256 verification means a corrupted download or a compromised
   mirror is detected and aborts the build, rather than producing a
   silently-wrong binary.
3. We can reason about "the patches apply" independent of "the
   archive still has this version".

## How the pin works

`build/build.sh` STAGE 1:

1. Constructs the three filenames from `CHROMIUM_VERSION_FULL` and
   `CHROMIUM_VERSION_UPSTREAM`.
2. Downloads each from `${UPSTREAM_RELEASE_URL}/<filename>` (defaults
   to this repo's release; can be overridden by setting
   `UPSTREAM_RELEASE_URL` in the environment, useful for forks or
   air-gapped mirrors).
3. SHA256-verifies each against constants compiled into `build.sh`.
4. Aborts if any checksum mismatches.
5. Runs `dpkg-source -x <dsc>` to extract.

`build/Dockerfile` `FROM` line uses
`debian:trixie@sha256:<digest>`, which freezes the base image
contents.

## Bumping to a new chromium version

When a new RPi `+rpt1` chromium release is published and we want to
re-base our patches onto it:

1. **Rebase the patches.** On a build VM, fetch the new source via
   `apt-get source chromium=<new-version>`, copy the new `debian/`
   tree into our quilt environment, and try to apply each of our
   patches in order. Fix conflicts manually (patch hunk offsets
   shift; sometimes upstream changes break a patch entirely).
2. **Iterate locally** until a full build produces a .deb and the
   binary plays HEVC correctly on a Pi.
3. **Vendor the new source files.** Download all three from
   `archive.raspberrypi.com/debian/pool/main/c/chromium/`, compute
   SHA256, and verify they match the `.dsc` file's
   `Checksums-Sha256:` block.
4. **Cut a new GitHub Release** named
   `upstream-source-<new-version>` on this repo and upload all three
   as assets, with the SHA256s in the release notes.
5. **Update `build/build.sh`**: bump
   `CHROMIUM_VERSION_FULL`, `CHROMIUM_VERSION_UPSTREAM`,
   `UPSTREAM_RELEASE_URL`, and the three SHA256 constants.
6. **Update `build/Dockerfile`** with the current `debian:trixie`
   manifest digest if the base image has rolled (often unnecessary).
7. **Update this document** with the new pinned version.
8. **Tag a new patch release** (e.g. `v0.3.0`).

## Verifying the pin manually

```bash
# Inside the build container after STAGE 1, you should see:
#   ok: chromium_147.0.7727.116.orig.tar.xz (b808992f...)
#   ok: chromium_147.0.7727.116-1~deb13u1+rpt1.debian.tar.xz (a8845002...)
#   ok: chromium_147.0.7727.116-1~deb13u1+rpt1.dsc (b0ac0f71...)
sha256sum /build/src/chromium_*.{orig.tar.xz,debian.tar.xz,dsc}
```

The same SHA256s also appear in the `Checksums-Sha256:` block of
the `.dsc` file — they are RPi-Distro's own checksums, which we
recorded but did not generate.

## Independent provenance check

The RPi-Distro `debian/` overlay (`*.debian.tar.xz`) is
content-equivalent to the GitHub tag
[`pios/1%147.0.7727.116-1_deb13u1+rpt1`](https://github.com/RPi-Distro/chromium/tree/pios/1%25147.0.7727.116-1_deb13u1+rpt1)
(commit `c5a65d9`). If our release is ever lost, this tag is a
permanent independent record of what we patched against — extract
the GitHub tag's `debian/` directory, repackage as a `.tar.xz`, and
the SHA256 should match.

The upstream chromium tarball (`*.orig.tar.xz`) is a repackage of
Google's upstream chromium release. Google's own snapshots are at
`https://commondatastorage.googleapis.com/chromium-browser-official/chromium-147.0.7727.116.tar.xz`
or similar paths, but RPi sometimes runs `xz -e` re-compression which
changes the SHA256. Treat our release as the authoritative copy.
