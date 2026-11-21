import XCTest
@testable import NotanCore

final class CutSearchTests: XCTestCase {
    func square(_ side: Float) -> [SIMD2<Float>] {
        [SIMD2(0, 0), SIMD2(side, 0), SIMD2(side, side), SIMD2(0, side)]
    }

    /// The summed squared distance of every pixel from the mean colour.
    func totalError(_ target: TargetImage) -> Float {
        let mean = target.meanColor
        var sum: Float = 0
        for y in 0..<target.height {
            for x in 0..<target.width {
                let c = target.color(x: x, y: y)
                sum += (c.r - mean.r) * (c.r - mean.r) + (c.g - mean.g) * (c.g - mean.g)
                    + (c.b - mean.b) * (c.b - mean.b)
            }
        }
        return sum
    }

    /// The summed squared distance from the mean of `count` pixels, `black` of them black
    /// and the rest white.
    func totalError(_ target: TargetImage, in count: Float, black: Float) -> Float {
        let share = black / count
        return count * share * (1 - share) * 3
    }

    /// The two pieces a choice cuts a polygon into, as `TileMesh.cut` makes them.
    func pieces(_ polygon: [SIMD2<Float>], _ choice: CutChoice) -> (first: [SIMD2<Float>], second: [SIMD2<Float>]) {
        func at(_ end: CutEnd) -> SIMD2<Float> {
            let a = polygon[end.edge]
            let b = polygon[(end.edge + 1) % polygon.count]
            return a + (b - a) * end.t
        }
        func run(after first: Int, through last: Int) -> [SIMD2<Float>] {
            var result: [SIMD2<Float>] = []
            var position = (first + 1) % polygon.count
            while true {
                result.append(polygon[position])
                if position == last { break }
                position = (position + 1) % polygon.count
            }
            return result
        }
        return (
            [at(choice.from)] + run(after: choice.from.edge, through: choice.to.edge) + [at(choice.to)],
            [at(choice.to)] + run(after: choice.to.edge, through: choice.from.edge) + [at(choice.from)]
        )
    }

    func testFindsTheEdgeBetweenTwoFlatHalves() throws {
        let target = makeTarget(width: 32, height: 32) { x, _ in x < 16 ? .black : .white }
        let choice = try XCTUnwrap(bestCut(of: square(32), in: target, minThickness: 1))
        XCTAssertEqual(choice.from.edge, 0)
        XCTAssertEqual(choice.to.edge, 2)
        XCTAssertEqual(choice.from.t * 32, 16, accuracy: 2.5)
        XCTAssertEqual((1 - choice.to.t) * 32, 16, accuracy: 2.5)
        XCTAssertGreaterThan(choice.gain, 0.7 * totalError(target))
        // The colours go with the pieces: the first piece is the one `TileMesh.cut` makes first.
        let first = pieces(square(32), choice).first
        let middle = first.reduce(SIMD2<Float>(0, 0), +) / Float(first.count)
        let (dark, light) = middle.x < 16 ? (choice.firstColor, choice.secondColor) : (choice.secondColor, choice.firstColor)
        XCTAssertLessThan(dark.r, 0.2)
        XCTAssertGreaterThan(light.r, 0.8)
    }

    func testFindsADiagonalEdge() throws {
        let target = makeTarget(width: 32, height: 32) { x, y in y > x ? .black : .white }
        let choice = try XCTUnwrap(bestCut(of: square(32), in: target, minThickness: 1))
        XCTAssertGreaterThan(choice.gain, 0.8 * totalError(target))
    }

    func testFlatImageStillGivesACutWithNoGain() throws {
        let target = makeTarget(width: 32, height: 32) { _, _ in .grey }
        let choice = try XCTUnwrap(bestCut(of: square(32), in: target, minThickness: 1))
        XCTAssertLessThan(choice.gain, 1e-4)
        XCTAssertGreaterThanOrEqual(choice.gain, 0)
    }

    func testTooSmallATileGivesNoCut() {
        let target = makeTarget(width: 32, height: 32) { x, _ in x < 1 ? .black : .white }
        XCTAssertNil(bestCut(of: square(2), in: target, minThickness: 1))
    }

    func testCutLeavesNoPieceThinnerThanAllowed() throws {
        // Black above, white below: the cut that gains most runs lengthwise, and would
        // leave two strips 5 px wide.
        let target = makeTarget(width: 40, height: 10) { _, y in y < 5 ? .black : .white }
        let strip: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(40, 0), SIMD2(40, 10), SIMD2(0, 10)]
        let free = try XCTUnwrap(bestCut(of: strip, in: target, minThickness: 1))
        XCTAssertEqual(Set([free.from.edge, free.to.edge]), [1, 3])
        let choice = try XCTUnwrap(bestCut(of: strip, in: target, minThickness: 6))
        XCTAssertEqual(Set([choice.from.edge, choice.to.edge]), [0, 2])
        let made = pieces(strip, choice)
        XCTAssertGreaterThanOrEqual(thickness(of: made.first), 6)
        XCTAssertGreaterThanOrEqual(thickness(of: made.second), 6)
    }

    func testThicknessOfAStripIsNearItsWidth() {
        XCTAssertEqual(thickness(of: square(10)), 5, accuracy: 1e-4)
        let strip: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 4), SIMD2(0, 4)]
        XCTAssertEqual(thickness(of: strip), 4, accuracy: 0.2)
    }

    func testCutOfADentedTileStaysInside() throws {
        let target = makeTarget(width: 20, height: 20) { x, y in (x < 10) == (y < 10) ? .black : .white }
        let dented: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 10), SIMD2(10, 10), SIMD2(10, 20), SIMD2(0, 20),
        ]
        let choice = try XCTUnwrap(bestCut(of: dented, in: target, minThickness: 1))
        let made = pieces(dented, choice)
        XCTAssertTrue(isSimplePolygon(made.first))
        XCTAssertTrue(isSimplePolygon(made.second))
        XCTAssertGreaterThan(polygonArea(made.first), 0)
        XCTAssertGreaterThan(polygonArea(made.second), 0)
        XCTAssertEqual(polygonArea(made.first) + polygonArea(made.second), 300, accuracy: 0.01)
        // A third of the tile is black, the rest white. The cut that would part them
        // exactly ends in the dent's corner, which a cut may not; one beside it gets
        // over half of the way.
        XCTAssertGreaterThan(choice.gain, 0.5 * totalError(target, in: 300, black: 100))
    }

    func testSameInputGivesTheSameCut() {
        let target = makeTarget(width: 32, height: 32) { x, y in
            RGB(r: Float((Int(x) * 7 + Int(y) * 13) % 11) / 10, g: 0.3, b: Float(Int(y) % 5) / 4)
        }
        XCTAssertEqual(
            bestCut(of: square(32), in: target, minThickness: 1),
            bestCut(of: square(32), in: target, minThickness: 1))
    }
}
