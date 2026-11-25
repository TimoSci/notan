import CoreGraphics
import MLX
import XCTest
@testable import NotanCore

/// A closed shape through four corners, with straight sides.
func quad(_ corners: [SIMD2<Float>], color: RGB = .white) -> NotanCore.Shape {
    var points: [SIMD2<Float>] = []
    for i in 0..<4 {
        let a = corners[i]
        let b = corners[(i + 1) % 4]
        points += [a, a + (b - a) / 3, a + (b - a) * 2 / 3]
    }
    return Shape(points: points, color: color)
}

/// Two triangles meeting at a point: the outline crosses itself once.
func bowTie() -> NotanCore.Shape {
    quad([SIMD2(10, 10), SIMD2(30, 10), SIMD2(10, 30), SIMD2(30, 30)])
}

/// An outline that goes round its centre twice: a big loop over the top and under the
/// bottom, then a smaller loop inside it the same way round.
func doubleLoop(center c: SIMD2<Float> = SIMD2(32, 32), color: RGB = .white) -> NotanCore.Shape {
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
    func looped() -> NotanCore.Shape {
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

    // MARK: Counting real crossings

    func testCrossingsAreCountedWhereTheOutlineCutsItself() {
        XCTAssertEqual(selfCrossings(of: circle), 0)
        XCTAssertEqual(selfCrossings(of: rectangle(x: 5, y: 5, width: 30, height: 12)), 0)
        // (Skewed, so that the crossing does not fall exactly on a sampled point.)
        let skewed = quad([SIMD2(10, 10), SIMD2(30, 10), SIMD2(10, 30), SIMD2(37, 26)])
        XCTAssertEqual(selfCrossings(of: skewed), 1)
        XCTAssertGreaterThan(selfCrossings(of: looped()), 0)
    }

    func testAThinTwistedTailCrossesItselfThoughItHardlyCountsAsFolded() {
        // A square body with a long tail one pixel wide whose two sides swap over half
        // way along. The tail sweeps almost no area, so the fold ratio barely sees it.
        let shape = Shape(
            points: [
                SIMD2(10, 10), SIMD2(20, 10), SIMD2(30, 10),
                SIMD2(30, 19.5), SIMD2(45, 20.5), SIMD2(60, 20.5),
                SIMD2(60, 19.5), SIMD2(45, 19.5), SIMD2(30, 20.5),
                SIMD2(30, 30), SIMD2(20, 30), SIMD2(10, 30),
            ], color: .white)
        XCTAssertGreaterThan(selfCrossings(of: shape), 0)
        XCTAssertLessThan(foldRatio(of: shape), 0.05)
    }

    // MARK: Undoing steps that cross

    func testAStepThatMakesAShapeCrossItselfIsUndoneForThatShapeOnly() {
        let skewed = quad([SIMD2(10, 10), SIMD2(30, 10), SIMD2(10, 30), SIMD2(37, 26)])
        let moved = Shape.circle(center: SIMD2(31, 30), radius: 10, color: .white)
        let before = pointsArray([circle, circle])
        let after = pointsArray([skewed, moved])
        let undone = undoingCrossings(after, previous: before)
        XCTAssertEqual(undone.points[0].asArray(Float.self), before[0].asArray(Float.self))
        XCTAssertEqual(undone.points[1].asArray(Float.self), after[1].asArray(Float.self))
        XCTAssertEqual(undone.undone, [0])
    }

    func testAStepWithoutCrossingsIsLeftAlone() {
        let before = pointsArray([circle])
        let after = pointsArray([Shape.circle(center: SIMD2(31, 30), radius: 10, color: .white)])
        let undone = undoingCrossings(after, previous: before)
        XCTAssertEqual(undone.points.asArray(Float.self), after.asArray(Float.self))
        XCTAssertTrue(undone.undone.isEmpty)
    }

    func testAShapeThatAlreadyCrossedMayStillMove() {
        // Only new crossings are undone: a shape that came in crossed is not frozen.
        let skewed = quad([SIMD2(10, 10), SIMD2(30, 10), SIMD2(10, 30), SIMD2(37, 26)])
        let shifted = Shape(points: skewed.points.map { $0 + SIMD2(1, 0) }, color: .white)
        let undone = undoingCrossings(pointsArray([shifted]), previous: pointsArray([skewed]))
        XCTAssertTrue(undone.undone.isEmpty)
    }

    func testOnlyNoFoldAtAllForbidsCrossings() {
        var settings = FitSettings()
        XCTAssertTrue(settings.forbidsCrossings)
        settings.foldTolerance = 0.05
        XCTAssertFalse(settings.forbidsCrossings)
    }

    func testWithFoldChecksOffNothingIsCheckedWhateverTheSliders() {
        var settings = FitSettings()
        XCTAssertTrue(settings.limitsFolds)
        settings.limitsFolds = false
        XCTAssertFalse(settings.forbidsCrossings)
        XCTAssertTrue(settings.allowsAnyFold)
        XCTAssertEqual(settings.withFolds(LossConfig()).foldWeight, 0)
        // The sliders keep their values for when it is switched on again.
        XCTAssertEqual(settings.foldTolerance, 0)
        XCTAssertEqual(settings.foldStrength, 1)
    }

    /// A busy picture: blocks of unrelated colours, which shapes twist themselves to reach.
    func blocks() -> TargetImage {
        makeTarget(width: 64, height: 64) { x, y in
            let cell = Int(x / 8) * 7 + Int(y / 8) * 13
            let value = Float((cell * 37) % 11) / 10
            return RGB(r: value, g: Float((cell * 17) % 7) / 6, b: 1 - value)
        }
    }

    func crossingShapes(_ mode: LevelMode, tolerance: Float) -> Int {
        var settings = FitSettings(
            totalShapes: 16, workingSize: 64, stepsPerStage: 60, mode: mode, foldTolerance: tolerance)
        settings.foldStrength = 1
        let levels = Fitter(target: blocks(), settings: settings)
            .run(progress: { _ in }, isCancelled: { false })
        return levels.map { $0.picture.shapes.filter { selfCrossings(of: $0) > 0 }.count }.max()!
    }

    func testWithFoldsAtNoneNoOutlineCrossesItselfAtAnyLevel() {
        XCTAssertEqual(crossingShapes(.refit, tolerance: 0), 0)
        XCTAssertEqual(crossingShapes(.prefix, tolerance: 0), 0)
        // The picture is one that does make shapes cross when they may.
        XCTAssertGreaterThan(crossingShapes(.refit, tolerance: FitSettings.maxFoldTolerance), 0)
    }

    // MARK: The penalty

    func testPenaltyIsTheFoldRatioTimesTheShapesShareOfThePicture() {
        // The bow-tie's two triangles cover 200 px² of a 1000 px² picture.
        let one = foldPenalty(points: pointsArray([bowTie()]), pictureArea: 1000).item(Float.self)
        XCTAssertEqual(one, foldRatio(of: bowTie()) * 0.2, accuracy: 2e-3)
        let mixed = foldPenalty(points: pointsArray([bowTie(), circle, bowTie()]), pictureArea: 1000)
            .item(Float.self)
        XCTAssertEqual(mixed, 2 * one, accuracy: 1e-3)
        XCTAssertEqual(foldPenalty(points: pointsArray([]), pictureArea: 1000).item(Float.self), 0)
    }

    func testPenaltyOfTheSameFoldGrowsWithTheShapesSize() {
        let small = bowTie()
        let big = Shape(points: small.points.map { $0 * 3 }, color: .white)
        let a = foldPenalty(points: pointsArray([small]), pictureArea: 10000).item(Float.self)
        let b = foldPenalty(points: pointsArray([big]), pictureArea: 10000).item(Float.self)
        XCTAssertEqual(b, 9 * a, accuracy: 1e-3)
        // And the same shape in a picture four times the area counts a quarter.
        let c = foldPenalty(points: pointsArray([small]), pictureArea: 40000).item(Float.self)
        XCTAssertEqual(c, a / 4, accuracy: 1e-4)
    }

    func testPenaltyCountsOnlyTheFoldOverTheTolerance() {
        let ratio = foldRatio(of: bowTie())
        let within = foldPenalty(points: pointsArray([bowTie()]), tolerance: ratio + 0.01, pictureArea: 1000)
        XCTAssertEqual(within.item(Float.self), 0)
        let over = foldPenalty(points: pointsArray([bowTie()]), tolerance: ratio - 0.1, pictureArea: 1000)
        XCTAssertEqual(over.item(Float.self), 0.1 * 0.2, accuracy: 2e-3)
    }

    func testPenaltyDoesNotRewardShrinkingTheShape() {
        // The share of the picture is a weight, not something to optimise: scaling a
        // folded shape about its centre leaves its fold as it is, so no gradient that way.
        let points = pointsArray([bowTie()])
        let g = grad { (p: MLXArray) in foldPenalty(points: p, pictureArea: 1000) }(points)
        let centre = points.mean(axis: 1, keepDims: true)
        let radial = (g * (points - centre)).sum().item(Float.self)
        XCTAssertEqual(radial, 0, accuracy: 1e-3)
    }

    func testPenaltyGradientUnfoldsTheShape() {
        var points = pointsArray([looped()])
        let start = foldPenalty(points: points, pictureArea: 100).item(Float.self)
        let gradient = grad { (p: MLXArray) in foldPenalty(points: p, pictureArea: 100) }
        for _ in 0..<40 {
            let g = gradient(points)
            XCTAssertTrue(g.asArray(Float.self).allSatisfy { $0.isFinite })
            points = points - 20 * g
            eval(points)
        }
        XCTAssertLessThan(foldPenalty(points: points, pictureArea: 100).item(Float.self), start * 0.5)
    }

    func testPenaltyOfCollapsedShapeHasFiniteGradient() {
        let collapsed = Shape(points: Array(repeating: SIMD2(5, 5), count: 12), color: .white)
        let g = grad { (p: MLXArray) in foldPenalty(points: p, pictureArea: 1000) }(pointsArray([collapsed]))
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
        // The picture here is 8 by 8.
        XCTAssertEqual(
            loss(on) - loss(off),
            0.2 * foldPenalty(points: points, pictureArea: 64).item(Float.self), accuracy: 1e-4)
        XCTAssertGreaterThan(LossConfig().foldWeight, 0)
    }

    func testNoFoldIsAllowedByDefault() {
        XCTAssertEqual(FitSettings().foldTolerance, 0)
        XCTAssertFalse(FitSettings().allowsAnyFold)
    }

    func testFoldSettingsReachTheLoss() {
        var settings = FitSettings()
        XCTAssertEqual(settings.foldStrength, 1)
        settings.foldTolerance = 0.2
        settings.foldStrength = 0.03
        let config = settings.withFolds(LossConfig())
        XCTAssertEqual(config.foldTolerance, 0.2)
        XCTAssertEqual(config.foldWeight, 0.03)
        // Any fold allowed: no penalty at all, whatever the strength.
        settings.foldTolerance = FitSettings.maxFoldTolerance
        XCTAssertEqual(settings.withFolds(LossConfig()).foldWeight, 0)
    }

    func testTheTopOfTheFoldRangeAllowsAnyFold() {
        var settings = FitSettings()
        settings.foldTolerance = FitSettings.maxFoldTolerance
        XCTAssertTrue(settings.allowsAnyFold)
        settings.foldTolerance = FitSettings.maxFoldTolerance - 0.05
        XCTAssertFalse(settings.allowsAnyFold)
    }

    // MARK: Fill rule

    func testSelfOverlapIsFilledNotCutOut() throws {
        // The centre is wound round twice. Filling by "non-zero" keeps it solid; "even-odd"
        // would cut a hole there.
        let shape = doubleLoop(color: .red)
        let picture = NotanCore.Picture(width: 64, height: 64, background: .white, shapes: [shape])
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
        let picture = NotanCore.Picture(width: 64, height: 64, background: .white, shapes: [parent])
        let text = svg(picture, outputSize: CGSize(width: 64, height: 64))
        XCTAssertFalse(text.contains("evenodd"))
        XCTAssertTrue(text.contains("fill-rule=\"nonzero\""))
        XCTAssertTrue(text.contains("clip-rule=\"nonzero\""))
    }
}
