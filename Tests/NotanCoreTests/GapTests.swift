import CoreGraphics
import XCTest
@testable import NotanCore

/// 64×64, white background, one grey bar from top to bottom at x 28…36: it leaves two gaps.
func barPicture() -> NotanCore.Picture {
    NotanCore.Picture(
        width: 64, height: 64, background: .white,
        shapes: [rectangle(x: 28, y: -4, width: 8, height: 72, color: .grey)])
}

/// Red left of the bar, blue right of it, grey under it.
func barTarget() -> TargetImage {
    makeTarget(width: 64, height: 64) { x, _ in x < 28 ? .red : (x < 36 ? .grey : .blue) }
}

final class GapTests: XCTestCase {
    func pixels(_ picture: NotanCore.Picture) throws -> TargetImage {
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: 64, height: 64)))
        return TargetImage(width: 64, height: 64, pixels: rgbPixels(of: image, width: 64, height: 64))
    }

    // MARK: Finding gaps

    func testGapMapFindsEachUncoveredPatch() {
        let map = gapMap(of: barPicture())
        XCTAssertEqual(map.count, 2)
        // Numbered in reading order of their first pixel: the left gap first.
        XCTAssertEqual(map.label(x: 5, y: 30), 0)
        XCTAssertEqual(map.label(x: 50, y: 30), 1)
        XCTAssertEqual(map.label(x: 32, y: 30), -1)
        XCTAssertEqual(map.areas, [28 * 64, 28 * 64])
    }

    func testGapMapNearestFillsCoveredPixels() {
        let map = gapMap(of: barPicture())
        XCTAssertEqual(map.nearest(x: 29, y: 10), 0)
        XCTAssertEqual(map.nearest(x: 35, y: 10), 1)
        XCTAssertEqual(map.nearest(x: 5, y: 10), 0)
    }

    func testTinyHolesAreNotGaps() {
        // Two bars one pixel apart leave a sliver 1 px wide and 64 px tall (a real gap),
        // but a 1×2 pixel hole is ignored.
        var picture = barPicture()
        picture.shapes = [
            rectangle(x: -4, y: -4, width: 72, height: 34, color: .grey),  // top: y < 30
            rectangle(x: -4, y: 32, width: 72, height: 40, color: .grey),  // bottom: y ≥ 32
            rectangle(x: -4, y: 28, width: 35, height: 6, color: .grey),  // x < 31
            rectangle(x: 32, y: 28, width: 40, height: 6, color: .grey),  // x ≥ 32
        ]
        // Uncovered: x = 31, y = 30…31 only.
        let map = gapMap(of: picture)
        XCTAssertEqual(map.count, 0)
        XCTAssertEqual(map.label(x: 31, y: 30), -1)
    }

    func testNoShapesIsOneGap() {
        var picture = barPicture()
        picture.shapes = []
        let map = gapMap(of: picture)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.areas, [64 * 64])
    }

    // MARK: Colouring

    func testAssignGapsTakesEachGapsMeanColour() {
        var picture = barPicture()
        picture.assignGaps(from: barTarget())
        XCTAssertEqual(picture.gaps.map { $0.color }, [.red, .blue])
    }

    func testAssignGapsKeepsNothingWhenFullyCovered() {
        var picture = barPicture()
        picture.shapes = [rectangle(x: -4, y: -4, width: 72, height: 72, color: .grey)]
        picture.assignGaps(from: barTarget())
        XCTAssertEqual(picture.gaps.count, 0)
    }

    func testGapsCostThreeBytesEach() {
        var picture = barPicture()
        XCTAssertEqual(picture.estimatedBytes, 3 + 51)
        picture.assignGaps(from: barTarget())
        XCTAssertEqual(picture.estimatedBytes, 3 + 51 + 2 * 3)
    }

    // MARK: Drawing

    func testEachGapIsDrawnInItsOwnColour() throws {
        var picture = barPicture()
        picture.assignGaps(from: barTarget())
        let image = try pixels(picture)
        XCTAssertEqual(image.color(x: 5, y: 30), .red)
        XCTAssertEqual(image.color(x: 60, y: 5), .blue)
        XCTAssertEqual(image.color(x: 32, y: 30).r, 0.5, accuracy: 0.01)  // the bar
        // Right up to the bar on both sides: no seam of background colour.
        XCTAssertEqual(image.color(x: 27, y: 30), .red)
        XCTAssertEqual(image.color(x: 36, y: 30), .blue)
    }

    func testGapsThatNoLongerMatchTheShapesFallBackToTheBackground() throws {
        var picture = barPicture()
        picture.assignGaps(from: barTarget())
        picture.shapes = []  // now one gap, but two colours stored
        XCTAssertEqual(try pixels(picture).color(x: 5, y: 30), .white)
    }

    func testEdgesStayVectorSharpWhenEnlarged() throws {
        var picture = barPicture()
        picture.assignGaps(from: barTarget())
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: 640, height: 640)))
        let big = TargetImage(width: 640, height: 640, pixels: rgbPixels(of: image, width: 640, height: 640))
        XCTAssertEqual(big.color(x: 279, y: 300), .red)  // one output pixel left of the bar's edge at 280
        XCTAssertEqual(big.color(x: 281, y: 300).r, 0.5, accuracy: 0.01)
        XCTAssertEqual(big.color(x: 281, y: 300).b, 0.5, accuracy: 0.01)
    }

    // MARK: Masks and clicking

    func testMaskOfOneGap() {
        var picture = barPicture()
        picture.assignGaps(from: barTarget())
        let whole = CGRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = renderRegion(picture, region: whole, width: 64, height: 64, style: .mask(of: .gap(1)))
        let mask = TargetImage(width: 64, height: 64, pixels: rgb)
        XCTAssertEqual(mask.color(x: 50, y: 30), .white)
        XCTAssertEqual(mask.color(x: 5, y: 30), .black)
        XCTAssertEqual(mask.color(x: 32, y: 30), .black)
    }

    func testBackgroundMaskCoversEveryGap() {
        var picture = barPicture()
        picture.assignGaps(from: barTarget())
        let whole = CGRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = renderRegion(picture, region: whole, width: 64, height: 64, style: .backgroundMask)
        let mask = TargetImage(width: 64, height: 64, pixels: rgb)
        XCTAssertEqual(mask.color(x: 50, y: 30), .white)
        XCTAssertEqual(mask.color(x: 5, y: 30), .white)
        XCTAssertEqual(mask.color(x: 32, y: 30), .black)
    }

    func testClickingAGapSelectsThatGap() {
        var picture = barPicture()
        XCTAssertEqual(picture.hitTest(SIMD2(5, 30)), .background)  // no gap colours yet
        picture.assignGaps(from: barTarget())
        XCTAssertEqual(picture.hitTest(SIMD2(5, 30)), .gap(0))
        XCTAssertEqual(picture.hitTest(SIMD2(50, 30)), .gap(1))
        XCTAssertEqual(picture.hitTest(SIMD2(32, 30)), .shape([0]))
        XCTAssertEqual(NodeID.gap(0), .background)
    }

    func testGapRefinementsAreKeptPerGap() throws {
        var picture = barPicture()
        picture.assignGaps(from: barTarget())
        let dot = Shape.circle(center: SIMD2(50, 20), radius: 5, color: .black)
        let inner = Inner(levels: [InnerLevel(shapes: [dot], mse: 0)], shown: 0)
        XCTAssertTrue(picture.setInner(inner, at: .gap(1)))
        XCTAssertNil(picture.inner(at: .gap(0)))
        XCTAssertEqual(picture.inner(at: .gap(1))?.shapes.count, 1)
        XCTAssertEqual(picture.shape(at: NodeID.gap(1).child(0))?.color, .black)
        XCTAssertEqual(picture.maxDepth, 1)
        XCTAssertEqual(picture.shapeCount(maxDepth: .max), 2)
        XCTAssertEqual(picture.hitTest(SIMD2(50, 20)), NodeID.gap(1).child(0))
        XCTAssertEqual(NodeID.gap(1).child(0).parent, .gap(1))
        XCTAssertEqual(try pixels(picture).color(x: 50, y: 20), .black)
        XCTAssertFalse(picture.setInner(inner, at: .gap(5)))
    }

    func testGapBoxIsItsExtent() {
        let map = gapMap(of: barPicture())
        XCTAssertEqual(map.box(of: 1), CGRect(x: 36, y: 0, width: 28, height: 64))
        XCTAssertNil(map.box(of: 7))
    }

    // MARK: SVG

    func testSVGCarriesTheGapColoursAsAnImageLayer() throws {
        var picture = barPicture()
        let plain = svg(picture, outputSize: CGSize(width: 640, height: 640))
        XCTAssertFalse(plain.contains("<image"))
        picture.assignGaps(from: barTarget())
        let text = svg(picture, outputSize: CGSize(width: 640, height: 640))
        let root = try XCTUnwrap(XMLDocument(xmlString: text).rootElement())
        let image = try XCTUnwrap(root.elements(forName: "image").first)
        XCTAssertEqual(image.attribute(forName: "width")?.stringValue, "64")
        XCTAssertTrue(image.attribute(forName: "href")?.stringValue?.hasPrefix("data:image/png;base64,") ?? false)
        // The image comes before the shapes, so they are painted over it.
        let names = (root.children ?? []).compactMap { $0.name }
        XCTAssertLessThan(names.firstIndex(of: "image")!, names.firstIndex(of: "path")!)
    }
}
