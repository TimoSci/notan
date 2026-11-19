import Foundation
import MLX

// Keeping shapes from thinning into slivers and spikes.
//
// "Mean width" is 2 × area / perimeter. For a long strip that is its width; for a round
// blob it is half its diameter. It measures the shape as a whole, so it does not see one
// thin spike on a fat shape: the corner penalty is there for those.

private let widthSamples = 8

/// 2 × area / perimeter of the shape's outline, in pixels.
public func meanWidth(of shape: Shape) -> Float {
    let polygon = samplePolygon(shape.points, samplesPerSegment: widthSamples)
    var doubleArea: Float = 0
    var perimeter: Float = 0
    for index in polygon.indices {
        let a = polygon[index]
        let b = polygon[(index + 1) % polygon.count]
        doubleArea += a.x * b.y - b.x * a.y
        perimeter += ((b - a) * (b - a)).sum().squareRoot()
    }
    return perimeter > 0 ? abs(doubleArea) / perimeter : 0
}

private func polygonEnds() -> (start: MLXArray, end: MLXArray) {
    let basis = bezierBasis(samplesPerSegment: widthSamples)
    let rotated = Array(basis[1...]) + [basis[0]]
    return (
        MLXArray(basis.flatMap { $0 }, [basis.count, Shape.pointCount]),
        MLXArray(rotated.flatMap { $0 }, [basis.count, Shape.pointCount])
    )
}

/// points [P, 12, 2] → mean width of each shape, [P].
public func meanWidths(points: MLXArray) -> MLXArray {
    guard points.dim(0) > 0 else { return MLXArray.zeros([0]) }
    let (start, end) = polygonEnds()
    let a = matmul(start, points)  // [P, E, 2]
    let b = matmul(end, points)
    let ax = a[0..., 0..., 0]
    let ay = a[0..., 0..., 1]
    let bx = b[0..., 0..., 0]
    let by = b[0..., 0..., 1]
    let signedDoubleArea = (ax * by - bx * ay).sum(axis: -1)
    // The outline may run either way round; a smooth |x| keeps the gradient finite at 0.
    let doubleArea = sqrt(signedDoubleArea * signedDoubleArea + 1e-8)
    let perimeter = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay) + 1e-10).sum(axis: -1)
    return doubleArea / (perimeter + 1e-6)
}

/// Sum over shapes of (1 − width / minimum)², counted only where the shape is narrower
/// than its minimum. points [P, 12, 2]; minWidths [P], where 0 switches a shape's check off.
public func widthPenalty(points: MLXArray, minWidths: MLXArray) -> MLXArray {
    guard points.dim(0) > 0 else { return MLXArray(Float(0)) }
    let active = minWidths .> 0
    let safeMinimum = which(active, minWidths, MLXArray(Float(1)))
    let shortfall = maximum(1 - meanWidths(points: points) / safeMinimum, 0)
    return which(active, shortfall * shortfall, MLXArray(Float(0))).sum()
}

private func anchorSelector(offset: Int) -> MLXArray {
    let anchors = Shape.pointCount / 3
    var rows = [Float](repeating: 0, count: anchors * Shape.pointCount)
    for anchor in 0..<anchors {
        let index = (3 * anchor + offset + Shape.pointCount) % Shape.pointCount
        rows[anchor * Shape.pointCount + index] = 1
    }
    return MLXArray(rows, [anchors, Shape.pointCount])
}

/// Penalises sharp corners where two curve segments join. At each of a shape's four joints
/// the outline turns by some angle θ; the cost is ((1 − cos θ) / 2)², which is 0 for a
/// smooth joint, 0.02 for a 45° turn, 0.25 for a right angle and 1 for a needle. The result is the sum over
/// shapes of the mean over their joints. points [P, 12, 2].
public func cornerPenalty(points: MLXArray) -> MLXArray {
    guard points.dim(0) > 0 else { return MLXArray(Float(0)) }
    let anchor = matmul(anchorSelector(offset: 0), points)  // [P, 4, 2]
    let incoming = anchor - matmul(anchorSelector(offset: -1), points)
    let outgoing = matmul(anchorSelector(offset: 1), points) - anchor
    let dot = (incoming * outgoing).sum(axis: -1)
    let lengths =
        sqrt((incoming * incoming).sum(axis: -1) + 1e-12)
        * sqrt((outgoing * outgoing).sum(axis: -1) + 1e-12)
    let turn = (1 - dot / (lengths + 1e-6)) / 2
    return (turn * turn).mean(axis: -1).sum()
}

// Keeping shapes from folding over themselves.
//
// Seen from its own centre, an unfolded outline sweeps round one way only. Where an outline
// crosses itself (a bow-tie, a lobe folded back, a loop) part of it sweeps the other way.
// The fold ratio is the share of the swept area that goes backward: 0 for any shape that
// is star-shaped about its centre, 0.5 for a bow-tie. Dents and bulges cost nothing; a
// shape curled most of the way round something does.

/// The share of a shape's swept area that runs backward round its centre, 0…0.5.
public func foldRatio(of shape: Shape) -> Float {
    let polygon = samplePolygon(shape.points, samplesPerSegment: widthSamples)
    let centre = polygon.reduce(SIMD2<Float>(0, 0), +) / Float(polygon.count)
    var sweeps: [Float] = []
    for index in polygon.indices {
        let u = polygon[index] - centre
        let v = polygon[(index + 1) % polygon.count] - centre
        sweeps.append(u.x * v.y - u.y * v.x)
    }
    let total = sweeps.reduce(0) { $0 + abs($1) }
    guard total > 1e-6 else { return 0 }
    let direction: Float = sweeps.reduce(0, +) >= 0 ? 1 : -1
    return sweeps.reduce(0) { $0 + max(-direction * $1, 0) } / total
}

/// Sum over shapes of their fold ratio, counting only what exceeds `tolerance`.
/// points [P, 12, 2].
public func foldPenalty(points: MLXArray, tolerance: Float = 0) -> MLXArray {
    guard points.dim(0) > 0 else { return MLXArray(Float(0)) }
    let (start, end) = polygonEnds()
    let a = matmul(start, points)  // [P, E, 2]
    let b = matmul(end, points)
    let centre = a.mean(axis: 1, keepDims: true)
    let u = a - centre
    let v = b - centre
    let sweep = u[0..., 0..., 0] * v[0..., 0..., 1] - u[0..., 0..., 1] * v[0..., 0..., 0]  // [P, E]
    let direction = stopGradient(
        which(sweep.sum(axis: -1, keepDims: true) .>= 0, MLXArray(Float(1)), MLXArray(Float(-1))))
    let backward = maximum(-direction * sweep, 0).sum(axis: -1)
    let total = sqrt(sweep * sweep + 1e-8).sum(axis: -1)
    return maximum(backward / (total + 1e-6) - tolerance, 0).sum()
}

/// The minimum width for the shapes added at each stage. It shrinks as shapes accumulate,
/// in proportion to 1 / √(shapes so far), and reaches `minWidth` at the last stage: big
/// features first, finer ones later. Never more than a sixth of the picture's long side.
/// A `minWidth` of 0 switches the check off.
public func minWidthSchedule(minWidth: Float, schedule: [Int], longSide: Float) -> [Float] {
    guard minWidth > 0 else { return schedule.map { _ in 0 } }
    let total = Float(schedule.reduce(0, +))
    let cap = max(longSide / 6, minWidth)
    var soFar: Float = 0
    return schedule.map { added in
        soFar += Float(added)
        return min(minWidth * (total / soFar).squareRoot(), cap)
    }
}
