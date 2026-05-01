# Build env for Raspberry Pi-flavored chromium 147 with custom HEVC patches.
# Target: arm64 / Debian trixie (matches Pi 5 / CM5 running Debian 13).
# Host:   any arm64 Linux (Docker Desktop on Windows-on-ARM works natively, no qemu).
#
# Usage (from repo root, C:\Users\stesli\chromium-rpi-build):
#   docker build -t chromium-rpi-build .
#   docker run --rm -it -v ${PWD}/out:/out -v ${PWD}/patches:/patches chromium-rpi-build /build.sh
#
# The image is a "build environment" — all heavy work happens in /build.sh,
# which mounts patches/ in and drops .debs into out/.

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# 1. Add Raspberry Pi archive so we can `apt source` the rpt1 source package
#    and get the same patch series RPi-Distro publishes.
#    NOTE: trusted=yes — the RPi archive's signing key still uses SHA1 self-
#    certification, which trixie's sqv rejects. We're a build container only,
#    never published, so accepting unverified is acceptable here.
RUN printf 'Types: deb deb-src\nURIs: http://archive.raspberrypi.com/debian/\nSuites: trixie\nComponents: main\nTrusted: yes\n' \
         > /etc/apt/sources.list.d/raspi.sources

# 2. Enable deb-src for debian itself (trixie ships sources.list as deb-only by default in some images).
RUN sed -i -E 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
    && (grep -rE '^deb-src' /etc/apt/sources.list /etc/apt/sources.list.d/ || true)

# 3. Core build tooling. apt build-dep for chromium pulls in another ~1-2GB.
#    We split this from build-dep so the layer caches between iterations.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential dpkg-dev debhelper devscripts quilt \
        ccache git python3 python3-pip rsync xz-utils \
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
