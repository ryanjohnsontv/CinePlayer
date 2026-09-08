import Testing
import CineKit
@testable import CinePlayerCore

/// Locks in `CFAPhase.forCFAPattern`'s mapping — picked by empirical
/// calibration against real sample footage (see that function's own doc
/// comment) rather than derived from anything checkable by inspection, so a
/// silent change here would reintroduce color fringing with no compiler
/// warning to catch it.
struct CFAPhaseTests {
    @Test func absentOrMonochromeCFAFallsBackToRGGB() {
        #expect(CFAPhase.forCFAPattern(nil) == .rggb)
        #expect(CFAPhase.forCFAPattern(CFAPattern.none) == .rggb)
    }

    @Test func knownCFAPatternsMapToTheirCalibratedPhase() {
        #expect(CFAPhase.forCFAPattern(.bayer) == .gbrg)
        #expect(CFAPhase.forCFAPattern(.bayerFlip) == .rggb)
        #expect(CFAPhase.forCFAPattern(.vri) == .gbrg)
        #expect(CFAPhase.forCFAPattern(.vriV6) == .bggr)
    }

    @Test func redOffsetMatchesEachPhasesNamedCorner() {
        #expect(CFAPhase.rggb.redOffset == (x: 0, y: 0))
        #expect(CFAPhase.grbg.redOffset == (x: 1, y: 0))
        #expect(CFAPhase.gbrg.redOffset == (x: 0, y: 1))
        #expect(CFAPhase.bggr.redOffset == (x: 1, y: 1))
    }
}
