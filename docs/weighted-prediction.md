# Weighted prediction and the chroma offset scale

This documents why `kWpOffsetHalfRangeC` in
`patches/0008-hevc-pred-weight-table.patch` is **128 at every bit depth**,
and how that was verified on hardware. It exists because the constant looks
like a bug on a plain reading of the spec, and has been reported as one
(issue #14). It is not.

## The apparent bug

H.265 eq. (7-56) derives the chroma weighted-prediction offset as

```
ChromaOffsetL0[i][j] = Clip3( -wpOffsetHalfRangeC, wpOffsetHalfRangeC - 1,
    ( wpOffsetHalfRangeC + delta_chroma_offset_l0[i][j]
      - ( ( wpOffsetHalfRangeC * ChromaWeightL0[i][j] ) >> ChromaLog2WeightDenom ) ) )
```

where `wpOffsetHalfRangeC = 1 << (BitDepthC - 1)` -- 128 for 8-bit, **512 for
Main 10**. Patch 0008 hardcodes 128. The obvious conclusion is that 10-bit
weighted prediction is broken and that `bit_depth_chroma_minus8` needs
plumbing through.

## Why 128 is correct

The value is not consumed by a spec-conformant software decoder. It is
written into the V4L2 stateless HEVC control, where the field is:

```c
struct v4l2_hevc_pred_weight_table {
        ...
        __s8    chroma_offset_l0[16][2];
```

`__s8` cannot represent the 10-bit range at all. The Raspberry Pi kernel
driver then truncates it again on the way to the hardware
(`drivers/staging/media/rpivid/rpivid_h265.c`):

```c
msg_slice(de, w->chroma_offset_l0[idx][0] & 0xff);
```

The register field is 8 bits. So the uAPI contract is "offset in 8-bit
units" -- an ABI scale, not the spec's bit-depth-dependent half range. The
hardware applies the bit-depth shift itself. Deriving with 512 would produce
a value 4x too large that would additionally be mangled by the `__s8` cast.

Worked example from a real Main10 slice in the `wp10` test clip:

| quantity | value |
|---|---|
| `luma_log2_weight_denom` | 7 |
| `delta_chroma_log2_weight_denom` | 1 (so `ChromaLog2WeightDenom` = 8) |
| `delta_chroma_weight_l0[0][0]` | -48 (so `ChromaWeightL0` = 208) |
| `delta_chroma_offset_l0[0][0]` | 0 |

* spec-literal with half range 512: `512 + 0 - ((512*208)>>8)` = **96**
* as implemented with 128:        `128 + 0 - ((128*208)>>8)` = **24**

`96 == 24 << (BitDepthC - 8)`. The implemented value is exactly the
8-bit-normalised form the ABI asks for.

## How this was verified

Reasoning about the ABI is not proof, so the claim is backed by a clip that
genuinely exercises the path:

1. `make_wp_pattern.py` renders a cross-fade between two chromatically
   opposed saturated colours, so U and V swing hard in opposite directions.
   A global illumination *and* chroma change is what makes an encoder choose
   weighted prediction; the standard `make_pattern.py` analysis band is
   static and never triggers it, which is why the normal gate passed over
   this code path without testing it.
2. `make_wp_clips.sh` encodes 8-bit and 10-bit versions with `weightp` and
   `weightb` enabled, then **fails the build if x265 reports `UV:0.0%`**
   weighting. Without that gate the test would be vacuous -- a clip with no
   chroma pred_weight_table passes against broken code.
3. The frame keeps a small static mid-grey patch. Weights are per-slice, so
   the patch is weighted-predicted like everything else, but it is
   chroma-neutral and its correct output never changes. That makes it an
   absolute detector needing no cross-run frame alignment: a wrong offset
   shows up as a colour cast on something that must stay neutral.

Confirmed present in the clip via `ffmpeg -bsf:v trace_headers`:
`chroma_weight_l0_flag = 1` on 224 slice references with
`delta_chroma_weight_l0` up to +-127, i.e. genuinely non-unity chroma
weights. (With a unity chroma weight the half-range term cancels and the
bug would be unobservable by construction.)

Measured on Pi 5, chromium `1:152.0.7977.75-1~deb13u1+rpt1`, hardware decode
confirmed by an open `/dev/video19` fd:

| clip | worst |chroma| on the neutral patch |
|---|---|
| `wp8` (8-bit control) | 0.00 / 255 |
| `wp10` (Main10) | 0.58 / 255 |

A half-range error would shift the derived offset by
`384 * (1 - ChromaWeight/2^denom)` in 10-bit units -- roughly 9-10 levels of
visible 8-bit cast for the weights above. Nothing of the sort appears.

## Consequence

Do not "fix" this constant. If it is ever changed to
`1 << (bit_depth_chroma_minus8 + 7)`, 10-bit weighted prediction will
regress, and `run-validation.sh` will fail `wp10` while `wp8` still passes --
which is precisely the signature the verdict output calls out.
