#include <metal_stdlib>
using namespace metal;

/// Mirrors `ExposureUniforms` in Swift exactly (twenty 4-byte fields, no
/// padding on either side).
///
/// `debayerMode` selects which of the five display modes `tonemapFragment`
/// renders (see the `DebayerMode`-shaped constants below); `cfaRedX`/
/// `cfaRedY` (each 0 or 1) give the column/row parity, within a pixel's 2x2
/// CFA tile, of the RED sample — from which every other position in the
/// tile follows for a standard Bayer array: BLUE always sits at the
/// diagonally-opposite corner `(1 - cfaRedX, 1 - cfaRedY)`, and GREEN fills
/// the other two corners. That's sufficient to describe any of the 4
/// possible Bayer phase alignments with just two bits.
///
/// `wbGainR`/`G`/`B` and `colorMatrix` are the camera color calibration
/// pipeline (see `readClampedWB`/`applyColorMatrix` below) — meaningful only
/// for, and applied only in, the 3 real demosaic modes. `.rawSensor`/
/// `.greyScale` never read any of these. `gamma` rides along in the same
/// buffer but is currently unread by `applyGamma` (see that function's doc
/// comment, and `ExposureUniforms.gamma`'s on the Swift side, for why the
/// field is kept rather than deleted) — the display-encoding curve is now
/// always the real Rec.709 OETF (`rec709OETF`), not a `gamma`-parameterized
/// power law.
///
/// `lutEnabled` (0 or 1) gates `tonemapFragment`'s final 3D LUT sampling
/// stage — see that function's own doc comment below.
struct ExposureUniforms {
    float blackLevel;
    float whiteLevel;
    uint flipVertically;
    uint debayerMode;
    uint cfaRedX;
    uint cfaRedY;
    float wbGainR;
    float wbGainG;
    float wbGainB;
    float colorMatrix[9]; // row-major 3x3, applied to demosaiced RGB after interpolation
    float gamma; // unread by applyGamma today; see that function's doc comment
    uint lutEnabled; // 0 or 1; gates tonemapFragment's post-gamma 3D LUT sample
};

/// Mirrors `GradingUniforms` in Swift exactly (sixteen 4-byte fields, no
/// padding) — the "Cine Colour" grading stage. Bound at buffer index 1 on
/// both `tonemapVertex` and `tonemapFragment` (independent of the
/// fragment's `texture(1)` LUT slot — buffer and texture argument tables are
/// separate in Metal, so the two indices don't collide).
///
/// `gain`/`gainR`/`gainG`/`gainB` and `pedestal`/`pedestalR`/`pedestalG`/
/// `pedestalB` apply in the linear, normalized-to-[0,1] domain, right after
/// the black/white stretch and before `applyGamma`. `gammaTrim`/
/// `gammaTrimR`/`gammaTrimB`/`gammaTrimG`, `brightness`, `hue`, and
/// `saturation` apply in the display-encoded domain, after `applyGamma`
/// and before the LUT stage. `flipHorizontal` (0 or
/// 1) mirrors the U texture
/// coordinate in `tonemapVertex`, exactly like `ExposureUniforms.
/// flipVertically` mirrors V.
///
/// `gammaTrimG` and `hue` were added after the other fields (both this
/// struct's field order and the Metal buffer layout are append-only for
/// backward compatibility with any already-serialized grade sidecar) — see
/// `GradingUniforms.swift`'s own doc comment for why.
///
/// See `GradingUniforms.swift`'s doc comment for the full pipeline-placement
/// rationale and the by-hand proof that `.identity` (every field at the
/// value listed below) is a true no-op through every stage it touches.
struct GradingUniforms {
    float brightness;
    float gain;
    float gainR;
    float gainG;
    float gainB;
    float pedestal;
    float pedestalR;
    float pedestalG;
    float pedestalB;
    float gammaTrim;
    float gammaTrimR;
    float gammaTrimB;
    float gammaTrimG;
    float saturation;
    float hue;
    uint flipHorizontal;
};

/// Mirrors `ViewportUniforms` in Swift exactly (three 4-byte fields, no
/// padding) — the on-screen zoom/pan transform. Bound only at buffer index 2
/// on `tonemapVertex`; `tonemapFragment` never reads it (this is purely a
/// vertex-stage UV remap, unlike `ExposureUniforms`/`GradingUniforms`, which
/// both stages need).
struct ViewportUniforms {
    float scale;
    float centerX;
    float centerY;
};

/// Mirrors `DebayerMode.rawValue` in Swift.
constant uint kDebayerRawSensor = 0;
constant uint kDebayerGreyScale = 1;
constant uint kDebayerNearestNeighbor = 2;
constant uint kDebayerBilinear = 3;
constant uint kDebayerHighQuality = 4;

/// CFA sample identity used internally below (not part of any uniform
/// layout).
constant uint kColorRed = 0;
constant uint kColorGreen = 1;
constant uint kColorBlue = 2;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// Emits a full-screen triangle (the classic oversized-triangle trick: three
/// vertices that cover the entire viewport once clipped) without needing a
/// vertex buffer.
vertex VertexOut tonemapVertex(uint vertexID [[vertex_id]],
                                constant ExposureUniforms &uniforms [[buffer(0)]],
                                constant GradingUniforms &grading [[buffer(1)]],
                                constant ViewportUniforms &viewport [[buffer(2)]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    float2 pos = positions[vertexID];

    // Map NDC -> texture coordinates with v=0 at the top of the screen
    // corresponding to row 0 of the raw pixel buffer (correct for
    // top-down-stored frames, i.e. needsVerticalFlip == false).
    float2 uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);

    // Frames stored bottom-up (needsVerticalFlip == true) need row 0 of the
    // pixel buffer mapped to the *bottom* of the screen instead.
    if (uniforms.flipVertically != 0) {
        uv.y = 1.0 - uv.y;
    }

    // "Cine Colour" grading's one vertex-stage control: mirrors the U
    // coordinate, exactly the same shape as `flipVertically` above mirroring
    // V. Neutral (`flipHorizontal == 0`) is a no-op.
    if (grading.flipHorizontal != 0) {
        uv.x = 1.0 - uv.x;
    }

    // Zoom/pan: shrink the sampled UV footprint around `viewport`'s center by
    // `1/scale`. At `scale == 1` this is `center + (uv - center) == uv`
    // exactly, a true no-op regardless of `center` — see
    // `ViewportUniforms.swift`'s doc comment for the by-hand proof.
    float2 viewportCenter = float2(viewport.centerX, viewport.centerY);
    uv = viewportCenter + (uv - viewportCenter) / viewport.scale;

    VertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.texCoord = uv;
    return out;
}

/// Linear black/white stretch, applied identically to every channel/mode —
/// debayering (if any) always happens first, in raw sensor units, and this
/// is applied per-channel afterwards.
inline float tonemapValue(float raw, constant ExposureUniforms &uniforms) {
    return clamp((raw - uniforms.blackLevel) / max(1.0, uniforms.whiteLevel - uniforms.blackLevel), 0.0, 1.0);
}

/// Reads `rawTexture` at `coord`, clamping to the texture bounds first —
/// every demosaic neighbor read in this file goes through this helper so
/// none of them can read out of bounds near the image edges.
inline float readClamped(texture2d<ushort, access::read> rawTexture, int2 coord) {
    int2 bounds = int2(int(rawTexture.get_width()) - 1, int(rawTexture.get_height()) - 1);
    int2 clamped = clamp(coord, int2(0, 0), bounds);
    return float(rawTexture.read(uint2(uint(clamped.x), uint(clamped.y))).r);
}

/// The CFA color (`kColorRed`/`kColorGreen`/`kColorBlue`) of the sample at
/// `coord`, given the tile's red-sample parity `(redX, redY)`.
inline uint cfaColorAt(int2 coord, uint redX, uint redY) {
    uint px = uint(coord.x) & 1u;
    uint py = uint(coord.y) & 1u;
    if (px == redX && py == redY) {
        return kColorRed;
    }
    uint blueX = 1u - redX;
    uint blueY = 1u - redY;
    if (px == blueX && py == blueY) {
        return kColorBlue;
    }
    return kColorGreen;
}

/// Per-channel white-balance gain for a CFA color role, looked up from
/// `uniforms` — the pre-demosaic half of `cmCalib`'s decomposition (see
/// `ColorCalibration`'s doc comment in CineKit).
inline float wbGainForColor(uint color, constant ExposureUniforms &uniforms) {
    if (color == kColorRed) { return uniforms.wbGainR; }
    if (color == kColorBlue) { return uniforms.wbGainB; }
    return uniforms.wbGainG;
}

/// Like `readClamped`, but scales the sample by its CFA color role's
/// white-balance gain first. Every demosaic neighbor read in the 3 real
/// demosaic modes goes through this (instead of `readClamped` directly) so
/// white balance is applied to the raw mosaic *before* interpolation, per
/// Vision Research's documented pipeline order. `tileAverage` (Grey Scale)
/// deliberately keeps using plain `readClamped` — white balance must not
/// affect the grayscale modes.
///
/// The gain multiplies the *black-subtracted* (scene-referred) sample, not
/// the raw ADU directly — `raw` still includes the sensor's fixed
/// black-level pedestal, and multiplying that pedestal by a per-channel
/// gain would bake in a spurious additive color bias of
/// `blackLevel * (gain - 1)` per channel (nonzero for every channel whose
/// gain isn't exactly 1). `blackLevel` is added back afterward so this
/// helper's return value stays in the same raw-referenced units every other
/// read in this file uses — every demosaic filter below is a weighted
/// average whose weights sum to 1, and `applyColorMatrix`'s first row also
/// sums to 1 (see `ColorCalibration.decompose`), so the re-added pedestal
/// passes through both stages unchanged and is still subtracted exactly
/// once, later, by `tonemapValue`.
inline float readClampedWB(texture2d<ushort, access::read> rawTexture, int2 coord, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    float v = readClamped(rawTexture, coord);
    uint color = cfaColorAt(coord, redX, redY);
    float gain = wbGainForColor(color, uniforms);
    return (v - uniforms.blackLevel) * gain + uniforms.blackLevel;
}

/// Applies `uniforms.colorMatrix` (row-major 3x3) to a demosaiced RGB
/// triple — the post-demosaic half of `cmCalib`'s decomposition, bringing
/// white-balanced camera-native RGB to Rec. 709.
inline float3 applyColorMatrix(float3 rgb, constant ExposureUniforms &uniforms) {
    float r = uniforms.colorMatrix[0] * rgb.r + uniforms.colorMatrix[1] * rgb.g + uniforms.colorMatrix[2] * rgb.b;
    float g = uniforms.colorMatrix[3] * rgb.r + uniforms.colorMatrix[4] * rgb.g + uniforms.colorMatrix[5] * rgb.b;
    float b = uniforms.colorMatrix[6] * rgb.r + uniforms.colorMatrix[7] * rgb.g + uniforms.colorMatrix[8] * rgb.b;
    return float3(r, g, b);
}

/// The real ITU-R BT.709 opto-electronic transfer function (OETF) — the
/// standard, exact Rec.709 display-encoding curve, not an approximation of
/// one: linear (`4.5 * L`) below `L = 0.018` (avoiding the infinite slope a
/// pure power curve would have at black), and `1.099 * pow(L, 0.45) - 0.099`
/// at and above it. The two pieces meet with equal value (and, by
/// construction of the standard's own constants, equal slope) exactly at
/// `L = 0.018`. `linear` is expected already clamped to [0, 1] by
/// `tonemapValue`, but is clamped again defensively since `pow` on a
/// negative base with a fractional exponent is undefined.
inline float rec709OETF(float linear) {
    float l = clamp(linear, 0.0, 1.0);
    return l < 0.018 ? (4.5 * l) : (1.099 * pow(l, 0.45) - 0.099);
}

/// Applies the real Rec.709 OETF (`rec709OETF`) per channel — the final
/// display-encoding step, applied after the color matrix (which already
/// targets Rec.709 primaries) and the black/white stretch. Replaces the
/// previous `pow(x, 1/uniforms.gamma)` approximation: that plain power law
/// was only ever a stand-in for this exact, piecewise-defined curve, and now
/// that the native view is meant to be a genuine Rec.709 conversion rather
/// than an approximation of one, this uses the real thing.
///
/// `uniforms` is intentionally still accepted here (unused by this exact
/// curve) rather than dropped from the signature — see `ExposureUniforms`'s
/// `gamma` field doc comment (Swift side) for why that field, and this
/// parameter, are being kept rather than removed.
inline float3 applyGamma(float3 rgb, constant ExposureUniforms &uniforms) {
    float3 clamped = clamp(rgb, 0.0, 1.0);
    return float3(rec709OETF(clamped.r), rec709OETF(clamped.g), rec709OETF(clamped.b));
}

/// A standard luma-preserving RGB hue rotation — the exact matrix behind
/// the SVG/CSS Filter Effects `hue-rotate()` primitive (`feColorMatrix
/// type="hueRotate"`), not an approximation of one: a rotation around the
/// (1,1,1) grey axis, so a fully neutral pixel is always fixed by any
/// angle. `degreesValue == 0` makes `cosA == 1`/`sinA == 0`, collapsing
/// every row to a one-hot identity (e.g. row 0 becomes `(0.213 + 0.787,
/// 0.715 - 0.715, 0.072 - 0.072) == (1, 0, 0)`) — a true no-op, not merely
/// visually close to one. Each row's three coefficients always sum to
/// exactly `1` for any angle (the `cosA`/`sinA` terms in each row cancel by
/// construction), which is what keeps a grey input grey at any hue angle.
inline float3 applyHueRotation(float3 rgb, float degreesValue) {
    float radians = degreesValue * (M_PI_F / 180.0);
    float cosA = cos(radians);
    float sinA = sin(radians);

    float r = (0.213 + cosA * 0.787 - sinA * 0.213) * rgb.r
        + (0.715 - cosA * 0.715 - sinA * 0.715) * rgb.g
        + (0.072 - cosA * 0.072 + sinA * 0.928) * rgb.b;
    float g = (0.213 - cosA * 0.213 + sinA * 0.143) * rgb.r
        + (0.715 + cosA * 0.285 + sinA * 0.140) * rgb.g
        + (0.072 - cosA * 0.072 - sinA * 0.283) * rgb.b;
    float b = (0.213 - cosA * 0.213 - sinA * 0.787) * rgb.r
        + (0.715 - cosA * 0.715 + sinA * 0.715) * rgb.g
        + (0.072 + cosA * 0.928 + sinA * 0.072) * rgb.b;

    return float3(r, g, b);
}

// MARK: - Mode 2: Grey Scale (2x2 tile average, no color)

/// Averages the 4 raw samples (the two greens plus red and blue) of the
/// 2x2 CFA tile containing `coord`, so every pixel in that tile reports the
/// identical value — this is what removes the mosaic/checkerboard texture
/// visible in Raw Sensor mode, by construction.
inline float tileAverage(texture2d<ushort, access::read> rawTexture, int2 coord) {
    int tileX = coord.x & ~1;
    int tileY = coord.y & ~1;
    float sum = readClamped(rawTexture, int2(tileX, tileY))
        + readClamped(rawTexture, int2(tileX + 1, tileY))
        + readClamped(rawTexture, int2(tileX, tileY + 1))
        + readClamped(rawTexture, int2(tileX + 1, tileY + 1));
    return sum * 0.25;
}

// MARK: - Mode 3: Nearest Neighbor

/// Nearest same-colored sample to `coord`, searching outward in order of
/// increasing distance (the 4 axis-aligned neighbors at distance 1, then the
/// 4 diagonal neighbors at distance sqrt(2)) — a Bayer tile's period-2
/// repetition guarantees a match is found by the diagonal step at the
/// latest, for either missing channel from any native color.
inline float nearestSameColor(texture2d<ushort, access::read> rawTexture, int2 coord, uint targetColor, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    int2 offsets[8] = {
        int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1),
        int2(1, 1), int2(1, -1), int2(-1, 1), int2(-1, -1)
    };
    for (int i = 0; i < 8; i++) {
        int2 candidate = coord + offsets[i];
        if (cfaColorAt(candidate, redX, redY) == targetColor) {
            return readClampedWB(rawTexture, candidate, redX, redY, uniforms);
        }
    }
    // Unreachable for a real 2x2-periodic Bayer pattern.
    return readClampedWB(rawTexture, coord, redX, redY, uniforms);
}

// MARK: - Mode 4: Bilinear

/// Standard bilinear Bayer demosaic: reconstructs each missing channel as
/// the plain average of its nearest same-colored neighbors (2 neighbors for
/// R/B at a green sample, 4 diagonal neighbors for the opposite color at a
/// red/blue sample, 4 cross neighbors for green at a red/blue sample).
inline float3 bilinearDemosaic(texture2d<ushort, access::read> rawTexture, int2 coord, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    uint native = cfaColorAt(coord, redX, redY);
    float center = readClampedWB(rawTexture, coord, redX, redY, uniforms);

    if (native == kColorGreen) {
        // Column/row parity of this green sample determines which axis
        // carries its Red neighbors and which carries its Blue neighbors.
        bool rowIsRedRow = (uint(coord.y) & 1u) == redY;
        float horizontal = (readClampedWB(rawTexture, coord + int2(-1, 0), redX, redY, uniforms) + readClampedWB(rawTexture, coord + int2(1, 0), redX, redY, uniforms)) * 0.5;
        float vertical = (readClampedWB(rawTexture, coord + int2(0, -1), redX, redY, uniforms) + readClampedWB(rawTexture, coord + int2(0, 1), redX, redY, uniforms)) * 0.5;
        float red = rowIsRedRow ? horizontal : vertical;
        float blue = rowIsRedRow ? vertical : horizontal;
        return float3(red, center, blue);
    }

    // Native Red or Blue: the opposite color is reconstructed from the 4
    // diagonal same-colored neighbors; green from the 4 cross neighbors.
    float diagonal = (readClampedWB(rawTexture, coord + int2(-1, -1), redX, redY, uniforms)
        + readClampedWB(rawTexture, coord + int2(1, -1), redX, redY, uniforms)
        + readClampedWB(rawTexture, coord + int2(-1, 1), redX, redY, uniforms)
        + readClampedWB(rawTexture, coord + int2(1, 1), redX, redY, uniforms)) * 0.25;
    float green = (readClampedWB(rawTexture, coord + int2(-1, 0), redX, redY, uniforms)
        + readClampedWB(rawTexture, coord + int2(1, 0), redX, redY, uniforms)
        + readClampedWB(rawTexture, coord + int2(0, -1), redX, redY, uniforms)
        + readClampedWB(rawTexture, coord + int2(0, 1), redX, redY, uniforms)) * 0.25;

    if (native == kColorRed) {
        return float3(center, green, diagonal);
    }
    return float3(diagonal, green, center);
}

// MARK: - Mode 5: High Quality (Malvar-He-Cutler)

/// H.S. Malvar, L. He, R. Cutler, "High-Quality Linear Interpolation for
/// Demosaicing of Bayer-Patterned Color Images", ICASSP 2004 — a fixed set
/// of gradient-corrected 5x5 linear filters, applied directly to the raw
/// Bayer mosaic (no intermediate bilinear pass). Coefficients below are
/// exactly Fig. 2 of the paper (each filter normalized by /8 as published).
///
/// Only 4 distinct filter shapes are needed (a 5th, "green at red/blue
/// locations", is shared by both of those cases):
///   - `filterGreenAtRedOrBlue`: G at a Red or Blue sample (9 nonzero taps).
///   - `filterA`: R at a Green sample whose row is the Red row and column
///     is the Blue column, and (by the same shape, 90 deg from itself) B at
///     a Green sample whose row is the Blue row and column is the Red
///     column (11 nonzero taps).
///   - `filterB`: `filterA` rotated 90 degrees — R at a Green sample in the
///     opposite row/column orientation, and B in the mirrored case.
///   - `filterOppositeAtOpposite`: R at a Blue sample, or B at a Red sample
///     (rotationally symmetric, 9 nonzero taps).
inline float filterGreenAtRedOrBlue(texture2d<ushort, access::read> rawTexture, int2 c, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    float sum =
        -1.0 * readClampedWB(rawTexture, c + int2(0, -2), redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(0, -1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(-2, 0), redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(-1, 0), redX, redY, uniforms)
        + 4.0 * readClampedWB(rawTexture, c, redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(1, 0), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(2, 0), redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(0, 1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(0, 2), redX, redY, uniforms);
    return sum / 8.0;
}

inline float filterA(texture2d<ushort, access::read> rawTexture, int2 c, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    float sum =
        0.5 * readClampedWB(rawTexture, c + int2(0, -2), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(-1, -1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(1, -1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(-2, 0), redX, redY, uniforms)
        + 4.0 * readClampedWB(rawTexture, c + int2(-1, 0), redX, redY, uniforms)
        + 5.0 * readClampedWB(rawTexture, c, redX, redY, uniforms)
        + 4.0 * readClampedWB(rawTexture, c + int2(1, 0), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(2, 0), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(-1, 1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(1, 1), redX, redY, uniforms)
        + 0.5 * readClampedWB(rawTexture, c + int2(0, 2), redX, redY, uniforms);
    return sum / 8.0;
}

inline float filterB(texture2d<ushort, access::read> rawTexture, int2 c, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    float sum =
        -1.0 * readClampedWB(rawTexture, c + int2(0, -2), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(-1, -1), redX, redY, uniforms)
        + 4.0 * readClampedWB(rawTexture, c + int2(0, -1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(1, -1), redX, redY, uniforms)
        + 0.5 * readClampedWB(rawTexture, c + int2(-2, 0), redX, redY, uniforms)
        + 5.0 * readClampedWB(rawTexture, c, redX, redY, uniforms)
        + 0.5 * readClampedWB(rawTexture, c + int2(2, 0), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(-1, 1), redX, redY, uniforms)
        + 4.0 * readClampedWB(rawTexture, c + int2(0, 1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(1, 1), redX, redY, uniforms)
        - 1.0 * readClampedWB(rawTexture, c + int2(0, 2), redX, redY, uniforms);
    return sum / 8.0;
}

inline float filterOppositeAtOpposite(texture2d<ushort, access::read> rawTexture, int2 c, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    float sum =
        -1.5 * readClampedWB(rawTexture, c + int2(0, -2), redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(-1, -1), redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(1, -1), redX, redY, uniforms)
        - 1.5 * readClampedWB(rawTexture, c + int2(-2, 0), redX, redY, uniforms)
        + 6.0 * readClampedWB(rawTexture, c, redX, redY, uniforms)
        - 1.5 * readClampedWB(rawTexture, c + int2(2, 0), redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(-1, 1), redX, redY, uniforms)
        + 2.0 * readClampedWB(rawTexture, c + int2(1, 1), redX, redY, uniforms)
        - 1.5 * readClampedWB(rawTexture, c + int2(0, 2), redX, redY, uniforms);
    return sum / 8.0;
}

inline float3 malvarHeCutlerDemosaic(texture2d<ushort, access::read> rawTexture, int2 coord, uint redX, uint redY, constant ExposureUniforms &uniforms) {
    uint native = cfaColorAt(coord, redX, redY);
    float center = readClampedWB(rawTexture, coord, redX, redY, uniforms);

    if (native == kColorRed) {
        float g = filterGreenAtRedOrBlue(rawTexture, coord, redX, redY, uniforms);
        float b = filterOppositeAtOpposite(rawTexture, coord, redX, redY, uniforms);
        return float3(center, g, b);
    }
    if (native == kColorBlue) {
        float g = filterGreenAtRedOrBlue(rawTexture, coord, redX, redY, uniforms);
        float r = filterOppositeAtOpposite(rawTexture, coord, redX, redY, uniforms);
        return float3(r, g, center);
    }

    // Native Green: row parity == redY means this row's non-green samples
    // are Red (so R uses filterA's "own row" orientation); the opposite
    // parity means this row's non-green samples are Blue.
    bool rowIsRedRow = (uint(coord.y) & 1u) == redY;
    float r = rowIsRedRow ? filterA(rawTexture, coord, redX, redY, uniforms) : filterB(rawTexture, coord, redX, redY, uniforms);
    float b = rowIsRedRow ? filterB(rawTexture, coord, redX, redY, uniforms) : filterA(rawTexture, coord, redX, redY, uniforms);
    return float3(r, center, b);
}

/// Reads the raw sensor mosaic and, depending on `uniforms.debayerMode`,
/// either shows it directly (mode 1: unchanged from the original
/// single-channel behavior) or demosaics it into full RGB (modes 3-5) —
/// tone-mapping is always applied per-channel *after* debayering, in raw
/// sensor units, exactly matching the original single-channel stretch.
///
/// Uses `.read()` with integer pixel coordinates rather than `.sample()` —
/// r16Uint textures do not support filtered sampling, and demosaicing needs
/// explicit, arbitrary neighbor-coordinate reads regardless.
fragment float4 tonemapFragment(VertexOut in [[stage_in]],
                                 texture2d<ushort, access::read> rawTexture [[texture(0)]],
                                 texture3d<float> lutTexture [[texture(1)]],
                                 constant ExposureUniforms &uniforms [[buffer(0)]],
                                 constant GradingUniforms &grading [[buffer(1)]]) {
    uint width = rawTexture.get_width();
    uint height = rawTexture.get_height();

    uint2 pixelCoord = uint2(uint(in.texCoord.x * float(width)),
                              uint(in.texCoord.y * float(height)));
    pixelCoord.x = min(pixelCoord.x, width - 1);
    pixelCoord.y = min(pixelCoord.y, height - 1);

    if (uniforms.debayerMode == kDebayerRawSensor) {
        // Byte-for-byte the original behavior: no regression.
        float raw = float(rawTexture.read(pixelCoord).r);
        float v = clamp((raw - uniforms.blackLevel) / max(1.0, uniforms.whiteLevel - uniforms.blackLevel), 0.0, 1.0);
        return float4(v, v, v, 1.0);
    }

    int2 coord = int2(int(pixelCoord.x), int(pixelCoord.y));

    if (uniforms.debayerMode == kDebayerGreyScale) {
        float v = tonemapValue(tileAverage(rawTexture, coord), uniforms);
        return float4(v, v, v, 1.0);
    }

    float3 rgb;
    if (uniforms.debayerMode == kDebayerNearestNeighbor) {
        uint native = cfaColorAt(coord, uniforms.cfaRedX, uniforms.cfaRedY);
        float center = readClampedWB(rawTexture, coord, uniforms.cfaRedX, uniforms.cfaRedY, uniforms);
        float r = (native == kColorRed) ? center : nearestSameColor(rawTexture, coord, kColorRed, uniforms.cfaRedX, uniforms.cfaRedY, uniforms);
        float g = (native == kColorGreen) ? center : nearestSameColor(rawTexture, coord, kColorGreen, uniforms.cfaRedX, uniforms.cfaRedY, uniforms);
        float b = (native == kColorBlue) ? center : nearestSameColor(rawTexture, coord, kColorBlue, uniforms.cfaRedX, uniforms.cfaRedY, uniforms);
        rgb = float3(r, g, b);
    } else if (uniforms.debayerMode == kDebayerBilinear) {
        rgb = bilinearDemosaic(rawTexture, coord, uniforms.cfaRedX, uniforms.cfaRedY, uniforms);
    } else if (uniforms.debayerMode == kDebayerHighQuality) {
        rgb = malvarHeCutlerDemosaic(rawTexture, coord, uniforms.cfaRedX, uniforms.cfaRedY, uniforms);
    } else {
        // Unrecognized value — fall back to the best available demosaic
        // rather than rendering raw-scaled garbage as if it were a
        // 3-channel image.
        rgb = malvarHeCutlerDemosaic(rawTexture, coord, uniforms.cfaRedX, uniforms.cfaRedY, uniforms);
    }

    // Color calibration pipeline (only reached by the 3 real demosaic
    // modes above): the color matrix — the post-demosaic half of
    // `cmCalib`'s decomposition — is applied here, still in raw sensor
    // units, before the linear black/white stretch; gamma is the final
    // display-encoding step, after that stretch has normalized to [0, 1].
    rgb = applyColorMatrix(rgb, uniforms);
    float3 stretched = float3(tonemapValue(rgb.r, uniforms), tonemapValue(rgb.g, uniforms), tonemapValue(rgb.b, uniforms));

    // "Cine Colour" grading, stage 1 (linear domain): gain (multiplicative)
    // and pedestal (additive black-lift), each a master value combined with
    // a per-channel offset/multiplier. Neutral defaults (gain*==1,
    // pedestal*==0) make this an exact no-op — see `GradingUniforms`'s doc
    // comment for the by-hand proof.
    float3 gain3 = float3(grading.gain * grading.gainR, grading.gain * grading.gainG, grading.gain * grading.gainB);
    float3 pedestal3 = float3(grading.pedestal + grading.pedestalR, grading.pedestal + grading.pedestalG, grading.pedestal + grading.pedestalB);
    stretched = clamp(stretched * gain3 + pedestal3, 0.0, 1.0);

    float3 encoded = applyGamma(stretched, uniforms);

    // "Cine Colour" grading, stage 2 (display-encoded domain): gamma trim
    // (master + independent R/G/B offset), brightness (additive), hue
    // (luma-preserving rotation), and saturation (luma-preserving lerp) —
    // applied here, after gamma and before the LUT stage below, so a loaded
    // LUT always sees the fully-graded image. Neutral defaults
    // (gammaTrim==1, gammaTrimR==gammaTrimG==gammaTrimB==0, brightness==0,
    // hue==0, saturation==1) make this an exact no-op — see
    // `GradingUniforms`'s doc comment for the by-hand proof.
    float gammaR = max(0.01, grading.gammaTrim + grading.gammaTrimR);
    float gammaGCh = max(0.01, grading.gammaTrim + grading.gammaTrimG);
    float gammaB = max(0.01, grading.gammaTrim + grading.gammaTrimB);
    encoded = float3(
        pow(clamp(encoded.r, 0.0, 1.0), 1.0 / gammaR),
        pow(clamp(encoded.g, 0.0, 1.0), 1.0 / gammaGCh),
        pow(clamp(encoded.b, 0.0, 1.0), 1.0 / gammaB)
    );
    encoded = clamp(encoded + grading.brightness, 0.0, 1.0);
    encoded = clamp(applyHueRotation(encoded, grading.hue), 0.0, 1.0);
    float luma = dot(encoded, float3(0.2126, 0.7152, 0.0722));
    encoded = clamp(luma + (encoded - luma) * grading.saturation, 0.0, 1.0);

    // Optional 3D color-grading LUT (see `LUTTexture`/`CubeLUT` in
    // CinePlayerCore/CineKit), sampled here against `encoded` — the final,
    // gamma-corrected, display-referred RGB — matching standard
    // color-grading practice (LUTs are authored/applied against display-
    // referred values, not linear/raw ones). `lutTexture` always has
    // *something* bound (see `CineRenderer`'s dummy identity texture) even
    // when disabled, so this branch is the only thing that decides whether
    // it's actually sampled.
    if (uniforms.lutEnabled != 0) {
        // Trilinear sampling with a half-texel-centered coordinate: for an
        // NxNxN LUT texture, sample position i in [0, N-1] sits at texture
        // coordinate (i + 0.5) / N, so mapping [0,1] input to [0, N-1]
        // sample space first (`encoded * (N - 1)`) before adding the
        // half-texel offset lands exactly on each corner's texel center at
        // the domain's own boundaries (0.0 and 1.0), avoiding the sampler
        // blending in a neighboring texel's value past the cube's edge.
        // `address::clamp_to_edge` is a second line of defense against the
        // same edge case.
        constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);
        float lutSize = float(lutTexture.get_width());
        float3 clampedEncoded = clamp(encoded, 0.0, 1.0);
        float3 lutCoord = (clampedEncoded * (lutSize - 1.0) + 0.5) / lutSize;
        encoded = lutTexture.sample(lutSampler, lutCoord).rgb;
    }

    return float4(encoded, 1.0);
}
