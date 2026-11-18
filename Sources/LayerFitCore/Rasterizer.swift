import Foundation
import MLX

/// [P, 12, 2] control points of the given shapes.
public func pointsArray(_ shapes: [Shape]) -> MLXArray {
    guard !shapes.isEmpty else { return MLXArray.zeros([0, Shape.pointCount, 2]) }
    let flat = shapes.flatMap { $0.points.flatMap { [$0.x, $0.y] } }
    return MLXArray(flat, [shapes.count, Shape.pointCount, 2])
}

/// [P, 3] fill colours of the given shapes.
public func colorsArray(_ shapes: [Shape]) -> MLXArray {
    guard !shapes.isEmpty else { return MLXArray.zeros([0, 3]) }
    return MLXArray(shapes.flatMap { [$0.color.r, $0.color.g, $0.color.b] }, [shapes.count, 3])
}

/// [3]
public func colorArray(_ color: RGB) -> MLXArray {
    MLXArray([color.r, color.g, color.b])
}

/// A soft rasteriser built only from MLX array operations, so MLX can differentiate
/// the image with respect to control points and colours. Used for fitting only; results
/// shown to the user are drawn from the vectors.
public struct Rasterizer {
    public let width: Int
    public let height: Int
    public let softness: Float
    public let chunk: Int

    /// Distance reported where there is no shape at all.
    public static let noBoundary: Float = 1e6

    private let basisStart: MLXArray  // [E, 12]: polygon vertex k
    private let basisEnd: MLXArray  // [E, 12]: polygon vertex k + 1 (wrapping)
    private let pixelX: MLXArray  // [H, W, 1, 1]
    private let pixelY: MLXArray  // [H, W, 1, 1]

    public init(
        width: Int, height: Int, samplesPerSegment: Int = 8, softness: Float = 1.0, chunk: Int = 32
    ) {
        precondition(width >= 1 && height >= 1 && chunk >= 1 && softness > 0)
        self.width = width
        self.height = height
        self.softness = softness
        self.chunk = chunk

        let basis = bezierBasis(samplesPerSegment: samplesPerSegment)
        let edges = basis.count
        let rotated = Array(basis[1...]) + [basis[0]]
        basisStart = MLXArray(basis.flatMap { $0 }, [edges, Shape.pointCount])
        basisEnd = MLXArray(rotated.flatMap { $0 }, [edges, Shape.pointCount])

        var xs = [Float](repeating: 0, count: width * height)
        var ys = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                xs[y * width + x] = Float(x) + 0.5
                ys[y * width + x] = Float(y) + 0.5
            }
        }
        pixelX = MLXArray(xs, [height, width, 1, 1])
        pixelY = MLXArray(ys, [height, width, 1, 1])
    }

    /// points [P, 12, 2], colors [P, 3], background [3]. P may be 0.
    /// Returns image [H, W, 3] and boundaryDistance [H, W]: the distance to the nearest edge
    /// of any shape, with its gradient stopped, or `noBoundary` everywhere when P == 0.
    public func render(points: MLXArray, colors: MLXArray, background: MLXArray)
        -> (image: MLXArray, boundaryDistance: MLXArray)
    {
        let shapeCount = points.dim(0)
        var image = MLXArray.zeros([height, width, 3]) + background.reshaped(1, 1, 3)
        var boundary = MLXArray.zeros([height, width]) + Rasterizer.noBoundary

        var start = 0
        while start < shapeCount {
            let end = min(start + chunk, shapeCount)
            let (alpha, distance) = coverage(points: points[start..<end])
            boundary = minimum(boundary, stopGradient(distance.min(axis: -1)))
            for index in 0..<(end - start) {
                let a = alpha[0..., 0..., index].expandedDimensions(axis: -1)  // [H, W, 1]
                let color = colors[start + index].reshaped(1, 1, 3)
                image = image * (1 - a) + color * a
            }
            start = end
        }
        return (image, boundary)
    }

    /// For C shapes: soft coverage [H, W, C] and unsigned edge distance [H, W, C].
    private func coverage(points: MLXArray) -> (alpha: MLXArray, distance: MLXArray) {
        let count = points.dim(0)
        let a = matmul(basisStart, points)  // [C, E, 2]
        let b = matmul(basisEnd, points)
        let edges = a.dim(1)
        let ax = a[0..., 0..., 0].reshaped(1, 1, count, edges)
        let ay = a[0..., 0..., 1].reshaped(1, 1, count, edges)
        let bx = b[0..., 0..., 0].reshaped(1, 1, count, edges)
        let by = b[0..., 0..., 1].reshaped(1, 1, count, edges)

        let dx = bx - ax
        let dy = by - ay
        let relX = pixelX - ax  // [H, W, C, E]
        let relY = pixelY - ay

        // Distance from each pixel centre to each edge.
        let t = clip((relX * dx + relY * dy) / (dx * dx + dy * dy + 1e-8), min: 0, max: 1)
        let offX = relX - t * dx
        let offY = relY - t * dy
        let distance = sqrt((offX * offX + offY * offY).min(axis: -1) + 1e-8)  // [H, W, C]

        // Even-odd inside test by counting edge crossings of a ray toward +x.
        // The sign carries no gradient; gradient flows through the distance.
        let straddles = (ay .> pixelY) .!= (by .> pixelY)
        let safeDy = which(straddles, dy, MLXArray(Float(1)))
        let crossX = ax + (pixelY - ay) / safeDy * dx
        let crossings = logicalAnd(straddles, pixelX .< crossX).asType(.int32).sum(axis: -1)
        let inside = remainder(crossings, MLXArray(Int32(2))) .== MLXArray(Int32(1))
        let sign = stopGradient(which(inside, MLXArray(Float(1)), MLXArray(Float(-1))))

        let alpha = sigmoid(sign * distance / softness)
        return (alpha, distance)
    }
}
