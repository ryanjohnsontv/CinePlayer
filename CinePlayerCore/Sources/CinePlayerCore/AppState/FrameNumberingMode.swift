import Foundation

/// The shared frame-numbering convention driving every place a frame number
/// is shown to the user: `PlaybackToolbar`'s "Frame N / Total" counter, the
/// on-video `MetadataOverlayView` HUD's own counter row, and
/// `ScrubberView`'s three left/center/right readouts. One persisted,
/// app-wide preference (see `CineDocumentModel.frameNumberingMode`) drives
/// all three consistently, rather than each view picking its own convention.
///
/// This type and its two static formatting functions below are deliberately
/// free functions on plain parameters, not methods on `PlaybackController` —
/// see `CineDocumentModel.frameNumberingMode`'s own doc comment for why.
public enum FrameNumberingMode: UInt32, CaseIterable, Sendable {
    /// Plain 1-based sequential index — today's pre-existing "Frame N /
    /// Total" convention, unchanged.
    case plain = 0
    /// SMPTE-style `HH:MM:SS:FF@fps` timecode, walked at the app's standard
    /// review rate (`reviewFPS`) — see `formattedFrameNumber`'s own doc
    /// comment for the exact formula and its provenance.
    case smpte = 1
    /// Trigger-relative numbering: `firstImageNo`-offset, i.e. the same
    /// convention Vision Research's own cameras use (frame 0 is the trigger
    /// point, so frames captured before the trigger are negative).
    case phantom = 2

    /// A short, user-facing label for the toolbar's mode picker.
    public var displayName: String {
        switch self {
        case .plain: return "Sequential"
        case .smpte: return "SMPTE Timecode"
        case .phantom: return "Trigger-Relative"
        }
    }

    /// Formats a single frame `index` (always the plain 0-based index used
    /// internally by `PlaybackController`, e.g. `currentFrameIndex` or
    /// `frameCount - 1` — never itself already trigger-relative) under
    /// `mode`.
    ///
    /// - `.plain`: 1-based index.
    /// - `.smpte`: `HH:MM:SS:FF@fps`, moved verbatim (only generalized to an
    ///   arbitrary `index` rather than always `currentFrameIndex`) from what
    ///   used to be `MetadataOverlayView.timecodeText`. The nominal frame
    ///   rate is `reviewFPS` rounded to the nearest integer (SMPTE's `FF`
    ///   field counts against a nominal *integer* rate, never a fractional
    ///   one), the `FF` field's zero-padding width is sized to that nominal
    ///   rate, and the `@fps` suffix is the raw (unrounded) `reviewFPS` with
    ///   0-3 fraction digits and no thousands grouping. Deliberately the
    ///   review rate, never the file's native capture rate — see the
    ///   original `timecodeText` doc comment (now folded into this one) for
    ///   why: per Glue Tools' "Phantom Cine Toolkit for macOS" manual, real
    ///   SMPTE 12M timecode cannot represent frame rates above 30fps at all,
    ///   so Vision Research's own documented convention is to derive
    ///   timecode from a standard review-rate walk-through regardless of how
    ///   fast the footage was actually captured.
    /// - `.phantom`: `firstImageNo + index`, comma-grouped via
    ///   `.formatted()` (can be negative) — the exact math `ScrubberView`'s
    ///   readouts already used before this type existed.
    public static func formattedFrameNumber(
        _ index: Int,
        mode: FrameNumberingMode,
        frameCount: Int,
        reviewFPS: Double,
        firstImageNo: Int
    ) -> String {
        switch mode {
        case .plain:
            return "\(index + 1)"
        case .smpte:
            let nominalFPS = max(1, Int(reviewFPS.rounded()))
            let totalSeconds = index / nominalFPS
            let frameWithinSecond = index % nominalFPS
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            let frameDigits = String(nominalFPS - 1).count
            let fpsLabel = reviewFPS
                .formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
            return String(
                format: "%02d:%02d:%02d:%0\(frameDigits)d@%@",
                hours, minutes, seconds, frameWithinSecond, fpsLabel
            )
        case .phantom:
            return (firstImageNo + index).formatted()
        }
    }

    /// The full counter string shared by both `PlaybackToolbar` and
    /// `MetadataOverlayView`, so neither duplicates this composition logic.
    ///
    /// - `.plain`/`.phantom`: `"Frame <current> / <last>"`, reusing
    ///   `formattedFrameNumber` for both `currentIndex` and the last frame
    ///   (`frameCount - 1`) under the same mode — for `.phantom` this
    ///   naturally produces e.g. `"Frame -2,984 / -2,268"`, mirroring
    ///   `ScrubberView`'s own left/right convention.
    /// - `.smpte`: just the single timecode for `currentIndex` — no `/`,
    ///   since a timecode is self-contained and isn't paired with a second
    ///   timecode the way a frame count is.
    public static func counterText(
        mode: FrameNumberingMode,
        currentIndex: Int,
        frameCount: Int,
        reviewFPS: Double,
        firstImageNo: Int
    ) -> String {
        switch mode {
        case .smpte:
            return formattedFrameNumber(
                currentIndex, mode: mode, frameCount: frameCount, reviewFPS: reviewFPS, firstImageNo: firstImageNo
            )
        case .plain, .phantom:
            let current = formattedFrameNumber(
                currentIndex, mode: mode, frameCount: frameCount, reviewFPS: reviewFPS, firstImageNo: firstImageNo
            )
            let last = formattedFrameNumber(
                frameCount - 1, mode: mode, frameCount: frameCount, reviewFPS: reviewFPS, firstImageNo: firstImageNo
            )
            return "Frame \(current) / \(last)"
        }
    }
}
