import Foundation
import MLX

public struct LossConfig: Sendable {
    /// Pixels farther than this from every shape edge get no boundary weight.
    /// In pixels at a 256 px working size; the fitter scales it with the working size.
    public var boundaryReach: Float = 10
    /// Weight of the plain, unweighted error over all pixels. A deliberate departure from
    /// LIVE: it keeps the background and large flat interiors trained when shapes are few.
    public var floorWeight: Float = 1.0
    public var xingWeight: Float = 0.01
    /// Edge softness of the raster used for fitting, in pixels. Too soft and thin shapes
    /// render faint, so the optimiser overdrives their colour and they show as bright
    /// slivers once drawn hard-edged.
    public var softness: Float = 0.5
    /// Weight of the penalty on shapes narrower than their minimum width.
    public var widthWeight: Float = 0.1
    /// Weight of the penalty on sharp corners, applied only with a minimum width.
    public var cornerWeight: Float = 0.05
    /// Weight of the penalty on shapes that fold over themselves; 0 allows folds.
    /// Kept small on purpose: a fold only ever buys a sliver of fit, so a light touch
    /// removes them all, while a heavy one also flattens long curved shapes (at 0.1 the
    /// error at 128 shapes rose by half; at 0.001 it is unchanged).
    public var foldWeight: Float = 0.001
    /// How much of a shape may sweep backward round its centre before the fold penalty
    /// applies. Long curved shapes sweep back a little without crossing themselves.
    public var foldTolerance: Float = 0
    /// Weight of the penalty that keeps a tile from shrinking away, where tiles are fitted
    /// with all their corners free.
    public var tileAreaWeight: Float = 1

    public init(
        boundaryReach: Float = 10, floorWeight: Float = 1.0, xingWeight: Float = 0.01,
        softness: Float = 0.5
    ) {
        self.boundaryReach = boundaryReach
        self.floorWeight = floorWeight
        self.xingWeight = xingWeight
        self.softness = softness
    }
}

/// Mean squared error over every pixel and channel.
public func plainMSE(image: MLXArray, target: MLXArray) -> MLXArray {
    let diff = image - target
    return (diff * diff).mean()
}

/// Mean squared error over the channels of the masked pixels. mask [H, W], 0…1.
public func maskedMSE(image: MLXArray, target: MLXArray, mask: MLXArray) -> MLXArray {
    let diff = image - target
    return ((diff * diff).sum(axis: -1) * mask).sum() / (3 * mask.sum() + 1e-6)
}

private func selector(offset: Int) -> MLXArray {
    let segments = Shape.pointCount / 3
    var rows = [Float](repeating: 0, count: segments * Shape.pointCount)
    for segment in 0..<segments {
        let index = (3 * segment + offset + Shape.pointCount) % Shape.pointCount
        rows[segment * Shape.pointCount + index] = 1
    }
    return MLXArray(rows, [segments, Shape.pointCount])
}

private func cross(_ u: MLXArray, _ v: MLXArray) -> MLXArray {
    u[0..., 0..., 0] * v[0..., 0..., 1] - u[0..., 0..., 1] * v[0..., 0..., 0]
}

private func length(_ u: MLXArray) -> MLXArray {
    sqrt((u * u).sum(axis: -1) + 1e-12)
}

/// LIVE's Xing loss: penalises a cubic segment whose two handles cross, which is what
/// makes a path self-intersect. points [P, 12, 2]; the result is the mean over segments.
public func xingLoss(points: MLXArray) -> MLXArray {
    guard points.dim(0) > 0 else { return MLXArray(Float(0)) }
    let a = matmul(selector(offset: 0), points)  // [P, 4, 2]
    let b = matmul(selector(offset: 1), points)
    let c = matmul(selector(offset: 2), points)
    let d = matmul(selector(offset: 3), points)
    let ab = b - a
    let bc = c - b
    let cd = d - c
    let turnsLeft = stopGradient(which(cross(ab, bc) .> 0, MLXArray(Float(1)), MLXArray(Float(0))))
    let sine = cross(ab, cd) / (length(ab) * length(cd) + 1e-6)
    let penalty = turnsLeft * maximum(-sine, 0) + (1 - turnsLeft) * maximum(sine, 0)
    return penalty.mean()
}

/// The error terms of `fitLoss` alone: image, target [H, W, 3]; boundaryDistance [H, W].
/// Boundary-weighted error plus the plain error floor. For tiles, which have no curves to
/// keep in shape.
public func tileLoss(
    image: MLXArray, target: MLXArray, boundaryDistance: MLXArray, config: LossConfig
) -> MLXArray {
    let diff = image - target
    let squared = (diff * diff).sum(axis: -1)  // [H, W]
    let weight = stopGradient(maximum(1 - boundaryDistance / config.boundaryReach, 0))
    let weighted = (weight * squared).sum() / (weight.sum() + 1e-6)
    return weighted + config.floorWeight * squared.mean()
}

/// image, target [H, W, 3]; boundaryDistance [H, W]; points [P, 12, 2] of the shapes that
/// can move. Boundary-weighted error (LIVE's UDF loss) plus a plain error floor plus Xing.
/// With `minWidths` [P], also penalises shapes narrower than their minimum and sharp corners.
/// With `mask` [H, W], only the masked pixels count.
public func fitLoss(
    image: MLXArray, target: MLXArray, boundaryDistance: MLXArray, points: MLXArray,
    config: LossConfig, minWidths: MLXArray? = nil, mask: MLXArray? = nil
) -> MLXArray {
    let diff = image - target
    var squared = (diff * diff).sum(axis: -1)  // [H, W]
    var weight = stopGradient(maximum(1 - boundaryDistance / config.boundaryReach, 0))
    let floor: MLXArray
    if let mask {
        squared = squared * mask
        weight = weight * mask
        floor = squared.sum() / (mask.sum() + 1e-6)
    } else {
        floor = squared.mean()
    }
    let weighted = (weight * squared).sum() / (weight.sum() + 1e-6)
    var loss =
        weighted + config.floorWeight * floor
        + config.xingWeight * xingLoss(points: points)
    if config.foldWeight > 0 {
        loss =
            loss + config.foldWeight * foldPenalty(points: points, tolerance: config.foldTolerance)
    }
    if let minWidths {
        loss =
            loss + config.widthWeight * widthPenalty(points: points, minWidths: minWidths)
            + config.cornerWeight * cornerPenalty(points: points)
    }
    return loss
}
