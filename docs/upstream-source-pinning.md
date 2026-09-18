# Upstream source pinning

This repo's build is **fully pinned** to a single Chromium upstream
version: `1:153.0.8010.47-2~deb13u1+rpt1`. This security-update rebase
retains the complete HEVC patch series and adds a guard against Wayland
modifiers arriving before a usable XKB keymap.

The 153 build passed all seven `XkbLayoutEngineVkTest` tests, including
the three missing-keymap regressions, and the five 1080p HEVC fixture checks
on Pi 5:
8-bit, 10-bit, HDR-coded, and weighted-prediction 8-bit/10-bit. These hardware
checks ran against the installed Debian packages on Pi100 and verified both
hardware decoder use and captured pixels. This does **not** establish
interactive GeForce NOW gameplay, 4K decoding, or HDR display output. See
the binary release notes for packaged-artifact verification and release
status.

The keyboard fix is deliberately narrower than "no keyboard attached":
`wl_keyboard.enter` followed by `modifiers` can arrive without an initial
keymap when joining an existing Sway session. Patch `0023` returns
`EF_NONE` instead of dereferencing a null `xkb_state`; a later valid keymap
restores normal modifier processing. Its existing-fixture regression tests
cover missing and invalid keymaps, a late keymap, depressed/latched/locked
modifiers, and preservation of valid state after an invalid replacement.

This document explains how the pin works, why it exists, and how to
move it forward when the time comes.

## What is pinned

Four independently-drifting inputs feed our build. All four are
locked.

| Input | What it is | Where the pin lives |
|---|---|---|
| Chromium source (`*.orig.tar.xz`, ~920 MiB) | Google's chromium tarball as repackaged by RPi-Distro | This repo's GitHub Release `upstream-source-153.0.8010.47-2-deb13u1-rpt1`, with SHA256 in `build/cli.sh` |
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

When a new RPi `+rptN` chromium release is published and we want to
re-base our patches onto it:

1. **Rebase the patches.** On a build VM, fetch the new source via
   `apt-get source chromium=<new-version>`, copy the new `debian/`
   tree into our quilt environment, and try to apply each of our
   patches in order with quilt's zero-fuzz checks, not only
   `git apply --check`. Fix conflicts manually (patch hunk offsets
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
3. **Vendor and publish the new source files.** The helper reads the
   `.dsc` instead of assuming a fixed component list, downloads every
   declared source artifact, verifies RPi-Distro's SHA256s, prints the
   exact `build/cli.sh` constants, and publishes the pinned-source release:

   ```bash
   GH_TOKEN=... scripts/vendor-upstream-source.sh --publish \
     153.0.8010.47-2~deb13u1+rpt1
   ```
4. **Update `build/cli.sh`**: bump
   `CHROMIUM_VERSION_FULL`, `CHROMIUM_VERSION_UPSTREAM`,
   `UPSTREAM_RELEASE_URL_DEFAULT`, and the SHA256 constants (add/remove
   constants if the `.dsc`'s component list changed).
5. **Update `CHROMIUM_BUILD_DEPS_VERSION` in `build/Dockerfile`** so
   Docker refreshes the package's build dependencies. Update the
   `debian:trixie` manifest digest too if the base image has rolled.
6. **Update this document** with the new pinned version.
7. **Tag the validated build** using the release versioning scheme below.

## Release versioning

Build release tags identify both the exact RPi-Distro base and our local
patchset revision:

```text
chromium-<chromium-version>-<debian-revision>-rpt<revision>-hevc<revision>
```

For example, the first local build based on
`153.0.8010.47-2~deb13u1+rpt1` is:

```text
chromium-153.0.8010.47-2-rpt1-hevc1
```

Increment `hevcN` for a local-only patch or packaging rebuild. Reset it to
`hevc1` whenever the RPi-Distro base changes, including an `rpt` revision.
Pinned-source releases use the exact Debian base too, for example
`upstream-source-153.0.8010.47-2-deb13u1-rpt1`; this prevents a later
`rpt2` source release from overwriting the `rpt1` artifacts.

## Verifying the pin manually

### Reusing a previous build safely

Keep the old source/output tree intact. Extract the new pin into a separate
build root, apply the complete patch series there, then copy the old
`out/Release` and reuse the existing compiler cache and toolchain image.
Do not run `fetch` against the old build root: source discovery accepts an
already-extracted tree and is not a version check.

For source timestamp reuse, compare contents rather than dates: restore the
old mtime only for byte-identical files, and mark changed/new files newer than
the retained outputs. Upstream archive mtimes can predate the previous build.
For example, the `.82` network-isolation Mojom input was dated September 2
while the retained `.75` generated header was dated September 5. Keeping that
mtime incorrectly reused a header missing `kSharedWorkerSameSiteCookiesNone`.
Do not fix this by editing generated headers or dropping the compiler cache.

GN can still schedule tens of thousands of actions across a version change;
report the actual action count and ccache hit rate, not an assumed tiny
incremental rebuild. Validate the raw binary before running `debs`, and build
all packaging targets before shipping their outputs.

### Checksums

```bash
# Inside the build container after STAGE 1, you should see:
#   ok: chromium_153.0.8010.47.orig.tar.xz (d7b52d13...)
#   ok: chromium_153.0.8010.47.orig-pre-gen.tar.xz (bdfb320a...)
#   ok: chromium_153.0.8010.47-2~deb13u1+rpt1.debian.tar.xz (16bca097...)
#   ok: chromium_153.0.8010.47-2~deb13u1+rpt1.dsc (889f8b8c...)
sha256sum /build/src/chromium_*.{orig.tar.xz,orig-pre-gen.tar.xz,debian.tar.xz,dsc}
```

The three archive SHA256s also appear in the `Checksums-Sha256:` block
of the `.dsc` file — they are RPi-Distro's own checksums, which we
recorded but did not generate. The `.dsc` itself is hashed separately.

## Independent provenance check

The RPi-Distro `debian/` overlay (`*.debian.tar.xz`) is
content-equivalent to the matching tag in the
[RPi-Distro/chromium](https://github.com/RPi-Distro/chromium) repo,
named `pios/1%<upstream-version>-1_deb13u1+rptN`. If our release is
ever lost, that tag is an independent record of what we
patched against. Compare the extracted `debian/` content; recreating a
tarball need not reproduce its original byte-level SHA256. This was verified for the
147 pin (tag `pios/1%147.0.7727.116-1_deb13u1+rpt1`, commit
`c5a65d9`); the equivalent 152 tag has not been byte-verified.

The upstream chromium tarball (`*.orig.tar.xz`) is a repackage of
Google's upstream chromium release. Google's own snapshots are at
`https://commondatastorage.googleapis.com/chromium-browser-official/chromium-<version>.tar.xz`
or similar paths, but RPi sometimes runs `xz -e` re-compression which
changes the SHA256. Treat our release as the authoritative copy.
