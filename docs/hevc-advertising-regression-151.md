# HEVC advertising regression on Chromium 151 — root cause, fix, and maintainability plan

Status: **root cause confirmed on-device; fix in progress on branch `fix/hevc-advertising-151`.**
Date: 2026-08-28

## Symptom

After porting all local HEVC patches from the working 147 build to 151
(`chromium-151-patch-port`), HEVC playback on Raspberry Pi 5 (Pi100,
`192.168.1.100`) fails with:

```
DEMUXER_ERROR_NO_SUPPORTED_STREAMS
```

`canPlayType('video/mp4; codecs="hev1.1.6.L120.90"')` returns `""` (empty),
so the demuxer rejects the stream before a decoder is ever selected. The
147 build advertised and played the exact same file fine.

## Root cause (confirmed by live device probe)

RPi-Distro added a **new-in-151** debian patch,
`debian/patches/rpi/v4l2-do-not-advertise-stateless-codecs.patch`, that
inserts an `IsStatelessDecoder()` guard into
`GetSupportedV4L2DecoderConfigs()` in `media/gpu/v4l2/v4l2_utils.cc`:

```c
#if !BUILDFLAG(IS_CHROMEOS)
bool IsStatelessDecoder(int device_fd) {
  struct v4l2_requestbuffers reqbufs = {};
  reqbufs.count = 0;
  reqbufs.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
  reqbufs.memory = V4L2_MEMORY_MMAP;
  if (HandledIoctl(device_fd, VIDIOC_REQBUFS, &reqbufs) != kIoctlOk)
    return false;
  return !!(reqbufs.capabilities & V4L2_BUF_CAP_SUPPORTS_REQUESTS);
}
#endif
...
    // in GetSupportedV4L2DecoderConfigs(), per candidate device:
#if !BUILDFLAG(IS_CHROMEOS)
    if (IsStatelessDecoder(device_fd.get())) {
      continue;   // <-- skips /dev/video19, the HEVC decoder
    }
#endif
```

RPi's own patch comment states the intent explicitly: *"On a Raspberry Pi 4
that device is /dev/video19 (HEVC): canPlayType() answers 'probably' and
playback then dies with DECODER_ERROR_NOT_SUPPORTED."* They suppress
advertising the stateless HEVC device because **their** build only wires up
the *stateful* decoder (`V4L2StatefulVideoDecoder`) and cannot drive the
stateless path.

**Our build is different: we DO drive the stateless HEVC decoder** (local
patch `0005-h265-slice-params-and-bitsize.patch` et al. wire up
`V4L2VideoDecoder` + the H.265 slice-params delegate). So RPi's suppression
actively breaks a path that works for us.

### Confirmed device facts (Pi100 `/dev/video19`, runtime probe)

- `VIDIOC_REQBUFS(count=0, OUTPUT_MPLANE)` → `capabilities = 0x1d`, i.e.
  `V4L2_BUF_CAP_SUPPORTS_REQUESTS` (0x08) is **set**.
- Therefore `IsStatelessDecoder(/dev/video19)` returns **true** → the device
  is `continue`d over → HEVC config never enumerated → supplemental decoder
  profile cache stays empty → `canPlayType('hvc1'/'hev1') = ""` →
  `DEMUXER_ERROR_NO_SUPPORTED_STREAMS`.
- OUTPUT_MPLANE coded format = `S265` (HEVC parsed slice). CAPTURE_MPLANE =
  Broadcom SAND tiled only (`Nc12`/`Nc30`/`NC12`/`NC30`, no plain NV12).
- Kiosk chromium runs as **root with `--no-sandbox`** — the GPU sandbox
  broker is inactive, so V4L2 device permissions are NOT the cause. (Two
  earlier sandbox/permission hypotheses were disproven by this probe.)

### Why it is a clean 147 -> 151 regression

`v4l2-do-not-advertise-stateless-codecs.patch` **did not exist in RPi's 147
packaging**. It is new in the 151 debian tarball
(`SHA256_DEBIAN` pinned in `build/cli.sh`), which the build downloads and
applies via `dpkg-source -x`. Nothing else in the media-type / build-flag
layer changed between 147 and 151 for our GN args.

## The fix

Add a project-owned local patch, applied **after** the RPi series (our
`patches/*.patch` are appended to `debian/patches/series` under
`local-hevc/`), that neutralizes RPi's suppression **only for our RPi V4L2
builds**:

- Change both `#if !BUILDFLAG(IS_CHROMEOS)` guards (the `IsStatelessDecoder`
  definition and its call site) to
  `#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(USE_V4L2_CODEC_RPI)`.
- On our build `USE_V4L2_CODEC_RPI` is defined (restored by local patch
  `0019-restore-use_v4l2_codec_rpi-gn-option.patch`), so both the function
  and the skip compile out — the HEVC device is advertised again, exactly
  as in 147. On any non-RPi Linux build, RPi's original behavior is
  preserved and there is no unused-function warning.

New patch: `patches/0020-rpi-advertise-stateless-hevc.patch`.

### Why a counter-patch rather than editing/removing RPi's patch

The RPi series lives inside the downloaded pinned debian tarball, not in our
tree. Deleting an entry from that series would mean mutating the fetched
tarball on every build (fragile, invisible in our git history). A local
counter-patch we own is self-documenting, versioned in *our* repo, and is
re-verified on every build by the patch-apply step — see maintainability
below.

## Maintainability — stop RPi rebases from silently breaking HEVC

The whole class of failure here is "RPi changes a shared file on a rebase
and silently disables our HEVC." Mitigations, in priority order:

1. **Own the advertising decision in a project-controlled patch**
   (`0020`, this fix). Any future RPi churn to `v4l2_utils.cc` that
   re-introduces or renames the suppression is countered by our patch; if
   RPi refactors the file enough that our patch no longer applies, the build
   *fails loudly at patch-apply time* instead of silently shipping broken
   HEVC.

2. **`canPlayType` smoke check (highest value, cheapest).** Add a
   boot-time / CI assertion that
   `canPlayType('video/mp4; codecs="hev1.1.6.L120.90"') != ""`. This exact
   regression would have been caught in seconds instead of via a multi-day
   device hunt. Candidate homes:
   - CI: a headless `--enable-features` smoke run in the build container
     that evaluates `navigator.mediaCapabilities` / `canPlayType`.
   - Device: an `agora` player self-test on first boot after an OTA that
     logs a loud error if HEVC is not advertised.

3. **Consolidate HEVC-critical code behind minimal, well-marked seams.**
   Where we must edit RPi/upstream shared files (`v4l2_utils.cc`,
   `Fourcc`), keep the edits small and guarded by `USE_V4L2_CODEC_RPI` with
   a `chromium-rpi-hevc:` marker comment, and move as much of the actual
   HEVC logic as possible into dedicated project-owned files
   (e.g. a `media/gpu/v4l2/rpi_hevc/` module reached by a one-line seam),
   so a rebase conflict surfaces on the *seam* rather than deep in shared
   logic.

4. **Vendor + pin the RPi debian tarball explicitly (already done via
   `SHA256_DEBIAN`), and diff the RPi series on every version bump.** Add a
   `docs/`/CI step that lists new/removed RPi patches between the old and
   new pinned tarball so decoder-affecting additions like
   `v4l2-do-not-advertise-stateless-codecs.patch` are reviewed, not
   discovered in the field.

## Validation plan

1. Author `0020` counter-patch, commit + push to `fix/hevc-advertising-151`.
2. On the ARM build VM (`chromium-builder-arm`): pull the branch, run a
   `ninja` build (`build/cli.sh fast`), scp the raw `chrome` binary to
   Pi100.
3. On Pi100: confirm `canPlayType('hev1...') != ""` and that `gears` HEVC
   clip plays (no `DEMUXER_ERROR_NO_SUPPORTED_STREAMS`).
4. Only after `ninja` + on-device validation passes, package `.debs`
   (`build/cli.sh full`) and cut a release.

## Secondary follow-ups (not blockers for this fix)

- The CAPTURE queue exposes only Broadcom SAND formats (no NV12); local
  patches `0002`/`0009` register those `Fourcc`s and remain load-bearing for
  actual decode. Re-verify they still apply/work on 151 during on-device
  decode validation (the advertising fix must land first — the skip happens
  before any CAPTURE-format handling matters).
- Relocate the `[HEVC_DBG]` VLOGs (patch 0005) behind a runtime debug flag
  so production builds are quiet.

## Recurrence on the 152 port (2026-09-05)

The exact same symptom reappeared on Chromium 152: `canPlayType` returned
`no` for every HEVC profile, and an `strace -e trace=openat,ioctl` of the
GPU process showed a single `VIDIOC_REQBUFS(count=0, OUTPUT_MPLANE)` against
`/dev/video19` followed by no `VIDIOC_ENUM_FMT` — the signature of
`IsStatelessDecoder()` returning true and `continue`-ing.

**Cause was not upstream churn.** The `chromium-152-patch-port` branch was
cut from a base that predated PR #64, so it never contained the fix:
`patches/0020-rpi-advertise-stateless-hevc.patch` and
`patches/0021-hevc-10bit-external-sampler-sand-rec601.patch` were simply
absent from the branch, and a new local patch had reused the number `0020`.
Restoring both patches (rustfft renumbered to `0022`) and rebuilding restored
`hevc_main/hevc_main10 = probably`, `decodingInfo hevc = hw`, and 8-bit /
10-bit / HDR playback all PASS on Pi100.

**Lesson.** The counter-patch mechanism worked exactly as designed on 151;
what failed was branch hygiene. When starting a new upstream port branch,
diff `patches/` against `main` before the first build:

```sh
git diff --stat origin/main..HEAD -- patches
```

Any patch present on `main` and missing on the port branch is a bug unless
its removal is deliberate and explained in the commit message.

**Smoke check.** `pi-runtime/hevc-validate/diag_codecs.py` is the cheap
(~40 s) assertion recommended in the maintainability section above: it
reports `canPlayType` and `navigator.mediaCapabilities.decodingInfo` for
HEVC/H.264/VP9/AV1 and, with `DIAG_STRACE=1`, captures the `/dev/video*`
ioctl sequence. Run it before the full `validate.py` on every new build.