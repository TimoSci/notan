import XCTest
@testable import NotanCore

final class TileMeshTests: XCTestCase {
    let grey = RGB(r: 0.5, g: 0.5, b: 0.5)

    func mesh() -> TileMesh { TileMesh(width: 64, height: 48, color: grey) }

    /// The picture cut top to bottom down the middle: node 1 is the right half, node 2 the left.
    func halves(shareCorners: Bool) -> TileMesh {
        var mesh = mesh()
        mesh.cut(
            0, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 1,
            shareCorners: shareCorners)
        return mesh
    }

    func testRootIsTheWholePicture() {
        let mesh = mesh()
        XCTAssertEqual(mesh.leaves, [0])
        XCTAssertEqual(mesh.polygon(0), [SIMD2(0, 0), SIMD2(64, 0), SIMD2(64, 48), SIMD2(0, 48)])
        XCTAssertEqual(polygonArea(mesh.polygon(0)), 64 * 48)
        XCTAssertEqual(mesh.nodes[0].path, [])
        XCTAssertEqual(mesh.freedom, [.fixed, .fixed, .fixed, .fixed])
    }

    func testCutMakesTwoTilesThatFillTheParent() {
        var mesh = mesh()
        let made = mesh.cut(
            0, from: CutEnd(edge: 0, t: 0.25), to: CutEnd(edge: 2, t: 0.5), stage: 1,
            shareCorners: false)
        XCTAssertEqual(made.first, 1)
        XCTAssertEqual(made.second, 2)
        XCTAssertEqual(mesh.polygon(1), [SIMD2(16, 0), SIMD2(64, 0), SIMD2(64, 48), SIMD2(32, 48)])
        XCTAssertEqual(mesh.polygon(2), [SIMD2(32, 48), SIMD2(0, 48), SIMD2(0, 0), SIMD2(16, 0)])
        XCTAssertEqual(mesh.nodes[1].path, [0])
        XCTAssertEqual(mesh.nodes[2].path, [1])
        XCTAssertEqual(mesh.nodes[1].stage, 1)
        XCTAssertEqual(mesh.nodes[1].color, grey)
        XCTAssertEqual(mesh.nodes[0].children, [1, 2])
        XCTAssertEqual(mesh.nodes[0].corners, [])
        XCTAssertEqual(mesh.leaves, [1, 2])
        let areas = [1, 2].map { polygonArea(mesh.polygon($0)) }
        XCTAssertTrue(areas.allSatisfy { $0 > 0 })
        XCTAssertEqual(areas[0] + areas[1], 64 * 48, accuracy: 0.001)
    }

    func testUnsharedCutEndSlidesOnItsEdgeAndLeavesTheNeighbourAlone() {
        var mesh = halves(shareCorners: false)
        let neighbour = mesh.nodes[2]
        // Node 1's edge 3 runs up the shared line, from (32, 48) to (32, 0).
        let onShared = mesh.nodes[1].corners[3]
        let onSharedEnd = mesh.nodes[1].corners[0]
        mesh.cut(
            1, from: CutEnd(edge: 3, t: 0.5), to: CutEnd(edge: 1, t: 0.5), stage: 2,
            shareCorners: false)
        XCTAssertEqual(mesh.nodes[2], neighbour)
        let added = mesh.points.count - 2
        XCTAssertEqual(mesh.points[added], SIMD2(32, 24))
        XCTAssertEqual(mesh.freedom[added], .slide(from: onShared, to: onSharedEnd))
    }

    func testSharedCutEndBecomesACornerOfTheNeighbour() {
        var mesh = halves(shareCorners: true)
        let before = mesh.nodes[2].corners.count
        let areaBefore = polygonArea(mesh.polygon(2))
        mesh.cut(
            1, from: CutEnd(edge: 3, t: 0.5), to: CutEnd(edge: 1, t: 0.5), stage: 2,
            shareCorners: true)
        let added = mesh.points.count - 2
        XCTAssertEqual(mesh.points[added], SIMD2(32, 24))
        XCTAssertEqual(mesh.nodes[2].corners.count, before + 1)
        XCTAssertTrue(mesh.nodes[2].corners.contains(added))
        XCTAssertEqual(polygonArea(mesh.polygon(2)), areaBefore, accuracy: 0.001)
        XCTAssertEqual(mesh.freedom[added], .free)
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
    }

    func testCutEndsOnTheBorderMoveOnlyAlongIt() {
        var mesh = halves(shareCorners: true)
        XCTAssertEqual(mesh.freedom[4], .alongX)  // (32, 0), on the top border
        XCTAssertEqual(mesh.freedom[5], .alongX)  // (32, 48), on the bottom border
        mesh.cut(
            1, from: CutEnd(edge: 3, t: 0.5), to: CutEnd(edge: 1, t: 0.5), stage: 2,
            shareCorners: true)
        XCTAssertEqual(mesh.points[7], SIMD2(64, 24))
        XCTAssertEqual(mesh.freedom[7], .alongY)  // on the right border
    }

    func testInvalidLeavesReportsAFlippedTile() {
        var mesh = halves(shareCorners: true)
        // Cut the left half top to bottom as well: a far-left strip and a middle one.
        let made = mesh.cut(
            2, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 2,
            shareCorners: true)
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
        mesh.setPoint(4, SIMD2(32, 100))  // the top of the middle line, dragged below the picture
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [1, made.second])
    }

    func testInvalidLeavesReportsATileBelowTheArea() {
        var mesh = mesh()
        mesh.cut(
            0, from: CutEnd(edge: 0, t: 0.99), to: CutEnd(edge: 2, t: 0.01), stage: 1,
            shareCorners: false)
        XCTAssertEqual(mesh.invalidLeaves(minArea: 50), [1])
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
    }

    func testIsSimplePolygonRejectsABowTie() {
        XCTAssertFalse(isSimplePolygon([SIMD2(0, 0), SIMD2(10, 10), SIMD2(10, 0), SIMD2(0, 10)]))
        XCTAssertTrue(isSimplePolygon([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]))
        XCTAssertTrue(
            isSimplePolygon([
                SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 5), SIMD2(5, 5), SIMD2(5, 10), SIMD2(0, 10),
            ]))
        // A corner lying on a straight edge, as a neighbour's cut end does.
        XCTAssertTrue(
            isSimplePolygon([SIMD2(0, 0), SIMD2(5, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]))
    }

    func testTilesListsTheLeavesWithPathAndColour() {
        var mesh = halves(shareCorners: false)
        let red = RGB(r: 1, g: 0, b: 0)
        mesh.setColor(2, red)
        let tiles = mesh.tiles()
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0], Tile(corners: mesh.polygon(1), color: grey, path: [0]))
        XCTAssertEqual(tiles[1], Tile(corners: mesh.polygon(2), color: red, path: [1]))
    }

    func testGrownPolygonMovesEveryEdgeOutward() {
        let square: [SIMD2<Float>] = [SIMD2(10, 10), SIMD2(20, 10), SIMD2(20, 20), SIMD2(10, 20)]
        XCTAssertEqual(
            grownPolygon(square, by: 2), [SIMD2(8, 8), SIMD2(22, 8), SIMD2(22, 22), SIMD2(8, 22)])
        // A corner on a straight edge moves straight out with it.
        let withMiddle: [SIMD2<Float>] = [SIMD2(10, 10), SIMD2(15, 10), SIMD2(20, 10), SIMD2(20, 20), SIMD2(10, 20)]
        XCTAssertEqual(grownPolygon(withMiddle, by: 2)[1], SIMD2(15, 8))
        // A dent's corner moves into the dent.
        let dented: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 10), SIMD2(10, 10), SIMD2(10, 20), SIMD2(0, 20),
        ]
        XCTAssertEqual(grownPolygon(dented, by: 2)[3], SIMD2(12, 12))
        // Area, plus a band along the outline, plus a square at each of the five outward
        // corners, less one at the dent.
        XCTAssertEqual(polygonArea(grownPolygon(dented, by: 2)), 300 + 2 * 80 + 4 * 4, accuracy: 0.01)
    }

    func testGrownPolygonLimitsHowFarASharpCornerGoes() {
        let spike: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 1), SIMD2(0, 2)]
        let tip = grownPolygon(spike, by: 2)[1]
        XCTAssertGreaterThan(tip.x, 102)
        XCTAssertLessThanOrEqual(tip.x, 106.01)
        XCTAssertEqual(tip.y, 1, accuracy: 0.01)
    }

    // MARK: A tiling of one tile's outline

    /// A five-cornered outline, none of it on the picture's border.
    let outline: [SIMD2<Float>] = [SIMD2(10, 10), SIMD2(50, 8), SIMD2(54, 30), SIMD2(30, 40), SIMD2(8, 30)]

    func testAMeshCanStartFromAnOutline() {
        let mesh = TileMesh(width: 64, height: 48, color: grey, outline: outline)
        XCTAssertEqual(mesh.leaves, [0])
        XCTAssertEqual(mesh.polygon(0), outline)
        XCTAssertEqual(mesh.freedom, Array(repeating: .fixed, count: 5))
    }

    func testSharedCutEndsOnTheOutlineSlideAlongIt() {
        var mesh = TileMesh(width: 64, height: 48, color: grey, outline: outline)
        // From the first edge to the third.
        let made = mesh.cut(
            0, from: CutEnd(edge: 0, t: 0.5), to: CutEnd(edge: 2, t: 0.5), stage: 1, shareCorners: true)
        XCTAssertEqual(mesh.freedom[5], .slide(from: 0, to: 1))
        XCTAssertEqual(mesh.freedom[6], .slide(from: 2, to: 3))
        // Cut the first piece from the cut line to what is left of the outline's first edge:
        // that end still slides between the outline's own corners.
        let first = mesh.nodes[made.first].corners  // 5, 1, 2, 6
        XCTAssertEqual(first, [5, 1, 2, 6])
        mesh.cut(
            made.first, from: CutEnd(edge: 3, t: 0.5), to: CutEnd(edge: 0, t: 0.5), stage: 2,
            shareCorners: true)
        XCTAssertEqual(mesh.freedom[7], .free)
        XCTAssertEqual(mesh.freedom[8], .slide(from: 0, to: 1))
        XCTAssertTrue(mesh.nodes[made.second].corners.contains(7), "the cut line's new corner is shared")
        XCTAssertEqual(mesh.invalidLeaves(minArea: 1), [])
    }
}
