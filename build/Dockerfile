# Build env for Raspberry Pi-flavored chromium 147 with custom HEVC patches.
# Target: arm64 / Debian trixie (matches Pi 5 / CM5 running Debian 13).
# Host:   any arm64 Linux (Docker Desktop on Windows-on-ARM works natively, no qemu).
#
# Usage (from repo root):
#   docker build -t chromium-rpi-build build/
#   docker run --rm -it -v ${PWD}/out:/out -v ${PWD}/patches:/patches chromium-rpi-build /build.sh
#
# The image is a "build environment" — all heavy work happens in /build.sh,
# which downloads the pinned chromium source and builds the .debs.

# Pinned to the multi-arch manifest digest of debian:trixie at 2026-05-03.
# This freezes the base userland so an image rebuild produces the same
# starting point regardless of when it runs.
FROM debian:trixie@sha256:35b8ff74ead4880f22090b617372daff0ccae742eb5674455d542bef71ef1999

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# 1. Add Raspberry Pi archive so we can `apt-get build-dep chromium` and pull
#    in the same -dev headers RPi-Distro uses. deb-src is required so apt can
#    read chromium's Build-Depends from RPi's source index. We do NOT use
#    `apt-get source` for the actual source — that is pinned and SHA256-
#    verified in build.sh.
#    NOTE: trusted=yes — the RPi archive's signing key still uses SHA1 self-
#    certification, which trixie's sqv rejects. We're a build container only,
#    never published, so accepting unverified is acceptable here.
RUN printf 'Types: deb deb-src\nURIs: http://archive.raspberrypi.com/debian/\nSuites: trixie\nComponents: main\nTrusted: yes\n' \
         > /etc/apt/sources.list.d/raspi.sources

# 3. Core build tooling. apt build-dep for chromium pulls in another ~1-2GB.
#    We split this from build-dep so the layer caches between iterations.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential dpkg-dev debhelper devscripts quilt \
        ccache git python3 python3-pip rsync xz-utils curl ca-certificates \
        sudo less vim file lsb-release \
    && rm -rf /var/lib/apt/lists/*

# 4. chromium build-dep. This is enormous (~3GB of -dev headers).
RUN apt-get update && apt-get build-dep -y chromium \
    && rm -rf /var/lib/apt/lists/*

# 5. Workspace
RUN mkdir -p /build /out /patches
WORKDIR /build

# Copy in the build script.
COPY build.sh /build.sh
RUN sed -i 's/\r$//' /build.sh && chmod +x /build.sh

CMD ["/build.sh"]
