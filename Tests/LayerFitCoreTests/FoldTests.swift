import CoreGraphics
import MLX
import XCTest
@testable import LayerFitCore

/// A closed shape through four corners, with straight sides.
func quad(_ corners: [SIMD2<Float>], color: RGB = .white) -> LayerFitCore.Shape {
    var points: [SIMD2<Float>] = []
    for i in 0..<4 {
        let a = corners[i]
        let b = corners[(i + 1) % 4]
        points += [a, a + (b - a) / 3, a + (b - a) * 2 / 3]
    }
    return Shape(points: points, color: color)
}

/// Two triangles meeting at a point: the outline crosses itself once.
func bowTie() -> LayerFitCore.Shape {
    quad([SIMD2(10, 10), SIMD2(30, 10), SIMD2(10, 30), SIMD2(30, 30)])
}

/// An outline that goes round its centre twice: a big loop over the top and under the
/// bottom, then a smaller loop inside it the same way round.
func doubleLoop(center c: SIMD2<Float> = SIMD2(32, 32), color: RGB = .white) -> LayerFitCore.Shape {
    func arc(from a: Float, to b: Float, over: Float) -> [SIMD2<Float>] {
        // From (a, 0) to (b, 0), bulging to y = over * 0.75.
        [SIMD2(c.x + a, c.y), SIMD2(c.x + a, c.y + over), SIMD2(c.x + b, c.y + over)]
    }
    let points =
        arc(from: 24, to: -24, over: -30) + arc(from: -24, to: 12, over: 30)
        + arc(from: 12, to: -12, over: -15) + arc(from: -12, to: 24, over: 15)
    return Shape(points: points, color: color)
}

final class FoldTests: XCTestCase {
    let circle = Shape.circle(center: SIMD2(30, 30), radius: 10, color: .white)

    // MARK: The fold measure

    func testUnfoldedShapesHaveNoFold() {
        XCTAssertLessThan(foldRatio(of: circle), 1e-4)
        XCTAssertLessThan(foldRatio(of: rectangle(x: 5, y: 5, width: 30, height: 12)), 1e-4)
        // The other way round is just as unfolded.
        let mirrored = Shape(points: circle.points.map { SIMD2(60 - $0.x, $0.y) }, color: .white)
        XCTAssertLessThan(foldRatio(of: mirrored), 1e-4)
    }

    func testADentIsNotAFold() {
        // A square with one side pushed a third of the way in.
        var dented = rectangle(x: 10, y: 10, width: 30, height: 30)
        dented.points[1].y += 8
        dented.points[2].y += 8
        XCTAssertLessThan(foldRatio(of: dented), 1e-3)
    }

    func testBowTieIsHalfFolded() {
        // Its two lobes sweep opposite ways round the centre: half the area is backward.
        XCTAssertEqual(foldRatio(of: bowTie()), 0.5, accuracy: 0.05)
    }

    /// A circle with the two handles of one segment thrown across each other, so that
    /// segment makes a small loop.
    func looped() -> LayerFitCore.Shape {
        var shape = circle
        shape.points[1] = SIMD2(24, 44)
        shape.points[2] = SIMD2(44, 24)
        return shape
    }

    func testASmallLoopGivesASmallRatio() {
        let ratio = foldRatio(of: looped())
        XCTAssertGreaterThan(ratio, 0.005)
        XCTAssertLessThan(ratio, 0.4)
    }

    func testCollapsedShapeIsFiniteAndUnfolded() {
        let collapsed = Shape(points: Array(repeating: SIMD2(5, 5), count: 12), color: .white)
        XCTAssertEqual(foldRatio(of: collapsed), 0, accuracy: 1e-3)
    }

    // MARK: The penalty

    func testPenaltyMatchesRatioAndAddsUpOverShapes() {
        let one = foldPenalty(points: pointsArray([bowTie()])).item(Float.self)
        XCTAssertEqual(one, foldRatio(of: bowTie()), accuracy: 1e-3)
        let mixed = foldPenalty(points: pointsArray([bowTie(), circle, bowTie()])).item(Float.self)
        XCTAssertEqual(mixed, 2 * one, accuracy: 1e-3)
        XCTAssertEqual(foldPenalty(points: pointsArray([])).item(Float.self), 0)
    }

    func testPenaltyGradientUnfoldsTheShape() {
        var points = pointsArray([looped()])
        let start = foldPenalty(points: points).item(Float.self)
        let gradient = grad { (p: MLXArray) in foldPenalty(points: p) }
        for _ in 0..<40 {
            let g = gradient(points)
            XCTAssertTrue(g.asArray(Float.self).allSatisfy { $0.isFinite })
            points = points - 20 * g
            eval(points)
        }
        XCTAssertLessThan(foldPenalty(points: points).item(Float.self), start * 0.5)
    }

    func testPenaltyOfCollapsedShapeHasFiniteGradient() {
        let collapsed = Shape(points: Array(repeating: SIMD2(5, 5), count: 12), color: .white)
        let g = grad { (p: MLXArray) in foldPenalty(points: p) }(pointsArray([collapsed]))
        XCTAssertTrue(g.asArray(Float.self).allSatisfy { $0.isFinite })
    }

    func testLossIncludesTheFoldPenaltyByItsWeight() {
        let image = MLXArray.zeros([8, 8, 3])
        let boundary = MLXArray.zeros([8, 8])
        let points = pointsArray([bowTie()])
        func loss(_ config: LossConfig) -> Float {
            fitLoss(image: image, target: image, boundaryDistance: boundary, points: points, config: config)
                .item(Float.self)
        }
        var off = LossConfig()
        off.foldWeight = 0
        var on = LossConfig()
        on.foldWeight = 0.2
        XCTAssertEqual(
            loss(on) - loss(off), 0.2 * foldPenalty(points: points).item(Float.self), accuracy: 1e-5)
        XCTAssertGreaterThan(LossConfig().foldWeight, 0)
    }

    func testAvoidFoldsIsOnByDefault() {
        XCTAssertTrue(FitSettings().avoidFolds)
    }

    // MARK: Fill rule

    func testSelfOverlapIsFilledNotCutOut() throws {
        // The centre is wound round twice. Filling by "non-zero" keeps it solid; "even-odd"
        // would cut a hole there.
        let shape = doubleLoop(color: .red)
        let picture = LayerFitCore.Picture(width: 64, height: 64, background: .white, shapes: [shape])
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: 64, height: 64)))
        let drawn = TargetImage(width: 64, height: 64, pixels: rgbPixels(of: image, width: 64, height: 64))
        XCTAssertEqual(drawn.color(x: 32, y: 32), .red)
        XCTAssertEqual(drawn.color(x: 32, y: 14), .red)  // wound once: filled either way
        XCTAssertEqual(drawn.color(x: 2, y: 2), .white)

        let soft = Rasterizer(width: 64, height: 64, softness: 0.25).render(
            points: pointsArray([shape]), colors: colorsArray([shape]),
            background: colorArray(.white)
        ).image
        XCTAssertEqual(soft[32, 32].asArray(Float.self), [1, 0, 0])
        XCTAssertLessThan(abs(MLXArray(drawn.pixels, [64, 64, 3]) - soft).mean().item(Float.self), 0.02)

        XCTAssertEqual(picture.hitTest(SIMD2(32, 32)), .shape([0]))
        XCTAssertEqual(gapMap(of: picture).label(x: 32, y: 32), -1)
    }

    func testClockwiseAndCounterClockwiseShapesBothFill() {
        let mirrored = Shape(points: circle.points.map { SIMD2(60 - $0.x, $0.y) }, color: .white)
        for shape in [circle, mirrored] {
            let image = Rasterizer(width: 64, height: 64).render(
                points: pointsArray([shape]), colors: colorsArray([shape]),
                background: colorArray(.black)
            ).image
            XCTAssertGreaterThan(image[30, 30, 0].item(Float.self), 0.99)
            XCTAssertLessThan(image[5, 5, 0].item(Float.self), 0.01)
        }
    }

    func testSVGUsesNonZeroFill() throws {
        var parent = doubleLoop(color: .red)
        parent.inner = Inner(levels: [InnerLevel(shapes: [circle], mse: 0)], shown: 0)
        let picture = LayerFitCore.Picture(width: 64, height: 64, background: .white, shapes: [parent])
        let text = svg(picture, outputSize: CGSize(width: 64, height: 64))
        XCTAssertFalse(text.contains("evenodd"))
        XCTAssertTrue(text.contains("fill-rule=\"nonzero\""))
        XCTAssertTrue(text.contains("clip-rule=\"nonzero\""))
    }
}
