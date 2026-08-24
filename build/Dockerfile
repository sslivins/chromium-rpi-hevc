# Build env for Raspberry Pi-flavored chromium 151 with custom HEVC patches.
# Target: arm64 / Debian trixie (matches Pi 5 / CM5 running Debian 13).
# Host:   any arm64 Linux (Docker Desktop on Windows-on-ARM works natively, no qemu).
#
# Usage (from repo root):
#   docker build -t chromium-rpi-build build/
#   docker run --rm -it -v ${PWD}/out:/out -v ${PWD}/patches:/patches \
#       -v ${PWD}/src:/build/src chromium-rpi-build full
#
# The image is a "build environment" — all heavy work happens in
# /usr/local/bin/chromium-rpi-hevc (the cli.sh uber-script). Subcommands
# include: full, fast, fetch, patch, configure, ninja, debs, doctor,
# status, shell, clean, help. Default CMD is `full`.

# Pinned to the multi-arch manifest digest of debian:trixie at 2026-05-03.
# This freezes the base userland so an image rebuild produces the same
# starting point regardless of when it runs.
FROM debian:trixie@sha256:35b8ff74ead4880f22090b617372daff0ccae742eb5674455d542bef71ef1999

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Belt-and-braces ccache wiring. cc_wrapper="ccache" in args.gn (set by
# cli.sh via debian/rules) is the primary mechanism; this PATH prepend
# is a backup so any tool that bypasses cc_wrapper still hits ccache.
# CCACHE_DIR lives under /out so the cache persists via the existing
# bind mount (-v ${PWD}/out:/out) without requiring a new mount point.
ENV PATH=/usr/lib/ccache:$PATH
ENV CCACHE_DIR=/out/.ccache
ENV CCACHE_MAXSIZE=100G
ENV CCACHE_COMPRESS=true
ENV CCACHE_COMPRESSLEVEL=6
ENV CCACHE_COMPILERCHECK=content
ENV CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,system_headers

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

# 3b. LLVM/Clang 22 toolchain. Chromium 151's debian/control hard-pins
#     llvm-22/clang-22/lld-22/clang-format-22/libclang-rt-22-dev, none of
#     which are in trixie main or the RPi archive yet — only available via
#     apt.llvm.org's nightly/branch builds. Needed before `build-dep` below
#     will resolve. If a future chromium bump moves off 22, update the
#     version number passed to llvm.sh accordingly.
RUN apt-get update && apt-get install -y --no-install-recommends gnupg && \
    curl -fsSL https://apt.llvm.org/llvm.sh -o /tmp/llvm.sh && \
    chmod +x /tmp/llvm.sh && /tmp/llvm.sh 22 && \
    rm -rf /var/lib/apt/lists/* /tmp/llvm.sh

# 4. chromium build-dep. This is enormous (~3GB of -dev headers).
RUN apt-get update && apt-get build-dep -y chromium \
    && rm -rf /var/lib/apt/lists/*

# 5. Workspace
RUN mkdir -p /build /out /patches
WORKDIR /build

# Copy in the uber CLI. cli.sh is the single source of truth; build.sh and
# build-fast.sh are kept as one-line exec wrappers for backward compatibility
# (will be removed in a follow-up cleanup PR after VM validation).
COPY cli.sh /usr/local/bin/chromium-rpi-hevc
COPY build.sh /build.sh
COPY build-fast.sh /build-fast.sh
RUN sed -i 's/\r$//' /usr/local/bin/chromium-rpi-hevc /build.sh /build-fast.sh \
    && chmod +x /usr/local/bin/chromium-rpi-hevc /build.sh /build-fast.sh

ENTRYPOINT ["/usr/local/bin/chromium-rpi-hevc"]
CMD ["full"]
