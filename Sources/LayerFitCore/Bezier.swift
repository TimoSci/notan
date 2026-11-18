import Foundation

/// Weights that turn a shape's 12 control points into a closed polygon.
/// Row k of segment i is sampled at t = k / samplesPerSegment, so t = 1 is the next
/// segment's first sample and no vertex is repeated.
/// polygon[row] = Σ_j basis[row][j] * points[j]
public func bezierBasis(samplesPerSegment: Int) -> [[Float]] {
    precondition(samplesPerSegment >= 1)
    let segments = Shape.pointCount / 3
    var basis: [[Float]] = []
    basis.reserveCapacity(segments * samplesPerSegment)
    for segment in 0..<segments {
        for sample in 0..<samplesPerSegment {
            let t = Float(sample) / Float(samplesPerSegment)
            let u = 1 - t
            let weights: [Float] = [u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t]
            var row = [Float](repeating: 0, count: Shape.pointCount)
            for (offset, weight) in weights.enumerated() {
                row[(3 * segment + offset) % Shape.pointCount] += weight
            }
            basis.append(row)
        }
    }
    return basis
}

public func samplePolygon(_ points: [SIMD2<Float>], samplesPerSegment: Int) -> [SIMD2<Float>] {
    precondition(points.count == Shape.pointCount)
    return bezierBasis(samplesPerSegment: samplesPerSegment).map { row in
        var vertex = SIMD2<Float>(0, 0)
        for (weight, point) in zip(row, points) where weight != 0 {
            vertex += weight * point
        }
        return vertex
    }
}
