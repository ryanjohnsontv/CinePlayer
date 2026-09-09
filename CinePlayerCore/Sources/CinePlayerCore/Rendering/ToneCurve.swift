import Foundation

/// A multi-point tone curve, baked to a lookup texture by `ToneCurveTexture`.
public struct ToneCurve: Equatable, Sendable {
    /// A control point in normalized `[0, 1]` curve space.
    public struct Point: Equatable, Sendable, Comparable {
        public var x: Float
        public var y: Float

        public init(x: Float, y: Float) {
            self.x = x
            self.y = y
        }

        public static func < (lhs: Point, rhs: Point) -> Bool { lhs.x < rhs.x }
    }

    /// Always at least the two pinned endpoints (x == 0, x == 1), sorted by x.
    public private(set) var points: [Point]

    public static let identity = ToneCurve(points: [Point(x: 0, y: 0), Point(x: 1, y: 1)])

    public init(points: [Point]) {
        precondition(points.count >= 2, "ToneCurve needs at least a black and white point")
        var byX: [Float: Point] = [:]
        for point in points { byX[point.x] = point }
        self.points = byX.values.sorted()
    }

    /// Adds an interior point, clamped away from the endpoints.
    public func addingPoint(x: Float, y: Float) -> ToneCurve {
        let epsilon: Float = 0.001
        let clampedX = min(max(x, epsilon), 1 - epsilon)
        let clampedY = min(max(y, 0), 1)
        var updated = points
        updated.removeAll { $0.x == clampedX }
        updated.append(Point(x: clampedX, y: clampedY))
        return ToneCurve(points: updated)
    }

    /// Moves the point at `index`; endpoints only move in y, interior points
    /// stay strictly between their neighbors.
    public func moving(pointAt index: Int, toX x: Float, y: Float) -> ToneCurve {
        guard points.indices.contains(index) else { return self }
        let isEndpoint = index == 0 || index == points.count - 1
        let clampedY = min(max(y, 0), 1)
        var updated = points
        if isEndpoint {
            updated[index].y = clampedY
        } else {
            let epsilon: Float = 0.001
            let lowerBound = updated[index - 1].x + epsilon
            let upperBound = updated[index + 1].x - epsilon
            updated[index] = Point(x: min(max(x, lowerBound), upperBound), y: clampedY)
        }
        var result = self
        result.points = updated
        return result
    }

    /// Removes the interior point at `index`; a no-op for an endpoint.
    public func removing(pointAt index: Int) -> ToneCurve {
        guard points.indices.contains(index), index != 0, index != points.count - 1 else { return self }
        var updated = points
        updated.remove(at: index)
        return ToneCurve(points: updated)
    }

    /// Bakes this curve to `count` evenly-spaced output levels using a
    /// monotone cubic Hermite spline (Fritsch-Carlson), which can't
    /// overshoot past a control point's own value.
    public func sampled(count: Int) -> [Float] {
        precondition(count >= 2, "need at least 2 samples")
        let tangents = Self.fritschCarlsonTangents(points)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let x = Float(i) / Float(count - 1)
            result[i] = Self.evaluate(points, tangents: tangents, at: x)
        }
        return result
    }

    private static func fritschCarlsonTangents(_ points: [Point]) -> [Float] {
        let n = points.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }

        var secants = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            secants[i] = dx > 0 ? (points[i + 1].y - points[i].y) / dx : 0
        }

        var tangents = [Float](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            if secants[i - 1] == 0 || secants[i] == 0 || (secants[i - 1] > 0) != (secants[i] > 0) {
                // Local extremum/flat run — zero tangent avoids overshoot.
                tangents[i] = 0
            } else {
                tangents[i] = (secants[i - 1] + secants[i]) / 2
            }
        }

        // Fritsch-Carlson monotonicity clamp.
        for i in 0..<(n - 1) {
            guard secants[i] != 0 else {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let a = tangents[i] / secants[i]
            let b = tangents[i + 1] / secants[i]
            let magnitude = (a * a + b * b).squareRoot()
            if magnitude > 3 {
                let scale = 3 / magnitude
                tangents[i] = scale * a * secants[i]
                tangents[i + 1] = scale * b * secants[i]
            }
        }
        return tangents
    }

    private static func evaluate(_ points: [Point], tangents: [Float], at x: Float) -> Float {
        guard let first = points.first, let last = points.last else { return x }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }

        var segment = 0
        for i in 0..<(points.count - 1) where x >= points[i].x && x <= points[i + 1].x {
            segment = i
            break
        }

        let p0 = points[segment]
        let p1 = points[segment + 1]
        let dx = p1.x - p0.x
        guard dx > 0 else { return p0.y }
        let t = (x - p0.x) / dx

        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        return h00 * p0.y + h10 * dx * tangents[segment] + h01 * p1.y + h11 * dx * tangents[segment + 1]
    }
}
