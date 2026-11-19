import XCTest
@testable import LayerFitCore

final class FitterTests: XCTestCase {
    func disc() -> TargetImage {
        makeTarget(width: 48, height: 48) { x, y in inDisc(x, y, 24, 24, 12) ? .white : .black }
    }

    func twoDiscs() -> TargetImage {
        makeTarget(width: 48, height: 48) { x, y in
            if inDisc(x, y, 14, 16, 9) { return .red }
            if inDisc(x, y, 33, 31, 10) { return .blue }
            return .grey
        }
    }

    func fit(
        _ target: TargetImage, shapes: Int, mode: LevelMode = .refit, steps: Int = 60,
        progress: (FitProgress) -> Void = { _ in }, isCancelled: () -> Bool = { false }
    ) -> [Level] {
        let settings = FitSettings(
            totalShapes: shapes, workingSize: 48, stepsPerStage: steps, mode: mode)
        return Fitter(target: target, settings: settings)
            .run(progress: progress, isCancelled: isCancelled)
    }

    func testLevelZeroIsMeanColour() {
        let levels = fit(twoDiscs(), shapes: 1, steps: 5)
        let target = twoDiscs()
        let n = Float(target.width * target.height)
        var mean = [Float](repeating: 0, count: 3)
        for (i, v) in target.pixels.enumerated() { mean[i % 3] += v / n }
        XCTAssertEqual(levels[0].picture.shapes.count, 0)
        XCTAssertEqual(levels[0].picture.background.r, mean[0], accuracy: 1e-4)
        XCTAssertEqual(levels[0].picture.background.g, mean[1], accuracy: 1e-4)
        XCTAssertEqual(levels[0].picture.background.b, mean[2], accuracy: 1e-4)
        XCTAssertEqual(levels[0].picture.width, 48)
        XCTAssertEqual(levels[0].picture.height, 48)
    }

    func testOneShapeConvergesOnDisc() {
        let levels = fit(disc(), shapes: 1)
        XCTAssertEqual(levels.count, 2)
        XCTAssertLessThan(levels[1].mse, 0.01)
        let c = centroid(levels[1].picture.shapes[0])
        XCTAssertEqual(c.x, 24, accuracy: 1.5)
        XCTAssertEqual(c.y, 24, accuracy: 1.5)
    }

    func testLevelCountAndShapeCounts() {
        let levels = fit(twoDiscs(), shapes: 8, steps: 5)
        XCTAssertEqual(levels.map { $0.picture.shapes.count }, [0, 1, 2, 3, 4, 6, 8])
    }

    func testRefitErrorFalls() {
        let levels = fit(twoDiscs(), shapes: 4)
        XCTAssertLessThan(levels.last!.mse, levels[0].mse * 0.3)
    }

    func testPrefixPropertyExact() {
        let levels = fit(twoDiscs(), shapes: 8, mode: .prefix, steps: 30)
        XCTAssertEqual(levels.count, 7)
        for k in 0..<(levels.count - 1) {
            let earlier = levels[k].picture
            let later = levels[k + 1].picture
            XCTAssertEqual(Array(later.shapes.prefix(earlier.shapes.count)), earlier.shapes, "level \(k)")
            XCTAssertEqual(later.background, earlier.background, "level \(k)")
        }
    }

    func testPrefixErrorStillFalls() {
        let levels = fit(twoDiscs(), shapes: 4, mode: .prefix)
        XCTAssertLessThan(levels.last!.mse, levels[0].mse * 0.5)
    }

    func testRefitMovesOldShapes() {
        let levels = fit(twoDiscs(), shapes: 4, mode: .refit, steps: 30)
        var anyMoved = false
        for k in 1..<(levels.count - 1) {
            let earlier = levels[k].picture.shapes
            if Array(levels[k + 1].picture.shapes.prefix(earlier.count)) != earlier { anyMoved = true }
        }
        XCTAssertTrue(anyMoved)
    }

    /// Three thin bright lines: without a width floor, shapes hug them.
    func stripes() -> TargetImage {
        makeTarget(width: 48, height: 48) { _, y in
            [8, 24, 40].contains { abs(y - Float($0)) < 1 } ? .white : .black
        }
    }

    func narrowest(_ levels: [Level]) -> Float {
        levels.last!.picture.shapes.map { meanWidth(of: $0) }.min()!
    }

    func testMinWidthKeepsShapesWide() {
        // minWidth is given at a 256 px scale: 32 means 6 px on this 48 px picture.
        func run(minWidth: Float) -> [Level] {
            let settings = FitSettings(
                totalShapes: 3, workingSize: 48, stepsPerStage: 80, mode: .refit, minWidth: minWidth)
            return Fitter(target: stripes(), settings: settings)
                .run(progress: { _ in }, isCancelled: { false })
        }
        XCTAssertLessThan(narrowest(run(minWidth: 0)), 3)
        XCTAssertGreaterThan(narrowest(run(minWidth: 32)), 4.5)
    }

    func testMinWidthFitIsFinite() {
        let settings = FitSettings(
            totalShapes: 4, workingSize: 48, stepsPerStage: 30, mode: .prefix, minWidth: 32)
        let levels = Fitter(target: twoDiscs(), settings: settings)
            .run(progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(levels.count, 5)
        for shape in levels.last!.picture.shapes {
            XCTAssertTrue(shape.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
        XCTAssertTrue(levels.allSatisfy { $0.mse.isFinite })
    }

    func testFlatImageFinishesFinite() {
        let target = makeTarget(width: 32, height: 32) { _, _ in .grey }
        let levels = fit(target, shapes: 4, steps: 20)
        XCTAssertEqual(levels.count, 5)
        for level in levels {
            XCTAssertTrue(level.mse.isFinite)
            for shape in level.picture.shapes {
                XCTAssertTrue(shape.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                XCTAssertTrue([shape.color.r, shape.color.g, shape.color.b].allSatisfy { $0.isFinite })
            }
        }
    }

    func testColoursStayInRange() {
        let levels = fit(twoDiscs(), shapes: 4, steps: 30)
        for shape in levels.last!.picture.shapes {
            for v in [shape.color.r, shape.color.g, shape.color.b] {
                XCTAssertTrue((0...1).contains(v))
            }
        }
    }

    func testCancelKeepsFinishedLevels() {
        var stageSeen = 0
        let levels = fit(
            twoDiscs(), shapes: 4, steps: 30,
            progress: { stageSeen = $0.stage },
            isCancelled: { stageSeen >= 2 })
        // Level 0 and stage 1 finished; stage 2 was running when cancelled.
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(levels.map { $0.picture.shapes.count }, [0, 1])
    }

    func testProgressReportsEachLevelOnce() {
        var finished: [Int] = []
        var stageCounts = Set<Int>()
        var sawMidStage = false
        let levels = fit(
            twoDiscs(), shapes: 4, steps: 30,
            progress: { p in
                stageCounts.insert(p.stageCount)
                if let level = p.finishedLevel {
                    finished.append(level.picture.shapes.count)
                } else {
                    sawMidStage = true
                }
            })
        XCTAssertEqual(finished, [0, 1, 2, 3, 4])
        XCTAssertEqual(finished.count, levels.count)
        XCTAssertEqual(stageCounts, [4])
        XCTAssertTrue(sawMidStage)
    }
}
