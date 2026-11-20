import MLX
import XCTest

@testable import LayerFitCore

/// The rasteriser against the plain reference: the same picture, the same edge distances
/// and the same derivatives, however the shapes are cropped and grouped.
final class RasterEquivalenceTests: XCTestCase {
    let width = 96
    let height = 64
    let softness: Float = 0.5
    /// As the fitter sets them: the crop margin lies past the soft edge and past the reach
    /// of the boundary weight.
    let margin: Float = 9
    let reach: Float = 8

    /// A lumpy closed shape with a gradient: a circle with every control point pushed in
    /// or out by a fixed pseudo-random amount.
    func blob(_ x: Float, _ y: Float, radius: Float, seed: UInt32) -> LayerFitCore.Shape {
        var state = seed &* 2_654_435_761 &+ 12345
        func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        let centre = SIMD2(x, y)
        var shape = Shape.circle(
            center: centre, radius: radius, color: RGB(r: next(), g: next(), b: next()))
        for index in shape.points.indices {
            shape.points[index] = centre + (shape.points[index] - centre) * (0.7 + 0.6 * next())
        }
        shape.gradient = Gradient(
            from: centre - SIMD2(radius, radius * 0.5), to: centre + SIMD2(radius, radius * 0.3),
            endColor: RGB(r: next(), g: next(), b: next()))
        return shape
    }

    /// Overlapping shapes of very different sizes, with the sizes mixed up in paint order.
    func scene() -> [LayerFitCore.Shape] {
        [
            blob(40, 30, radius: 4, seed: 1),
            blob(48, 32, radius: 30, seed: 2),  // too big for any window
            blob(70, 20, radius: 2, seed: 3),
            blob(30, 30, radius: 14, seed: 4),
            blob(-30, -30, radius: 5, seed: 5),  // off the picture
            blob(92, 60, radius: 6, seed: 6),  // hangs off the corner
            blob(52, 36, radius: 10, seed: 7),
            blob(44, 30, radius: 20, seed: 8),
            blob(60, 24, radius: 3, seed: 9),
        ]
    }

    func pattern(_ value: (Float, Float, Float) -> Float, channels: Int) -> MLXArray {
        var values: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels { values.append(value(Float(x), Float(y), Float(c))) }
            }
        }
        return MLXArray(values, channels == 1 ? [height, width] : [height, width, channels])
    }

    /// A scalar that depends on the picture everywhere and on the edge distances near edges.
    func loss(_ rendered: (image: MLXArray, boundaryDistance: MLXArray), target: MLXArray) -> MLXArray {
        let diff = rendered.image - target
        let squared = (diff * diff).sum(axis: -1)
        let weight = maximum(1 - rendered.boundaryDistance / reach, 0)
        return (squared * (1 + weight)).sum()
    }

    /// Renders the shapes with the rasteriser and with the reference, and checks that the
    /// pictures, the edge distances and the derivatives of a loss agree.
    func check(
        _ shapes: [LayerFitCore.Shape], cropped: Bool, fills: Bool = false,
        masked: Bool = false, layered: Bool = false, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rasterizer = Rasterizer(width: width, height: height, softness: softness)
        let reference = ReferenceRaster(width: width, height: height, softness: softness)
        let crops =
            cropped
            ? shapes.map { cropRect(points: $0.points, margin: margin, width: width, height: height) }
            : nil
        let skipped = Set((crops ?? []).indices.filter { crops![$0].isEmpty })
        let background = colorArray(RGB(r: 0.3, g: 0.4, b: 0.5))
        let target = pattern({ x, y, c in 0.5 + 0.5 * sin(0.13 * x + 0.07 * y + c) }, channels: 3)
        let mask = masked ? pattern({ x, y, _ in 0.5 + 0.5 * sin(0.2 * x) * cos(0.15 * y) }, channels: 1) : nil
        let base: (image: MLXArray, boundaryDistance: MLXArray)? =
            layered
            ? (
                pattern({ x, y, c in 0.5 + 0.4 * cos(0.05 * x - 0.11 * y + 2 * c) }, channels: 3),
                pattern({ x, y, _ in 2 + 0.3 * x + 0.1 * y }, channels: 1)
            ) : nil

        var inputs = [pointsArray(shapes), colorsArray(shapes)]
        if fills {
            let arrays = gradientArrays(shapes)
            inputs += [arrays.endColors, arrays.axes]
        }
        func real(_ arrays: [MLXArray]) -> (image: MLXArray, boundaryDistance: MLXArray) {
            rasterizer.render(
                points: arrays[0], colors: arrays[1], background: background, crops: crops,
                over: base, mask: mask, gradients: fills ? (arrays[3], arrays[2]) : nil)
        }
        func plain(_ arrays: [MLXArray]) -> (image: MLXArray, boundaryDistance: MLXArray) {
            reference.render(
                points: arrays[0], colors: arrays[1], background: background, skipping: skipped,
                over: base, mask: mask, gradients: fills ? (arrays[3], arrays[2]) : nil)
        }

        let got = real(inputs)
        let expected = plain(inputs)
        XCTAssertLessThan(
            abs(got.image - expected.image).max().item(Float.self), 1e-4, "picture", file: file,
            line: line)
        // A cropped shape's edge only has to be measured within the margin of the shape.
        let near = expected.boundaryDistance .< reach
        let nearGap = which(
            near, abs(got.boundaryDistance - expected.boundaryDistance), MLXArray(Float(0)))
        XCTAssertLessThan(
            nearGap.max().item(Float.self), 1e-3, "edge distance near edges", file: file, line: line)
        let far = which(near, MLXArray(Float(1e6)), got.boundaryDistance)
        XCTAssertGreaterThanOrEqual(
            far.min().item(Float.self), reach, "edge distance away from edges", file: file, line: line)

        let arguments = Array(inputs.indices)
        let realGradient = valueAndGrad(
            { [self.loss(real($0), target: target)] }, argumentNumbers: arguments)(inputs)
        let plainGradient = valueAndGrad(
            { [self.loss(plain($0), target: target)] }, argumentNumbers: arguments)(inputs)
        let names = ["points", "colours", "end colours", "axes"]
        for index in arguments {
            let g = realGradient.1[index]
            let e = plainGradient.1[index]
            XCTAssertTrue(
                g.asArray(Float.self).allSatisfy { $0.isFinite }, "\(names[index]) finite",
                file: file, line: line)
            let scale = abs(e).max().item(Float.self)
            XCTAssertGreaterThan(scale, 1e-3, "\(names[index]) matter", file: file, line: line)
            XCTAssertLessThan(
                abs(g - e).max().item(Float.self), 1e-4 * scale,
                "derivative by \(names[index])", file: file, line: line)
            // Shape by shape as well. The optimiser scales each shape's step to the size
            // of that shape's own derivative, so a small error on a shape whose derivative
            // is small would move it as far as a large error on any other. (Shapes whose
            // derivative is next to nothing, hidden under others, are held to the floor.)
            let mine = g.reshaped(shapes.count, -1)
            let theirs = e.reshaped(shapes.count, -1)
            let worst = abs(mine - theirs).max(axis: 1) / (abs(theirs).max(axis: 1) + 1e-5 * scale)
            XCTAssertLessThan(
                worst.max().item(Float.self), 1e-3,
                "derivative by \(names[index]), shape by shape", file: file, line: line)
        }
    }

    func testWholePictureMatchesReference() {
        check(scene(), cropped: false)
    }

    func testCroppedMatchesReference() {
        check(scene(), cropped: true)
    }

    func testGradientFillsMatchReference() {
        check(scene(), cropped: true, fills: true)
        check(scene(), cropped: false, fills: true)
    }

    func testMaskOverABaseMatchesReference() {
        check(scene(), cropped: true, fills: true, masked: true, layered: true)
    }

    /// Deep inside a shape its coverage is exactly 1, so nothing beneath shows through at
    /// all; several such shapes stacked must still give finite, correct derivatives.
    func testStackedOpaqueShapesMatchReference() {
        let shapes = (0..<5).map {
            blob(40 + Float($0) * 4, 32, radius: 26 - Float($0) * 2, seed: UInt32(20 + $0))
        }
        check(shapes, cropped: true, fills: true)
    }

    /// The picture the shapes are painted over shows through wherever they do not cover,
    /// so the loss has a derivative by it too.
    func testDerivativeByThePictureBeneathMatchesReference() {
        let shapes = scene()
        let rasterizer = Rasterizer(width: width, height: height, softness: softness)
        let reference = ReferenceRaster(width: width, height: height, softness: softness)
        let crops = shapes.map {
            cropRect(points: $0.points, margin: margin, width: width, height: height)
        }
        let skipped = Set(crops.indices.filter { crops[$0].isEmpty })
        let background = colorArray(RGB(r: 0.3, g: 0.4, b: 0.5))
        let target = pattern({ x, y, c in 0.5 + 0.5 * sin(0.13 * x + 0.07 * y + c) }, channels: 3)
        let beneath = pattern({ x, y, c in 0.5 + 0.4 * cos(0.05 * x - 0.11 * y + 2 * c) }, channels: 3)
        let far = MLXArray.zeros([height, width]) + Rasterizer.noBoundary
        let points = pointsArray(shapes)
        let colors = colorsArray(shapes)
        let fills = gradientArrays(shapes)

        let real = valueAndGrad { (arrays: [MLXArray]) -> [MLXArray] in
            [
                self.loss(
                    rasterizer.render(
                        points: points, colors: colors, background: background, crops: crops,
                        over: (arrays[0], far), gradients: fills), target: target)
            ]
        }([beneath]).1[0]
        let plain = valueAndGrad { (arrays: [MLXArray]) -> [MLXArray] in
            [
                self.loss(
                    reference.render(
                        points: points, colors: colors, background: background, skipping: skipped,
                        over: (arrays[0], far), gradients: fills), target: target)
            ]
        }([beneath]).1[0]
        let scale = abs(plain).max().item(Float.self)
        XCTAssertGreaterThan(scale, 1e-3)
        XCTAssertLessThan(abs(real - plain).max().item(Float.self), 1e-4 * scale)
    }

    /// One shape, so one window and nothing to put in order.
    func testSingleShapeMatchesReference() {
        check([blob(30, 40, radius: 9, seed: 31)], cropped: true, fills: true)
    }
}
