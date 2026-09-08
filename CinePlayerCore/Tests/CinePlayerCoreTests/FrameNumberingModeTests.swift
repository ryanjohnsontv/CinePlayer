import Testing
@testable import CinePlayerCore

/// Pure formatting logic, no `.cine` file needed — every case below is
/// checked against the exact formula in `FrameNumberingMode`'s own doc
/// comment rather than against a real capture.
struct FrameNumberingModeTests {
    @Test func plainIsOneBased() {
        #expect(FrameNumberingMode.formattedFrameNumber(0, mode: .plain, frameCount: 10, reviewFPS: 30, firstImageNo: 0) == "1")
        #expect(FrameNumberingMode.formattedFrameNumber(9, mode: .plain, frameCount: 10, reviewFPS: 30, firstImageNo: 0) == "10")
    }

    @Test func phantomIsFirstImageNoOffsetAndCanBeNegative() {
        // Mirrors the real "Frame -2,658 / -2,209" readout the app shows for
        // a trigger-relative file whose recording starts well before frame 0.
        #expect(FrameNumberingMode.formattedFrameNumber(0, mode: .phantom, frameCount: 450, reviewFPS: 30, firstImageNo: -2658) == "-2,658")
        #expect(FrameNumberingMode.formattedFrameNumber(449, mode: .phantom, frameCount: 450, reviewFPS: 30, firstImageNo: -2658) == "-2,209")
    }

    @Test func smpteWalksAtTheNominalReviewRateNotCaptureRate() {
        // nominalFPS = round(29.97) = 30, so frame 29 is the last frame of
        // second 0 and frame 30 rolls into second 1 — the fractional capture
        // rate only shows up in the trailing "@29.97" label.
        let fps = 29.97
        #expect(FrameNumberingMode.formattedFrameNumber(0, mode: .smpte, frameCount: 100, reviewFPS: fps, firstImageNo: 0) == "00:00:00:00@29.97")
        #expect(FrameNumberingMode.formattedFrameNumber(29, mode: .smpte, frameCount: 100, reviewFPS: fps, firstImageNo: 0) == "00:00:00:29@29.97")
        #expect(FrameNumberingMode.formattedFrameNumber(30, mode: .smpte, frameCount: 100, reviewFPS: fps, firstImageNo: 0) == "00:00:01:00@29.97")
    }

    @Test func smpteRollsOverHoursAndMinutesCorrectly() {
        // 1 hour, 1 minute, 1 second, frame 5 at a nominal 30fps.
        let index = ((3600 + 60 + 1) * 30) + 5
        #expect(FrameNumberingMode.formattedFrameNumber(index, mode: .smpte, frameCount: index + 1, reviewFPS: 30, firstImageNo: 0) == "01:01:01:05@30")
    }

    @Test func counterTextPairsCurrentWithLastFrameExceptInSMPTEMode() {
        #expect(FrameNumberingMode.counterText(mode: .plain, currentIndex: 0, frameCount: 10, reviewFPS: 30, firstImageNo: 0) == "Frame 1 / 10")
        #expect(FrameNumberingMode.counterText(mode: .phantom, currentIndex: 0, frameCount: 450, reviewFPS: 30, firstImageNo: -2658) == "Frame -2,658 / -2,209")
        // SMPTE is self-contained timecode, never a "current / last" pair.
        #expect(FrameNumberingMode.counterText(mode: .smpte, currentIndex: 0, frameCount: 10, reviewFPS: 30, firstImageNo: 0) == "00:00:00:00@30")
    }
}
