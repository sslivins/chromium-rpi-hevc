# Phase 1 — 10-bit HEVC (Path A) investigation log

Tracking issue: #14 (Main 10 / HDR support on Pi 5).

## Goal

**Path A — downconvert.** Forward 10-bit HEVC bitstreams through the Pi 5
hevc-dec V4L2 stateless decoder and have it produce 8-bit NV12 frames for
existing renderers/compositors. SDR only. Ships when verified as v0.2.3.

(Path C — full 10-bit P010 / NV12_10_COL128 through to display, with HDR —
is Phase 2 and out of scope here.)

## Status as of 2026-05-05

**Patch 0008 (pred_weight_table) currently hardcodes `kWpOffsetHalfRangeC = 128`,
correct for 8-bit chroma only.** The original TODO said "plumb
bit_depth_chroma_minus8 through" for 10-bit. Initial reading suggested a
2-line change: replace the constant with `1 << (sps->bit_depth_chroma_minus8 + 7)`.

A rubber-duck review surfaced two structural concerns that gate any
real 10-bit Path A claim:

### Concern 1 — V4L2 UAPI `__s8` width

`v4l2_hevc_pred_weight_table.chroma_offset_lX[i][j]` is `__s8` in
`<linux/v4l2-controls.h>`. HEVC 10-bit derives offsets in the range
`[-512, 511]`, which cannot be represented in a signed 8-bit field.

The Raspberry Pi 6.12 `hevc_dec` driver appears to consume this field as
`& 0xff` when packing into the firmware message — i.e. the kernel ABI
treats this as an opaque 8-bit-domain value, not as a true HEVC-derived
offset. **This means the hardcoded 128 may be the intentional ABI
contract and not a bug for 10-bit at all.** Need to read the rpi
hevc-dec firmware-side source to confirm what the firmware does with
the value (does it scale to BitDepthC internally? does it expect
8-bit-domain offsets always?).

Until this is resolved, deriving the value from `bit_depth_chroma_minus8`
and writing 512 into `__s8` would just narrow back to a wrong wrap-around
value. Don't claim a fix until we know.

### Concern 2 — capture format negotiation for 10-bit SPS

The same Pi 6.12 driver appears to *reject* setups where the SPS reports
10-bit but the chromium V4L2 client requests plain `NV12` (8-bit) on the
CAPTURE queue. It instead requires one of:

- `V4L2_PIX_FMT_NV12_10_COL128`
- `V4L2_PIX_FMT_NV12MT_10_COL128`

If true on our target kernel, "downconvert in the decoder, output 8-bit"
isn't supported by the kernel driver — Path A as scoped requires a
**format conversion stage outside the V4L2 decoder** (chromium client
side: ask for NV12_10_COL128 capture, downconvert in libyuv or the GPU
to NV12 8-bit before handing to compositor).

That pushes Path A scope from "1-line patch fix" to "add NV12_10_COL128
capture support to chromium V4L2 plus a downconvert step".

## Open investigation tasks

- [ ] Read rpi-hevc-dec kernel source on the actual Pi target kernel
  (`uname -r` of Pi 192.168.1.114 → fetch matching
  `drivers/staging/media/rpivid` or out-of-tree `hevc_dec` driver).
- [ ] Confirm whether `chroma_offset_lX` `__s8` is masked/narrowed or
  reinterpreted by the firmware-side message builder.
- [ ] Confirm whether the kernel rejects `(SPS=10-bit, CAPTURE=NV12)` or
  whether existing chromium V4L2 negotiation already handles
  format-not-supported by adding a downconvert.
- [ ] Encode test asset `test_hevc_10bit.mp4` once we know what to test.

## What this branch does land

1. **`docs/phase1-10bit-investigation.md`** (this file).
2. **Cosmetic refactor of patch 0008**: replace `kWpOffsetHalfRangeC = 128`
   constexpr with a runtime value `wp_offset_half_range_c` derived from
   `sps->bit_depth_chroma_minus8`. **For 8-bit input the value is
   identical (128).** The change is byte-identical for any 8-bit stream;
   it only differs for 10-bit, which we are not yet feeding. The point
   is to:
   - Validate the incremental build + deploy + smoke flow end-to-end
     with the freshly primed ccache.
   - Stage the patch structure so the actual 10-bit Path A change (when
     we know what it should be) is one constant tweak, not a
     re-architecture.

## Out of scope on this branch

- Encoding the 10-bit test asset.
- Touching V4L2 capture format negotiation.
- Anything that would alter 8-bit behavior on the test rig.

The branch ships only after 8-bit regression is green on Pi 192.168.1.114
with `test_hevc.mp4`.
