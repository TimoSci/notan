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

/// A soft rasteriser built only from MLX array operations, so MLX can differentiate
/// the image with respect to control points and colours. Used for fitting only; results
/// shown to the user are drawn from the vectors.
///
/// Each shape is rasterised over a window of pixels around it, not the whole picture, and
/// shapes with windows of the same size are done together (see `WindowLayout`). The windows
/// are then placed in the picture and all the shapes are painted in one pass.
public struct Rasterizer {
    public let width: Int
    public let height: Int
    public let softness: Float
    /// How many whole pictures' worth of window pixels are rasterised in one go. It bounds
    /// the memory a render needs and does not change the result.
    public let chunk: Int

    /// Distance reported where there is no shape at all.
    public static let noBoundary: Float = 1e6

    private let basisStart: MLXArray  // [E, 12]: polygon vertex k
    private let basisEnd: MLXArray  // [E, 12]: polygon vertex k + 1 (wrapping)
    private let pixelX: MLXArray  // [1, 1, W]: pixel centres
    private let pixelY: MLXArray  // [1, H, 1]

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
        pixelX = MLXArray((0..<width).map { Float($0) + 0.5 }, [1, 1, width])
        pixelY = MLXArray((0..<height).map { Float($0) + 0.5 }, [1, height, 1])
    }

    /// points [P, 12, 2], colors [P, 3], background [3]. P may be 0.
    /// Returns image [H, W, 3] and boundaryDistance [H, W]: the distance to the nearest edge
    /// of any shape, with its gradient stopped, or `noBoundary` everywhere when P == 0.
    ///
    /// `crops`, one per shape, names the pixels each shape can affect. The work for a shape
    /// is limited to a window that covers its rectangle; outside the window the shape
    /// counts as absent and its edge as far away, and a shape with an empty rectangle is
    /// left out. This is what keeps time and memory in check when there are many small
    /// shapes.
    /// `base` is an already rendered picture to paint on top of, in place of the background.
    /// `mask` [H, W], 0…1, limits where shapes may paint: a shape's coverage is multiplied
    /// by it, as if the shapes were clipped to the masked region.
    /// `gradients` (axes [P, 2, 2], endColors [P, 3]) fills each shape with a linear
    /// gradient: `colors` at the first axis point, running to `endColors` at the second and
    /// held beyond both.
    public func render(
        points: MLXArray, colors: MLXArray, background: MLXArray, crops: [PixelRect]? = nil,
        over base: (image: MLXArray, boundaryDistance: MLXArray)? = nil, mask: MLXArray? = nil,
        gradients: (axes: MLXArray, endColors: MLXArray)? = nil
    ) -> (image: MLXArray, boundaryDistance: MLXArray) {
        let shapeCount = points.dim(0)
        precondition(crops == nil || crops!.count == shapeCount)
        let baseImage =
            base?.image ?? MLXArray.zeros([height, width, 3]) + background.reshaped(1, 1, 3)
        let baseBoundary =
            base?.boundaryDistance ?? MLXArray.zeros([height, width]) + Rasterizer.noBoundary
        let whole = PixelRect(x0: 0, y0: 0, x1: width, y1: height)
        let layout = WindowLayout(
            crops: crops ?? Array(repeating: whole, count: shapeCount), width: width,
            height: height, budget: chunk * width * height)
        let drawnCount = layout.drawn.count
        guard drawnCount > 0 else { return (baseImage, baseBoundary) }

        // Every shape's signed edge distance over its own window, the windows laid end to
        // end in one strip. The spare row and column of each stand for everywhere else in
        // the picture: far outside the shape.
        let everyShape = Array(0..<shapeCount)
        let windows = layout.batches.map { batch -> MLXArray in
            let batchPoints =
                batch.shapes == everyShape
                ? points : take(points, MLXArray(batch.shapes.map { Int32($0) }), axis: 0)
            return padded(
                signedDistance(points: batchPoints, batch: batch),
                widths: [IntOrPair((0, 0)), IntOrPair((0, 1)), IntOrPair((0, 1))],
                value: MLXArray(-Rasterizer.noBoundary)
            ).reshaped(-1)
        }
        let strip = windows.count == 1 ? windows[0] : concatenated(windows)

        // Each drawn shape's window placed in the whole picture, in paint order.
        let place =
            MLXArray(layout.rows, [drawnCount, height, 1])
            + MLXArray(layout.columns, [drawnCount, 1, width])
        let signed = take(strip, place, axis: 0)  // [P', H, W]
        var alpha = sigmoid(signed / softness)
        if let mask { alpha = alpha * mask }
        let boundary = minimum(baseBoundary, stopGradient(abs(signed).min(axis: 0)))

        // Painted in order, a shape shows where it covers and nothing painted after it
        // does. `above` is how much of each shape the later ones let through.
        let through = 1 - alpha
        let above = cumprod(through, axis: 0, reverse: true, inclusive: false)
        let shows = (alpha * above).transposed(1, 2, 0)  // [H, W, P']
        let ground = (above[0] * through[0]).expandedDimensions(axis: -1)  // [H, W, 1]

        let drawnIndices = MLXArray(layout.drawn.map { Int32($0) })
        func drawn(_ array: MLXArray) -> MLXArray {
            drawnCount == shapeCount ? array : take(array, drawnIndices, axis: 0)
        }
        let fills = drawn(colors)
        var image = baseImage * ground + matmul(shows, fills)
        if let gradients {
            // How far along its axis each pixel lies for each shape, 0 at the start and 1
            // at the end; the fill moves that far from `colors` toward `endColors`.
            let axes = drawn(gradients.axes)
            let from = axes[0..., 0]  // [P', 2]
            let along = axes[0..., 1] - from
            func perShape(_ values: MLXArray) -> MLXArray { values.reshaped(drawnCount, 1, 1) }
            let x = pixelX - perShape(from[0..., 0])  // [P', 1, W]
            let y = pixelY - perShape(from[0..., 1])  // [P', H, 1]
            let length = perShape((along * along).sum(axis: -1)) + 1e-6
            let t = clip(
                (x * perShape(along[0..., 0]) + y * perShape(along[0..., 1])) / length, min: 0,
                max: 1)  // [P', H, W]
            image =
                image + matmul(shows * t.transposed(1, 2, 0), drawn(gradients.endColors) - fills)
        }
        return (image, boundary)
    }

    /// For the n shapes of a batch, the signed distance [n, h, w] from every pixel centre
    /// of each shape's window to that shape's outline: positive inside, negative outside.
    private func signedDistance(points: MLXArray, batch: WindowLayout.Batch) -> MLXArray {
        let count = batch.shapes.count
        let starts = matmul(basisStart, points)  // [n, E, 2]: where each edge starts
        let ends = matmul(basisEnd, points)
        let edges = starts.dim(1)
        let startX = starts[0..., 0..., 0]  // [n, E]
        let startY = starts[0..., 0..., 1]
        let endX = ends[0..., 0..., 0]
        let endY = ends[0..., 0..., 1]
        let x =
            MLXArray(batch.originsX.map { Float($0) }, [count, 1, 1])
            + MLXArray((0..<batch.width).map { Float($0) + 0.5 }, [1, 1, batch.width])  // [n, 1, w]
        let y =
            MLXArray(batch.originsY.map { Float($0) }, [count, 1, 1])
            + MLXArray((0..<batch.height).map { Float($0) + 0.5 }, [1, batch.height, 1])  // [n, h, 1]

        // The costly part, every pixel against every edge, only has to find which edge is
        // nearest and whether the pixel is inside. Neither answer has a derivative, so
        // this is done on copies of the edges that carry none: nothing here is
        // revisited when the derivative is taken.
        func fixed(_ values: MLXArray) -> MLXArray {
            stopGradient(values).reshaped(count, 1, 1, edges)
        }
        let ax = fixed(startX)
        let ay = fixed(startY)
        let bx = fixed(endX)
        let by = fixed(endY)
        let pixelX = x.expandedDimensions(axis: -1)  // [n, 1, w, 1]
        let pixelY = y.expandedDimensions(axis: -1)  // [n, h, 1, 1]
        let dx = bx - ax
        let dy = by - ay
        let relX = pixelX - ax  // [n, 1, w, E]
        let relY = pixelY - ay  // [n, h, 1, E]
        let t = clip((relX * dx + relY * dy) / (dx * dx + dy * dy + 1e-8), min: 0, max: 1)
        let offX = relX - t * dx
        let offY = relY - t * dy
        let squared = offX * offX + offY * offY  // [n, h, w, E]
        // Which edge is nearest to each pixel, as a table of 0s and 1s. Where edges are
        // equally near, as two are all around the corner they share, the first one counts.
        // (Two plain minimums: MLX's own "index of the least" is several times slower.)
        let order = MLXArray(Int32(0)..<Int32(edges))
        let rank = which(
            squared .== squared.min(axis: -1, keepDims: true), order, MLXArray(Int32(edges)))
        let isNearest = (rank .== rank.min(axis: -1, keepDims: true)).asType(.float32)

        // Non-zero inside test: a ray toward +x counts each edge it crosses as +1 or -1 by
        // the edge's direction; the pixel is inside if these do not cancel. A shape that
        // overlaps itself is therefore solid there, not cut out.
        let straddles = (ay .> pixelY) .!= (by .> pixelY)
        let safeDy = which(straddles, dy, MLXArray(Float(1)))
        let crossX = ax + (pixelY - ay) / safeDy * dx
        let direction = which(by .> ay, MLXArray(Int32(1)), MLXArray(Int32(-1)))
        let winding = which(
            logicalAnd(straddles, pixelX .< crossX), direction, MLXArray(Int32(0))
        ).sum(axis: -1)
        let sign = which(winding .!= MLXArray(Int32(0)), MLXArray(Float(1)), MLXArray(Float(-1)))

        // The distance to that one nearest edge again, this time with its derivative. It
        // is the same number, and the same derivative, as the least distance over all the
        // edges would give.
        // The edge's end points are picked out by multiplying with the table, not looked
        // up by index. Taking the derivative then adds each edge's share back up as a
        // matrix product, in the same order every time; an indexed lookup adds in whatever
        // order the GPU gets to the pixels, and the rounding differences are enough for
        // two fits of the same photo to drift apart. The product is taken one window row
        // at a time because MLX is slow at one product spanning a whole large window.
        let rows = count * batch.height
        let endPoints = concatenated([starts, ends], axis: -1)  // [n, E, 4]
        let perRow = broadcast(
            endPoints.expandedDimensions(axis: 1), to: [count, batch.height, edges, 4]
        ).reshaped(rows, edges, 4)
        let chosen = split(
            matmul(isNearest.reshaped(rows, batch.width, edges), perRow), parts: 4, axis: -1
        ).map { $0.reshaped(count, batch.height, batch.width) }
        let nearX = chosen[0]
        let nearY = chosen[1]
        let edgeX = chosen[2] - nearX
        let edgeY = chosen[3] - nearY
        let fromX = x - nearX
        let fromY = y - nearY
        let s = clip(
            (fromX * edgeX + fromY * edgeY) / (edgeX * edgeX + edgeY * edgeY + 1e-8), min: 0, max: 1)
        let gapX = fromX - s * edgeX
        let gapY = fromY - s * edgeY
        return sign * sqrt(gapX * gapX + gapY * gapY + 1e-8)
    }
}
