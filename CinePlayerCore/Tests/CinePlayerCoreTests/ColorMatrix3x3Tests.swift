import Testing
@testable import CinePlayerCore

struct ColorMatrix3x3Tests {
    @Test func identityMatchesRealIdentityMatrix() {
        let m = ColorMatrix3x3.identity
        #expect(m.m00 == 1 && m.m01 == 0 && m.m02 == 0)
        #expect(m.m10 == 0 && m.m11 == 1 && m.m12 == 0)
        #expect(m.m20 == 0 && m.m21 == 0 && m.m22 == 1)
    }

    @Test func rowMajorInitPreservesFieldOrder() {
        let m = ColorMatrix3x3(rowMajor: [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(m.m00 == 1 && m.m01 == 2 && m.m02 == 3)
        #expect(m.m10 == 4 && m.m11 == 5 && m.m12 == 6)
        #expect(m.m20 == 7 && m.m21 == 8 && m.m22 == 9)
    }
}
