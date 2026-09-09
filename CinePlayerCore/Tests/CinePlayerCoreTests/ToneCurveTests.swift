import Testing
@testable import CinePlayerCore

struct ToneCurveTests {
    @Test func identityHasExactlyTwoPinnedEndpoints() {
        let identity = ToneCurve.identity
        #expect(identity.points.count == 2)
        #expect(identity.points[0] == ToneCurve.Point(x: 0, y: 0))
        #expect(identity.points[1] == ToneCurve.Point(x: 1, y: 1))
    }

    @Test func identitySamplesToAPerfectRamp() {
        let samples = ToneCurve.identity.sampled(count: 5)
        #expect(samples == [0, 0.25, 0.5, 0.75, 1.0])
    }

    @Test func sampledCountControlsResolutionExactly() {
        #expect(ToneCurve.identity.sampled(count: 2) == [0, 1])
        #expect(ToneCurve.identity.sampled(count: 256).count == 256)
    }

    @Test func realHumpDoesNotOvershootItsOwnPeak() {
        let curve = ToneCurve(points: [
            ToneCurve.Point(x: 0, y: 0.2),
            ToneCurve.Point(x: 0.5, y: 0.8),
            ToneCurve.Point(x: 1, y: 0.2),
        ])
        let samples = curve.sampled(count: 101)
        #expect(samples.allSatisfy { $0 <= 0.8 + 0.0001 })
        #expect(abs(samples[50] - 0.8) < 0.01)
    }

    @Test func realDipDoesNotOvershootItsOwnTrough() {
        let curve = ToneCurve(points: [
            ToneCurve.Point(x: 0, y: 0.8),
            ToneCurve.Point(x: 0.5, y: 0.2),
            ToneCurve.Point(x: 1, y: 0.8),
        ])
        let samples = curve.sampled(count: 101)
        #expect(samples.allSatisfy { $0 >= 0.2 - 0.0001 })
    }

    @Test func sampledCurveIsMonotonicForMonotonicControlPoints() {
        let curve = ToneCurve(points: [
            ToneCurve.Point(x: 0, y: 0),
            ToneCurve.Point(x: 0.25, y: 0.15),
            ToneCurve.Point(x: 0.75, y: 0.85),
            ToneCurve.Point(x: 1, y: 1),
        ])
        let samples = curve.sampled(count: 200)
        for i in 1..<samples.count {
            #expect(samples[i] >= samples[i - 1] - 0.0001, "sample \(i) dipped below its predecessor")
        }
    }

    @Test func addingPointClampsAwayFromTheEndpoints() {
        let curve = ToneCurve.identity.addingPoint(x: 0, y: 0.5).addingPoint(x: 1, y: 0.5)
        #expect(curve.points.count == 4)
        #expect(curve.points.first?.x == 0)
        #expect(curve.points.last?.x == 1)
    }

    @Test func movingAnEndpointOnlyChangesItsY() {
        let curve = ToneCurve.identity.moving(pointAt: 0, toX: 0.9, y: 0.3)
        #expect(curve.points[0].x == 0, "black point's x must stay pinned at 0")
        #expect(curve.points[0].y == 0.3)
    }

    @Test func movingAnInteriorPointCannotCrossItsNeighbors() {
        let curve = ToneCurve(points: [
            ToneCurve.Point(x: 0, y: 0),
            ToneCurve.Point(x: 0.3, y: 0.3),
            ToneCurve.Point(x: 0.7, y: 0.7),
            ToneCurve.Point(x: 1, y: 1),
        ])
        let moved = curve.moving(pointAt: 1, toX: 0.95, y: 0.5)
        #expect(moved.points[1].x < moved.points[2].x, "must not cross its right neighbor")
    }

    @Test func removingAnEndpointIsANoOp() {
        let curve = ToneCurve.identity
        #expect(curve.removing(pointAt: 0) == curve)
        #expect(curve.removing(pointAt: curve.points.count - 1) == curve)
    }

    @Test func removingAnInteriorPointWorks() {
        let curve = ToneCurve.identity.addingPoint(x: 0.5, y: 0.5)
        #expect(curve.points.count == 3)
        let removed = curve.removing(pointAt: 1)
        #expect(removed == ToneCurve.identity)
    }
}
