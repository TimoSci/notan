import MLX

@testable import LayerFitCore

/// The rasteriser's arithmetic written the slow, plain way, as a yardstick for the real
/// one: each shape over the whole picture, its edge distance the least over all its edges,
/// and the shapes painted one after another. No windows, no batches, no shortcuts.
struct ReferenceRaster {
    let width: Int
    let height: Int
    let softness: Float

    /// The same arguments as `Rasterizer.render`; shapes listed in `skipping` are left out.
    func render(
        points: MLXArray, colors: MLXArray, background: MLXArray, skipping: Set<Int> = [],
        over base: (image: MLXArray, boundaryDistance: MLXArray)? = nil, mask: MLXArray? = nil,
        gradients: (axes: MLXArray, endColors: MLXArray)? = nil
    ) -> (image: MLXArray, boundaryDistance: MLXArray) {
        let basis = bezierBasis(samplesPerSegment: 8)
        let edges = basis.count
        let rotated = Array(basis[1...]) + [basis[0]]
        let basisStart = MLXArray(basis.flatMap { $0 }, [edges, Shape.pointCount])
        let basisEnd = MLXArray(rotated.flatMap { $0 }, [edges, Shape.pointCount])
        let pixelX = MLXArray((0..<width).map { Float($0) + 0.5 }).reshaped(1, width, 1)
        let pixelY = MLXArray((0..<height).map { Float($0) + 0.5 }).reshaped(height, 1, 1)

        var image = base?.image ?? MLXArray.zeros([height, width, 3]) + background.reshaped(1, 1, 3)
        var boundary = base?.boundaryDistance ?? MLXArray.zeros([height, width]) + Float(1e6)
        for index in 0..<points.dim(0) where !skipping.contains(index) {
            let a = matmul(basisStart, points[index])  // [E, 2]
            let b = matmul(basisEnd, points[index])
            let ax = a[0..., 0].reshaped(1, 1, edges)
            let ay = a[0..., 1].reshaped(1, 1, edges)
            let bx = b[0..., 0].reshaped(1, 1, edges)
            let by = b[0..., 1].reshaped(1, 1, edges)
            let dx = bx - ax
            let dy = by - ay
            let relX = pixelX - ax
            let relY = pixelY - ay
            let t = clip((relX * dx + relY * dy) / (dx * dx + dy * dy + 1e-8), min: 0, max: 1)
            let offX = relX - t * dx
            let offY = relY - t * dy
            let distance = sqrt((offX * offX + offY * offY).min(axis: -1) + 1e-8)  // [H, W]

            let straddles = (ay .> pixelY) .!= (by .> pixelY)
            let safeDy = which(straddles, dy, MLXArray(Float(1)))
            let crossX = ax + (pixelY - ay) / safeDy * dx
            let direction = which(by .> ay, MLXArray(Int32(1)), MLXArray(Int32(-1)))
            let winding = which(
                logicalAnd(straddles, pixelX .< crossX), direction, MLXArray(Int32(0))
            ).sum(axis: -1)
            let sign = stopGradient(
                which(winding .!= MLXArray(Int32(0)), MLXArray(Float(1)), MLXArray(Float(-1))))

            var alpha = sigmoid(sign * distance / softness)
            if let mask { alpha = alpha * mask }
            boundary = minimum(boundary, stopGradient(distance))

            var color = colors[index].reshaped(1, 1, 3)
            if let gradients {
                let from = gradients.axes[index, 0]
                let along = gradients.axes[index, 1] - from
                let x = pixelX - from[0]
                let y = pixelY - from[1]
                let along2 = (along * along).sum() + 1e-6
                let s = clip((x * along[0] + y * along[1]) / along2, min: 0, max: 1)
                color = color + s * (gradients.endColors[index].reshaped(1, 1, 3) - color)
            }
            let a3 = alpha.expandedDimensions(axis: -1)
            image = image * (1 - a3) + color * a3
        }
        return (image, boundary)
    }
}
