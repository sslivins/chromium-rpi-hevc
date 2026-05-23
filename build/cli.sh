#!/bin/bash
# chromium-rpi-hevc — uber CLI for the chromium build container.
#
# Single source of truth replacing the divergent build.sh / build-fast.sh /
# Dockerfile-CMD trio. See docs/incremental-build-fragility-plan.md and
# session files/uber-build-script-draft.md for the design.
#
# Subcommands:
#   fetch      Download + verify + extract pinned chromium source.
#   patch      Apply local /patches/*.patch + en-US.pak fix to debian/rules.
#   configure  Run gn gen out/Release with defines extracted from debian/rules.
#   ninja      Direct ninja build of out/Release/chrome (fast iteration, no .deb).
#   debs       Full dpkg-buildpackage producing .debs in /out, then re-applies patches.
#
# !!! WARNING !!! Running `debs` (or `full`) WILL BREAK INCREMENTAL BUILDS.
#   dpkg-buildpackage runs `dpkg-source --after-build` at the end, which
#   unapplies patches. The cli.sh EXIT trap re-applies them, but the
#   round-trip changes file mtimes / contents and busts ccache so the
#   NEXT `ninja` does a cold rebuild of tens of thousands of objects
#   instead of using the warm out/Release tree.
#   DO NOT run `debs` until the chromium change actually works under
#   `ninja` + raw-binary scp to the Pi. Only package once validated.
#   The function refuses to run unless CHROMIUM_DEBS_CONFIRM=1 is set.
#
#   full       fetch + patch + debs (matches old build.sh).
#   fast       patch + configure + ninja (matches old build-fast.sh).
#   doctor     Preflight checks; exits nonzero if container is unhealthy.
#   status     Print current state of source tree, stamps, ccache.
#   logs       List recent cli.sh log files (in /out/.cli-logs/).
#   tail       tail -F /out/.cli-logs/latest.log.
#   shell      Drop into a bash shell inside the container.
#   clean      Remove /build/src/chromium-* and /out/* (NOT ccache).
#   help       Show this help.
#
# Global flags (must precede subcommand):
#   --jobs N         Parallel jobs (default: nproc).
#   --no-ccache      Disable ccache wrapper for this run (debug only).
#   --ccache-dir D   Override CCACHE_DIR (default: /out/.ccache).
#   -v, --verbose    Verbose shell tracing.
#   -h, --help       Show this help.
#
# Design notes (from bench-test results, files/tier2-bench-results.md):
#   - Patch reapply only touches 486 files in 1.1s; ninja stays warm across
#     reapply. So we don't need a fancy stable-source-path or multi-stamp
#     fingerprint scheme — single sha256 stamp of /patches/*.patch + the
#     existing en-US.pak/cc_wrapper rules-tail is sufficient.
#   - dpkg-source --after-build runs unconditionally at end of dpkg-buildpackage
#     (line 785 of /usr/bin/dpkg-buildpackage). We MUST re-apply patches after
#     `debs`, so `_cmd_debs` installs an EXIT trap that always re-applies.
#   - dpkg-buildpackage is invoked with `-nc` so the pre-build clean does NOT
#     wipe out/Release. This is essential for warm/incremental deb builds.
#   - args.gn mtime stability inside the dpkg-buildpackage path is deferred to
#     Tier 3 (it requires patching upstream debian/rules' override_dh_auto_-
#     configure-arch to write args.gn via cmp-then-mv). Bench testing showed
#     ninja stays warm even after patch reapply, so this is theoretical.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SRC_DIR=/build/src
readonly OUT_DIR=/out
readonly PATCHES_DIR=/patches
readonly STAMP_PATCH_FP="$SRC_DIR/.local-hevc-patch-fp"
readonly STAMP_RULES_TAIL="$SRC_DIR/.local-hevc-rules-tail-applied"

readonly CHROMIUM_VERSION_FULL="147.0.7727.116-1~deb13u1+rpt1"
readonly CHROMIUM_VERSION_UPSTREAM="147.0.7727.116"
readonly UPSTREAM_RELEASE_URL_DEFAULT="https://github.com/sslivins/chromium-rpi-hevc/releases/download/upstream-source-147.0.7727.116"
readonly SHA256_ORIG="b808992f5a680372b8276466645183315326d8d0e66f080266883a07f36551c8"
readonly SHA256_DEBIAN="a884500201313734ea3b185473b867df48c97dedb3915fcbd9b6e0ce411fd318"
readonly SHA256_DSC="b0ac0f716b8bb04bac2a4c0d793146b456f39bbd3a4dbb1dd5d337704012ea54"

# These are deliberately marker text; we both append them to debian/rules and
# grep for them to detect whether the rules-tail has been applied.
readonly MARKER_EN_US='# chromium-rpi-hevc: drop duplicate en-US.pak from chromium-l10n staging'
readonly MARKER_CCACHE='# chromium-rpi-hevc: enable ccache as cc_wrapper (Tier 1)'
readonly MARKER_CONFIGURE_TARGET='# chromium-rpi-hevc: split-out configure target so cli.sh fast can work cold (#29)'

# ---------------------------------------------------------------------------
# Globals (set by main argv parsing; not user env vars)
# ---------------------------------------------------------------------------
JOBS=""
NO_CCACHE=0
CCACHE_DIR_OVERRIDE=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_log()  { printf '%s %s\n' "[$(date -u +%H:%M:%S)]" "$*"; }
_step() { printf '\n=== %s ===\n' "$*"; }
_die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Common setup — env vars used by both `fast` (direct ninja) and `debs`
# (dpkg-buildpackage) paths. These match upstream debian/rules expectations.
# ---------------------------------------------------------------------------
_setup_env() {
    export CC=clang-19
    export CXX=clang++-19
    export AR=ar
    export NM=nm
    export BUILD_CC=clang-19
    export BUILD_CXX=clang++-19
    export BUILD_AR=ar
    export BUILD_NM=nm
    export CXXFLAGS="-stdlib=libc++"
    export LDFLAGS="-stdlib=libc++ -static-libstdc++"
    export BUILD_CXXFLAGS="-stdlib=libc++"
    export BUILD_LDFLAGS="-stdlib=libc++ -static-libstdc++"
    export DEBIAN_FRONTEND=noninteractive

    if [ -z "$JOBS" ]; then
        JOBS="$(nproc)"
    fi
}

_setup_ccache() {
    if [ "$NO_CCACHE" = "1" ]; then
        _log "ccache: DISABLED (--no-ccache)"
        # Strip /usr/lib/ccache from PATH so cc/cc++ symlinks don't sneak in.
        PATH="$(echo "$PATH" | tr ':' '\n' | grep -vFx '/usr/lib/ccache' | paste -sd: -)"
        export PATH
        return 0
    fi
    local cdir="${CCACHE_DIR_OVERRIDE:-${CCACHE_DIR:-/out/.ccache}}"
    export CCACHE_DIR="$cdir"
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-100G}"
    export CCACHE_COMPRESS=true
    export CCACHE_COMPRESSLEVEL=6
    export CCACHE_COMPILERCHECK=content
    export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,system_headers
    mkdir -p "$CCACHE_DIR"
    ccache -o cache_dir="$CCACHE_DIR" \
           -o max_size="$CCACHE_MAXSIZE" \
           -o compression=true \
           -o compression_level=6 \
           -o compiler_check=content \
           -o sloppiness=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,system_headers \
           >/dev/null
    case ":$PATH:" in
        *:/usr/lib/ccache:*) : ;;
        *) export PATH="/usr/lib/ccache:$PATH" ;;
    esac
}

# ---------------------------------------------------------------------------
# Source-tree discovery — single chromium-* dir under /build/src.
# ---------------------------------------------------------------------------
_find_src_tree() {
    mkdir -p "$SRC_DIR"
    local trees=()
    while IFS= read -r d; do trees+=("$d"); done < <(find "$SRC_DIR" -maxdepth 1 -type d -name 'chromium-*' | sort)
    if [ "${#trees[@]}" -eq 0 ]; then
        return 1
    fi
    if [ "${#trees[@]}" -gt 1 ]; then
        _die "multiple chromium-* trees in $SRC_DIR; clean first"
    fi
    printf '%s\n' "${trees[0]}"
}

_require_src_tree() {
    local t
    if ! t=$(_find_src_tree); then
        _die "no chromium-* source tree in $SRC_DIR; run 'fetch' first"
    fi
    printf '%s\n' "$t"
}

# ---------------------------------------------------------------------------
# Patch-fingerprint helpers
# ---------------------------------------------------------------------------
_compute_patch_fp() {
    # Single sha256 over local patches: includes filename and content hash so
    # rename/delete/reorder is detected (duck #13).
    if ls "$PATCHES_DIR"/*.patch >/dev/null 2>&1; then
        (
            cd "$PATCHES_DIR"
            LC_ALL=C
            for p in *.patch; do
                printf 'FILE %s\n' "$p"
                sha256sum "$p"
            done
        ) | sha256sum | awk '{print $1}'
    else
        printf '%s\n' "no-local-patches"
    fi
}

# ---------------------------------------------------------------------------
# fetch — download + verify + extract pinned upstream source.
# ---------------------------------------------------------------------------
_cmd_fetch() {
    _setup_env
    mkdir -p "$SRC_DIR"
    cd "$SRC_DIR"

    local upstream_url="${UPSTREAM_RELEASE_URL:-$UPSTREAM_RELEASE_URL_DEFAULT}"
    local orig="chromium_${CHROMIUM_VERSION_UPSTREAM}.orig.tar.xz"
    local debian="chromium_${CHROMIUM_VERSION_FULL}.debian.tar.xz"
    local dsc="chromium_${CHROMIUM_VERSION_FULL}.dsc"
    # GitHub Releases mangle ~ to . in asset filenames.
    local orig_url="$orig"
    local debian_url="${debian//\~/.}"
    local dsc_url="${dsc//\~/.}"

    _step "STAGE 0: refresh apt lists"
    apt-get update

    _step "STAGE 1: fetch pinned chromium source"
    _log "Version: $CHROMIUM_VERSION_FULL"
    _log "Release: $upstream_url"

    _verify_sha256() {
        local file="$1" expected="$2" actual
        actual=$(sha256sum "$file" | awk '{print $1}')
        [ "$actual" = "$expected" ] || { _log "ERROR: SHA256 mismatch for $file"; _log "  expected: $expected"; _log "  actual:   $actual"; return 1; }
        _log "  ok: $file ($expected)"
    }
    _fetch_one() {
        local local_name="$1" url_name="$2" expected="$3"
        if [ -f "$local_name" ] && _verify_sha256 "$local_name" "$expected" >/dev/null 2>&1; then
            _log "  cached: $local_name"
            return 0
        fi
        _log "  fetching: $local_name (URL: $url_name)"
        rm -f "$local_name"
        curl -fL --retry 3 --retry-delay 5 -o "$local_name" "${upstream_url}/${url_name}"
        _verify_sha256 "$local_name" "$expected"
    }
    _fetch_one "$orig"   "$orig_url"   "$SHA256_ORIG"
    _fetch_one "$debian" "$debian_url" "$SHA256_DEBIAN"
    _fetch_one "$dsc"    "$dsc_url"    "$SHA256_DSC"

    if t=$(_find_src_tree 2>/dev/null); then
        _log "Source tree already extracted: $t"
        return 0
    fi

    _step "STAGE 1b: extract source via dpkg-source"
    # A fresh extraction means our patches and rules-tail are NOT yet applied
    # to the new tree, even though dpkg-source -x will create .pc/applied-
    # patches for upstream debian/distro patches. Invalidate any surviving
    # stamps so the next `cli.sh patch` does not false-noop (issue #28).
    rm -f "$STAMP_PATCH_FP" "$STAMP_RULES_TAIL"
    dpkg-source -x "$dsc"
    local t
    t=$(_find_src_tree) || _die "no chromium-* tree after dpkg-source -x"
    _log "Source tree: $t"
}

# ---------------------------------------------------------------------------
# patch — append en-US.pak + cc_wrapper rules-tail (idempotent), apply
# /patches/*.patch via debian/patches/series + dpkg-source --before-build.
#
# State machine:
#   - tree pristine (no .pc/applied-patches)         -> apply
#   - tree patched + fp matches                       -> noop
#   - tree patched + fp mismatch                      -> unapply, apply
# ---------------------------------------------------------------------------
_apply_rules_tail() {
    # en-US.pak fix and ccache wiring. Two append blocks, idempotent via marker.
    if grep -qF "$MARKER_EN_US" debian/rules; then
        :
    elif grep -q '^override_dh_install-indep:' debian/rules; then
        _die "upstream debian/rules has override_dh_install-indep without our marker — manual merge needed"
    else
        cat >> debian/rules <<EOF

$MARKER_EN_US
override_dh_install-indep:
	dh_install
	rm -f debian/chromium-l10n/usr/lib/chromium/locales/en-US.pak
EOF
        _log "  appended override_dh_install-indep (en-US.pak fix) to debian/rules"
    fi
    if grep -qF "$MARKER_CCACHE" debian/rules; then
        :
    else
        cat >> debian/rules <<EOF

$MARKER_CCACHE
defines+=cc_wrapper=\\"ccache\\"
EOF
        _log "  appended cc_wrapper=\"ccache\" to defines in debian/rules"
    fi
    # Custom configure-only target so cli.sh fast can write args.gn without
    # invoking the full build-arch pipeline (issue #29). The target is named
    # cli-* (not override_dh_*) so dpkg-buildpackage / dh do NOT call it; only
    # explicit `make -f debian/rules cli-chromium-rpi-hevc-configure` does.
    if grep -qF "$MARKER_CONFIGURE_TARGET" debian/rules; then
        :
    else
        # Use unquoted heredoc so $MARKER_CONFIGURE_TARGET expands; escape
        # $(defines)/$(threads) so they remain literal make variable refs.
        # The recipe line MUST start with a real TAB (make requires it).
        printf '\n%s\n' "$MARKER_CONFIGURE_TARGET" >> debian/rules
        printf 'cli-chromium-rpi-hevc-configure: override_dh_auto_configure\n' >> debian/rules
        printf '\tgn gen out/Release --args="$(defines)" --threads="$(threads)"\n' >> debian/rules
        _log "  appended cli-chromium-rpi-hevc-configure target to debian/rules"
    fi
}

_apply_patches() {
    local src
    src=$(_require_src_tree)
    cd "$src"

    local tree_state="pristine"
    if [ -f .pc/applied-patches ] && [ -s .pc/applied-patches ]; then
        tree_state="patched"
    fi
    local fp_new fp_old=""
    fp_new=$(_compute_patch_fp)
    [ -f "$STAMP_PATCH_FP" ] && fp_old=$(cat "$STAMP_PATCH_FP")
    _log "patch state: tree=$tree_state fp_old=${fp_old:-none} fp_new=$fp_new"

    if [ "$tree_state" = "patched" ] && [ "$fp_new" = "$fp_old" ] && [ -f "$STAMP_RULES_TAIL" ] \
       && grep -qF "$MARKER_CCACHE" debian/rules \
       && grep -qF "$MARKER_EN_US" debian/rules \
       && grep -qF "$MARKER_CONFIGURE_TARGET" debian/rules; then
        _log "patch: tree patched, fp matches, rules-tail markers present — noop"
        return 0
    fi

    # Snapshot mtime+sha for every file that any patch in the OLD series OR
    # the NEW local set will touch. After the dpkg-source unapply/re-apply
    # round-trip, restore mtimes for sha-unchanged files. See PR #50: without
    # this, `quilt pop+push` of an unchanged patch series bumps mtime on every
    # touched file even though sha is identical, which makes `args.gni` /
    # `.gn` look newer than `build.ninja.stamp`, forcing `gn gen` to re-run
    # which rewrites build.ninja with subtly different per-target command
    # lines (rust crates, protobuf, ...). Ninja then sees ~7,480
    # CMDLINE_CHANGED + ~19,236 INPUT_NEWER reasons and plans ~50,551 actions
    # for an "incremental" rebuild. Preserving mtimes keeps args.gni older
    # than build.ninja.stamp, so gn-gen doesn't re-fire and the cascade is
    # avoided.
    _MTIME_PRESERVE_SNAPSHOT=""
    _mtime_preserve_snapshot

    if [ "$tree_state" = "patched" ]; then
        _log "patch: unapplying current patches before reapply"
        dpkg-source --after-build . 2>/dev/null || quilt pop -af 2>/dev/null || true
    fi

    # Strip prior local block from series + remove staged files.
    local marker_begin="# === BEGIN LOCAL HEVC PATCHES ==="
    local marker_end="# === END LOCAL HEVC PATCHES ==="
    local local_subdir="local-hevc"
    if grep -qFx "$marker_begin" debian/patches/series 2>/dev/null; then
        sed -i "/^${marker_begin}$/,/^${marker_end}$/d" debian/patches/series
    fi
    rm -rf "debian/patches/$local_subdir"

    # Apply en-US.pak + ccache rules-tail (idempotent).
    _apply_rules_tail
    : > "$STAMP_RULES_TAIL"

    # Append local patches into series.
    shopt -s nullglob
    local extras=("$PATCHES_DIR"/*.patch)
    if [ ${#extras[@]} -gt 0 ]; then
        mkdir -p "debian/patches/$local_subdir"
        printf '%s\n' "$marker_begin" >> debian/patches/series
        for p in "${extras[@]}"; do
            local name; name=$(basename "$p")
            cp "$p" "debian/patches/$local_subdir/$name"
            printf '%s\n' "$local_subdir/$name" >> debian/patches/series
            _log "  added $local_subdir/$name to series"
        done
        printf '%s\n' "$marker_end" >> debian/patches/series
    else
        _log "  no patches in $PATCHES_DIR; building stock RPi-Distro source"
    fi

    _log "patch: applying via dpkg-source --before-build"
    dpkg-source --before-build . || _die "patch application failed"

    # Restore mtimes for any file whose post-push sha matches pre-pop sha.
    # Files with genuinely-changed content (sha differs) are left alone so
    # ninja correctly sees them as dirty.
    _mtime_preserve_restore "$_MTIME_PRESERVE_SNAPSHOT"
    unset _MTIME_PRESERVE_SNAPSHOT

    # Issue #42: keep patches applied across dpkg-buildpackage so iterative
    # fast builds get ccache hits. By default dpkg-source --after-build
    # unapplies patches (via quilt pop -af), which our exit trap then has
    # to reapply, and which the next 'fast' run's _cmd_patch reapplies
    # again. Each unapply/reapply cycle perturbs source file mtimes and
    # leaves the tree in a state that isn't byte-identical to the previous
    # build's, causing ccache to miss on every translation unit (observed:
    # 0.77% hit rate after a full build had populated the cache).
    #
    # debian/source/local-options with `unapply-patches = no` tells
    # dpkg-source to skip the --after-build unapply, so the tree stays
    # patched across runs. The exit-trap _apply_patches and next-run
    # _cmd_patch then short-circuit on the fp-match path.
    mkdir -p debian/source
    if ! grep -qF 'unapply-patches = no' debian/source/local-options 2>/dev/null; then
        printf '%s\n' 'unapply-patches = no' 'abort-on-upstream-changes' \
            > debian/source/local-options
        _log "  wrote debian/source/local-options (unapply-patches = no) — see issue #42"
    fi

    printf '%s\n' "$fp_new" > "$STAMP_PATCH_FP"
    _log "patch: applied; stamp updated"
}

# Snapshot mtime+sha for every file that any patch in the current series OR
# the local /patches/*.patch set is going to touch. Writes the snapshot
# tempfile path into the global $_MTIME_PRESERVE_SNAPSHOT (avoids capturing
# _log noise that command substitution would otherwise pull in).
#
# Caller must already be cd'd to the chromium source tree.
_mtime_preserve_snapshot() {
    local out; out=$(mktemp /tmp/quilt-mtime-XXXXXX.tsv)
    local files; files=$(mktemp /tmp/quilt-mtime-files-XXXXXX)

    # Existing series patches.
    if [ -f debian/patches/series ]; then
        while IFS= read -r p; do
            [[ "$p" =~ ^[[:space:]]*# ]] && continue
            [ -z "${p// }" ] && continue
            local pf="debian/patches/$p"
            [ -f "$pf" ] || continue
            lsdiff --strip=1 "$pf" 2>/dev/null | grep -v '^/dev/null$' >> "$files" || true
        done < debian/patches/series
    fi
    # Local patches we're about to install on top.
    shopt -s nullglob
    for p in "$PATCHES_DIR"/*.patch; do
        lsdiff --strip=1 "$p" 2>/dev/null | grep -v '^/dev/null$' >> "$files" || true
    done
    shopt -u nullglob
    sort -u "$files" -o "$files"

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        local m s
        m=$(stat -c '%.Y' "$f" 2>/dev/null) || continue
        s=$(sha256sum "$f" 2>/dev/null | cut -c1-64) || continue
        printf '%s\t%s\t%s\n' "$f" "$m" "$s" >> "$out"
    done < "$files"
    rm -f "$files"

    _MTIME_PRESERVE_SNAPSHOT="$out"
    _log "  mtime-preserve: snapshot $(wc -l <"$out" | awk '{print $1}') files → $out"
}

# Restore mtimes for files whose sha did NOT change across the quilt round-trip.
# Files with sha changes (genuine patch edits) are left alone.
_mtime_preserve_restore() {
    local snap="${1:-}"
    [ -z "$snap" ] && { _log "  mtime-preserve: no snapshot path, skipping"; return 0; }
    [ -f "$snap" ] || { _log "  mtime-preserve: snapshot file missing: $snap"; return 0; }

    local restored=0 sha_changed=0 missing=0
    while IFS=$'\t' read -r f m0 s0; do
        if [ ! -f "$f" ]; then missing=$((missing+1)); continue; fi
        local s1; s1=$(sha256sum "$f" 2>/dev/null | cut -c1-64) || { sha_changed=$((sha_changed+1)); continue; }
        if [ "$s0" = "$s1" ]; then
            touch -d "@$m0" "$f" 2>/dev/null && restored=$((restored+1)) || sha_changed=$((sha_changed+1))
        else
            sha_changed=$((sha_changed+1))
        fi
    done < "$snap"
    _log "  mtime-preserve: restored=$restored sha_changed=$sha_changed missing=$missing"
    rm -f "$snap"
}

_cmd_patch() { _setup_env; _apply_patches; }

# ---------------------------------------------------------------------------
# configure — run upstream debian/rules' GN-args generation. Verifies args.gn
# was written and that cc_wrapper="ccache" is present (the Tier 1 invariant).
# Note: args.gn mtime stabilization across dpkg-buildpackage runs is deferred
# to Tier 3 — it requires patching upstream debian/rules and bench has not
# confirmed it's a real warm-build regression yet.
# ---------------------------------------------------------------------------
_cmd_configure() {
    _setup_env
    _setup_ccache
    # Make sure rules-tail (including our cli-chromium-rpi-hevc-configure
    # target) is in debian/rules; harmless noop if already applied.
    _apply_patches
    local src; src=$(_require_src_tree)
    cd "$src"

    local args_gn=out/Release/args.gn

    _step "configure: make -f debian/rules cli-chromium-rpi-hevc-configure"
    grep -qF "$MARKER_CONFIGURE_TARGET" debian/rules \
        || _die "configure: $MARKER_CONFIGURE_TARGET not present in debian/rules (rules-tail not applied)"
    make -f debian/rules cli-chromium-rpi-hevc-configure

    [ -f "$args_gn" ] || _die "configure ran but $args_gn missing"

    if [ "$NO_CCACHE" != "1" ]; then
        if ! grep -q '^cc_wrapper *= *"ccache"' "$args_gn"; then
            _die "args.gn does NOT contain cc_wrapper=\"ccache\" — ccache wiring broken"
        fi
        _log "configure: args.gn OK (cc_wrapper=ccache present)"
    else
        _log "configure: --no-ccache set; not asserting cc_wrapper presence"
    fi
}

# ---------------------------------------------------------------------------
# Tripwire — watches a build for ccache-wiring failure. Returns 0 if ccache
# wiring is confirmed working OR if build finishes before the threshold.
# Returns 1 if it killed the build for a wiring failure.
# Args: $1 = build_pid, $2 = build_log path, $3 = tripwire_log path,
#       $4 = src tree absolute path (for args.gn check).
# ---------------------------------------------------------------------------
_get_ccache_calls() {
    local n
    n=$(ccache --print-stats 2>/dev/null | awk '$1=="called"{print $2; exit}')
    if [ -n "$n" ]; then
        echo "$n"
        return
    fi
    # Fallback parser for `ccache -s` text output (older ccache without
    # --print-stats). Field $2 looks like " 123 / 456 (26.97%)" — extract
    # the FIRST integer only (duck #11: previous gsub mangled this).
    ccache -s 2>/dev/null | awk -F: '
        /[Cc]acheable calls|[Cc]ache hits|[Cc]ache misses/ {
            v=$2
            sub(/^[^0-9]*/,"",v)
            sub(/[^0-9].*$/,"",v)
            s += v+0
        }
        END {print s+0}'
}

_run_tripwire() {
    local build_pid="$1" build_log="$2" trip_log="$3" src_abs="$4"
    local start args_checked=0
    start=$(date +%s)
    while kill -0 "$build_pid" 2>/dev/null; do
        sleep 30
        kill -0 "$build_pid" 2>/dev/null || break
        local elapsed=$(( $(date +%s) - start ))

        # (a) args.gn check — one-shot.
        if [ "$args_checked" = "0" ]; then
            local args_gn="$src_abs/out/Release/args.gn"
            if [ -f "$args_gn" ]; then
                args_checked=1
                {
                    printf '=== args.gn check at T+%ss ===\n' "$elapsed"
                    cat "$args_gn"
                } >> "$trip_log"
                if ! grep -q '^cc_wrapper *= *"ccache"' "$args_gn"; then
                    {
                        printf '\n######################################################################\n'
                        printf 'FATAL: args.gn does NOT contain cc_wrapper="ccache" (T+%ss).\n' "$elapsed"
                        printf '       Killing build to save VM time. See %s.\n' "$trip_log"
                        printf '######################################################################\n'
                    } >&2
                    kill -TERM -- "-$build_pid" 2>/dev/null || kill -TERM "$build_pid" 2>/dev/null || true
                    sleep 5
                    kill -KILL -- "-$build_pid" 2>/dev/null || kill -KILL "$build_pid" 2>/dev/null || true
                    exit 0
                fi
                _log "tripwire (a): args.gn OK at T+${elapsed}s"
            fi
        fi

        # (b) compile-stats check.
        local cxx
        cxx=$(grep -cE '^\[[0-9]+/[0-9]+\] (CXX|CC|RUST_CC|RUST_BIN) ' "$build_log" 2>/dev/null || true)
        cxx=${cxx:-0}
        if [ "$cxx" -ge 100 ]; then
            local calls
            calls=$(_get_ccache_calls)
            calls=${calls:-0}
            {
                printf '=== ccache stats check at T+%ss (cxx_actions=%s) ===\n' "$elapsed" "$cxx"
                ccache --print-stats 2>&1 || ccache -s 2>&1
            } >> "$trip_log"
            if [ "$calls" -eq 0 ]; then
                {
                    printf '\n######################################################################\n'
                    printf 'FATAL: ccache TRIPWIRE — 0 calls after %s CXX actions (T+%ss).\n' "$cxx" "$elapsed"
                    printf '       Killing build to save VM time. See %s.\n' "$trip_log"
                    printf '######################################################################\n'
                } >&2
                kill -TERM -- "-$build_pid" 2>/dev/null || kill -TERM "$build_pid" 2>/dev/null || true
                sleep 5
                kill -KILL -- "-$build_pid" 2>/dev/null || kill -KILL "$build_pid" 2>/dev/null || true
                exit 0
            fi
            _log "tripwire (b): $calls calls observed at $cxx CXX actions — OK. Disarming."
            exit 0
        fi

        # Heartbeat every 5 min.
        if [ $((elapsed % 300)) -lt 30 ] && [ "$elapsed" -ge 300 ]; then
            local now; now=$(_get_ccache_calls)
            _log "tripwire heartbeat T+${elapsed}s: cxx=$cxx ccache_called=${now:-?} args_checked=$args_checked"
        fi
    done
}

# ---------------------------------------------------------------------------
# ninja — direct ninja build of out/Release/chrome with tripwire watching.
# Runs after configure (or skips if out/Release/build.ninja already exists).
# A trap kills the build process group + tail + tripwire on EXIT/INT/TERM
# so we don't leak compiles after Ctrl-C or container-stop (duck #6).
# ---------------------------------------------------------------------------
_cmd_ninja() {
    _setup_env
    _setup_ccache
    local src; src=$(_require_src_tree)
    cd "$src"

    [ -f out/Release/args.gn ] || _die "no out/Release/args.gn — run configure first"

    mkdir -p "$OUT_DIR"
    local build_log="$OUT_DIR/ninja.log" trip_log="$OUT_DIR/ccache-tripwire.log"
    : > "$build_log"
    : > "$trip_log"

    if [ "$NO_CCACHE" != "1" ]; then ccache --zero-stats >/dev/null; fi
    _step "ninja: out/Release chrome (-j$JOBS)"
    local start; start=$(date +%s)

    local build_pid="" tail_pid="" trip_pid=""
    _ninja_cleanup() {
        local rc=$?
        trap - EXIT INT TERM
        [ -n "$trip_pid" ] && kill "$trip_pid" 2>/dev/null || true
        [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
        if [ -n "$build_pid" ] && kill -0 "$build_pid" 2>/dev/null; then
            _log "trap: terminating ninja process group $build_pid"
            kill -TERM -- "-$build_pid" 2>/dev/null || kill -TERM "$build_pid" 2>/dev/null || true
            sleep 3
            kill -KILL -- "-$build_pid" 2>/dev/null || kill -KILL "$build_pid" 2>/dev/null || true
        fi
        return $rc
    }
    trap _ninja_cleanup EXIT INT TERM

    set -m
    ninja -C out/Release -j"$JOBS" chrome > "$build_log" 2>&1 &
    build_pid=$!
    set +m
    tail -F -n 0 "$build_log" --pid="$build_pid" &
    tail_pid=$!

    if [ "$NO_CCACHE" != "1" ]; then
        _run_tripwire "$build_pid" "$build_log" "$trip_log" "$(pwd)" &
        trip_pid=$!
    fi

    set +e
    wait "$build_pid"
    local rc=$?
    set -e
    [ -n "$trip_pid" ] && kill "$trip_pid" 2>/dev/null || true
    kill "$tail_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    trap - EXIT INT TERM

    _step "ccache stats (post-ninja)"
    ccache -s --verbose 2>/dev/null | head -30 || ccache -s
    [ -s "$trip_log" ] && { _log "--- tripwire log ---"; cat "$trip_log"; }

    [ "$rc" -eq 0 ] || _die "ninja exited $rc"
    _log "ninja: $(($(date +%s) - start))s"

    if [ -f out/Release/chrome ]; then
        cp out/Release/chrome "$OUT_DIR/chromium"
        _log "Copied chromium binary to $OUT_DIR/chromium ($(stat -c %s "$OUT_DIR/chromium") bytes)"
    fi
}

# ---------------------------------------------------------------------------
# debs — full dpkg-buildpackage. Behavior:
#   - Self-contained: applies patches first (duck #2). Standalone `debs` no
#     longer silently builds an unpatched tree.
#   - Uses `-nc` to skip the pre-build clean so out/Release stays warm across
#     incremental deb runs (duck #5).
#   - EXIT trap re-applies patches no matter how the function exits, so the
#     "tree is patched" post-condition holds even on failure (duck #6, #7).
#   - Trap also kills the build process group + tail + tripwire on signals
#     (duck #6).
# ---------------------------------------------------------------------------
_cmd_debs() {
    # !!! WARNING: this BREAKS the next incremental `ninja` build. !!!
    # dpkg-source --after-build unapplies patches at end-of-build; the
    # EXIT-trap re-apply changes mtimes/contents and busts ccache so the
    # next `ninja` does a cold rebuild of tens of thousands of objects.
    # ONLY run debs after the change is validated via `ninja` + raw chrome
    # binary scp to the Pi. See the header WARNING block for details.
    if [ -z "$CHROMIUM_DEBS_CONFIRM" ]; then
        echo "REFUSING: set CHROMIUM_DEBS_CONFIRM=1 to run debs (busts incremental build cache)." >&2
        echo "See header WARNING in cli.sh for why." >&2
        return 1
    fi
    _setup_env
    _setup_ccache

    # Pre-condition: tree exists AND is patched. Apply if needed.
    _apply_patches

    local src; src=$(_require_src_tree)
    cd "$src"

    mkdir -p "$OUT_DIR"
    local build_log="$OUT_DIR/build.log" trip_log="$OUT_DIR/ccache-tripwire.log"
    : > "$build_log"
    : > "$trip_log"
    if [ "$NO_CCACHE" != "1" ]; then ccache --zero-stats >/dev/null; fi

    _step "STAGE 4: dpkg-buildpackage (long; hours)"
    _log "Using $JOBS parallel jobs."
    export DEB_BUILD_OPTIONS="parallel=$JOBS nocheck terse"

    local build_pid="" tail_pid="" trip_pid=""
    _debs_cleanup() {
        local rc=$?
        trap - EXIT INT TERM
        [ -n "$trip_pid" ] && kill "$trip_pid" 2>/dev/null || true
        [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
        if [ -n "$build_pid" ] && kill -0 "$build_pid" 2>/dev/null; then
            _log "trap: terminating dpkg-buildpackage process group $build_pid"
            kill -TERM -- "-$build_pid" 2>/dev/null || kill -TERM "$build_pid" 2>/dev/null || true
            sleep 5
            kill -KILL -- "-$build_pid" 2>/dev/null || kill -KILL "$build_pid" 2>/dev/null || true
        fi
        # Post-condition: tree must be patched. dpkg-source --after-build
        # always unapplies on success; on failure the state is uncertain.
        # Reapply unconditionally — _apply_patches is idempotent.
        _apply_patches >/dev/null 2>&1 || _log "WARN: post-debs patch reapply failed (rc=$?)"
        return $rc
    }
    trap _debs_cleanup EXIT INT TERM

    set -m
    # -nc: no pre-build clean (preserve out/Release for warm/incremental builds).
    dpkg-buildpackage -us -uc -b -d -nc -j"$JOBS" > "$build_log" 2>&1 &
    build_pid=$!
    set +m
    tail -F -n 0 "$build_log" --pid="$build_pid" &
    tail_pid=$!

    if [ "$NO_CCACHE" != "1" ]; then
        _run_tripwire "$build_pid" "$build_log" "$trip_log" "$(pwd)" &
        trip_pid=$!
    fi

    set +e
    wait "$build_pid"
    local rc=$?
    set -e
    [ -n "$trip_pid" ] && kill "$trip_pid" 2>/dev/null || true
    kill "$tail_pid" 2>/dev/null || true
    wait 2>/dev/null || true

    _step "ccache stats (post-build)"
    ccache -s --verbose 2>/dev/null | head -30 || ccache -s
    [ -s "$trip_log" ] && { _log "--- tripwire log ---"; cat "$trip_log"; }

    [ "$rc" -eq 0 ] || _die "dpkg-buildpackage exited $rc"

    _step "STAGE 5: collect .debs"
    cd "$SRC_DIR"
    mv -v *.deb "$OUT_DIR"/ 2>/dev/null || _log "no .debs in $SRC_DIR"
    mv -v *.changes *.buildinfo "$OUT_DIR"/ 2>/dev/null || true

    _step "STAGE 6: verify en-US.pak ownership invariant"
    # Match exact current version to avoid stale artifacts (duck #15).
    local common_deb="$OUT_DIR/chromium-common_${CHROMIUM_VERSION_FULL}_arm64.deb"
    local l10n_deb="$OUT_DIR/chromium-l10n_${CHROMIUM_VERSION_FULL}_all.deb"
    if [ ! -f "$common_deb" ]; then
        common_deb=$(ls -t "$OUT_DIR"/chromium-common_*_arm64.deb 2>/dev/null | head -1 || true)
    fi
    if [ ! -f "$l10n_deb" ]; then
        l10n_deb=$(ls -t "$OUT_DIR"/chromium-l10n_*_all.deb 2>/dev/null | head -1 || true)
    fi
    [ -n "$common_deb" ] && [ -f "$common_deb" ] || _die "chromium-common .deb missing"
    [ -n "$l10n_deb"   ] && [ -f "$l10n_deb"   ] || _die "chromium-l10n .deb missing"
    _log "  chromium-common: $common_deb"
    _log "  chromium-l10n:   $l10n_deb"
    local common_listing l10n_listing
    common_listing=$(dpkg-deb -c "$common_deb")
    l10n_listing=$(dpkg-deb -c "$l10n_deb")
    grep -qE ' \./usr/lib/chromium/locales/en-US\.pak$' <<< "$common_listing" \
        || _die "chromium-common is missing usr/lib/chromium/locales/en-US.pak"
    _log "  ok: chromium-common contains en-US.pak"
    if grep -qE ' \./usr/lib/chromium/locales/en-US\.pak$' <<< "$l10n_listing"; then
        _die "chromium-l10n still contains usr/lib/chromium/locales/en-US.pak (en-US.pak fix did not take effect)"
    fi
    _log "  ok: chromium-l10n does NOT contain en-US.pak (collision fixed)"

    # Run cleanup explicitly while locals (build_pid/tail_pid/trip_pid) are
    # still in scope. _debs_cleanup untraps EXIT/INT/TERM internally so the
    # trap won't refire on script exit (where set -u would trip on the now-
    # gone locals — duck #16, observed in v0.2.4 cold full).
    _debs_cleanup || true
    _step "DONE"
    ls -lh "$OUT_DIR"/
}

# ---------------------------------------------------------------------------
# full — fetch + patch + debs (matches old build.sh).
# fast — patch + configure + ninja (matches old build-fast.sh).
# ---------------------------------------------------------------------------
_cmd_full() { _cmd_fetch; _cmd_debs; }   # _cmd_debs now applies patches itself.
_cmd_fast() {
    _find_src_tree >/dev/null 2>&1 || _die "no source tree; run 'fetch' first (or use 'full')"
    _cmd_patch; _cmd_configure; _cmd_ninja;
}

# ---------------------------------------------------------------------------
# doctor — preflight checks. Fail-closed. NOT a stub — bench results showed
# stubs add no validation value.
# ---------------------------------------------------------------------------
_cmd_doctor() {
    _setup_env
    local fail=0
    _step "doctor: preflight checks"

    # 1. /patches exists and is mounted (or at least populated).
    if [ ! -d "$PATCHES_DIR" ]; then
        _log "  FAIL: $PATCHES_DIR missing"; fail=$((fail+1))
    else
        local n; n=$(find "$PATCHES_DIR" -maxdepth 1 -name '*.patch' 2>/dev/null | wc -l)
        if [ "$n" -eq 0 ]; then
            _log "  WARN: $PATCHES_DIR is empty (full/debs will produce stock RPi chromium with no HEVC patches)"
        else
            _log "  ok: $PATCHES_DIR present ($n local patches)"
        fi
    fi

    # 2. ccache writable + version.
    local cdir="${CCACHE_DIR_OVERRIDE:-${CCACHE_DIR:-/out/.ccache}}"
    if mkdir -p "$cdir" 2>/dev/null && [ -w "$cdir" ]; then
        _log "  ok: ccache dir writable ($cdir)"
    else
        _log "  FAIL: ccache dir not writable: $cdir"; fail=$((fail+1))
    fi
    if command -v ccache >/dev/null 2>&1; then
        _log "  ok: ccache installed ($(ccache -V 2>/dev/null | head -1))"
    else
        _log "  FAIL: ccache not installed"; fail=$((fail+1))
    fi

    # 3. clang-19 on PATH.
    if command -v clang-19 >/dev/null 2>&1; then
        _log "  ok: clang-19 found ($(command -v clang-19))"
    else
        _log "  FAIL: clang-19 missing"; fail=$((fail+1))
    fi

    # 4. Source tree presence (informational unless we want to be strict).
    local src
    if src=$(_find_src_tree 2>/dev/null); then
        _log "  ok: source tree present ($src)"
        # 5. If patched, stamps must match.
        cd "$src"
        if [ -f .pc/applied-patches ] && [ -s .pc/applied-patches ]; then
            local fp_new fp_old=""
            fp_new=$(_compute_patch_fp)
            [ -f "$STAMP_PATCH_FP" ] && fp_old=$(cat "$STAMP_PATCH_FP")
            if [ "$fp_new" = "$fp_old" ] && [ -f "$STAMP_RULES_TAIL" ]; then
                _log "  ok: tree patched, fingerprint matches, rules-tail applied"
            else
                _log "  FAIL: tree patched but stamp mismatch (fp_new=$fp_new fp_old=${fp_old:-none}, rules-tail-stamp=$([ -f "$STAMP_RULES_TAIL" ] && echo yes || echo no))"; fail=$((fail+1))
            fi
            # 6. args.gn cc_wrapper.
            if [ -f out/Release/args.gn ]; then
                if grep -q '^cc_wrapper *= *"ccache"' out/Release/args.gn; then
                    _log "  ok: args.gn has cc_wrapper=\"ccache\""
                else
                    _log "  FAIL: args.gn missing cc_wrapper=\"ccache\""; fail=$((fail+1))
                fi
            else
                _log "  info: no args.gn yet (configure not run)"
            fi
        else
            _log "  info: tree pristine (patch not run)"
        fi
    else
        _log "  info: no source tree (fetch not run)"
    fi

    if [ "$fail" -ne 0 ]; then
        _die "doctor: $fail check(s) failed"
    fi
    _log "doctor: all checks passed"
}

# ---------------------------------------------------------------------------
# status — print current state without exit code semantics.
# ---------------------------------------------------------------------------
_cmd_status() {
    _step "status"
    if t=$(_find_src_tree 2>/dev/null); then
        _log "source tree: $t"
        cd "$t"
        if [ -f .pc/applied-patches ] && [ -s .pc/applied-patches ]; then
            _log "tree state: patched ($(wc -l < .pc/applied-patches) patches applied)"
        else
            _log "tree state: pristine"
        fi
        if [ -f out/Release/args.gn ]; then
            _log "args.gn: present ($(stat -c %s out/Release/args.gn) bytes, mtime $(stat -c %Y out/Release/args.gn))"
            grep -E '^cc_wrapper' out/Release/args.gn || _log "  (no cc_wrapper line)"
        else
            _log "args.gn: absent"
        fi
    else
        _log "source tree: none"
    fi
    _log "patch fp current: $(_compute_patch_fp)"
    _log "patch fp stamp:   $([ -f "$STAMP_PATCH_FP" ] && cat "$STAMP_PATCH_FP" || echo none)"
    _log "rules-tail stamp: $([ -f "$STAMP_RULES_TAIL" ] && echo present || echo absent)"
    _log "ccache dir: ${CCACHE_DIR_OVERRIDE:-${CCACHE_DIR:-/out/.ccache}}"
    _log "out dir:    $(ls "$OUT_DIR" 2>/dev/null | wc -l) entries in $OUT_DIR"
}

_cmd_clean() {
    _step "clean: removing source tree and outputs (NOT ccache)"
    rm -rf "$SRC_DIR"/chromium-* "$SRC_DIR"/.local-hevc-*
    rm -rf "$OUT_DIR"/*.deb "$OUT_DIR"/*.changes "$OUT_DIR"/*.buildinfo "$OUT_DIR"/chromium "$OUT_DIR"/build.log "$OUT_DIR"/ninja.log "$OUT_DIR"/ccache-tripwire.log
    _log "clean: done"
}

_cmd_shell() { _setup_env; _setup_ccache; exec /bin/bash; }

# ---------------------------------------------------------------------------
# Auto-log — every cli.sh invocation tees stdout+stderr to a timestamped file
# under /out/.cli-logs/<sub>-<UTC>.log. A `latest.log` symlink always points
# at the most recent run. Skipped for interactive/read-only subcommands.
# ---------------------------------------------------------------------------
_LOG_PATH=""
_TEE_PID=""

_setup_autolog() {
    local sub="$1"
    case "$sub" in
        shell|help|logs|tail) return 0 ;;
    esac
    local logdir="$OUT_DIR/.cli-logs"
    mkdir -p "$logdir" 2>/dev/null || return 0
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    local logfile="${sub}-${ts}.log"
    _LOG_PATH="$logdir/$logfile"
    ln -sfn "$logfile" "$logdir/latest.log" 2>/dev/null || true
    # Tee stdout+stderr into the log. We must capture the process-substitution
    # PID here (right after the exec, while $! still refers to the tee child)
    # so that _teardown_autolog can wait for it explicitly. Without an
    # explicit teardown, bash deadlocks at script exit: it retains an open fd
    # to the write side of the pipe even though stdout/stderr have been
    # redirected, so tee never sees EOF on its stdin and 'wait' never
    # returns. See fix in main() below.
    exec > >(tee -a "$_LOG_PATH") 2>&1
    _TEE_PID=$!
    printf '=== cli.sh %s @ %s (log: %s) ===\n' "$sub" "$ts" "$_LOG_PATH"
}

# Drain and reap the autolog tee child set up by _setup_autolog. Idempotent;
# safe to call when autolog was skipped. Must be called AFTER the subcommand
# dispatch returns (i.e. from main, not from inside an EXIT trap) because
# subcommands like _cmd_ninja install their own EXIT traps with
# `trap - EXIT INT TERM` resets that would clobber any trap set in
# _setup_autolog.
_teardown_autolog() {
    [ -n "${_TEE_PID:-}" ] || return 0
    # Close our copies of fds 1 and 2 (both currently point at the pipe
    # going to tee). This delivers EOF to tee's stdin so it flushes and
    # exits. Until those fds close, tee blocks in read() forever.
    exec 1>&- 2>&-
    wait "$_TEE_PID" 2>/dev/null || true
    _TEE_PID=""
}

_cmd_logs() {
    local logdir="$OUT_DIR/.cli-logs"
    if [ ! -d "$logdir" ]; then
        _log "no logs in $logdir (no cli.sh build has logged yet)"
        return 0
    fi
    _step "recent cli.sh logs (in $logdir)"
    # shellcheck disable=SC2012
    ls -lht "$logdir"/*.log 2>/dev/null | grep -v ' latest\.log$' | head -20 \
        || _log "no .log files in $logdir"
    if [ -L "$logdir/latest.log" ]; then
        _log "latest -> $(readlink "$logdir/latest.log")"
    fi
}

_cmd_tail() {
    local latest="$OUT_DIR/.cli-logs/latest.log"
    if [ ! -e "$latest" ]; then
        _die "no latest.log in $OUT_DIR/.cli-logs (run a build first)"
    fi
    _log "tailing $latest (Ctrl-C to exit)"
    exec tail -F "$latest"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
_cmd_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local sub=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --jobs) JOBS="$2"; shift 2 ;;
            --jobs=*) JOBS="${1#--jobs=}"; shift ;;
            -j) JOBS="$2"; shift 2 ;;
            --no-ccache) NO_CCACHE=1; shift ;;
            --ccache-dir) CCACHE_DIR_OVERRIDE="$2"; shift 2 ;;
            --ccache-dir=*) CCACHE_DIR_OVERRIDE="${1#--ccache-dir=}"; shift ;;
            -v|--verbose) set -x; shift ;;
            -h|--help) _cmd_help; exit 0 ;;
            -*) _die "unknown global flag: $1" ;;
            *) sub="$1"; shift; break ;;
        esac
    done

    [ -n "$sub" ] || { _cmd_help; exit 1; }

    _setup_autolog "$sub"

    case "$sub" in
        fetch)     _cmd_fetch "$@" ;;
        patch)     _cmd_patch "$@" ;;
        configure) _cmd_configure "$@" ;;
        ninja)     _cmd_ninja "$@" ;;
        debs)      _cmd_debs "$@" ;;
        full)      _cmd_full "$@" ;;
        fast)      _cmd_fast "$@" ;;
        doctor)    _cmd_doctor "$@" ;;
        status)    _cmd_status "$@" ;;
        logs)      _cmd_logs "$@" ;;
        tail)      _cmd_tail "$@" ;;
        clean)     _cmd_clean "$@" ;;
        shell)     _cmd_shell "$@" ;;
        help)      _cmd_help ;;
        *)         _die "unknown subcommand: $sub (try: $0 help)" ;;
    esac
    local rc=$?
    _teardown_autolog
    return $rc
}

main "$@"
