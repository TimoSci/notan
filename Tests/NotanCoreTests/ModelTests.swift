import MLX
import XCTest
@testable import NotanCore

final class ModelTests: XCTestCase {
    func testSchedule128() {
        XCTAssertEqual(stageSchedule(totalShapes: 128), [1, 1, 1, 1, 2, 2, 4, 4, 8, 8, 16, 16, 32, 32])
    }

    func testSchedule32() {
        XCTAssertEqual(stageSchedule(totalShapes: 32), [1, 1, 1, 1, 2, 2, 4, 4, 8, 8])
    }

    func testSchedule256() {
        XCTAssertEqual(Array(stageSchedule(totalShapes: 256).suffix(2)), [64, 64])
        XCTAssertEqual(stageSchedule(totalShapes: 256).reduce(0, +), 256)
    }

    func testScheduleOddTotalTruncatesLastStage() {
        XCTAssertEqual(stageSchedule(totalShapes: 10), [1, 1, 1, 1, 2, 2, 2])
    }

    func testScheduleZeroIsEmpty() {
        XCTAssertEqual(stageSchedule(totalShapes: 0), [])
    }

    func testEstimatedBytes() {
        let shape = Shape.circle(center: SIMD2(10, 10), radius: 5, color: RGB(r: 1, g: 0, b: 0))
        let picture = Picture(
            width: 32, height: 32, background: RGB(r: 0, g: 0, b: 0),
            shapes: Array(repeating: shape, count: 16))
        XCTAssertEqual(picture.estimatedBytes, 819)
    }

    func testCircleHas12PointsWithAnchorsOnRadius() {
        let centre = SIMD2<Float>(50, 40)
        let shape = Shape.circle(center: centre, radius: 20, color: RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(shape.points.count, 12)
        for anchor in [0, 3, 6, 9] {
            let d = shape.points[anchor] - centre
            XCTAssertEqual((d * d).sum().squareRoot(), 20, accuracy: 1e-4)
        }
    }

    func testMLXGradWorks() {
        let g = grad { (x: MLXArray) in (x * x).sum() }(MLXArray([1.0, 2.0, 3.0] as [Float]))
        XCTAssertEqual(g.asArray(Float.self), [2, 4, 6])
    }
}
