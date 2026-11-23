import CoreGraphics
import XCTest
@testable import NotanCore

final class TileRefineTests: XCTestCase {
    func fourTiles() -> NotanCore.Picture { tilePicture(fourTileMesh()) }

    func area(_ tiles: [Tile]) -> Float { tiles.map { polygonArea($0.corners) }.reduce(0, +) }

    // MARK: Putting finer tiles in place of a tile

    func testReplacingTilesPutsTheNewOnesWhereTheOldWere() {
        var picture = fourTiles()
        let old = picture.tiles
        let finer = (0..<3).map { Tile(corners: old[0].corners, color: .red, path: [0, 9, $0]) }
        XCTAssertTrue(picture.replaceTiles(under: [0], with: finer))
        XCTAssertEqual(picture.tiles.map(\.path), [[0, 9, 0], [0, 9, 1], [0, 9, 2], [1, 0], [1, 1]])
    }

    func testReplacingTilesOfAnAbsentTileDoesNothing() {
        var picture = fourTiles()
        let before = picture
        // Not cut out at this level: there is a tile that contains it, but none under it.
        XCTAssertFalse(picture.replaceTiles(under: [1, 0, 1], with: []))
        XCTAssertFalse(picture.replaceTiles(under: [7], with: []))
        XCTAssertEqual(picture, before)
    }

    func testInnerLevelsCarryTiles() {
        let tile = fourTiles().tiles[0]
        let inner = Inner(
            levels: [InnerLevel(shapes: [], mse: 0.2), InnerLevel(shapes: [], mse: 0.1, tiles: [tile])],
            shown: 1)
        XCTAssertEqual(inner.tiles, [tile])
        XCTAssertEqual(InnerLevel(shapes: [], mse: 0).tiles, [])
    }

    // MARK: The outline of a group of tiles

    func testOutlineOfOneTileIsItsOwn() {
        let tile = fourTiles().tiles[2]
        XCTAssertEqual(groupOutline([tile]), tile.corners)
    }

    func testOutlineOfTwoPiecesGoesRoundBoth() throws {
        let pieces = fourTiles().tiles(under: .tile([0]))
        XCTAssertEqual(pieces.count, 2)
        let outline = try XCTUnwrap(groupOutline(pieces))
        XCTAssertTrue(isSimplePolygon(outline))
        // A hundredth of a pixel all round the pieces: 160 px of outline.
        XCTAssertEqual(polygonArea(outline), area(pieces) + 1.6, accuracy: 0.2)
        // The right part of the picture: its four corners, near enough.
        for corner in [SIMD2<Float>(32, 0), SIMD2(64, 0), SIMD2(64, 48), SIMD2(38.4, 48)] {
            XCTAssertTrue(outline.contains { abs($0.x - corner.x) < 0.05 && abs($0.y - corner.y) < 0.05 }, "\(corner)")
        }
    }

    func testTilesThatDoNotTouchHaveNoOutline() {
        let apart = [
            Tile(corners: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)], color: .red, path: [0]),
            Tile(corners: [SIMD2(30, 0), SIMD2(40, 0), SIMD2(40, 10), SIMD2(30, 10)], color: .red, path: [1]),
        ]
        XCTAssertNil(groupOutline(apart))
        XCTAssertNil(groupOutline([]))
    }

    // MARK: Refining

    func testPlanZoomsToTheTile() throws {
        let picture = fourTiles()
        let plan = try XCTUnwrap(
            refinePlan(
                picture: picture, node: .tile([0]), originalPixelSize: CGSize(width: 640, height: 480),
                workingSize: 128))
        // The right part, from x = 32 to 64, plus a margin, kept inside the picture.
        XCTAssertEqual(plan.viewport.minX, 32 - 0.04 * 32, accuracy: 0.01)
        XCTAssertEqual(plan.viewport.maxX, 64, accuracy: 0.01)
        XCTAssertEqual(plan.viewport.minY, 0, accuracy: 0.01)
        XCTAssertEqual(plan.viewport.maxY, 48, accuracy: 0.01)
        XCTAssertEqual(max(plan.width, plan.height), 128)
        XCTAssertNil(
            refinePlan(
                picture: picture, node: .tile([7]), originalPixelSize: CGSize(width: 640, height: 480),
                workingSize: 128))
    }

    /// A 640×480 photo for the 64×48 picture: black above the middle, white below.
    func photo() -> URL {
        let image = Fixtures.image(width: 640, height: 480) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 240, width: 640, height: 240))
        }
        return Fixtures.write(image, name: "tile-refine.png")
    }

    func refine(_ node: NodeID, mode: LevelMode, tiles: Int = 6) throws -> [InnerLevel] {
        var settings = FitSettings()
        settings.kind = .tiles
        settings.mode = mode
        settings.totalShapes = tiles
        settings.stepsPerStage = 20
        settings.workingSize = 64
        return try Refiner(photoURL: photo(), picture: fourTiles(), node: node, settings: settings)
            .run(progress: { _ in }, isCancelled: { false })
    }

    func testRefiningATileCutsItFurther() throws {
        for mode in LevelMode.allCases {
            let whole = fourTiles().tiles(under: .tile([0]))
            let levels = try refine(.tile([0]), mode: mode)
            XCTAssertEqual(levels[0].tiles.count, 1, "\(mode)")
            XCTAssertEqual(levels[0].tiles[0].path, [0], "\(mode)")
            XCTAssertEqual(levels.last?.tiles.count, 6, "\(mode)")
            for level in levels {
                XCTAssertTrue(level.shapes.isEmpty)
                XCTAssertEqual(area(level.tiles), area(whole) + 1.6, accuracy: 0.5, "\(mode)")
                for tile in level.tiles {
                    XCTAssertTrue(tile.path.starts(with: [0]), "\(mode)")
                    XCTAssertTrue(tile.corners.allSatisfy { $0.x > 31.9 && $0.x < 64.1 && $0.y > -0.1 && $0.y < 48.1 })
                }
            }
            XCTAssertEqual(Set(levels.last!.tiles.map(\.path)).count, 6, "every piece has its own address")
            // Black over white: one cut across is nearly all there is to gain.
            XCTAssertLessThan(levels.last!.mse, 0.2 * levels[0].mse, "\(mode)")
        }
    }

    func testRefiningOneTileStartsFromItsOutline() throws {
        let tile = fourTiles().tiles[2]
        let levels = try refine(.tile(tile.path), mode: .prefix, tiles: 3)
        XCTAssertEqual(levels[0].tiles.count, 1)
        for (corner, original) in zip(levels[0].tiles[0].corners, tile.corners) {
            XCTAssertEqual(corner.x, original.x, accuracy: 0.01)
            XCTAssertEqual(corner.y, original.y, accuracy: 0.01)
        }
    }

    func testRefiningATileThatIsNotThereThrows() {
        XCTAssertThrowsError(try refine(.tile([7]), mode: .prefix)) {
            XCTAssertEqual($0 as? RefineError, .regionNotFound)
        }
    }
}
