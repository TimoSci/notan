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

/// A half-open rectangle of pixels: columns x0..<x1, rows y0..<y1.
public struct PixelRect: Equatable, Sendable {
    public var x0, y0, x1, y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }

    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return PixelRect(
            x0: min(x0, other.x0), y0: min(y0, other.y0), x1: max(x1, other.x1),
            y1: max(y1, other.y1))
    }
}

/// The pixels a shape can affect: the box around its control points (which always contains
/// the curve) grown by `margin`, clamped to the image. Empty if that misses the image.
public func cropRect(points: [SIMD2<Float>], margin: Float, width: Int, height: Int) -> PixelRect {
    var low = SIMD2<Float>(Float.infinity, Float.infinity)
    var high = SIMD2<Float>(-Float.infinity, -Float.infinity)
    for point in points where point.x.isFinite && point.y.isFinite {
        low = pointwiseMin(low, point)
        high = pointwiseMax(high, point)
    }
    guard low.x <= high.x else { return PixelRect(x0: 0, y0: 0, x1: 0, y1: 0) }
    func clamp(_ value: Float, _ limit: Int) -> Int { Int(min(max(value, 0), Float(limit))) }
    return PixelRect(
        x0: clamp((low.x - margin).rounded(.down), width),
        y0: clamp((low.y - margin).rounded(.down), height),
        x1: clamp((high.x + margin).rounded(.up), width),
        y1: clamp((high.y + margin).rounded(.up), height))
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
    ///
    /// `crops`, one per shape, limits the work for each shape to the pixels it can affect;
    /// outside its rectangle a shape counts as absent and its edge as far away. This is
    /// what keeps time and memory in check when there are many small shapes.
    /// `base` is an already rendered picture to paint on top of, in place of the background.
    public func render(
        points: MLXArray, colors: MLXArray, background: MLXArray, crops: [PixelRect]? = nil,
        over base: (image: MLXArray, boundaryDistance: MLXArray)? = nil
    ) -> (image: MLXArray, boundaryDistance: MLXArray) {
        let shapeCount = points.dim(0)
        precondition(crops == nil || crops!.count == shapeCount)
        var image = base?.image ?? MLXArray.zeros([height, width, 3]) + background.reshaped(1, 1, 3)
        var boundary =
            base?.boundaryDistance ?? MLXArray.zeros([height, width]) + Rasterizer.noBoundary
        let whole = PixelRect(x0: 0, y0: 0, x1: width, y1: height)

        var start = 0
        while start < shapeCount {
            let end = min(start + chunk, shapeCount)
            defer { start = end }
            let rect =
                crops?[start..<end].reduce(PixelRect(x0: 0, y0: 0, x1: 0, y1: 0)) { $0.union($1) }
                ?? whole
            if rect.isEmpty { continue }
            var (alpha, distance) = coverage(points: points[start..<end], rect: rect)
            if rect != whole {
                let widths: [IntOrPair] = [
                    IntOrPair((rect.y0, height - rect.y1)), IntOrPair((rect.x0, width - rect.x1)),
                    IntOrPair((0, 0)),
                ]
                alpha = padded(alpha, widths: widths)
                distance = padded(distance, widths: widths, value: MLXArray(Rasterizer.noBoundary))
            }
            boundary = minimum(boundary, stopGradient(distance.min(axis: -1)))
            for index in 0..<(end - start) {
                let a = alpha[0..., 0..., index].expandedDimensions(axis: -1)  // [H, W, 1]
                let color = colors[start + index].reshaped(1, 1, 3)
                image = image * (1 - a) + color * a
            }
        }
        return (image, boundary)
    }

    /// For C shapes, over the pixels of `rect` (h × w): soft coverage [h, w, C] and unsigned
    /// edge distance [h, w, C].
    private func coverage(points: MLXArray, rect: PixelRect) -> (alpha: MLXArray, distance: MLXArray) {
        let pixelX = self.pixelX[rect.y0..<rect.y1, rect.x0..<rect.x1]
        let pixelY = self.pixelY[rect.y0..<rect.y1, rect.x0..<rect.x1]
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
