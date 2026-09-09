import Testing
@testable import CineKit
@testable import CinePlayerCore

/// Synthetic-fixture tests for `CalibrationPlausibility` — always run
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

    @Test func nativeChannelTriplesReturnsOneTriplePerSampledTile() {
        let frame = Self.uniformFrame(r: 600, g: 500, b: 400)
        let triples = CalibrationPlausibility.nativeChannelTriples(frame: frame, cfaPhase: .rggb, blackLevel: 0)
        // An 8x8 frame sampled on `stride`'s 4-pixel grid visits (0,0) and
        // (4,0)/(0,4)/(4,4) — 4 tiles — each producing exactly one triple,
        // and every tile in this uniform fixture reads the same values.
        #expect(triples.count == 4)
        for triple in triples {
            #expect(triple.r == 600)
            #expect(triple.g == 500)
            #expect(triple.b == 400)
        }
    }

    @Test func nativeChannelTriplesSubtractsBlackLevel() {
        let frame = Self.uniformFrame(r: 600, g: 500, b: 400)
        let triples = CalibrationPlausibility.nativeChannelTriples(frame: frame, cfaPhase: .rggb, blackLevel: 100)
        #expect(triples.allSatisfy { $0.r == 500 && $0.g == 400 && $0.b == 300 })
    }

    @Test func clippingFractionIsZeroForANeutralCalibration() {
        let triples: [(r: Float, g: Float, b: Float)] = [(600, 500, 400), (100, 500, 900)]
        #expect(CalibrationPlausibility.clippingFraction(Self.neutralCalibration, for: triples) == 0)
    }

    @Test func clippingFractionCountsLocationsPushedNegative() {
        let clippingMatrix = ColorCalibration(
            whiteBalanceR: 1, whiteBalanceG: 1, whiteBalanceB: 1,
            matrix: [1, 0, 0, 0, 1, 0, 0, -1, 1]
        )
        let triples: [(r: Float, g: Float, b: Float)] = [
            (100, 100, 100),
            (100, 200, 50),
            (100, 50, 200),
        ]
        #expect(CalibrationPlausibility.clippingFraction(clippingMatrix, for: triples) == Float(1) / 3)
    }

    @Test func clippingFractionIsZeroForEmptyTriples() {
        #expect(CalibrationPlausibility.clippingFraction(Self.neutralCalibration, for: []) == 0)
    }

    /// Like `uniformFrame`, but each tile gets its own r/g/b pattern.
    private static func tiledFrame(patterns: [(r: UInt16, g: UInt16, b: UInt16)]) -> DecodedFrame {
        let width = patterns.count * 4
        let height = 4
        var pixels = [UInt16](repeating: 0, count: width * height)
        for (tileIndex, pattern) in patterns.enumerated() {
            let originX = tileIndex * 4
            for y in 0..<2 {
                for x in 0..<2 {
                    let value: UInt16
                    switch (x, y) {
                    case (0, 0): value = pattern.r
                    case (1, 1): value = pattern.b
                    default: value = pattern.g
                    }
                    pixels[y * width + (originX + x)] = value
                }
            }
        }
        return DecodedFrame(index: 0, width: width, height: height, pixels: pixels, needsVerticalFlip: false)
    }

    @Test func vetoedCalibrationCatchesACalibrationThatClipsLocallyDespitePassingOnAverage() {
        // Passes on frame-average alone, but one of three tiles clips
        // locally — must still be vetoed.
        let frame = Self.tiledFrame(patterns: [
            (r: 100, g: 300, b: 100),
            (r: 300, g: 100, b: 100),
            (r: 100, g: 100, b: 300),
        ])
        let clippingMatrix = ColorCalibration(
            whiteBalanceR: 1, whiteBalanceG: 1, whiteBalanceB: 1,
            matrix: [1, 0, 0, 0, 1, 0, 1, -1, 1]
        )
        let native = CalibrationPlausibility.nativeChannelAverages(frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(CalibrationPlausibility.isPlausible(clippingMatrix, for: (native.r, native.g, native.b)))
        let result = CalibrationPlausibility.vetoedCalibration(clippingMatrix, frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023)
        #expect(result != clippingMatrix)
    }

    @Test func vetoedCalibrationSelectsAKnownCameraFallbackByHardwareVersion() {
        let frame = Self.uniformFrame(r: 500, g: 500, b: 500)
        let distorting = ColorCalibration(
            whiteBalanceR: 2, whiteBalanceG: 1, whiteBalanceB: 1,
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        let unknownCameraResult = CalibrationPlausibility.vetoedCalibration(
            distorting, frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023, cameraVersion: nil
        )
        let veoResult = CalibrationPlausibility.vetoedCalibration(
            distorting, frame: frame, cfaPhase: .rggb, blackLevel: 0, whiteLevel: 1023, cameraVersion: 7011
        )
        #expect(unknownCameraResult != distorting)
        #expect(veoResult != distorting)
        #expect(unknownCameraResult != veoResult)
    }
}
