import XCTest
@testable import LayerFitCore

final class SeedsTests: XCTestCase {
    /// Grey 64×64 with a red 20×20 square at (8...27, 8...27) and a blue 8×8 at (44...51, 44...51).
    func twoSquares() -> TargetImage {
        makeTarget(width: 64, height: 64) { x, y in
            if (8..<28).contains(x) && (8..<28).contains(y) { return .red }
            if (44..<52).contains(x) && (44..<52).contains(y) { return .blue }
            return .grey
        }
    }

    func testPicksLargestRegion() {
        let target = twoSquares()
        let seeds = findSeeds(
            target: target, current: flatPixels(width: 64, height: 64, color: .grey), count: 1)
        XCTAssertEqual(seeds.count, 1)
        XCTAssertTrue((8..<28).contains(seeds[0].center.x) && (8..<28).contains(seeds[0].center.y))
        XCTAssertEqual(seeds[0].color, .red)
        XCTAssertTrue((2...10).contains(seeds[0].radius), "radius \(seeds[0].radius)")
    }

    func testSecondSeedGoesElsewhere() {
        let seeds = findSeeds(
            target: twoSquares(), current: flatPixels(width: 64, height: 64, color: .grey), count: 2)
        XCTAssertEqual(seeds.count, 2)
        XCTAssertTrue((44..<52).contains(seeds[1].center.x) && (44..<52).contains(seeds[1].center.y))
        XCTAssertEqual(seeds[1].color, .blue)
    }

    func testCentreIsInsideConcaveRegion() {
        // An L: its centre of mass falls in the notch, outside the region.
        func inL(_ x: Float, _ y: Float) -> Bool {
            ((10..<50).contains(x) && (10..<20).contains(y))
                || ((10..<20).contains(x) && (10..<50).contains(y))
        }
        let target = makeTarget(width: 64, height: 64) { x, y in inL(x, y) ? .white : .black }
        let seeds = findSeeds(
            target: target, current: flatPixels(width: 64, height: 64, color: .black), count: 1)
        XCTAssertTrue(inL(seeds[0].center.x, seeds[0].center.y), "\(seeds[0].center)")
    }

    func testSmallBadlyWrongRegionBeatsLargeSlightlyWrongOne() {
        // A white disc on black, compared with a dark grey picture: the background is the
        // larger region, but fixing the disc removes far more error.
        let target = makeTarget(width: 48, height: 48) { x, y in
            inDisc(x, y, 24, 24, 12) ? .white : .black
        }
        let current = flatPixels(width: 48, height: 48, color: RGB(r: 0.2, g: 0.2, b: 0.2))
        let seeds = findSeeds(target: target, current: current, count: 1)
        XCTAssertTrue(inDisc(seeds[0].center.x, seeds[0].center.y, 24, 24, 12), "\(seeds[0].center)")
        XCTAssertEqual(seeds[0].color, .white)
    }

    func testPaperRulePicksLargestRegionWithSmallCircle() {
        // LIVE as published: the largest region wins whatever its error, and the seed is small.
        let target = makeTarget(width: 256, height: 256) { x, y in
            inDisc(x, y, 128, 128, 60) ? .white : .black
        }
        let current = flatPixels(width: 256, height: 256, color: RGB(r: 0.2, g: 0.2, b: 0.2))
        let seeds = findSeeds(target: target, current: current, count: 1, rule: .paper)
        XCTAssertFalse(inDisc(seeds[0].center.x, seeds[0].center.y, 128, 128, 60))
        XCTAssertEqual(seeds[0].color, .black)
        XCTAssertEqual(seeds[0].radius, 5)
        // The default rule goes for the disc and fills it.
        let ours = findSeeds(target: target, current: current, count: 1)
        XCTAssertTrue(inDisc(ours[0].center.x, ours[0].center.y, 128, 128, 60))
        XCTAssertGreaterThan(ours[0].radius, 40)
    }

    func testPaperRuleRadiusScalesWithPictureAndStaysAtLeastTwo() {
        let target = twoSquares()  // 64 px: 5 * 64 / 256 is below the minimum
        let seeds = findSeeds(
            target: target, current: flatPixels(width: 64, height: 64, color: .grey), count: 1,
            rule: .paper)
        XCTAssertEqual(seeds[0].radius, 2)
    }

    func testRadiusIsInscribed() {
        let seeds = findSeeds(
            target: twoSquares(), current: flatPixels(width: 64, height: 64, color: .grey), count: 1)
        // The seed circle must stay inside the 20×20 square.
        let c = seeds[0].center
        let r = seeds[0].radius
        XCTAssertGreaterThanOrEqual(c.x - r, 8)
        XCTAssertLessThanOrEqual(c.x + r, 28)
        XCTAssertGreaterThanOrEqual(c.y - r, 8)
        XCTAssertLessThanOrEqual(c.y + r, 28)
    }

    func testFallbackWhenNoError() {
        let target = twoSquares()
        let seeds = findSeeds(target: target, current: target.pixels, count: 3)
        XCTAssertEqual(seeds.count, 3)
        XCTAssertTrue(seeds.allSatisfy { $0.radius == 2 })
        for i in 0..<3 {
            for j in (i + 1)..<3 {
                let d = seeds[i].center - seeds[j].center
                XCTAssertGreaterThan((d * d).sum().squareRoot(), 4)
            }
        }
    }

    func testMoreSeedsThanPixelsStillReturnsCount() {
        let target = makeTarget(width: 2, height: 2) { _, _ in .grey }
        let seeds = findSeeds(target: target, current: target.pixels, count: 9)
        XCTAssertEqual(seeds.count, 9)
    }
}
