import CoreGraphics
import XCTest
@testable import NotanCore

/// 64×48 cut into four tiles: the picture top to bottom on a slant, then each half across.
/// Their paths are [0, 0], [0, 1], [1, 0] and [1, 1].
func fourTileMesh(color: RGB = .white) -> TileMesh {
    var mesh = TileMesh(width: 64, height: 48, color: color)
    mesh.cut(0, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.4), stage: 1, shareCorners: false)
    mesh.cut(1, from: CutEnd(edge: 3, t: 0.5), to: CutEnd(edge: 1, t: 0.3), stage: 2, shareCorners: false)
    mesh.cut(2, from: CutEnd(edge: 1, t: 0.6), to: CutEnd(edge: 3, t: 0.7), stage: 2, shareCorners: false)
    return mesh
}

func tilePicture(_ mesh: TileMesh, background: RGB = .red) -> NotanCore.Picture {
    var picture = NotanCore.Picture(width: mesh.width, height: mesh.height, background: background, shapes: [])
    picture.tiles = mesh.tiles()
    return picture
}

func centroid(_ tile: Tile) -> SIMD2<Float> {
    tile.corners.reduce(SIMD2<Float>(0, 0), +) / Float(tile.corners.count)
}

final class TilePictureTests: XCTestCase {
    let colours = [RGB.black, .white, .blue, .grey]

    func colouredPicture() -> NotanCore.Picture {
        var mesh = fourTileMesh()
        for (index, leaf) in mesh.leaves.enumerated() { mesh.setColor(leaf, colours[index]) }
        return tilePicture(mesh)
    }

    func pixels(_ picture: NotanCore.Picture, width: Int, height: Int) throws -> [Float] {
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: width, height: height)))
        return rgbPixels(of: image, width: width, height: height)
    }

    func testNoSeamShowsBetweenTilesOfOneColour() throws {
        // A scale that is not a whole number, so tile edges fall inside pixels.
        let rgb = try pixels(tilePicture(fourTileMesh()), width: 211, height: 158)
        let lowest = try XCTUnwrap(rgb.min())
        XCTAssertGreaterThanOrEqual(lowest, 254.0 / 255, "the red background shows between white tiles")
    }

    func testEachTileShowsItsOwnColour() throws {
        let picture = colouredPicture()
        let rgb = try pixels(picture, width: 64, height: 48)
        for tile in picture.tiles {
            let at = centroid(tile)
            let base = (Int(at.y) * 64 + Int(at.x)) * 3
            XCTAssertEqual(rgb[base], tile.color.r, accuracy: 1.5 / 255)
            XCTAssertEqual(rgb[base + 1], tile.color.g, accuracy: 1.5 / 255)
            XCTAssertEqual(rgb[base + 2], tile.color.b, accuracy: 1.5 / 255)
        }
    }

    func testHitTestFindsTheTileUnderAPoint() {
        let picture = colouredPicture()
        for tile in picture.tiles {
            XCTAssertEqual(picture.hitTest(centroid(tile)), .tile(tile.path))
        }
        XCTAssertNil(picture.hitTest(SIMD2(-1, 5)))
        XCTAssertNil(picture.hitTest(SIMD2(5, 48)))
    }

    func testParentOfATileIsTheTileItWasCutFrom() {
        XCTAssertEqual(NodeID.tile([0, 1]).parent, .tile([0]))
        XCTAssertEqual(NodeID.tile([0]).parent, .tile([]))
        XCTAssertNil(NodeID.tile([]).parent)
        XCTAssertTrue(NodeID.tile([0]).isTile)
        XCTAssertNotEqual(NodeID.tile([0]), NodeID.shape([0]))
        XCTAssertTrue(NodeID.tile([0]).contains(.tile([0, 1])))
        XCTAssertFalse(NodeID.tile([0]).contains(.shape([0, 1])))
    }

    func testTilesUnderAnAddress() {
        let picture = colouredPicture()
        XCTAssertEqual(picture.tiles(under: .tile([0])).map(\.path), [[0, 0], [0, 1]])
        XCTAssertEqual(picture.tiles(under: .tile([])).count, 4)
        // Not cut that far at this level: the tile that contains it.
        XCTAssertEqual(picture.tiles(under: .tile([1, 0, 1, 1])).map(\.path), [[1, 0]])
        XCTAssertEqual(picture.tiles(under: .shape([0])).count, 0)
    }

    func testResolvedFallsBackToTheContainingTile() {
        let picture = colouredPicture()
        XCTAssertEqual(picture.resolved(.tile([0])), .tile([0]))
        XCTAssertEqual(picture.resolved(.tile([1, 1])), .tile([1, 1]))
        XCTAssertEqual(picture.resolved(.tile([1, 0, 1, 1])), .tile([1, 0]))
        let plain = NotanCore.Picture(width: 64, height: 48, background: .red, shapes: [])
        XCTAssertNil(plain.resolved(.tile([0])))
    }

    func testSVGWritesOnePolygonPerTile() throws {
        let text = svg(colouredPicture(), outputSize: CGSize(width: 640, height: 480))
        XCTAssertTrue(XMLParser(data: Data(text.utf8)).parse())
        let polygons = text.split(separator: "\n").filter { $0.hasPrefix("<polygon") }
        XCTAssertEqual(polygons.count, 4)
        XCTAssertTrue(polygons[0].contains("fill=\"#000000\" stroke=\"#000000\""))
        XCTAssertTrue(polygons[2].contains("fill=\"#0000ff\" stroke=\"#0000ff\""))
        XCTAssertTrue(polygons.allSatisfy { $0.contains("stroke-linejoin=\"round\"") })
        // The first tile's first corner: the top end of the first cut, where the second cut starts.
        XCTAssertTrue(polygons[0].contains("points=\""))
    }

    func testBytesCountTilesAndDistinctCorners() {
        var mesh = TileMesh(width: 64, height: 48, color: .white)
        mesh.cut(0, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 1, shareCorners: false)
        let picture = tilePicture(mesh)
        XCTAssertEqual(picture.shapeCount(maxDepth: .max), 2)
        XCTAssertEqual(picture.estimatedBytes, 3 + 2 * 3 + 6 * 4)
    }

    func testMeasuredMSEIsZeroForAPictureOfItself() throws {
        var mesh = fourTileMesh()
        for (index, leaf) in mesh.leaves.enumerated() { mesh.setColor(leaf, index % 2 == 0 ? .black : .white) }
        let picture = tilePicture(mesh)
        let own = try pixels(picture, width: 64, height: 48)
        XCTAssertLessThan(
            measuredMSE(picture, against: TargetImage(width: 64, height: 48, pixels: own)), 1e-6)
        let inverse = TargetImage(width: 64, height: 48, pixels: own.map { 1 - $0 })
        XCTAssertGreaterThan(measuredMSE(picture, against: inverse), 0.85)
    }
}
