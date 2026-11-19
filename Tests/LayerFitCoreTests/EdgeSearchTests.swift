import MLX
import XCTest

@testable import LayerFitCore

/// The search for each pixel's nearest edge, against the same search written as a plain
/// loop.
final class EdgeSearchTests: XCTestCase {
    typealias Edge = (a: SIMD2<Float>, b: SIMD2<Float>)

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

    /// Runs the search and checks every pixel of every window against the plain loop.
    func check(
        _ shapes: [[Edge]], batch: WindowLayout.Batch, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let edgeCount = shapes[0].count
        let found = EdgeSearch.nearest(edges: edgesArray(shapes), batch: batch)
        XCTAssertEqual(
            found.isNearest.shape, [shapes.count, batch.height, batch.width, edgeCount], file: file,
            line: line)
        XCTAssertEqual(
            found.sign.shape, [shapes.count, batch.height, batch.width], file: file, line: line)
        guard found.isNearest.size == shapes.count * batch.height * batch.width * edgeCount,
            found.sign.size == shapes.count * batch.height * batch.width
        else { return }
        let table = found.isNearest.asArray(Float.self)
        let signs = found.sign.asArray(Float.self)

        var notOneEdge = 0
        var notNearest = 0
        var wrongSide = 0
        for (index, edges) in shapes.enumerated() {
            for row in 0..<batch.height {
                for column in 0..<batch.width {
                    let p = SIMD2(
                        Float(batch.originsX[index] + column) + 0.5,
                        Float(batch.originsY[index] + row) + 0.5)
                    let pixel = (index * batch.height + row) * batch.width + column
                    let marks = Array(table[(pixel * edgeCount)..<((pixel + 1) * edgeCount)])
                    let chosen = marks.indices.filter { marks[$0] == 1 }
                    if chosen.count != 1 || marks.contains(where: { $0 != 0 && $0 != 1 }) {
                        notOneEdge += 1
                        continue
                    }
                    let distances = edges.map { squaredDistance(p, $0) }
                    if distances[chosen[0]] > distances.min()! * 1.0001 + 1e-6 { notNearest += 1 }
                    let wound = winding(p, edges)
                    if !wound.doubtful && signs[pixel] != (wound.count != 0 ? 1 : -1) {
                        wrongSide += 1
                    }
                }
            }
        }
        XCTAssertEqual(notOneEdge, 0, "pixels without exactly one nearest edge", file: file, line: line)
        XCTAssertEqual(notNearest, 0, "pixels whose chosen edge is not the nearest", file: file, line: line)
        XCTAssertEqual(wrongSide, 0, "pixels on the wrong side of the outline", file: file, line: line)
    }

    func testNearestEdgeAndSideMatchAPlainLoop() {
        // Windows that are wider than high, at different places, some cutting their shape.
        let shapes = [
            wobbly(14, 9, radius: 6, phase: 0.3), wobbly(30.4, 20.7, radius: 9, phase: 1.1),
            wobbly(52, 8, radius: 3, phase: 2.5), wobbly(8.2, 30.1, radius: 12, phase: 4),
            wobbly(70, 40, radius: 5, phase: 5.2),
        ]
        let batch = WindowLayout.Batch(
            shapes: [0, 1, 2, 3, 4], width: 24, height: 16, originsX: [2, 20, 40, 0, 58],
            originsY: [1, 12, 0, 22, 33])
        check(shapes, batch: batch)
    }

    func testOneShapeOverALargeWindow() {
        let batch = WindowLayout.Batch(
            shapes: [0], width: 96, height: 64, originsX: [0], originsY: [0])
        check([wobbly(45.3, 30.8, radius: 22, phase: 0.7)], batch: batch)
    }

    /// An outline that crosses itself is solid wherever it winds around at all: the middle
    /// of a five-pointed star, which the outline goes around twice, is inside.
    func testSelfCrossingOutlineIsSolid() {
        let star = outline(
            (0..<5).map { k in
                let angle = 2 * Float.pi * Float(2 * k) / 5 + 0.2
                return SIMD2(16.1 + 13 * cos(angle), 15.9 + 13 * sin(angle))
            })
        let batch = WindowLayout.Batch(
            shapes: [0], width: 32, height: 32, originsX: [0], originsY: [0])
        check([star], batch: batch)
        let sign = EdgeSearch.nearest(edges: edgesArray([star]), batch: batch).sign
        XCTAssertEqual(sign[0, 16, 16].item(Float.self), 1)
        XCTAssertEqual(sign[0, 1, 1].item(Float.self), -1)
    }

    /// Beyond a corner, the two edges that meet there are exactly equally near. The first
    /// of them, in the order the edges are given, is the one that counts.
    func testFirstOfEquallyNearEdgesCounts() {
        let square = outline([SIMD2(4, 4), SIMD2(10, 4), SIMD2(10, 10), SIMD2(4, 10)])
        let batch = WindowLayout.Batch(
            shapes: [0], width: 16, height: 16, originsX: [0], originsY: [0])
        let table = EdgeSearch.nearest(edges: edgesArray([square]), batch: batch).isNearest
        func chosen(_ x: Int, _ y: Int) -> [Float] { table[0, y, x].asArray(Float.self) }
        XCTAssertEqual(chosen(2, 2), [1, 0, 0, 0])  // edges 3 and 0 meet at (4, 4)
        XCTAssertEqual(chosen(11, 2), [1, 0, 0, 0])  // edges 0 and 1 meet at (10, 4)
        XCTAssertEqual(chosen(11, 11), [0, 1, 0, 0])  // edges 1 and 2 meet at (10, 10)
        XCTAssertEqual(chosen(2, 11), [0, 0, 1, 0])  // edges 2 and 3 meet at (4, 10)
    }
}
