# SAND128 chroma offset bug

## Status

This is the **outstanding bug** as of repo creation. Decode succeeds
end-to-end (luma is correct, picture is recognizable, motion is
smooth), but chroma is corrupt.

## Symptom

Magenta / bright-green vertical banding across the rendered video,
repeating roughly every 128 px horizontally. See
`chroma-bug-screenshot.png` (captured via `grim` on Pi 5 running a
1920×1080 panda HEVC clip).

## Root cause hypothesis

The `rpi-hevc-dec` driver outputs frames in the
`DRM_FORMAT_MOD_BROADCOM_SAND128` modifier layout. In SAND128 for
NV12-equivalent (`V4L2_PIX_FMT_NC12`), the image is divided into
**vertical columns 128 bytes wide**, and within each column the Y
plane (1080 rows) and CbCr plane (540 rows) are **stacked**:

```
column 0           column 1           ...
+--------+         +--------+
| Y row 0|         | Y row 0|
| Y row 1|         | Y row 1|
|   ...  |         |   ...  |
| Y r1079|         | Y r1079|
| C row 0|         | C row 0|
|   ...  |         |   ...  |
| C r 539|         | C r 539|
+--------+         +--------+
```

Total column height = 1080 + 540 = **1620 rows**. V4L2 reports this
as `bytesperline = 1620` which is **NOT** the byte stride in the
linear sense.

In `media/gpu/v4l2/v4l2_utils.cc::V4L2FormatToVideoFrameLayout` the
chroma plane offset is currently set to:

```cpp
planes.emplace_back(y_stride, y_stride_abs * pix_mp.height,
                    y_stride_abs * pix_mp.height / 2);
```

For NC12 with `y_stride_abs = 1620` and `pix_mp.height = 1080` that
yields chroma offset `1620 * 1080 = 1749600` (linear math). Mesa v3d
will read chroma from the wrong memory.

## Evidence

From the working build's stderr log:

```
strides=[1620 1620] offsets=[0 1749600] modifier=0x0700000000000004
```

`0x0700000000000004` = `fourcc_mod_code(BROADCOM, 4)` =
`DRM_FORMAT_MOD_BROADCOM_SAND128`.

## Investigation order (do this BEFORE editing offsets)

1. **Read Mesa v3d SAND import code.** Search in Mesa source for
   `DRM_FORMAT_MOD_BROADCOM_SAND128`, `SAND128`, `resource_from_handle`,
   `modifier`. Confirm how it interprets `stride`, `offset`, and the
   modifier parameter. The right offset value depends on whether
   Mesa expects bytes or rows.
2. **Read kernel/uAPI definitions for Broadcom SAND modifiers.**
   Confirm whether modifier parameter `0` means default column
   height or absent parameter.
3. **Log the exact V4L2 CAPTURE format from the driver.** Save
   output from:
   - `v4l2-ctl -d /dev/video19 --all`
   - `v4l2-ctl -d /dev/video19 --list-formats-ext`
   - the existing `0007` instrumentation logs showing
     `strides[]`, `offsets[]`, `modifier`, and whether one fd or
     two are passed
4. **Then test offset candidates** in this order:
   - `pix_mp.height * 128 = 138240` — bytes into a 128-byte-wide
     column where chroma starts (most plausible byte-offset
     candidate)
   - `0` with single-plane import (let Mesa derive both planes
     from the modifier)
   - `pix_mp.height = 1080` — only if Mesa clearly treats offset as
     row count, not byte offset (probably not)

Each iteration: edit `v4l2_utils.cc` → `build/build-fast.sh`
(~5 min via fingerprint skip + ccache) → scp to Pi → restart
`hevc-test` → snapshot.

## Note from rubber-duck review

The original draft of this doc suggested trying `offset = 1080`
first. That is most likely wrong: `gbm_import_fd_modifier_data.offsets[]`
are byte offsets in normal usage, even with a modifier. Try
`pix_mp.height * 128` first, and only fall back to row-count
semantics if Mesa source confirms it.

## Workaround

None — chroma is corrupt. Luma-only output is not a useful
deliverable.
