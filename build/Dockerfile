# Build env for Raspberry Pi-flavored chromium 147 with custom HEVC patches.
# Target: arm64 / Debian trixie (matches Pi 5 / CM5 running Debian 13).
# Host:   any arm64 Linux (Docker Desktop on Windows-on-ARM works natively, no qemu).
#
# Usage (build context = repo root, NOT the build/ subdir, so we can COPY vendor/):
#
#   git submodule update --init --recursive
#   docker build -f build/Dockerfile -t chromium-rpi-build:trixie .
#   docker run --rm -it \
#       -v ${PWD}/out:/out \
#       -v ${PWD}/patches:/patches \
#       chromium-rpi-build:trixie /build.sh
#
# The image bakes in the pinned RPi-Distro packaging (vendor/rpi-distro-chromium)
# and the upstream-fetch script. The chromium source tarball (~5.7 GB) is NOT
# baked in — it's downloaded into /build/upstream on first run, and that path
# can be a docker volume to persist across runs.
#
# Heavy work happens in /build.sh (or /build-incremental.sh / /build-fast.sh).
# Patches are mounted in at runtime so a patch tweak doesn't require rebuilding
# the image.

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# 1. Add Raspberry Pi archive — kept as a fallback for any Pi-specific
#    build-deps that RPi-Distro's debian/control may declare. We do NOT rely
#    on the raspi archive to carry the chromium source package itself any
#    more (Phase 4: see build/fetch-upstream.sh and the vendored RPi-Distro
#    submodule for the pinned source recipe).
#
#    NOTE: trusted=yes — the RPi archive's signing key still uses SHA1 self-
#    certification, which trixie's sqv rejects. We're a build container only,
#    never published, so accepting unverified is acceptable here.
RUN printf 'Types: deb\nURIs: http://archive.raspberrypi.com/debian/\nSuites: trixie\nComponents: main\nTrusted: yes\n' \
         > /etc/apt/sources.list.d/raspi.sources

# 2. Core build tooling. Split from build-dep installation so iteration on
#    debian/control doesn't bust the apt cache for the whole base toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential dpkg-dev debhelper devscripts equivs quilt \
        ccache git python3 python3-pip rsync wget xz-utils \
        sudo less vim file lsb-release \
    && rm -rf /var/lib/apt/lists/*

# 3. Bake in the pinned RPi-Distro chromium packaging.
#    Build context must be the REPO ROOT (not build/) for this COPY to see
#    the vendored submodule.
COPY vendor/rpi-distro-chromium /build-tools/rpi-distro-chromium

# 4. Install chromium build-deps from the vendored debian/control. We use
#    mk-build-deps (devscripts) instead of `apt-get build-dep -y chromium`
#    because build-dep requires the chromium SOURCE package to be in the
#    archive, and raspi archive only retains the *current* version. With
#    mk-build-deps we provide our own pinned debian/control directly.
RUN apt-get update \
    && cd /build-tools/rpi-distro-chromium \
    && mk-build-deps --install --remove --tool='apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends' debian/control \
    && rm -rf /var/lib/apt/lists/*

# 5. Bake in build scripts + upstream fetcher.
COPY build/fetch-upstream.sh    /build-tools/fetch-upstream.sh
COPY build/build.sh             /build.sh
COPY build/build-incremental.sh /build-incremental.sh
COPY build/build-fast.sh        /build-fast.sh
RUN sed -i 's/\r$//' /build-tools/fetch-upstream.sh /build.sh /build-incremental.sh /build-fast.sh \
    && chmod +x /build-tools/fetch-upstream.sh /build.sh /build-incremental.sh /build-fast.sh

# 6. Workspace
RUN mkdir -p /build/src /build/upstream /build/.ccache /out /patches
WORKDIR /build

CMD ["/build.sh"]
