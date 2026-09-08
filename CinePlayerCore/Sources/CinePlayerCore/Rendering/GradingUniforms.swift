import Foundation

/// Uniform parameters for the "Cine Colour" grading stage — phase 1 of a
/// larger planned grading panel (modeled on a reference tool's own color
/// panel; see the project's own backlog notes for the fuller set of controls
/// still to come — Flare/Toe/Color-Temp/WBCC/Log-Modes/Exposure-Index/a
/// tone-curve widget are all later phases, not here).
///
/// Deliberately a brand-new struct, bound to its own new buffer index,
/// rather than more fields added to `ExposureUniforms`: `ExposureUniforms` is
/// already mirrored byte-for-byte across 3 files (this package's Swift copy,
/// plus 2 separate `Tonemap.metal` copies — see that struct's own doc
/// comment for the existing gotcha), and growing it further would multiply
/// the risk of a subtle transcription bug across every existing field, not
/// just the new ones. This struct is purely additive.
///
/// Memory layout must exactly mirror the `GradingUniforms` struct declared in
/// **both** copies of `Shaders/Tonemap.metal` (this package's, and
/// `CinePlayerApp`'s separate copy — they must stay byte-identical to each
/// other) — sixteen 4-byte fields, no padding, same field order.
///
/// Pipeline placement (see `Tonemap.metal`'s `tonemapFragment` for the exact
/// insertion points):
///   - `gain`/`gainR`/`gainG`/`gainB` and `pedestal`/`pedestalR`/`pedestalG`/
///     `pedestalB` apply in the LINEAR, normalized-to-[0,1] domain — right
///     after the existing per-channel `tonemapValue` black/white stretch,
///     before `applyGamma`. A gain multiplies, a pedestal adds, both clamped
///     back to [0,1] afterward.
///   - `gammaTrim`/`gammaTrimR`/`gammaTrimG`/`gammaTrimB`, `brightness`,
///     `hue`, and `saturation` apply in the DISPLAY-ENCODED domain — after
///     `applyGamma` produces the real Rec.709-encoded RGB, but before the
///     existing 3D LUT sampling stage, so a loaded LUT always sees the
///     fully-graded image (matching how a real grading pipeline feeds a
///     look-LUT the already-graded result, not a pre-grade one). `hue`
///     applies a standard luma-preserving RGB rotation (the same matrix
///     used by the SVG/CSS `hue-rotate()` filter — see `applyHueRotation`
///     in `Tonemap.metal`), applied before the saturation lerp.
///   - `flipHorizontal` affects vertex UV computation in `tonemapVertex`,
///     mirroring the existing `ExposureUniforms.flipVertically` handling
///     exactly (mirrors the U coordinate instead of V).
///
/// **`.identity` must render pixel-identically to no grading at all** — this
/// is this whole feature's single non-negotiable requirement: every existing
/// user of this app renders with these controls untouched, so a regression
/// here would silently degrade the live view and every export path for
/// everyone, not just people who touch the new sliders. Verified by hand
/// (and independently, live, against the real renderer): with every field at
/// its default, `gain3 == (1,1,1)` and `pedestal3 == (0,0,0)` so the linear
/// stretch is unchanged; `gammaTrim == 1`, `gammaTrimR == gammaTrimG ==
/// gammaTrimB == 0` so each channel's trim exponent `1/1.0 == 1.0`, making
/// `pow(x, 1.0) == x` a true no-op (modulo the same clamp the code already
/// performs); `brightness == 0` is a no-op add; `hue == 0` makes
/// `applyHueRotation`'s rotation angle exactly `0`, so its matrix is the
/// identity matrix by construction (`cos(0) == 1`, `sin(0) == 0`); `saturation
/// == 1` makes `luma + (encoded - luma) * 1 == encoded` exactly;
/// `flipHorizontal == 0` leaves `tonemapVertex`'s UV computation untouched.
/// Every one of these is exact float arithmetic (no
/// accumulated rounding beyond what the existing pipeline already does), so
/// `.identity` is a true no-op, not merely a visually-close approximation of
/// one.
///
public struct GradingUniforms: Equatable, Sendable {
    /// Display-encoded-domain additive brightness, applied after gamma
    /// trim, before saturation. Neutral at `0`.
    public var brightness: Float
    /// Linear-domain master gain multiplier, combined with the per-channel
    /// gain below (`gain * gainR`, etc.) before being applied. Neutral at
    /// `1`.
    public var gain: Float
    public var gainR: Float
    public var gainG: Float
    public var gainB: Float
    /// Linear-domain master pedestal (black-lift) offset, combined with the
    /// per-channel pedestal below (`pedestal + pedestalR`, etc.) before
    /// being applied. Neutral at `0`.
    public var pedestal: Float
    public var pedestalR: Float
    public var pedestalG: Float
    public var pedestalB: Float
    /// Display-encoded-domain master gamma trim — the exponent applied is
    /// `1.0 / (gammaTrim + channelOffset)`, clamped to a minimum of `0.01` to
    /// avoid a divide-by-zero/negative-exponent degenerate. Neutral at `1`
    /// (exponent `1.0`, a true no-op).
    public var gammaTrim: Float
    /// Red-channel gamma trim offset, added to `gammaTrim` before the
    /// per-channel exponent is computed. Neutral at `0`.
    public var gammaTrimR: Float
    /// Blue-channel gamma trim offset. Neutral at `0`.
    public var gammaTrimB: Float
    /// Green-channel gamma trim offset — added later than `gammaTrimR`/
    /// `gammaTrimB` (both this struct's field order and the Metal buffer
    /// layout are append-only for backward compatibility), but applied at
    /// exactly the same pipeline stage. Independent per-channel gamma for
    /// all three channels matches Phantom PCC's own "Advanced Adjustments"
    /// panel, which exposes full R/G/B gamma — this phase originally
    /// exposed only a master + R/B offset on the (mistaken) assumption that
    /// green was never independently trimmed in the reference tool this
    /// panel is modeled on. Neutral at `0`.
    public var gammaTrimG: Float
    /// Display-encoded-domain saturation multiplier, applied last (after
    /// brightness and hue): `luma + (encoded - luma) * saturation`, where
    /// `luma` is the Rec.709 luma weighting of the (already
    /// brightness/hue-adjusted) encoded color. `0` fully desaturates to
    /// grayscale, `1` (neutral) is a no-op, values above `1` boost
    /// saturation.
    public var saturation: Float
    /// Display-encoded-domain hue rotation, in degrees — a standard
    /// luma-preserving RGB rotation (see `applyHueRotation` in
    /// `Tonemap.metal`), applied after brightness and before saturation.
    /// Matches Phantom PCC's own "Hue" control. Neutral at `0` (a true
    /// identity rotation).
    public var hue: Float
    /// 0 or 1. Non-zero mirrors the U texture coordinate in `tonemapVertex`
    /// — the first Flip control exposed in this app's UI (the existing
    /// `ExposureUniforms.flipVertically` has always been shader-only, for
    /// frame-orientation correctness, never a user-facing toggle).
    public var flipHorizontal: UInt32

    /// The neutral/default grade — every field at the value that makes its
    /// corresponding shader stage a true no-op (see this struct's own doc
    /// comment for the full derivation). `CineDocumentModel.grading` starts
    /// here and is reset back to this on every `open(url:)` (a creative
    /// grade is inherently per-shot, unlike the Debayer-mode/Color-Matrix
    /// preferences that persist across files — see that type's own doc
    /// comment).
    public static let identity = GradingUniforms(
        brightness: 0, gain: 1, gainR: 1, gainG: 1, gainB: 1,
        pedestal: 0, pedestalR: 0, pedestalG: 0, pedestalB: 0,
        gammaTrim: 1, gammaTrimR: 0, gammaTrimB: 0, gammaTrimG: 0,
        saturation: 1, hue: 0, flipHorizontal: 0
    )

    public init(
        brightness: Float,
        gain: Float,
        gainR: Float,
        gainG: Float,
        gainB: Float,
        pedestal: Float,
        pedestalR: Float,
        pedestalG: Float,
        pedestalB: Float,
        gammaTrim: Float,
        gammaTrimR: Float,
        gammaTrimB: Float,
        gammaTrimG: Float,
        saturation: Float,
        hue: Float,
        flipHorizontal: UInt32
    ) {
        self.brightness = brightness
        self.gain = gain
        self.gainR = gainR
        self.gainG = gainG
        self.gainB = gainB
        self.pedestal = pedestal
        self.pedestalR = pedestalR
        self.pedestalG = pedestalG
        self.pedestalB = pedestalB
        self.gammaTrim = gammaTrim
        self.gammaTrimR = gammaTrimR
        self.gammaTrimB = gammaTrimB
        self.gammaTrimG = gammaTrimG
        self.saturation = saturation
        self.hue = hue
        self.flipHorizontal = flipHorizontal
    }
}
