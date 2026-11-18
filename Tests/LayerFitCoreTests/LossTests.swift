import MLX
import XCTest
@testable import LayerFitCore

final class LossTests: XCTestCase {
    let white = RGB(r: 1, g: 1, b: 1)

    func testXingZeroForCircle() {
        let circle = Shape.circle(center: SIMD2(20, 20), radius: 10, color: white)
        XCTAssertLessThan(xingLoss(points: pointsArray([circle])).item(Float.self), 1e-4)
    }

    func testXingZeroForNoShapes() {
        XCTAssertEqual(xingLoss(points: pointsArray([])).item(Float.self), 0)
    }

    func testXingPositiveForSelfCrossingSegment() {
        var circle = Shape.circle(center: SIMD2(0, 0), radius: 10, color: white)
        // Throw segment 0's second control point across the chord so the handles cross.
        circle.points[2] = SIMD2(-5.5, 10)
        XCTAssertGreaterThan(xingLoss(points: pointsArray([circle])).item(Float.self), 0.1)
    }

    func testXingIsMirrorSymmetric() {
        // A clockwise circle is as valid as a counter-clockwise one.
        let circle = Shape.circle(center: SIMD2(0, 0), radius: 10, color: white)
        let mirrored = Shape(points: circle.points.map { SIMD2(-$0.x, $0.y) }, color: white)
        XCTAssertLessThan(xingLoss(points: pointsArray([mirrored])).item(Float.self), 1e-4)
    }

    func testLossIsOnlyXingWhenImageEqualsTarget() {
        var circle = Shape.circle(center: SIMD2(0, 0), radius: 10, color: white)
        circle.points[2] = SIMD2(-5.5, 10)
        let points = pointsArray([circle])
        let image = MLXArray.ones([8, 8, 3]) * 0.3
        let config = LossConfig()
        let loss = fitLoss(
            image: image, target: image, boundaryDistance: MLXArray.zeros([8, 8]),
            points: points, config: config
        ).item(Float.self)
        let expected = config.xingWeight * xingLoss(points: points).item(Float.self)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(loss, expected, accuracy: 1e-6)
    }

    func testFloorTermActsWithNoShapes() {
        let image = MLXArray.zeros([8, 8, 3])
        let target = MLXArray.ones([8, 8, 3]) * 0.5
        let config = LossConfig()
        let loss = fitLoss(
            image: image, target: target,
            boundaryDistance: MLXArray.zeros([8, 8]) + Rasterizer.noBoundary,
            points: pointsArray([]), config: config
        ).item(Float.self)
        // Per-pixel squared error summed over channels is 3 * 0.25.
        XCTAssertEqual(loss, config.floorWeight * 0.75, accuracy: 1e-5)
    }

    func testPixelsNearBoundaryWeighMore() {
        // Same error placed near the boundary must cost more than far from it.
        var distance = [Float](repeating: 100, count: 64)
        distance[0] = 0
        let boundary = MLXArray(distance, [8, 8])
        let target = MLXArray.zeros([8, 8, 3])
        func loss(errorAt index: Int) -> Float {
            var pixels = [Float](repeating: 0, count: 64 * 3)
            pixels[index * 3] = 1
            return fitLoss(
                image: MLXArray(pixels, [8, 8, 3]), target: target, boundaryDistance: boundary,
                points: pointsArray([]), config: LossConfig()
            ).item(Float.self)
        }
        XCTAssertGreaterThan(loss(errorAt: 0), loss(errorAt: 40) * 5)
    }

    func testWeightIsNotDifferentiated() {
        let image = MLXArray.zeros([8, 8, 3])
        let target = MLXArray.ones([8, 8, 3])
        let g = grad { (distance: MLXArray) -> MLXArray in
            fitLoss(
                image: image, target: target, boundaryDistance: distance,
                points: pointsArray([]), config: LossConfig())
        }(MLXArray.ones([8, 8]) * 3)
        XCTAssertEqual(abs(g).max().item(Float.self), 0)
    }

    func testPlainMSE() {
        let image = MLXArray.zeros([4, 4, 3])
        let target = MLXArray.ones([4, 4, 3]) * 0.5
        XCTAssertEqual(plainMSE(image: image, target: target).item(Float.self), 0.25, accuracy: 1e-6)
    }
}
