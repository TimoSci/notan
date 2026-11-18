import MLX
import XCTest
@testable import LayerFitCore

final class RasterizerTests: XCTestCase {
    let white = RGB(r: 1, g: 1, b: 1)
    let black = RGB(r: 0, g: 0, b: 0)
    let red = RGB(r: 1, g: 0, b: 0)
    let blue = RGB(r: 0, g: 0, b: 1)

    func render(_ shapes: [LayerFitCore.Shape], background: RGB, size: Int = 64, chunk: Int = 32)
        -> (image: MLXArray, boundaryDistance: MLXArray)
    {
        let rasterizer = Rasterizer(width: size, height: size, chunk: chunk)
        return rasterizer.render(
            points: pointsArray(shapes), colors: colorsArray(shapes),
            background: colorArray(background))
    }

    func pixel(_ image: MLXArray, x: Int, y: Int) -> [Float] {
        image[y, x].asArray(Float.self)
    }

    func testEmptyRendersBackground() {
        let (image, distance) = render([], background: RGB(r: 0.2, g: 0.4, b: 0.6))
        XCTAssertEqual(image.shape, [64, 64, 3])
        XCTAssertEqual(pixel(image, x: 0, y: 0), [0.2, 0.4, 0.6])
        XCTAssertEqual(pixel(image, x: 63, y: 31), [0.2, 0.4, 0.6])
        XCTAssertEqual(distance.shape, [64, 64])
        XCTAssertEqual(distance.min().item(Float.self), 1e6)
    }

    func testCircleCoverage() {
        let circle = Shape.circle(center: SIMD2(32, 32), radius: 20, color: white)
        let (image, _) = render([circle], background: black)
        let area = image.sum().item(Float.self) / 3
        let expected = Float.pi * 20 * 20
        XCTAssertEqual(area, expected, accuracy: expected * 0.02)
    }

    func testCentreAndCornerPixels() {
        let circle = Shape.circle(center: SIMD2(32, 32), radius: 20, color: white)
        let (image, _) = render([circle], background: black)
        XCTAssertGreaterThan(pixel(image, x: 32, y: 32)[0], 0.99)
        XCTAssertLessThan(pixel(image, x: 0, y: 0)[0], 0.01)
    }

    func testLaterShapeCoversEarlier() {
        let big = Shape.circle(center: SIMD2(32, 32), radius: 20, color: red)
        let small = Shape.circle(center: SIMD2(32, 32), radius: 10, color: blue)
        let (image, _) = render([big, small], background: black)
        let centre = pixel(image, x: 32, y: 32)
        XCTAssertLessThan(centre[0], 0.01)
        XCTAssertGreaterThan(centre[2], 0.99)
        let ring = pixel(image, x: 47, y: 32)
        XCTAssertGreaterThan(ring[0], 0.9)
    }

    func testBoundaryDistance() {
        let circle = Shape.circle(center: SIMD2(32.5, 32.5), radius: 20, color: white)
        let (_, distance) = render([circle], background: black)
        XCTAssertEqual(distance[32, 32].item(Float.self), 20, accuracy: 0.5)
        XCTAssertLessThan(distance[32, 52].item(Float.self), 1)
    }

    func testGradientMovesShapeTowardTarget() {
        let rasterizer = Rasterizer(width: 64, height: 64)
        let targetShape = Shape.circle(center: SIMD2(36, 32), radius: 12, color: white)
        let target = render([targetShape], background: black).image
        let start = Shape.circle(center: SIMD2(32, 32), radius: 12, color: white)
        let colors = colorsArray([start])
        let background = colorArray(black)
        let lossGrad = grad { (points: MLXArray) -> MLXArray in
            let image = rasterizer.render(points: points, colors: colors, background: background).image
            return ((image - target) * (image - target)).mean()
        }
        let g = lossGrad(pointsArray([start]))
        XCTAssertEqual(g.shape, [1, 12, 2])
        // Moving every point in +x lowers the loss.
        XCTAssertLessThan(g[0..., 0..., 0].mean().item(Float.self), 0)
        XCTAssertEqual(g[0..., 0..., 1].mean().item(Float.self), 0, accuracy: 1e-5)
    }

    func testCollapsedShapeIsFinite() {
        let rasterizer = Rasterizer(width: 32, height: 32)
        let collapsed = Shape(points: Array(repeating: SIMD2(16, 16), count: 12), color: white)
        let colors = colorsArray([collapsed])
        let background = colorArray(black)
        let target = MLXArray.ones([32, 32, 3])
        let lossGrad = valueAndGrad { (arrays: [MLXArray]) -> [MLXArray] in
            let image = rasterizer.render(points: arrays[0], colors: colors, background: background).image
            return [((image - target) * (image - target)).mean()]
        }
        let (value, g) = lossGrad([pointsArray([collapsed])])
        XCTAssertTrue(value[0].item(Float.self).isFinite)
        XCTAssertTrue(g[0].asArray(Float.self).allSatisfy { $0.isFinite })
        let image = rasterizer.render(
            points: pointsArray([collapsed]), colors: colors, background: background).image
        XCTAssertTrue(image.asArray(Float.self).allSatisfy { $0.isFinite })
    }

    func testChunkingMatchesUnchunked() {
        let shapes = (0..<5).map { i in
            Shape.circle(
                center: SIMD2(12 + Float(i) * 9, 20 + Float(i) * 5), radius: 8,
                color: RGB(r: Float(i) / 5, g: 0.5, b: 1 - Float(i) / 5))
        }
        let whole = render(shapes, background: black, chunk: 32)
        let chunked = render(shapes, background: black, chunk: 2)
        let imageDiff = abs(whole.image - chunked.image).max().item(Float.self)
        let distanceDiff = abs(whole.boundaryDistance - chunked.boundaryDistance).max().item(Float.self)
        XCTAssertLessThan(imageDiff, 1e-5)
        XCTAssertLessThan(distanceDiff, 1e-4)
    }

    func testNonSquareImageShape() {
        let rasterizer = Rasterizer(width: 40, height: 20)
        let circle = Shape.circle(center: SIMD2(30, 10), radius: 5, color: white)
        let image = rasterizer.render(
            points: pointsArray([circle]), colors: colorsArray([circle]),
            background: colorArray(black)
        ).image
        XCTAssertEqual(image.shape, [20, 40, 3])
        XCTAssertGreaterThan(image[10, 30, 0].item(Float.self), 0.95)  // soft edge: ~4.5 px inside a r=5 circle
        XCTAssertLessThan(image[10, 10, 0].item(Float.self), 0.01)
    }
}
