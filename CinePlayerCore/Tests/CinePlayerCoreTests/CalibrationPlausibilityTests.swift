import Testing
@testable import CineKit
@testable import CinePlayerCore

/// `CalibrationPlausibility` is the heuristic behind the "Color-matrix
/// residual color cast" item in the README's Known Limitations — today it's
/// wired into `cine-diagnostic` but not the live app, and (per that same
/// section) had no automated coverage at all. Every fixture here is a small
/// synthetic `DecodedFrame`, not a real `.cine` sample, so these always run
/// regardless of `CINE_SAMPLES_DIR`.
struct CalibrationPlausibilityTests {
    /// An 8x8 RGGB-tiled frame (four 2x2 tiles in each dimension — well
    /// above `CalibrationPlausibility.stride`'s 4-pixel step, so every CFA
    /// role gets sampled) where every Red/Green/Blue sample is pinned to its
    /// own flat value, black level 0.
    private static func uniformFrame(r: UInt16, g: UInt16, b: UInt16) -> DecodedFrame {
        var pixels = [UInt16](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<8 {
                let value: UInt16
                switch (x & 1, y & 1) {
                case (0, 0): value = r
                case (1, 1): value = b
                default: value = g
                }
                pixels[y * 8 + x] = value
            }
        }
        return DecodedFrame(index: 0, width: 8, height: 8, pixels: pixels, needsVerticalFlip: false)
    }

    private static let neutralCalibration = ColorCalibration(
        whiteBalanceR: 1, whiteBalanceG: 1, whiteBalanceB: 1,
        matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
    )

    @Test func nativeChannelAveragesReadsEachCFARoleIndependently() {
        let frame = Self.uniformFrame(r: 600, g: 500, b: 400)
        let native = CalibrationPlausibility.nativeChannelAverages(frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(native.r == 600)
        #expect(native.g == 500)
        #expect(native.b == 400)
        #expect(native.degenerateFraction == 0)
    }

    @Test func blackLevelIsSubtractedBeforeAveraging() {
        let frame = Self.uniformFrame(r: 600, g: 500, b: 400)
        let native = CalibrationPlausibility.nativeChannelAverages(frame: frame, cfaPhase: .rggb, blackLevel: 100, whiteLevel: 1023)
        #expect(native.r == 500)
        #expect(native.g == 400)
        #expect(native.b == 300)
    }

    @Test func alreadyNeutralFrameHasZeroDegenerateFraction() {
        // Sits well clear of both blackLevel and whiteLevel, so nothing
        // should register as clipped or noise-floor.
        let frame = Self.uniformFrame(r: 512, g: 512, b: 512)
        let native = CalibrationPlausibility.nativeChannelAverages(frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(native.degenerateFraction == 0)
    }

    @Test func mostlyClippedFrameIsFlaggedDegenerate() {
        let frame = Self.uniformFrame(r: 1023, g: 1023, b: 1023)
        let native = CalibrationPlausibility.nativeChannelAverages(frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(native.degenerateFraction == 1)
    }

    @Test func isPlausibleAcceptsACalibrationThatMovesTowardNeutral() {
        // Unbalanced native content (spread 200) corrected by a white
        // balance that brings all three channels to the same value (spread
        // 0) — a textbook working calibration, must never be vetoed.
        let native: (r: Float, g: Float, b: Float) = (600, 500, 400)
        let correcting = ColorCalibration(
            whiteBalanceR: 500.0 / 600.0, whiteBalanceG: 1, whiteBalanceB: 500.0 / 400.0,
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        #expect(CalibrationPlausibility.isPlausible(correcting, for: native))
    }

    @Test func isPlausibleRejectsACalibrationThatMovesAwayFromNeutral() {
        // Already-neutral native content (spread 0) that a bad calibration
        // pushes apart (spread > 0) — exactly the "stale session calibration"
        // failure mode described in ExposureUniforms' own doc comment.
        let native: (r: Float, g: Float, b: Float) = (500, 500, 500)
        let distorting = ColorCalibration(
            whiteBalanceR: 2, whiteBalanceG: 1, whiteBalanceB: 1,
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        #expect(!CalibrationPlausibility.isPlausible(distorting, for: native))
    }

    @Test func isPlausibleAcceptsAnAlreadyNeutralNoOpCalibrationAtTheBoundary() {
        // Doc comment on `isPlausible` calls out `<=` (not `<`) specifically
        // so a calibration whose corrected spread exactly equals the
        // uncorrected spread (the degenerate all-zero case) passes rather
        // than being wrongly vetoed.
        let native: (r: Float, g: Float, b: Float) = (500, 500, 500)
        #expect(CalibrationPlausibility.isPlausible(Self.neutralCalibration, for: native))
    }

    @Test func vetoedCalibrationPassesThroughIdentityWithoutScanningTheFrame() {
        let frame = Self.uniformFrame(r: 0, g: 0, b: 0)
        let result = CalibrationPlausibility.vetoedCalibration(.identity, frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(result == .identity)
    }

    @Test func vetoedCalibrationFallsBackWhenCalibrationHurtsAnAlreadyNeutralFrame() {
        let frame = Self.uniformFrame(r: 500, g: 500, b: 500)
        let distorting = ColorCalibration(
            whiteBalanceR: 2, whiteBalanceG: 1, whiteBalanceB: 1,
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        let result = CalibrationPlausibility.vetoedCalibration(distorting, frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(result != distorting)
    }

    @Test func vetoedCalibrationKeepsACalibrationThatGenuinelyCorrectsTheFrame() {
        let frame = Self.uniformFrame(r: 600, g: 500, b: 400)
        let correcting = ColorCalibration(
            whiteBalanceR: 500.0 / 600.0, whiteBalanceG: 1, whiteBalanceB: 500.0 / 400.0,
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        let result = CalibrationPlausibility.vetoedCalibration(correcting, frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(result == correcting)
    }

    @Test func vetoedCalibrationTrustsCalibrationOnAnAlmostFullyClippedFrame() {
        // The documented blind spot: a ~99%-clipped frame gives the
        // gray-world check nothing real to measure, so the recorded
        // calibration is trusted even though it would otherwise be vetoed.
        let frame = Self.uniformFrame(r: 1023, g: 1023, b: 1023)
        let distorting = ColorCalibration(
            whiteBalanceR: 2, whiteBalanceG: 1, whiteBalanceB: 1,
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        let result = CalibrationPlausibility.vetoedCalibration(distorting, frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(result == distorting)
    }
}
