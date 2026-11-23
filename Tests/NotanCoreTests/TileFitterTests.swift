import XCTest
@testable import NotanCore

let patchOutline: [SIMD2<Float>] = [SIMD2(8, 6), SIMD2(42, 10), SIMD2(38, 40), SIMD2(6, 36)]

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
        for end in shared { XCTAssertEqual(end.x, 13, accuracy: 0.15) }
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

    // MARK: Re-fit

    /// The picture cut into four upright strips, corners shared. Point 7 is the top of the
    /// line at x = 16, point 4 the top of the one at 32, point 8 the top of the one at 48.
    func strips() -> TileMesh {
        var mesh = TileMesh(width: 64, height: 48, color: .grey)
        mesh.cut(0, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 1, shareCorners: true)
        mesh.cut(2, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 2, shareCorners: true)
        mesh.cut(1, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 2, shareCorners: true)
        return mesh
    }

    func testStripsAreAsDescribed() {
        let mesh = strips()
        XCTAssertEqual(mesh.points[7], SIMD2(16, 0))
        XCTAssertEqual(mesh.points[4], SIMD2(32, 0))
        XCTAssertEqual(mesh.points[8], SIMD2(48, 0))
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
    }

    func testRevertPutsBackOnlyTheCornersOfBrokenTiles() {
        var mesh = strips()
        let previous = mesh.points
        mesh.setPoint(7, SIMD2(16, 100))  // dragged below the picture: breaks the two left strips
        mesh.setPoint(8, SIMD2(48.5, 0))  // a sound move, between the two right strips
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1).count, 2)
        revertInvalid(&mesh, previous: previous, minArea: 1)
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
        XCTAssertEqual(mesh.points[7], SIMD2(16, 0))
        XCTAssertEqual(mesh.points[8], SIMD2(48.5, 0))
    }

    func testRevertPutsEverythingBackWhenThatIsNotEnough() {
        var mesh = strips()
        let previous = mesh.points
        mesh.setPoint(7, SIMD2(16, 100))
        // Sound only together: with the first back at 32, the second lies on its wrong side.
        mesh.setPoint(4, SIMD2(10, 0))
        mesh.setPoint(8, SIMD2(20, 0))
        revertInvalid(&mesh, previous: previous, minArea: 1)
        XCTAssertEqual(mesh.points, previous)
    }

    func testRevertGoesNoFurtherThanTheTilesItBreaks() {
        // As above, with the right strip cut across as well: one end of that cut lies on
        // the right border, in tiles that never become unsound.
        var mesh = strips()
        let rightStrip = mesh.leaves.first { mesh.polygon($0).contains(SIMD2(64, 0)) }!
        let edge = mesh.polygon(rightStrip).firstIndex(of: SIMD2(64, 0))!
        let opposite = mesh.polygon(rightStrip).firstIndex(of: SIMD2(48, 48))!
        mesh.cut(
            rightStrip, from: CutEnd(edge: edge, t: 0.5), to: CutEnd(edge: opposite, t: 0.5), stage: 3,
            shareCorners: true)
        let onBorder = mesh.points.firstIndex(of: SIMD2(64, 24))!
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
        let previous = mesh.points
        mesh.setPoint(7, SIMD2(16, 100))
        mesh.setPoint(4, SIMD2(10, 0))
        mesh.setPoint(8, SIMD2(20, 0))
        mesh.setPoint(onBorder, SIMD2(64, 25))
        let reverted = revertInvalid(&mesh, previous: previous, minArea: 1)
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
        XCTAssertEqual(mesh.points[7], previous[7])
        XCTAssertEqual(mesh.points[4], previous[4])
        XCTAssertEqual(mesh.points[8], previous[8])
        XCTAssertEqual(mesh.points[onBorder], SIMD2(64, 25), "a sound move far from the damage stands")
        XCTAssertTrue(reverted.contains(8))
        XCTAssertFalse(reverted.contains(onBorder))
    }

    func testRevertPutsBackATileThatHasGrownTooThin() {
        var mesh = strips()
        let previous = mesh.points
        // The line at x = 48 moved to 62.5: the right strip is 1.5 px wide, and sound otherwise.
        mesh.setPoint(8, SIMD2(62.5, 0))
        mesh.setPoint(9, SIMD2(62.5, 48))
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1, minThickness: 3).count, 1)
        revertInvalid(&mesh, previous: previous, minArea: 1, minThickness: 3)
        XCTAssertEqual(mesh.points, previous)
    }

    func testNoTileEndsThinnerThanTheMinimumWidth() {
        let big = makeTarget(width: 48, height: 48) { x, y in
            let n = Int(x) * 73 + Int(y) * 151
            return RGB(r: Float(n % 17) / 16, g: Float(n * 7 % 13) / 12, b: Float(n * 3 % 11) / 10)
        }
        for mode in LevelMode.allCases {
            var settings = settings(16, .worst, mode, steps: 40)
            settings.minWidth = 16  // at 48 px that is 3 px
            for level in fit(big, settings) {
                for tile in level.picture.tiles {
                    XCTAssertGreaterThanOrEqual(thickness(of: tile.corners), 3 - 0.01, "\(mode) \(tile.path)")
                }
            }
        }
    }

    func testRevertLeavesASoundTilingAlone() {
        var mesh = strips()
        let previous = mesh.points
        mesh.setPoint(8, SIMD2(50, 0))
        let moved = mesh
        revertInvalid(&mesh, previous: previous, minArea: 1)
        XCTAssertEqual(mesh, moved)
    }

    func testRefitTilesShareWholeEdges() {
        for level in fit(noise, settings(8, .worst, .refit)) {
            let tiles = level.picture.tiles
            func edges(_ tile: Tile) -> [[SIMD2<Float>]] {
                tile.corners.indices.map { [tile.corners[$0], tile.corners[($0 + 1) % tile.corners.count]] }
            }
            for (index, tile) in tiles.enumerated() {
                for edge in edges(tile) {
                    let onBorder =
                        (edge[0].x == 0 && edge[1].x == 0) || (edge[0].x == 32 && edge[1].x == 32)
                        || (edge[0].y == 0 && edge[1].y == 0) || (edge[0].y == 32 && edge[1].y == 32)
                    let matches = tiles.indices.filter { other in
                        other != index && edges(tiles[other]).contains([edge[1], edge[0]])
                    }
                    XCTAssertEqual(matches.count, onBorder ? 0 : 1, "edge \(edge) of tile \(tile.path)")
                }
            }
        }
    }

    func testRefitKeepsThePictureCornersAndBorder() {
        for level in fit(noise, settings(8, .tree, .refit)) {
            assertTilesThePicture(level)
            let corners = level.picture.tiles.flatMap(\.corners)
            for corner in [SIMD2<Float>(0, 0), SIMD2(32, 0), SIMD2(32, 32), SIMD2(0, 32)] {
                XCTAssertTrue(corners.contains(corner))
            }
            XCTAssertTrue(corners.allSatisfy { $0.x >= 0 && $0.x <= 32 && $0.y >= 0 && $0.y <= 32 })
        }
    }

    func testRefitMovesCornersMadeInEarlierStages() throws {
        let ramp = makeTarget(width: 32, height: 32) { x, y in
            let v = (x + 2 * y) / 96
            return RGB(r: v, g: v * v, b: 1 - v)
        }
        let levels = fit(ramp, settings(8, .worst, .refit))
        let first = levels[1].picture.tiles
        let cutEnds = first[0].corners.filter { first[1].corners.contains($0) }
        XCTAssertEqual(cutEnds.count, 2)
        let later = try XCTUnwrap(levels.last).picture.tiles.flatMap(\.corners)
        XCTAssertFalse(cutEnds.allSatisfy { later.contains($0) }, "the first cut never moved again")
    }

    func testRefitTilingStaysValidOnNoise() {
        let big = makeTarget(width: 48, height: 48) { x, y in
            let n = Int(x) * 73 + Int(y) * 151
            return RGB(r: Float(n % 17) / 16, g: Float(n * 7 % 13) / 12, b: Float(n * 3 % 11) / 10)
        }
        for order in TileOrder.allCases {
            for level in fit(big, settings(16, order, .refit, steps: 40)) {
                for tile in level.picture.tiles {
                    XCTAssertTrue(isSimplePolygon(tile.corners))
                    XCTAssertGreaterThanOrEqual(polygonArea(tile.corners), 1)
                }
            }
        }
    }

    func testRefitErrorFallsAsTilesAreAdded() throws {
        let levels = fit(quadrants, settings(8, .tree, .refit))
        XCTAssertEqual(levels.map { $0.picture.tiles.count }, [1, 2, 4, 8])
        XCTAssertLessThan(try XCTUnwrap(levels.last).mse, 0.2 * levels[0].mse)
        for (level, next) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThanOrEqual(next.mse, level.mse * 1.02 + 0.001)
        }
    }

    func testRefitPlacesEdgesOnTheEdgesInThePhoto() throws {
        // Painting soft tiles one over another must not favour the tile painted later:
        // that would pull every shared edge off the edge in the photo.
        let refit = try XCTUnwrap(fit(quadrants, settings(4, .tree, .refit, steps: 100)).last)
        let prefix = try XCTUnwrap(fit(quadrants, settings(4, .tree, .prefix, steps: 100)).last)
        XCTAssertLessThan(refit.mse, 0.0008)
        // Prefix cannot do as well: its first cut was placed when there were two tiles,
        // and stays there.
        XCTAssertLessThan(prefix.mse, 0.0015)
        XCTAssertLessThan(refit.mse, prefix.mse)
        for corner in refit.picture.tiles.flatMap(\.corners) where corner.x > 0 && corner.x < 32 {
            XCTAssertEqual(corner.x, 16, accuracy: 0.15)
        }
    }

    func testRefitFitsAreReproducible() {
        // Many tiles meeting at shared corners: the sums over them must not depend on the run.
        let first = fit(noise, settings(16, .tree, .refit)).map(\.picture)
        for _ in 0..<2 { XCTAssertEqual(fit(noise, settings(16, .tree, .refit)).map(\.picture), first) }
    }

    // MARK: Inside one tile's outline

    /// A slanted four-cornered outline inside a 48×48 picture.
    let patch = patchOutline

    /// Inside the patch, black left of x = 22 and white right of it; outside it a loud
    /// checker, which a fit kept to the patch never sees.
    let patchTarget = makeTarget(width: 48, height: 48) { x, y in
        guard polygonContains(patchOutline, SIMD2(x, y)) else {
            return (Int(x) / 2 + Int(y) / 2) % 2 == 0 ? .red : .blue
        }
        return x < 22 ? .black : .white
    }

    func fitPatch(_ settings: FitSettings) -> [Level] {
        TileFitter(target: patchTarget, settings: settings, outline: patch)
            .run(progress: { _ in }, isCancelled: { false })
    }

    /// How far a point is from the nearest edge of a polygon's outline.
    func distance(_ point: SIMD2<Float>, toOutlineOf polygon: [SIMD2<Float>]) -> Float {
        polygon.indices.map { index -> Float in
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let t = max(0, min(1, ((point - a) * (b - a)).sum() / ((b - a) * (b - a)).sum()))
            let offset = point - (a + (b - a) * t)
            return (offset * offset).sum().squareRoot()
        }.min()!
    }

    func testAFitInsideAnOutlineTilesThatOutline() {
        for mode in LevelMode.allCases {
            let levels = fitPatch(settings(8, .worst, mode))
            XCTAssertEqual(levels[0].picture.tiles.map(\.corners), [patch], "\(mode)")
            XCTAssertEqual(levels.last?.picture.tiles.count, 8, "\(mode)")
            for level in levels {
                var area: Float = 0
                for tile in level.picture.tiles {
                    XCTAssertTrue(isSimplePolygon(tile.corners))
                    XCTAssertGreaterThan(polygonArea(tile.corners), 0)
                    area += polygonArea(tile.corners)
                }
                XCTAssertEqual(area, polygonArea(patch), accuracy: 0.05, "\(mode)")
                // The outline's own corners are all still there, and nothing lies outside it.
                let corners = level.picture.tiles.flatMap(\.corners)
                for corner in patch { XCTAssertTrue(corners.contains(corner), "\(mode)") }
                for corner in corners {
                    let onOutline = distance(corner, toOutlineOf: patch) < 0.01
                    let inside = polygonContains(patch, corner)
                    XCTAssertTrue(onOutline || inside, "\(mode): \(corner) has left the outline")
                }
            }
        }
    }

    func testAFitInsideAnOutlineIsScoredInsideItOnly() throws {
        for mode in LevelMode.allCases {
            let levels = fitPatch(settings(4, .worst, mode, steps: 60))
            // The first tile is the mean of the patch's own pixels: grey, with no red or blue in it.
            let first = levels[0].picture.tiles[0].color
            XCTAssertEqual(first.r, first.b, accuracy: 0.08, "\(mode)")
            XCTAssertGreaterThan(levels[0].mse, 0.1, "\(mode)")
            // One cut along x = 22 is all it takes inside the patch.
            XCTAssertLessThan(try XCTUnwrap(levels.last).mse, 0.03, "\(mode)")
        }
    }
}
