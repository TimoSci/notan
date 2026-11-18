import XCTest
@testable import LayerFitCore

final class BezierTests: XCTestCase {
    func testBasisShape() {
        let basis = bezierBasis(samplesPerSegment: 8)
        XCTAssertEqual(basis.count, 32)
        XCTAssertTrue(basis.allSatisfy { $0.count == 12 })
    }

    func testBasisRowsSumToOne() {
        for row in bezierBasis(samplesPerSegment: 8) {
            XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-5)
        }
    }

    func testCirclePolygonIsRound() {
        let centre = SIMD2<Float>(50, 50)
        let circle = Shape.circle(center: centre, radius: 20, color: RGB(r: 1, g: 1, b: 1))
        let polygon = samplePolygon(circle.points, samplesPerSegment: 8)
        XCTAssertEqual(polygon.count, 32)
        for vertex in polygon {
            let d = vertex - centre
            XCTAssertEqual((d * d).sum().squareRoot(), 20, accuracy: 0.05)
        }
    }

    func testFirstVertexIsFirstAnchor() {
        let circle = Shape.circle(center: SIMD2(50, 50), radius: 20, color: RGB(r: 1, g: 1, b: 1))
        let polygon = samplePolygon(circle.points, samplesPerSegment: 8)
        XCTAssertEqual(polygon[0], circle.points[0])
        XCTAssertEqual(polygon[8], circle.points[3])
    }

    func testLastSegmentWrapsToFirstAnchor() {
        // The last sample of the last segment must be pulled toward p[0], not past the array end.
        let basis = bezierBasis(samplesPerSegment: 4)
        XCTAssertGreaterThan(basis[15][0], 0.3)
    }
}
