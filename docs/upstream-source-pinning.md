# Upstream source pinning

This repo's build is **fully pinned** to a single Chromium upstream
version: `1:152.0.7977.75-1~deb13u1+rpt1`. The patches under
`patches/` were rebased onto, built against, and validated on Pi 5
hardware with this exact version, so unlike the 151 pin there is no
gap between the version the patches were reviewed against and the
version that is built.

This document explains how the pin works, why it exists, and how to
move it forward when the time comes.

## What is pinned

Four independently-drifting inputs feed our build. All four are
locked.

| Input | What it is | Where the pin lives |
|---|---|---|
| Chromium source (`*.orig.tar.xz`, ~905 MB) | Google's chromium tarball as repackaged by RPi-Distro | This repo's GitHub Release `upstream-source-152.0.7977.75`, with SHA256 in `build/cli.sh` |
| Chromium pre-gen source (`*.orig-pre-gen.tar.xz`, ~15 MB) | Second orig component introduced by the 151.x `.dsc` and still present in 152.x (multi-tarball Debian format 3.0 quilt); holds pre-generated files not in the main orig tarball | Same release, same SHA256 enforcement |
| RPi debian/ overlay (`*.debian.tar.xz`, ~560 KB) | RPi-Distro's `debian/` packaging directory: `debian/rules`, ~100 packaging patches, etc. | Same release, same SHA256 enforcement |
| Base Docker image | `debian:trixie` userland | Multi-arch manifest digest in `build/Dockerfile`'s `FROM` line |

Note: the 147.x pin only had three components (orig + debian + dsc).
The `orig-pre-gen` tarball is new to the 151.x `.dsc` — discovered the
hard way when `dpkg-source -x` failed with `cannot fstat file
./chromium_151.0.7922.173.orig-pre-gen.tar.xz: No such file or
directory` because it wasn't in our first cut of the vendored release.

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

`build/cli.sh` `_cmd_fetch` STAGE 1:

1. Constructs the four filenames from `CHROMIUM_VERSION_FULL` and
   `CHROMIUM_VERSION_UPSTREAM`.
2. Downloads each from `${UPSTREAM_RELEASE_URL}/<filename>` (defaults
   to this repo's release; can be overridden by setting
   `UPSTREAM_RELEASE_URL` in the environment, useful for forks or
   air-gapped mirrors).
3. SHA256-verifies each against constants compiled into `cli.sh`.
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

   **Cut the port branch from `main`, and verify it.** The 152 port
   branch was cut from a stale base and silently lost two patches
   (`0020-rpi-advertise-stateless-hevc`,
   `0021-hevc-10bit-external-sampler-sand-rec601`), which cost a full
   rebuild to rediscover. The build succeeds and HEVC simply is not
   advertised. Before building, confirm the only patch differences are
   ones you intended:

   ```bash
   git diff --stat origin/main..HEAD -- patches
   ```

   Also check for number collisions — a new patch reusing an existing
   number silently displaces the original in the quilt series.
2. **Iterate locally** until a full build produces a .deb and the
   binary plays HEVC correctly on a Pi. `cli.sh debs` STAGE 7 fails the
   build if the .deb does not contain the binary just compiled; do not
   bypass it, since that check exists because a stale binary shipped
   once.
3. **Vendor the new source files.** Download all files listed in the
   `.dsc`'s `Files:`/`Checksums-Sha256:` blocks (as of 152.x: orig,
   orig-pre-gen, debian — don't assume it's still exactly three; the
   set has changed once already) from
   `archive.raspberrypi.com/debian/pool/main/c/chromium/`, compute
   SHA256, and verify they match the `.dsc` file's
   `Checksums-Sha256:` block.
4. **Cut a new GitHub Release** named
   `upstream-source-<new-version>` on this repo and upload all
   vendored files as assets, with the SHA256s in the release notes.
5. **Update `build/cli.sh`**: bump
   `CHROMIUM_VERSION_FULL`, `CHROMIUM_VERSION_UPSTREAM`,
   `UPSTREAM_RELEASE_URL_DEFAULT`, and the SHA256 constants (add/remove
   constants if the `.dsc`'s component list changed).
6. **Update `build/Dockerfile`** with the current `debian:trixie`
   manifest digest if the base image has rolled (often unnecessary).
7. **Update this document** with the new pinned version.
8. **Tag a new patch release** (e.g. `v0.3.0`).

## Verifying the pin manually

```bash
# Inside the build container after STAGE 1, you should see:
#   ok: chromium_152.0.7977.75.orig.tar.xz (971e4581...)
#   ok: chromium_152.0.7977.75.orig-pre-gen.tar.xz (44ca7934...)
#   ok: chromium_152.0.7977.75-1~deb13u1+rpt1.debian.tar.xz (c02f90eb...)
#   ok: chromium_152.0.7977.75-1~deb13u1+rpt1.dsc (fd804112...)
sha256sum /build/src/chromium_*.{orig.tar.xz,orig-pre-gen.tar.xz,debian.tar.xz,dsc}
```

The same SHA256s also appear in the `Checksums-Sha256:` block of
the `.dsc` file — they are RPi-Distro's own checksums, which we
recorded but did not generate.

## Independent provenance check

The RPi-Distro `debian/` overlay (`*.debian.tar.xz`) is
content-equivalent to the matching tag in the
[RPi-Distro/chromium](https://github.com/RPi-Distro/chromium) repo,
named `pios/1%<upstream-version>-1_deb13u1+rpt1`. If our release is
ever lost, that tag is a permanent independent record of what we
patched against — extract the tag's `debian/` directory, repackage as
a `.tar.xz`, and the SHA256 should match. This was verified for the
147 pin (tag `pios/1%147.0.7727.116-1_deb13u1+rpt1`, commit
`c5a65d9`); the equivalent 152 tag has not been byte-verified.

The upstream chromium tarball (`*.orig.tar.xz`) is a repackage of
Google's upstream chromium release. Google's own snapshots are at
`https://commondatastorage.googleapis.com/chromium-browser-official/chromium-<version>.tar.xz`
or similar paths, but RPi sometimes runs `xz -e` re-compression which
changes the SHA256. Treat our release as the authoritative copy.
