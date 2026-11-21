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

/// The gradients of the given shapes: axes [P, 2, 2] (the `from` and `to` points) and
/// endColors [P, 3]. A flat shape gets its own colour at both ends.
public func gradientArrays(_ shapes: [Shape]) -> (axes: MLXArray, endColors: MLXArray) {
    guard !shapes.isEmpty else { return (MLXArray.zeros([0, 2, 2]), MLXArray.zeros([0, 3])) }
    var axes: [Float] = []
    var ends: [Float] = []
    for shape in shapes {
        let from = shape.gradient?.from ?? SIMD2(0, 0)
        let to = shape.gradient?.to ?? SIMD2(1, 0)
        let end = shape.gradient?.endColor ?? shape.color
        axes += [from.x, from.y, to.x, to.y]
        ends += [end.r, end.g, end.b]
    }
    return (MLXArray(axes, [shapes.count, 2, 2]), MLXArray(ends, [shapes.count, 3]))
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

/// A soft rasteriser whose picture MLX can differentiate with respect to control points,
/// colours, gradient fills and the picture beneath. Used for fitting only; results shown
/// to the user are drawn from the vectors.
///
/// Each shape is rasterised over a window of pixels around it, not the whole picture (see
/// `WindowLayout`). Turning control points into the edges of an outline is done with MLX
/// array operations; everything from the edges to the picture runs as a few small GPU
/// programs with their derivative written by hand (see `RasterKernels`).
public struct Rasterizer {
    public let width: Int
    public let height: Int
    public let softness: Float

    /// Distance reported where there is no shape at all.
    public static let noBoundary: Float = 1e6

    private let basisStart: MLXArray  // [E, 12]: polygon vertex k
    private let basisEnd: MLXArray  // [E, 12]: polygon vertex k + 1 (wrapping)

    public init(width: Int, height: Int, samplesPerSegment: Int = 8, softness: Float = 1.0) {
        precondition(width >= 1 && height >= 1 && softness > 0)
        self.width = width
        self.height = height
        self.softness = softness

        let basis = bezierBasis(samplesPerSegment: samplesPerSegment)
        let edges = basis.count
        let rotated = Array(basis[1...]) + [basis[0]]
        basisStart = MLXArray(basis.flatMap { $0 }, [edges, Shape.pointCount])
        basisEnd = MLXArray(rotated.flatMap { $0 }, [edges, Shape.pointCount])
    }

    /// points [P, 12, 2], colors [P, 3], background [3]. P may be 0.
    /// Returns image [H, W, 3] and boundaryDistance [H, W]: the distance to the nearest edge
    /// of any shape, which carries no derivative, or `noBoundary` everywhere when P == 0.
    ///
    /// `crops`, one per shape, names the pixels each shape can affect. The work for a shape
    /// is limited to its rectangle; outside it the shape counts as absent and its edge as
    /// far away, and a shape with an empty rectangle is left out. This is what keeps time
    /// and memory in check when there are many small shapes.
    /// `base` is an already rendered picture to paint on top of, in place of the background.
    /// `mask` [H, W], 0…1, limits where shapes may paint: a shape's coverage is multiplied
    /// by it, as if the shapes were clipped to the masked region. No derivative is taken
    /// with respect to the mask.
    /// `gradients` (axes [P, 2, 2], endColors [P, 3]) fills each shape with a linear
    /// gradient: `colors` at the first axis point, running to `endColors` at the second and
    /// held beyond both.
    public func render(
        points: MLXArray, colors: MLXArray, background: MLXArray, crops: [PixelRect]? = nil,
        over base: (image: MLXArray, boundaryDistance: MLXArray)? = nil, mask: MLXArray? = nil,
        gradients: (axes: MLXArray, endColors: MLXArray)? = nil
    ) -> (image: MLXArray, boundaryDistance: MLXArray) {
        // Each shape's outline as a closed polygon: for every edge its start x, start y,
        // end x and end y.
        let edges = concatenated(
            [matmul(basisStart, points), matmul(basisEnd, points)], axis: -1)  // [P, E, 4]
        return render(
            edges: edges, colors: colors, background: background, crops: crops, over: base,
            mask: mask, gradients: gradients)
    }

    /// As `render(points:…)`, for shapes given directly as closed polygons: `edges`
    /// [P, E, 4] holds the start x, start y, end x and end y of every edge of each shape,
    /// each edge starting where the one before it ended. All shapes have the same number
    /// of edges. This is how straight-edged tiles are rendered.
    public func render(
        edges allEdges: MLXArray, colors: MLXArray, background: MLXArray, crops: [PixelRect]? = nil,
        over base: (image: MLXArray, boundaryDistance: MLXArray)? = nil, mask: MLXArray? = nil,
        gradients: (axes: MLXArray, endColors: MLXArray)? = nil
    ) -> (image: MLXArray, boundaryDistance: MLXArray) {
        let shapeCount = allEdges.dim(0)
        precondition(crops == nil || crops!.count == shapeCount)
        let baseImage =
            base?.image ?? MLXArray.zeros([height, width, 3]) + background.reshaped(1, 1, 3)
        let baseBoundary =
            base?.boundaryDistance ?? MLXArray.zeros([height, width]) + Rasterizer.noBoundary
        let whole = PixelRect(x0: 0, y0: 0, x1: width, y1: height)
        let layout = WindowLayout(
            crops: crops ?? Array(repeating: whole, count: shapeCount), width: width,
            height: height)
        let drawnCount = layout.drawn.count
        guard drawnCount > 0 else { return (baseImage, baseBoundary) }

        let drawnIndices = MLXArray(layout.drawn.map { Int32($0) })
        func drawn(_ array: MLXArray) -> MLXArray {
            drawnCount == shapeCount ? array : take(array, drawnIndices, axis: 0)
        }
        return RasterKernels.paint(
            edges: drawn(allEdges), colors: drawn(colors),
            fills: gradients.map { (drawn($0.endColors), drawn($0.axes)) },
            base: (baseImage, baseBoundary), mask: mask, layout: layout, softness: softness)
    }
}
