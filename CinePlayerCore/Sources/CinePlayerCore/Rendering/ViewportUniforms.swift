import Foundation

/// Uniform parameters for the video viewport's on-screen zoom/pan transform —
/// purely a vertex-stage concern (`tonemapFragment` never reads it, unlike
/// `ExposureUniforms`/`GradingUniforms`, both of which every stage needs), so
/// this is bound only to `tonemapVertex`, at its own new buffer index (2).
///
/// Deliberately a third, brand-new struct rather than more fields on
/// `ExposureUniforms`/`GradingUniforms` — same reasoning as
/// `GradingUniforms`'s own doc comment: those two are already mirrored
/// byte-for-byte across 3 files, and zoom/pan is a different concern
/// (viewport presentation, not exposure or per-clip color grading) that has
/// nothing to do with either.
///
/// Memory layout must exactly mirror the `ViewportUniforms` struct declared
/// in **both** copies of `Shaders/Tonemap.metal` (this package's, and
/// `CinePlayerApp`'s separate copy — they must stay byte-identical to each
/// other, same gotcha as `ExposureUniforms`/`GradingUniforms`) — three
/// 4-byte fields, no padding, same field order.
///
/// **`.identity` must render pixel-identically to no viewport transform at
/// all** — `tonemapVertex`'s UV remap is `center + (uv - center) / scale`,
/// which at `scale == 1` is `center + (uv - center) == uv` exactly,
/// regardless of `center`'s value. Every existing render call site (there
/// are several: the live view, `cine-diagnostic`, `FrameExporter`,
/// `DNGExporter`, `CinePreviewImage`) keeps rendering exactly as before by
/// simply not passing this parameter at all.
public struct ViewportUniforms: Equatable, Sendable {
    /// Zoom multiplier on top of "fit" (the whole frame visible — this
    /// feature's only behavior before it existed, and still `scale == 1`'s
    /// exact behavior). `2` samples/shows a quarter of the frame's area
    /// (half width, half height) magnified to fill the same viewport, and so
    /// on. Neutral at `1`.
    public var scale: Float
    /// Where the zoomed viewport is centered, in the frame's own normalized
    /// (0...1, 0...1) texture space — `(0.5, 0.5)` is the frame's center.
    /// Mathematically inert at `scale == 1` (see this struct's own doc
    /// comment for why), so its value doesn't matter until zoomed in.
    public var centerX: Float
    public var centerY: Float

    public static let identity = ViewportUniforms(scale: 1, centerX: 0.5, centerY: 0.5)

    public init(scale: Float, centerX: Float, centerY: Float) {
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
    }
}
