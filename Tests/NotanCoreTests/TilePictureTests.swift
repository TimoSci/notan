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

    // MARK: Gradient fills

    /// One tile over the whole 64×48 picture, black at the left edge running to white at
    /// the right.
    func rampPicture() -> NotanCore.Picture {
        var mesh = TileMesh(width: 64, height: 48, color: .black)
        mesh.setGradient(0, Gradient(from: SIMD2(0, 24), to: SIMD2(64, 24), endColor: .white))
        return tilePicture(mesh)
    }

    func testATileCarriesItsGradientIntoThePicture() {
        XCTAssertEqual(rampPicture().tiles[0].gradient?.endColor, .white)
        XCTAssertNil(tilePicture(fourTileMesh()).tiles[0].gradient)
    }

    func testATileWithAGradientIsDrawnAsARamp() throws {
        let rgb = try pixels(rampPicture(), width: 64, height: 48)
        func red(_ x: Int, _ y: Int) -> Float { rgb[(y * 64 + x) * 3] }
        XCTAssertEqual(red(8, 10), 8.5 / 64, accuracy: 0.03)
        XCTAssertEqual(red(32, 40), 32.5 / 64, accuracy: 0.03)
        XCTAssertEqual(red(56, 24), 56.5 / 64, accuracy: 0.03)
    }

    func testNoSeamShowsBetweenTilesWithGradients() throws {
        var mesh = fourTileMesh()
        for leaf in mesh.leaves {
            mesh.setGradient(leaf, Gradient(from: SIMD2(0, 0), to: SIMD2(64, 48), endColor: .white))
        }
        let rgb = try pixels(tilePicture(mesh), width: 211, height: 158)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rgb.min()), 254.0 / 255)
    }

    func testSVGWritesATilesGradientForItsFillAndItsOutline() throws {
        let text = svg(rampPicture(), outputSize: CGSize(width: 640, height: 480))
        XCTAssertTrue(XMLParser(data: Data(text.utf8)).parse())
        XCTAssertTrue(text.contains("<linearGradient id=\"g1\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"24\" x2=\"64\" y2=\"24\">"))
        XCTAssertTrue(text.contains("stop-color=\"#000000\""))
        XCTAssertTrue(text.contains("stop-color=\"#ffffff\""))
        let polygon = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("<polygon") })
        XCTAssertTrue(polygon.contains("fill=\"url(#g1)\" stroke=\"url(#g1)\""))
    }

    func testATilesGradientCostsElevenBytes() {
        var mesh = TileMesh(width: 64, height: 48, color: .white)
        mesh.cut(0, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 1, shareCorners: false)
        let flat = tilePicture(mesh).estimatedBytes
        mesh.setGradient(mesh.leaves[0], Gradient(from: SIMD2(0, 0), to: SIMD2(9, 9), endColor: .black))
        XCTAssertEqual(tilePicture(mesh).estimatedBytes, flat + 11)
    }

    func testMeasuredMSEIsNearZeroForARampDrawnAsItsOwnTarget() throws {
        let picture = rampPicture()
        let target = TargetImage(width: 64, height: 48, pixels: try pixels(picture, width: 64, height: 48))
        XCTAssertLessThan(measuredMSE(picture, against: target), 1e-4)
    }

    func testMeasuredMSEIsNearZeroForAPictureOfItself() throws {
        // Upright and level cuts on whole pixels, so every pixel lies in one tile.
        var mesh = TileMesh(width: 64, height: 48, color: .white)
        mesh.cut(0, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 1, shareCorners: false)
        mesh.cut(1, from: CutEnd(edge: 3, t: 0.5), to: CutEnd(edge: 1, t: 0.5), stage: 2, shareCorners: false)
        mesh.cut(2, from: CutEnd(edge: 1, t: 0.5), to: CutEnd(edge: 3, t: 0.5), stage: 2, shareCorners: false)
        for (index, leaf) in mesh.leaves.enumerated() { mesh.setColor(leaf, index % 2 == 0 ? .black : .white) }
        let picture = tilePicture(mesh)
        let own = makeTarget(width: 64, height: 48) { x, y in
            picture.tiles.first { outline(of: $0).contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) }!.color
        }
        // Not quite zero: the tiles are drawn grown by an eighth of a pixel to hide seams.
        XCTAssertLessThan(measuredMSE(picture, against: own), 0.002)
        let inverse = TargetImage(width: 64, height: 48, pixels: own.pixels.map { 1 - $0 })
        XCTAssertGreaterThan(measuredMSE(picture, against: inverse), 0.95)
    }

    func testDimmingLeavesTheSelectedTilesBright() throws {
        let picture = tilePicture(fourTileMesh())  // every tile white
        let selected = picture.tiles(under: .tile([0]))
        let image = try XCTUnwrap(
            makeCGImage(picture, pixelSize: CGSize(width: 128, height: 96), dimmingAllBut: selected))
        let rgb = rgbPixels(of: image, width: 128, height: 96)
        for tile in picture.tiles {
            let at = centroid(tile) * 2
            let value = rgb[(Int(at.y) * 128 + Int(at.x)) * 3]
            if tile.path.first == 0 {
                XCTAssertGreaterThan(value, 0.99, "selected tile \(tile.path) is left as it is")
            } else {
                XCTAssertEqual(value, 1 - Float(selectionDimming), accuracy: 0.02, "tile \(tile.path) is dimmed")
            }
        }
        // No line shows between the two selected pieces.
        let between = (selected[0].corners.filter { selected[1].corners.contains($0) })
        let middle = between.reduce(SIMD2<Float>(0, 0), +) / Float(between.count) * 2
        XCTAssertGreaterThan(rgb[(Int(middle.y) * 128 + Int(middle.x)) * 3], 0.99)
    }
}
