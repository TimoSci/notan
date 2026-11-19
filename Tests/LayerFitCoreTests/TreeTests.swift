import CoreGraphics
import XCTest
@testable import LayerFitCore

/// A 64×64 white picture with a big red circle (shape 0) and a small blue one (shape 1)
/// overlapping its right side. The red circle holds one green child that is larger than
/// the part of it lying inside the red circle, so clipping is visible.
func treePicture() -> LayerFitCore.Picture {
    var red = Shape.circle(center: SIMD2(28, 32), radius: 20, color: .red)
    let green = Shape.circle(center: SIMD2(12, 32), radius: 12, color: RGB(r: 0, g: 1, b: 0))
    red.inner = Inner(
        levels: [InnerLevel(shapes: [], mse: 0.2), InnerLevel(shapes: [green], mse: 0.1)], shown: 1)
    let blue = Shape.circle(center: SIMD2(48, 32), radius: 8, color: .blue)
    return LayerFitCore.Picture(width: 64, height: 64, background: .white, shapes: [red, blue])
}

final class TreeTests: XCTestCase {
    let green = RGB(r: 0, g: 1, b: 0)

    func pixels(_ picture: LayerFitCore.Picture, maxDepth: Int = .max) throws -> TargetImage {
        let image = try XCTUnwrap(
            makeCGImage(picture, pixelSize: CGSize(width: 64, height: 64), maxDepth: maxDepth))
        return TargetImage(width: 64, height: 64, pixels: rgbPixels(of: image, width: 64, height: 64))
    }

    // MARK: Structure

    func testInnerShowsItsChosenLevel() {
        var inner = treePicture().shapes[0].inner!
        XCTAssertEqual(inner.shapes.count, 1)
        inner.shown = 0
        XCTAssertEqual(inner.shapes.count, 0)
        inner.shown = 99  // out of range is clamped
        XCTAssertEqual(inner.shapes.count, 1)
    }

    func testMaxDepthAndCounts() {
        var picture = treePicture()
        XCTAssertEqual(picture.maxDepth, 1)
        XCTAssertEqual(picture.shapeCount(maxDepth: .max), 3)
        XCTAssertEqual(picture.shapeCount(maxDepth: 0), 2)
        XCTAssertEqual(picture.estimatedBytes(maxDepth: .max), 3 + 3 * 51)
        XCTAssertEqual(picture.estimatedBytes, 3 + 3 * 51)
        picture.shapes[0].inner?.shown = 0
        XCTAssertEqual(picture.maxDepth, 0)
        XCTAssertEqual(picture.shapeCount(maxDepth: .max), 2)
    }

    func testLookUpByNode() {
        let picture = treePicture()
        XCTAssertEqual(picture.shape(at: .shape([1]))?.color, .blue)
        XCTAssertEqual(picture.shape(at: .shape([0, 0]))?.color, green)
        XCTAssertNil(picture.shape(at: .shape([0, 5])))
        XCTAssertNil(picture.shape(at: .shape([7])))
        XCTAssertNil(picture.shape(at: .background))
        XCTAssertEqual(picture.inner(at: .shape([0]))?.levels.count, 2)
        XCTAssertNil(picture.inner(at: .shape([1])))
    }

    func testSetInnerOnNestedShapeAndBackground() {
        var picture = treePicture()
        let dot = Shape.circle(center: SIMD2(10, 32), radius: 3, color: .black)
        let inner = Inner(levels: [InnerLevel(shapes: [dot], mse: 0)], shown: 0)
        XCTAssertTrue(picture.setInner(inner, at: .shape([0, 0])))
        XCTAssertEqual(picture.shape(at: .shape([0, 0, 0]))?.color, .black)
        XCTAssertEqual(picture.maxDepth, 2)
        XCTAssertTrue(picture.setInner(inner, at: .background))
        XCTAssertEqual(picture.shape(at: NodeID(inBackground: true, path: [0]))?.color, .black)
        XCTAssertFalse(picture.setInner(inner, at: .shape([9])))
    }

    // MARK: Drawing

    func testChildIsClippedToItsParent() throws {
        let image = try pixels(treePicture())
        XCTAssertEqual(image.color(x: 14, y: 32), green)  // inside both
        XCTAssertEqual(image.color(x: 3, y: 32), .white)  // inside the child but outside the parent
        XCTAssertEqual(image.color(x: 34, y: 32), .red)  // parent only
    }

    func testLaterShapeCoversEarlierShapesChildren() throws {
        var picture = treePicture()
        picture.shapes[1] = Shape.circle(center: SIMD2(14, 32), radius: 4, color: .blue)
        XCTAssertEqual(try pixels(picture).color(x: 14, y: 32), .blue)
    }

    func testDepthLimitHidesChildren() throws {
        let image = try pixels(treePicture(), maxDepth: 0)
        XCTAssertEqual(image.color(x: 14, y: 32), .red)
    }

    func testBackgroundChildrenAreDrawnUnderEveryShape() throws {
        var picture = treePicture()
        let wide = Shape.circle(center: SIMD2(32, 32), radius: 30, color: .black)
        picture.backgroundInner = Inner(levels: [InnerLevel(shapes: [wide], mse: 0)], shown: 0)
        let image = try pixels(picture)
        XCTAssertEqual(image.color(x: 32, y: 6), .black)  // background child, no shape above
        XCTAssertEqual(image.color(x: 34, y: 32), .red)  // shapes still on top
        XCTAssertEqual(image.color(x: 1, y: 1), .white)
        XCTAssertEqual(picture.maxDepth, 1)
    }

    // MARK: Region rendering

    func testRegionRenderZoomsIntoThePicture() {
        // The 8×8 picture-pixel square around the blue circle's centre, drawn at 32×32.
        let region = CGRect(x: 44, y: 28, width: 8, height: 8)
        let rgb = renderRegion(treePicture(), region: region, width: 32, height: 32)
        XCTAssertEqual(rgb.count, 32 * 32 * 3)
        let image = TargetImage(width: 32, height: 32, pixels: rgb)
        XCTAssertEqual(image.color(x: 16, y: 16), .blue)
        XCTAssertEqual(image.color(x: 1, y: 1), .blue)
    }

    func testMaskIsWhiteWhereTheNodeIsVisible() {
        let whole = CGRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = renderRegion(
            treePicture(), region: whole, width: 64, height: 64, style: .mask(of: .shape([0])))
        let mask = TargetImage(width: 64, height: 64, pixels: rgb)
        XCTAssertEqual(mask.color(x: 30, y: 32), .white)  // red circle, visible
        XCTAssertEqual(mask.color(x: 14, y: 32), .white)  // under its own child: still its region
        XCTAssertEqual(mask.color(x: 44, y: 32), .black)  // covered by the blue circle
        XCTAssertEqual(mask.color(x: 2, y: 2), .black)  // outside
    }

    func testMaskOfNestedNode() {
        let whole = CGRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = renderRegion(
            treePicture(), region: whole, width: 64, height: 64, style: .mask(of: .shape([0, 0])))
        let mask = TargetImage(width: 64, height: 64, pixels: rgb)
        XCTAssertEqual(mask.color(x: 14, y: 32), .white)
        XCTAssertEqual(mask.color(x: 3, y: 32), .black)  // child's outline, but clipped away
        XCTAssertEqual(mask.color(x: 34, y: 32), .black)
    }

    func testMaskOfBackground() {
        let whole = CGRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = renderRegion(
            treePicture(), region: whole, width: 64, height: 64, style: .mask(of: .background))
        let mask = TargetImage(width: 64, height: 64, pixels: rgb)
        XCTAssertEqual(mask.color(x: 2, y: 2), .white)
        XCTAssertEqual(mask.color(x: 30, y: 32), .black)
        XCTAssertEqual(mask.color(x: 48, y: 32), .black)
    }

    func testOmittingInnerDrawsTheBareShape() {
        let whole = CGRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = renderRegion(
            treePicture(), region: whole, width: 64, height: 64, omittingInnerOf: .shape([0]))
        XCTAssertEqual(TargetImage(width: 64, height: 64, pixels: rgb).color(x: 14, y: 32), .red)
    }

    // MARK: Clicking

    func testHitTestFindsTopmostShape() {
        let picture = treePicture()
        XCTAssertEqual(picture.hitTest(SIMD2(48, 32)), .shape([1]))
        XCTAssertEqual(picture.hitTest(SIMD2(44, 32)), .shape([1]))  // blue is above red here
        XCTAssertEqual(picture.hitTest(SIMD2(34, 32)), .shape([0]))
    }

    func testHitTestDescendsToDeepestShownShape() {
        let picture = treePicture()
        XCTAssertEqual(picture.hitTest(SIMD2(14, 32)), .shape([0, 0]))
        XCTAssertEqual(picture.hitTest(SIMD2(14, 32), maxDepth: 0), .shape([0]))
        // Inside the child's outline but outside the parent: neither.
        XCTAssertEqual(picture.hitTest(SIMD2(3, 32)), .background)
    }

    func testHitTestBackgroundAndOutside() {
        var picture = treePicture()
        XCTAssertEqual(picture.hitTest(SIMD2(2, 2)), .background)
        XCTAssertNil(picture.hitTest(SIMD2(-1, 10)))
        XCTAssertNil(picture.hitTest(SIMD2(10, 64.5)))
        let dot = Shape.circle(center: SIMD2(5, 5), radius: 4, color: .black)
        picture.backgroundInner = Inner(levels: [InnerLevel(shapes: [dot], mse: 0)], shown: 0)
        XCTAssertEqual(picture.hitTest(SIMD2(5, 5)), NodeID(inBackground: true, path: [0]))
        XCTAssertEqual(picture.hitTest(SIMD2(5, 5), maxDepth: 0), .background)
    }

    func testParentOfNode() {
        XCTAssertEqual(NodeID.shape([0, 3]).parent, .shape([0]))
        XCTAssertNil(NodeID.shape([2]).parent)
        XCTAssertEqual(NodeID(inBackground: true, path: [1]).parent, .background)
        XCTAssertNil(NodeID.background.parent)
    }

    // MARK: SVG

    /// Elements with this name anywhere under `element`.
    func count(_ name: String, under element: XMLElement) -> Int {
        (element.children ?? []).compactMap { $0 as? XMLElement }.reduce(0) {
            $0 + ($1.name == name ? 1 : 0) + count(name, under: $1)
        }
    }

    func testSVGNestsChildrenInAClip() throws {
        let text = svg(treePicture(), outputSize: CGSize(width: 64, height: 64))
        let root = try XCTUnwrap(XMLDocument(xmlString: text).rootElement())
        XCTAssertEqual(count("clipPath", under: root), 1)
        // Two root shapes, one clip outline, one clipped child.
        XCTAssertEqual(count("path", under: root), 4)
        let group = try XCTUnwrap(root.elements(forName: "g").first)
        XCTAssertTrue(group.attribute(forName: "clip-path")?.stringValue?.hasPrefix("url(#") ?? false)
        XCTAssertEqual(group.elements(forName: "path").first?.attribute(forName: "fill")?.stringValue, "#00ff00")
    }

    func testSVGDepthLimit() throws {
        let text = svg(treePicture(), outputSize: CGSize(width: 64, height: 64), maxDepth: 0)
        let root = try XCTUnwrap(XMLDocument(xmlString: text).rootElement())
        XCTAssertEqual(count("path", under: root), 2)
        XCTAssertEqual(root.elements(forName: "g").count, 0)
    }
}
