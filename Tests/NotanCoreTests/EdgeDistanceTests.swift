import MLX
import XCTest

@testable import NotanCore

/// The GPU's search for each window pixel's nearest edge, against the same search written
/// as a plain loop.
final class EdgeDistanceTests: XCTestCase {
    typealias Edge = (a: SIMD2<Float>, b: SIMD2<Float>)

    func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> PixelRect {
        PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    func outline(_ vertices: [SIMD2<Float>]) -> [Edge] {
        vertices.indices.map { (vertices[$0], vertices[($0 + 1) % vertices.count]) }
    }

    /// A closed outline of 32 edges that wobbles around a circle.
    func wobbly(_ x: Float, _ y: Float, radius: Float, phase: Float) -> [Edge] {
        outline(
            (0..<32).map { k in
                let angle = 2 * Float.pi * Float(k) / 32
                let r = radius * (1 + 0.3 * sin(3 * angle + phase))
                return SIMD2(x + r * cos(angle), y + r * sin(angle))
            })
    }

    func edgesArray(_ shapes: [[Edge]]) -> MLXArray {
        MLXArray(
            shapes.flatMap { $0.flatMap { [$0.a.x, $0.a.y, $0.b.x, $0.b.y] } },
            [shapes.count, shapes[0].count, 4])
    }

    func squaredDistance(_ p: SIMD2<Float>, _ edge: Edge) -> Float {
        let d = edge.b - edge.a
        let rel = p - edge.a
        let t = min(max((rel.x * d.x + rel.y * d.y) / (d.x * d.x + d.y * d.y + 1e-8), 0), 1)
        let off = rel - t * d
        return off.x * off.x + off.y * off.y
    }

    /// How many times the outline winds around the point, and whether the point is so
    /// close to an edge crossing that rounding could decide the count.
    func winding(_ p: SIMD2<Float>, _ edges: [Edge]) -> (count: Int, doubtful: Bool) {
        var count = 0
        var doubtful = false
        for edge in edges where (edge.a.y > p.y) != (edge.b.y > p.y) {
            let crossX = edge.a.x + (p.y - edge.a.y) / (edge.b.y - edge.a.y) * (edge.b.x - edge.a.x)
            if abs(p.x - crossX) < 1e-3 { doubtful = true }
            if p.x < crossX { count += edge.b.y > edge.a.y ? 1 : -1 }
        }
        return (count, doubtful)
    }

    /// Runs the search over one window per shape and checks every window pixel against the
    /// plain loop.
    func check(
        _ shapes: [[Edge]], windows: [PixelRect], file: StaticString = #filePath, line: UInt = #line
    ) {
        let layout = WindowLayout(crops: windows, width: 200, height: 200)
        XCTAssertEqual(layout.drawn.count, shapes.count, file: file, line: line)
        let found = RasterKernels.distances(edges: edgesArray(shapes), layout: layout)
        XCTAssertEqual(found.distance.shape, [layout.stripLength], file: file, line: line)
        XCTAssertEqual(found.nearest.shape, [layout.stripLength], file: file, line: line)
        XCTAssertEqual(found.nearest.dtype, .int32, file: file, line: line)
        guard found.distance.size == layout.stripLength, found.nearest.size == layout.stripLength
        else { return }
        let distances = found.distance.asArray(Float.self)
        let nearest = found.nearest.asArray(Int32.self)

        var notAnEdge = 0
        var notNearest = 0
        var wrongDistance = 0
        var wrongSide = 0
        var element = 0
        for (edges, window) in zip(shapes, layout.windows) {
            for y in window.y0..<window.y1 {
                for x in window.x0..<window.x1 {
                    defer { element += 1 }
                    let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    let chosen = Int(nearest[element])
                    guard edges.indices.contains(chosen) else {
                        notAnEdge += 1
                        continue
                    }
                    let squared = edges.map { squaredDistance(p, $0) }
                    let least = squared.min()!
                    if squared[chosen] > least * 1.0001 + 1e-6 { notNearest += 1 }
                    let expected = (least + 1e-8).squareRoot()
                    if abs(abs(distances[element]) - expected) > 1e-4 * (1 + expected) {
                        wrongDistance += 1
                    }
                    let wound = winding(p, edges)
                    if !wound.doubtful && (distances[element] > 0) != (wound.count != 0) {
                        wrongSide += 1
                    }
                }
            }
        }
        XCTAssertEqual(notAnEdge, 0, "pixels whose nearest edge is no edge", file: file, line: line)
        XCTAssertEqual(notNearest, 0, "pixels whose chosen edge is not the nearest", file: file, line: line)
        XCTAssertEqual(wrongDistance, 0, "pixels at the wrong distance", file: file, line: line)
        XCTAssertEqual(wrongSide, 0, "pixels on the wrong side of the outline", file: file, line: line)
    }

    func testDistanceAndSideMatchAPlainLoop() {
        // Windows of different sizes and places, some cutting their shape.
        let shapes = [
            wobbly(14, 9, radius: 6, phase: 0.3), wobbly(30.4, 20.7, radius: 9, phase: 1.1),
            wobbly(52, 8, radius: 3, phase: 2.5), wobbly(8.2, 30.1, radius: 12, phase: 4),
            wobbly(70, 40, radius: 5, phase: 5.2),
        ]
        check(
            shapes,
            windows: [
                rect(2, 1, 26, 17), rect(20, 12, 41, 30), rect(40, 0, 64, 16), rect(0, 22, 9, 61),
                rect(58, 33, 82, 47),
            ])
    }

    func testOneShapeOverALargeWindow() {
        check([wobbly(45.3, 30.8, radius: 22, phase: 0.7)], windows: [rect(0, 0, 96, 64)])
    }

    /// An outline that crosses itself is solid wherever it winds around at all: the middle
    /// of a five-pointed star, which the outline goes around twice, is inside.
    func testSelfCrossingOutlineIsSolid() {
        let star = outline(
            (0..<5).map { k in
                let angle = 2 * Float.pi * Float(2 * k) / 5 + 0.2
                return SIMD2(16.1 + 13 * cos(angle), 15.9 + 13 * sin(angle))
            })
        check([star], windows: [rect(0, 0, 32, 32)])
        let layout = WindowLayout(crops: [rect(0, 0, 32, 32)], width: 32, height: 32)
        let distance = RasterKernels.distances(edges: edgesArray([star]), layout: layout).distance
        XCTAssertGreaterThan(distance[16 * 32 + 16].item(Float.self), 0)
        XCTAssertLessThan(distance[1 * 32 + 1].item(Float.self), 0)
    }

    /// Beyond a corner, the two edges that meet there are exactly equally near. The first
    /// of them, in the order the edges are given, is the one that counts.
    func testFirstOfEquallyNearEdgesCounts() {
        let square = outline([SIMD2(4, 4), SIMD2(10, 4), SIMD2(10, 10), SIMD2(4, 10)])
        let layout = WindowLayout(crops: [rect(0, 0, 16, 16)], width: 16, height: 16)
        let nearest = RasterKernels.distances(edges: edgesArray([square]), layout: layout).nearest
        func chosen(_ x: Int, _ y: Int) -> Int32 { nearest[y * 16 + x].item(Int32.self) }
        XCTAssertEqual(chosen(2, 2), 0)  // edges 3 and 0 meet at (4, 4)
        XCTAssertEqual(chosen(11, 2), 0)  // edges 0 and 1 meet at (10, 4)
        XCTAssertEqual(chosen(11, 11), 1)  // edges 1 and 2 meet at (10, 10)
        XCTAssertEqual(chosen(2, 11), 2)  // edges 2 and 3 meet at (4, 10)
    }
}
