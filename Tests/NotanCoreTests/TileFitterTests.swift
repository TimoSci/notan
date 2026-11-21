import XCTest
@testable import NotanCore

final class TileFitterTests: XCTestCase {
    func settings(_ tiles: Int, _ order: TileOrder, _ mode: LevelMode = .prefix, steps: Int = 30) -> FitSettings {
        var settings = FitSettings()
        settings.kind = .tiles
        settings.tileOrder = order
        settings.mode = mode
        settings.totalShapes = tiles
        settings.stepsPerStage = steps
        return settings
    }

    func fit(_ target: TargetImage, _ settings: FitSettings) -> [Level] {
        TileFitter(target: target, settings: settings).run(progress: { _ in }, isCancelled: { false })
    }

    /// Four flat quadrants.
    let quadrants = makeTarget(width: 32, height: 32) { x, y in
        x < 16 ? (y < 16 ? .black : .red) : (y < 16 ? .white : .blue)
    }
    /// Something different in every pixel, the same on every run.
    let noise = makeTarget(width: 32, height: 32) { x, y in
        let n = Int(x) * 73 + Int(y) * 151
        return RGB(r: Float(n % 17) / 16, g: Float(n * 7 % 13) / 12, b: Float(n * 3 % 11) / 10)
    }

    func assertTilesThePicture(_ level: Level, file: StaticString = #filePath, line: UInt = #line) {
        let picture = level.picture
        var area: Float = 0
        for tile in picture.tiles {
            XCTAssertTrue(isSimplePolygon(tile.corners), file: file, line: line)
            XCTAssertGreaterThan(polygonArea(tile.corners), 0, file: file, line: line)
            area += polygonArea(tile.corners)
        }
        XCTAssertEqual(area, Float(picture.width * picture.height), accuracy: 0.01, file: file, line: line)
    }

    // MARK: Schedules

    func testTreeScheduleDoublesAndStopsAtTheTotal() {
        XCTAssertEqual(tileSchedule(totalTiles: 128, order: .tree), [1, 2, 4, 8, 16, 32, 64])
        XCTAssertEqual(tileSchedule(totalTiles: 100, order: .tree), [1, 2, 4, 8, 16, 32, 36])
        XCTAssertEqual(tileSchedule(totalTiles: 1, order: .tree), [])
    }

    func testWorstScheduleFollowsTheCurveSchedule() {
        XCTAssertEqual(tileSchedule(totalTiles: 128, order: .worst), stageSchedule(totalShapes: 127))
        XCTAssertEqual(tileSchedule(totalTiles: 6, order: .worst), [1, 1, 1, 1, 1])
        XCTAssertEqual(tileSchedule(totalTiles: 1, order: .worst), [])
    }

    // MARK: The two orders

    func testTreeOrderCutsEveryTileAtEachLevel() {
        let levels = fit(quadrants, settings(8, .tree))
        XCTAssertEqual(levels.map { $0.picture.tiles.count }, [1, 2, 4, 8])
        for (depth, level) in levels.enumerated() {
            XCTAssertTrue(level.picture.tiles.allSatisfy { $0.path.count == depth })
            XCTAssertTrue(level.picture.shapes.isEmpty)
        }
    }

    func testWorstOrderAddsTilesByTheSchedule() {
        let levels = fit(quadrants, settings(6, .worst))
        XCTAssertEqual(levels.map { $0.picture.tiles.count }, [1, 2, 3, 4, 5, 6])
    }

    func testWorstOrderCutsWhereTheErrorIs() throws {
        // Flat red but for the right quarter, which is black over white. Once a cut has
        // parted the two, only the right piece has anything to gain.
        let target = makeTarget(width: 32, height: 32) { x, y in x < 24 ? .red : (y < 16 ? .black : .white) }
        let last = try XCTUnwrap(fit(target, settings(3, .worst)).last)
        let middles = last.picture.tiles.map { centroid($0).x }
        XCTAssertEqual(middles.filter { $0 < 22 }.count, 1)
        XCTAssertEqual(middles.filter { $0 > 22 }.count, 2)
    }

    // MARK: Tilings

    func testEveryLevelTilesThePicture() {
        for level in fit(noise, settings(8, .worst)) { assertTilesThePicture(level) }
        for level in fit(noise, settings(8, .tree)) { assertTilesThePicture(level) }
    }

    func testPrefixTilesAreUnionsOfTheNextLevels() {
        let levels = fit(noise, settings(8, .worst))
        // One tile, then cuts by the schedule 1, 1, 1, 1, 2, 1.
        XCTAssertEqual(levels.map { $0.picture.tiles.count }, [1, 2, 3, 4, 5, 7, 8])
        for (level, next) in zip(levels, levels.dropFirst()) {
            for tile in level.picture.tiles {
                let pieces = next.picture.tiles.filter { $0.path.starts(with: tile.path) }
                XCTAssertTrue(pieces.count == 1 || pieces.count == 2)
                XCTAssertEqual(
                    pieces.map { polygonArea($0.corners) }.reduce(0, +), polygonArea(tile.corners),
                    accuracy: 0.01)
                if pieces.count == 1 { XCTAssertEqual(pieces[0], tile, "an uncut tile is untouched") }
            }
        }
    }

    // MARK: Fitting

    func testCutEndsMoveOntoTheEdgeInThePhoto() throws {
        // The search only tries cuts through x = 10 and x = 14; the fit has to find 13.
        let target = makeTarget(width: 32, height: 32) { x, _ in x < 13 ? .black : .white }
        let levels = fit(target, settings(2, .worst, steps: 60))
        XCTAssertEqual(levels.count, 2)
        let tiles = levels[1].picture.tiles
        let shared = tiles[0].corners.filter { tiles[1].corners.contains($0) }
        XCTAssertEqual(shared.count, 2)
        for end in shared { XCTAssertEqual(end.x, 13, accuracy: 0.6) }
        XCTAssertLessThan(levels[1].mse, 0.01)
        XCTAssertGreaterThan(levels[0].mse, 0.2)
    }

    func testErrorFallsAsTilesAreAdded() throws {
        let levels = fit(quadrants, settings(8, .tree))
        XCTAssertLessThan(try XCTUnwrap(levels.last).mse, 0.2 * levels[0].mse)
        // Once the four quadrants are parted there is nothing left to gain, and a further
        // cut may cost a trace at its edges.
        for (level, next) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThanOrEqual(next.mse, level.mse * 1.02 + 0.001)
        }
    }

    func testAFlatPhotoStillFits() {
        let flat = makeTarget(width: 32, height: 32) { _, _ in .grey }
        let levels = fit(flat, settings(8, .tree))
        XCTAssertEqual(levels.map { $0.picture.tiles.count }, [1, 2, 4, 8])
        for level in levels {
            assertTilesThePicture(level)
            for tile in level.picture.tiles {
                XCTAssertEqual(tile.color.r, 0.5, accuracy: 0.02)
                XCTAssertEqual(tile.color.g, 0.5, accuracy: 0.02)
                XCTAssertEqual(tile.color.b, 0.5, accuracy: 0.02)
            }
        }
        XCTAssertEqual(fit(flat, settings(8, .tree)).map(\.picture), levels.map(\.picture))
    }

    func testStopsEarlyWhenNoTileCanBeCut() throws {
        let small = makeTarget(width: 8, height: 8) { x, y in (Int(x) + Int(y)) % 2 == 0 ? .black : .white }
        let levels = fit(small, settings(64, .tree, steps: 10))
        let last = try XCTUnwrap(levels.last)
        XCTAssertLessThan(last.picture.tiles.count, 64)
        XCTAssertGreaterThan(last.picture.tiles.count, 1)
        assertTilesThePicture(last)
        for tile in last.picture.tiles {
            XCTAssertGreaterThanOrEqual(polygonArea(tile.corners), minTileArea - 0.01)
        }
    }

    func testCancelKeepsTheLevelsFinished() {
        var finished = 0
        let levels = TileFitter(target: quadrants, settings: settings(8, .worst)).run(
            progress: { if $0.finishedLevel != nil { finished += 1 } }, isCancelled: { finished >= 2 })
        XCTAssertEqual(levels.count, 2)
    }

    func testReportsProgressWithinAStage() {
        var within = 0
        var stages: Set<Int> = []
        _ = TileFitter(target: quadrants, settings: settings(3, .worst)).run(
            progress: {
                if $0.finishedLevel == nil { within += 1 }
                stages.insert($0.stage)
                XCTAssertEqual($0.stageCount, 2)
            }, isCancelled: { false })
        XCTAssertEqual(within, 2 * 2)  // 30 steps a stage, reported every 10, the last by the level
        XCTAssertEqual(stages, [0, 1, 2])
    }

    func testFitsAreReproducible() {
        XCTAssertEqual(
            fit(noise, settings(8, .worst)).map(\.picture), fit(noise, settings(8, .worst)).map(\.picture))
    }
}
