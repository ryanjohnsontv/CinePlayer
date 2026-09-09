import Testing
@testable import CinePlayerCore

/// `.identity`'s exact field values ARE the contract described in
/// `GradingUniforms`'s own doc comment ("must render pixel-identically to no
/// grading at all") — this locks that data in against silent drift, e.g. a
/// future field addition accidentally defaulting to a non-neutral value.
struct GradingUniformsTests {
    @Test func identityIsNeutralOnEveryField() {
        let identity = GradingUniforms.identity
        #expect(identity.brightness == 0)
        #expect(identity.gain == 1)
        #expect(identity.gainR == 1)
        #expect(identity.gainG == 1)
        #expect(identity.gainB == 1)
        #expect(identity.pedestal == 0)
        #expect(identity.pedestalR == 0)
        #expect(identity.pedestalG == 0)
        #expect(identity.pedestalB == 0)
        #expect(identity.gammaTrim == 1)
        #expect(identity.gammaTrimR == 0)
        #expect(identity.gammaTrimG == 0)
        #expect(identity.gammaTrimB == 0)
        #expect(identity.saturation == 1)
        #expect(identity.hue == 0)
        #expect(identity.flipHorizontal == 0)
        #expect(identity.flipVertical == 0)
        #expect(identity.exposureIndexGain == 1)
    }
}
