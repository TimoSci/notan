import MLX
import XCTest
@testable import NotanCore

/// An axis-aligned rectangle as a shape: four straight segments, handles on the edges.
func rectangle(x: Float, y: Float, width: Float, height: Float, color: RGB = .white) -> NotanCore.Shape {
    let corners: [SIMD2<Float>] = [
        SIMD2(x, y), SIMD2(x + width, y), SIMD2(x + width, y + height), SIMD2(x, y + height),
    ]
    var points: [SIMD2<Float>] = []
    for i in 0..<4 {
        let a = corners[i]
        let b = corners[(i + 1) % 4]
        points += [a, a + (b - a) / 3, a + (b - a) * 2 / 3]
    }
    return Shape(points: points, color: color)
}

/// A circle with one anchor pulled far out into a needle.
func spiked() -> NotanCore.Shape {
    var shape = Shape.circle(center: SIMD2(0, 0), radius: 10, color: .white)
    shape.points[0] = SIMD2(60, 0)
    shape.points[1] = SIMD2(12, 0.5)
    shape.points[11] = SIMD2(12, -0.5)
    return shape
}

final class ThinnessTests: XCTestCase {
    let circle = Shape.circle(center: SIMD2(30, 30), radius: 10, color: .white)
    let sliver = rectangle(x: 5, y: 20, width: 40, height: 2)

    // MARK: Mean width

    func testMeanWidthOfCircleIsItsRadius() {
        XCTAssertEqual(meanWidth(of: circle), 10, accuracy: 0.2)
    }

    func testMeanWidthOfLongStripIsItsWidth() {
        // 2 * area / perimeter = 2 * 80 / 84
        XCTAssertEqual(meanWidth(of: sliver), 1.905, accuracy: 0.02)
    }

    func testMeanWidthIgnoresWindingDirection() {
        let mirrored = Shape(points: circle.points.map { SIMD2(60 - $0.x, $0.y) }, color: .white)
        XCTAssertEqual(meanWidth(of: mirrored), meanWidth(of: circle), accuracy: 1e-3)
    }

    func testArrayMeanWidthsMatchPerShape() {
        let widths = meanWidths(points: pointsArray([circle, sliver])).asArray(Float.self)
        XCTAssertEqual(widths[0], meanWidth(of: circle), accuracy: 1e-3)
        XCTAssertEqual(widths[1], meanWidth(of: sliver), accuracy: 1e-3)
    }

    func testMeanWidthOfCollapsedShapeIsZeroAndFinite() {
        let collapsed = Shape(points: Array(repeating: SIMD2(5, 5), count: 12), color: .white)
        XCTAssertEqual(meanWidth(of: collapsed), 0, accuracy: 1e-3)
    }

    // MARK: Width penalty

    func testWidthPenaltyIsZeroForWideShape() {
        let penalty = widthPenalty(points: pointsArray([circle]), minWidths: MLXArray([4.0] as [Float]))
        XCTAssertEqual(penalty.item(Float.self), 0)
    }

    func testWidthPenaltyIsPositiveForThinShape() {
        let penalty = widthPenalty(points: pointsArray([sliver]), minWidths: MLXArray([4.0] as [Float]))
        // (1 - 1.905 / 4)^2
        XCTAssertEqual(penalty.item(Float.self), 0.274, accuracy: 0.01)
    }

    func testWidthPenaltyAddsUpOverShapesWithTheirOwnThresholds() {
        // The circle (width 10) is fine at 4 but not at 20; the sliver fails at 4.
        let penalty = widthPenalty(
            points: pointsArray([circle, sliver, circle]),
            minWidths: MLXArray([4.0, 4.0, 20.0] as [Float]))
        XCTAssertEqual(penalty.item(Float.self), 0.274 + 0.25, accuracy: 0.02)
    }

    func testWidthPenaltyIsOffWhereThresholdIsZero() {
        let penalty = widthPenalty(points: pointsArray([sliver]), minWidths: MLXArray([0.0] as [Float]))
        XCTAssertEqual(penalty.item(Float.self), 0)
    }

    func testWidthPenaltyGradientWidensTheShape() {
        let minWidths = MLXArray([4.0] as [Float])
        let points = pointsArray([sliver])
        let g = grad { (p: MLXArray) in widthPenalty(points: p, minWidths: minWidths) }(points)
        XCTAssertTrue(g.asArray(Float.self).allSatisfy { $0.isFinite })
        let stepped = points - 5 * g
        XCTAssertLessThan(
            widthPenalty(points: stepped, minWidths: minWidths).item(Float.self),
            widthPenalty(points: points, minWidths: minWidths).item(Float.self))
    }

    func testWidthPenaltyOfCollapsedShapeIsFinite() {
        let collapsed = Shape(points: Array(repeating: SIMD2(5, 5), count: 12), color: .white)
        let minWidths = MLXArray([4.0] as [Float])
        let g = grad { (p: MLXArray) in widthPenalty(points: p, minWidths: minWidths) }(
            pointsArray([collapsed]))
        XCTAssertTrue(g.asArray(Float.self).allSatisfy { $0.isFinite })
    }

    // MARK: Corner penalty

    func testCornerPenaltyIsZeroForCircle() {
        XCTAssertLessThan(cornerPenalty(points: pointsArray([circle])).item(Float.self), 1e-4)
    }

    func testCornerPenaltyForRightAnglesIsAQuarterOfANeedles() {
        // Each corner turns 90°: ((1 - cos 90°) / 2)^2 = 0.25; a full reversal would be 1.
        let box = rectangle(x: 0, y: 0, width: 20, height: 20)
        XCTAssertEqual(cornerPenalty(points: pointsArray([box])).item(Float.self), 0.25, accuracy: 1e-3)
    }

    func testCornerPenaltyIsLargeForSpike() {
        // One anchor of four turns back on itself almost completely.
        XCTAssertGreaterThan(cornerPenalty(points: pointsArray([spiked()])).item(Float.self), 0.2)
    }

    func testCornerPenaltyAddsUpOverShapes() {
        let one = cornerPenalty(points: pointsArray([spiked()])).item(Float.self)
        let two = cornerPenalty(points: pointsArray([spiked(), spiked()])).item(Float.self)
        XCTAssertEqual(two, 2 * one, accuracy: 1e-4)
    }

    func testCornerPenaltyOfCollapsedShapeIsFinite() {
        let collapsed = Shape(points: Array(repeating: SIMD2(5, 5), count: 12), color: .white)
        let g = grad { (p: MLXArray) in cornerPenalty(points: p) }(pointsArray([collapsed]))
        XCTAssertTrue(g.asArray(Float.self).allSatisfy { $0.isFinite })
    }

    // MARK: In the loss

    func testFitLossUnchangedWithoutMinWidths() {
        let image = MLXArray.zeros([8, 8, 3])
        let target = MLXArray.ones([8, 8, 3]) * 0.5
        let boundary = MLXArray.zeros([8, 8])
        let points = pointsArray([sliver])
        let plain = fitLoss(
            image: image, target: target, boundaryDistance: boundary, points: points,
            config: LossConfig()
        ).item(Float.self)
        let config = LossConfig()
        let withWidths = fitLoss(
            image: image, target: target, boundaryDistance: boundary, points: points,
            config: config, minWidths: MLXArray([4.0] as [Float])
        ).item(Float.self)
        let expected =
            plain
            + config.widthWeight
                * widthPenalty(points: points, minWidths: MLXArray([4.0] as [Float])).item(Float.self)
            + config.cornerWeight * cornerPenalty(points: points).item(Float.self)
        XCTAssertGreaterThan(withWidths, plain)
        XCTAssertEqual(withWidths, expected, accuracy: 1e-5)
    }

    // MARK: Schedule

    func testMinWidthShrinksWithTheSquareRootOfShapesSoFar() {
        let schedule = stageSchedule(totalShapes: 128)
        let widths = minWidthSchedule(minWidth: 2, schedule: schedule, longSide: 2560)
        XCTAssertEqual(widths.count, schedule.count)
        XCTAssertEqual(widths[0], 2 * Float(128).squareRoot(), accuracy: 1e-3)  // 1 shape so far
        XCTAssertEqual(widths[3], 2 * Float(32).squareRoot(), accuracy: 1e-3)  // 4 shapes so far
        XCTAssertEqual(widths.last!, 2, accuracy: 1e-5)
        XCTAssertEqual(widths, widths.sorted(by: >))
    }

    func testMinWidthIsCappedAtASixthOfTheLongSide() {
        let widths = minWidthSchedule(
            minWidth: 8, schedule: stageSchedule(totalShapes: 256), longSide: 256)
        XCTAssertEqual(widths[0], 256.0 / 6, accuracy: 1e-3)
        XCTAssertEqual(widths.last!, 8, accuracy: 1e-5)
    }

    func testMinWidthOffGivesZeros() {
        XCTAssertEqual(
            minWidthSchedule(minWidth: 0, schedule: [1, 1, 2], longSide: 256), [0, 0, 0])
    }
}
