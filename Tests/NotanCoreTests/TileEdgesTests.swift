import MLX
import XCTest
@testable import NotanCore

final class TileEdgesTests: XCTestCase {
    /// A square from (8, 8) to (24, 24), then two points no tile uses.
    let squarePoints = MLXArray([8, 8, 24, 8, 24, 24, 8, 24, 3, 3, 30, 30] as [Float], [6, 2])

    func pointsArray(_ mesh: TileMesh) -> MLXArray {
        MLXArray(mesh.points.flatMap { [$0.x, $0.y] }, [mesh.points.count, 2])
    }

    func testEdgeCountIsRoundedUpToAMultipleOfFour() {
        XCTAssertEqual(TileEdgeLayout(tiles: [[0, 1, 2, 3], [0, 1, 2, 3, 4]]).edgeCount, 8)
        XCTAssertEqual(TileEdgeLayout(tiles: [[0, 1, 2]]).edgeCount, 8)
        XCTAssertEqual(TileEdgeLayout(tiles: [[0, 1, 2, 3, 4, 5, 6, 7]]).edgeCount, 8)
        XCTAssertEqual(TileEdgeLayout(tiles: [Array(0..<9)]).edgeCount, 12)
        XCTAssertEqual(TileEdgeLayout(tiles: [[0, 1, 2, 3], [0, 1, 2, 3, 4]]).tileCount, 2)
    }

    func testEdgesFormAClosedOutline() {
        let layout = TileEdgeLayout(tiles: [[0, 1, 2, 3]])
        let edges = layout.edges(points: squarePoints)
        XCTAssertEqual(edges.shape, [1, 8, 4])
        let flat = edges.asArray(Float.self)
        var length: Float = 0
        var starts: [SIMD2<Float>] = []
        for edge in 0..<8 {
            let start = SIMD2(flat[edge * 4], flat[edge * 4 + 1])
            let end = SIMD2(flat[edge * 4 + 2], flat[edge * 4 + 3])
            let next = (edge + 1) % 8
            XCTAssertEqual(end, SIMD2(flat[next * 4], flat[next * 4 + 1]), "edge \(edge) leads into the next")
            let step = ((end - start) * (end - start)).sum().squareRoot()
            XCTAssertGreaterThan(step, 1, "no edge is a point")
            length += step
            starts.append(start)
        }
        XCTAssertEqual(length, 64, accuracy: 1e-3)
        for corner in [SIMD2<Float>(8, 8), SIMD2(24, 8), SIMD2(24, 24), SIMD2(8, 24)] {
            XCTAssertTrue(starts.contains(corner))
        }
    }

    func testAreasMatchPolygonArea() {
        let mesh = fourTileMesh()
        let layout = TileEdgeLayout(tiles: mesh.leaves.map { mesh.nodes[$0].corners })
        let areas = layout.areas(points: pointsArray(mesh)).asArray(Float.self)
        XCTAssertEqual(areas.count, 4)
        for (index, leaf) in mesh.leaves.enumerated() {
            XCTAssertEqual(areas[index], polygonArea(mesh.polygon(leaf)), accuracy: 1e-2)
        }
    }

    func testAreaHasADerivativeByACorner() {
        let layout = TileEdgeLayout(tiles: [[0, 1, 2, 3]])
        let gradient = grad { (points: MLXArray) in layout.areas(points: points).sum() }(squarePoints)
            .asArray(Float.self)
        // Moving a corner out along x by 1 adds half the height between its neighbours.
        let expected: [Float] = [-8, -8, 8, -8, 8, 8, -8, 8, 0, 0, 0, 0]
        for index in expected.indices {
            XCTAssertEqual(gradient[index], expected[index], accuracy: 1e-3, "element \(index)")
        }
    }

    func testASquareTileRendersAsASquare() {
        let layout = TileEdgeLayout(tiles: [[0, 1, 2, 3]])
        let rasterizer = Rasterizer(width: 32, height: 32, softness: 0.5)
        let rendered = rasterizer.render(
            edges: layout.edges(points: squarePoints), colors: MLXArray([1, 1, 1] as [Float], [1, 3]),
            background: MLXArray([0, 0, 0] as [Float]))
        let image = rendered.image
        XCTAssertGreaterThan(image[16, 16, 0].item(Float.self), 0.99)
        XCTAssertLessThan(image[2, 2, 0].item(Float.self), 0.01)
        XCTAssertEqual(image.sum().item(Float.self) / 3, 256, accuracy: 256 * 0.02)
        // The distance to the tile's outline: 8 px from its middle, none on its edge.
        XCTAssertEqual(rendered.boundaryDistance[16, 16].item(Float.self), 7.5, accuracy: 0.01)
    }

    func testRenderHasADerivativeByACorner() {
        let layout = TileEdgeLayout(tiles: [[0, 1, 2, 3]])
        let rasterizer = Rasterizer(width: 32, height: 32, softness: 0.5)
        let gradient = grad { (points: MLXArray) in
            rasterizer.render(
                edges: layout.edges(points: points), colors: MLXArray([1, 1, 1] as [Float], [1, 3]),
                background: MLXArray([0, 0, 0] as [Float])
            ).image.sum()
        }(squarePoints).asArray(Float.self)
        // Pulling the top left corner up and left makes the tile, and so the white, bigger.
        XCTAssertLessThan(gradient[0], -1)
        XCTAssertLessThan(gradient[1], -1)
        XCTAssertGreaterThan(gradient[4], 1)
        XCTAssertGreaterThan(gradient[5], 1)
        XCTAssertEqual(Array(gradient[8...]), [0, 0, 0, 0])
    }

    func testTileLossIsTheErrorTermsOfFitLoss() {
        let target = MLXArray((0..<(8 * 8 * 3)).map { Float($0 % 7) / 7 }, [8, 8, 3])
        let image = MLXArray((0..<(8 * 8 * 3)).map { Float($0 % 5) / 5 }, [8, 8, 3])
        let boundary = MLXArray((0..<64).map { Float($0 % 13) }, [8, 8])
        var config = LossConfig()
        config.xingWeight = 0
        config.foldWeight = 0
        let circle = NotanCore.pointsArray([Shape.circle(center: SIMD2(4, 4), radius: 2, color: .white)])
        let whole = fitLoss(
            image: image, target: target, boundaryDistance: boundary, points: circle, config: config)
        let tiles = tileLoss(image: image, target: target, boundaryDistance: boundary, config: LossConfig())
        XCTAssertEqual(tiles.item(Float.self), whole.item(Float.self), accuracy: 1e-6)
        XCTAssertGreaterThan(tiles.item(Float.self), 0.01)
    }
}
