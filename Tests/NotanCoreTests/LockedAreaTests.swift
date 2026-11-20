import CoreGraphics
import XCTest

@testable import NotanCore

/// A locked area is a region of an earlier level's picture, kept as it was there and
/// painted on top of a later level's picture.
final class LockedAreaTests: XCTestCase {
    let green = RGB(r: 0, g: 1, b: 0)
    let yellow = RGB(r: 1, g: 1, b: 0)

    /// A later level: white with one yellow circle on the left. Locked on top of it is the
    /// red circle of `treePicture()`, which has a green child and is partly covered, in
    /// its own picture, by a blue circle.
    func laterPicture() -> NotanCore.Picture {
        var picture = NotanCore.Picture(
            width: 64, height: 64, background: .white,
            shapes: [Shape.circle(center: SIMD2(16, 32), radius: 14, color: yellow)])
        picture.locked = [LockedArea(picture: treePicture(), node: .shape([0]))]
        return picture
    }

    let onChild = SIMD2<Float>(14, 32)  // in the yellow circle, the red one and its child
    let onRed = SIMD2<Float>(30, 20)  // in the red circle only
    let onRedOverYellow = SIMD2<Float>(20, 45)  // in the yellow and the red circle
    let underBlue = SIMD2<Float>(48, 32)  // where blue covered red in the earlier picture
    let onYellow = SIMD2<Float>(4, 32)  // in the yellow circle only

    func pixels(_ picture: NotanCore.Picture, maxDepth: Int = .max) throws -> TargetImage {
        let image = try XCTUnwrap(
            makeCGImage(picture, pixelSize: CGSize(width: 64, height: 64), maxDepth: maxDepth))
        return TargetImage(width: 64, height: 64, pixels: rgbPixels(of: image, width: 64, height: 64))
    }

    func color(_ image: TargetImage, _ p: SIMD2<Float>) -> RGB { image.color(x: Int(p.x), y: Int(p.y)) }

    func assertColor(_ got: RGB, _ want: RGB, _ what: String, line: UInt = #line) {
        XCTAssertEqual(got.r, want.r, accuracy: 0.02, what, line: line)
        XCTAssertEqual(got.g, want.g, accuracy: 0.02, what, line: line)
        XCTAssertEqual(got.b, want.b, accuracy: 0.02, what, line: line)
    }

    func testLockedAreaIsPaintedOverTheLaterShapes() throws {
        let image = try pixels(laterPicture())
        assertColor(color(image, onChild), green, "child")
        assertColor(color(image, onRed), .red, "red")
        assertColor(color(image, onRedOverYellow), .red, "red over yellow")
        assertColor(color(image, onYellow), yellow, "yellow")
    }

    /// Only the part of the area that showed in its own picture is kept.
    func testWhatCoveredTheAreaInItsOwnPictureIsNotPainted() throws {
        let image = try pixels(laterPicture())
        assertColor(color(image, underBlue), .white, "under blue")
    }

    func testDepthLimitHidesALockedAreasChildren() throws {
        assertColor(color(try pixels(laterPicture(), maxDepth: 0), onChild), .red, "child hidden")
    }

    func testHitTestFindsTheLockedAreaFirst() {
        let picture = laterPicture()
        XCTAssertEqual(picture.hitTest(onChild), NodeID.shape([0, 0]).inLocked(0))
        XCTAssertEqual(picture.hitTest(onChild, maxDepth: 0), NodeID.shape([0]).inLocked(0))
        XCTAssertEqual(picture.hitTest(onRed), NodeID.shape([0]).inLocked(0))
        XCTAssertEqual(picture.hitTest(onYellow), .shape([0]))
        XCTAssertEqual(picture.hitTest(underBlue), .background)
    }

    func testNodesInALockedAreaAreNotThePicturesOwn() {
        let locked = NodeID.shape([0]).inLocked(0)
        XCTAssertNotEqual(locked, .shape([0]))
        XCTAssertEqual(locked.child(1), NodeID.shape([0, 1]).inLocked(0))
        XCTAssertEqual(NodeID.shape([0, 1]).inLocked(0).parent, locked)
        XCTAssertTrue(locked.contains(NodeID.shape([0, 1]).inLocked(0)))
        XCTAssertFalse(locked.contains(.shape([0, 1])))
        XCTAssertFalse(NodeID.shape([0]).contains(locked))
        XCTAssertEqual(locked.inLocked(nil), .shape([0]))
    }

    func testLookUpAndSetInnerReachIntoALockedArea() {
        var picture = laterPicture()
        let locked = NodeID.shape([0]).inLocked(0)
        XCTAssertEqual(picture.shape(at: locked)?.color, .red)
        XCTAssertEqual(picture.shape(at: locked.child(0))?.color, green)
        XCTAssertEqual(picture.inner(at: locked)?.levels.count, 2)
        XCTAssertNil(picture.shape(at: NodeID.shape([0]).inLocked(3)))
        XCTAssertTrue(picture.setInner(nil, at: locked))
        XCTAssertNil(picture.locked[0].picture.shapes[0].inner)
        XCTAssertEqual(picture.shapes[0].color, yellow)  // the picture's own shape 0 is untouched
        XCTAssertFalse(picture.setInner(nil, at: NodeID.shape([0]).inLocked(3)))
    }

    func testCountsIncludeLockedAreas() {
        let picture = laterPicture()
        XCTAssertEqual(picture.maxDepth, 1)
        XCTAssertEqual(picture.shapeCount(maxDepth: .max), 3)
        XCTAssertEqual(picture.shapeCount(maxDepth: 0), 2)
        XCTAssertEqual(picture.estimatedBytes(maxDepth: .max), 3 + 3 * 51)
    }

    func mask(_ picture: NotanCore.Picture, of node: NodeID) -> TargetImage {
        TargetImage(
            width: 64, height: 64,
            pixels: renderRegion(
                picture, region: CGRect(x: 0, y: 0, width: 64, height: 64), width: 64, height: 64,
                style: .mask(of: node)))
    }

    func testMaskOfALockedAreaIsWhereItShows() {
        let image = mask(laterPicture(), of: NodeID.shape([0]).inLocked(0))
        XCTAssertGreaterThan(color(image, onRed).r, 0.9)
        XCTAssertGreaterThan(color(image, onChild).r, 0.9)  // its own children do not count
        XCTAssertLessThan(color(image, underBlue).r, 0.1)
        XCTAssertLessThan(color(image, onYellow).r, 0.1)
    }

    func testMaskOfAShapeLeavesOutWhatALockedAreaCovers() {
        let image = mask(laterPicture(), of: .shape([0]))
        XCTAssertGreaterThan(color(image, onYellow).r, 0.9)
        XCTAssertLessThan(color(image, onChild).r, 0.1)
        XCTAssertLessThan(color(image, onRedOverYellow).r, 0.1)
    }

    func testOmittingInnerOfALockedArea() {
        let bare = TargetImage(
            width: 64, height: 64,
            pixels: renderRegion(
                laterPicture(), region: CGRect(x: 0, y: 0, width: 64, height: 64), width: 64,
                height: 64, omittingInnerOf: NodeID.shape([0]).inLocked(0)))
        assertColor(color(bare, onChild), .red, "bare")
    }

    /// A locked gap: the uncovered part of the earlier picture, with what was fitted in it.
    func testLockedBackgroundKeepsOnlyWhatWasUncovered() throws {
        let child = Shape.circle(center: SIMD2(12, 32), radius: 12, color: green)
        let earlier = NotanCore.Picture(
            width: 64, height: 64, background: .white,
            shapes: [Shape.circle(center: SIMD2(48, 32), radius: 8, color: .blue)],
            backgroundInner: Inner(levels: [InnerLevel(shapes: [child], mse: 0.1)], shown: 0))
        var later = NotanCore.Picture(
            width: 64, height: 64, background: .black,
            shapes: [Shape.circle(center: SIMD2(32, 32), radius: 30, color: yellow)])
        later.locked = [LockedArea(picture: earlier, node: .background)]
        let image = try pixels(later)
        assertColor(color(image, SIMD2(12, 32)), green, "child of the background")
        assertColor(color(image, SIMD2(30, 10)), .white, "earlier background")
        assertColor(color(image, underBlue), yellow, "covered in the earlier picture")
        XCTAssertEqual(later.hitTest(SIMD2(12, 32)), NodeID(inBackground: true, path: [0]).inLocked(0))
        XCTAssertEqual(later.hitTest(SIMD2(30, 10)), NodeID.background.inLocked(0))
        XCTAssertEqual(later.hitTest(underBlue), .shape([0]))
        XCTAssertEqual(later.shapeCount(maxDepth: .max), 2)
    }

    /// One gap of several: a bar down the middle leaves a gap on each side, each with its
    /// own colour, and only the left one is locked.
    func testOneLockedGapAmongSeveral() throws {
        let corners = [SIMD2<Float>(28, -5), SIMD2(36, -5), SIMD2(36, 69), SIMD2(28, 69)]
        var points: [SIMD2<Float>] = []
        for index in 0..<4 {
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            points += [a, a + (b - a) / 3, a + (b - a) * 2 / 3]
        }
        var earlier = NotanCore.Picture(
            width: 64, height: 64, background: .white,
            shapes: [Shape(points: points, color: .black)])
        earlier.assignGaps(from: makeTarget(width: 64, height: 64) { x, _ in x < 32 ? .red : .blue })
        XCTAssertEqual(earlier.gaps.count, 2)
        var later = NotanCore.Picture(
            width: 64, height: 64, background: yellow, shapes: [])
        later.locked = [LockedArea(picture: earlier, node: .gap(0))]
        let image = try pixels(later)
        assertColor(color(image, SIMD2(10, 30)), .red, "the locked gap")
        assertColor(color(image, SIMD2(10, 2)), .red, "the locked gap, top")
        assertColor(color(image, SIMD2(50, 30)), yellow, "the other gap")
        assertColor(color(image, SIMD2(32, 30)), yellow, "the bar")
        XCTAssertEqual(later.hitTest(SIMD2(10, 30)), NodeID.gap(0).inLocked(0))
        XCTAssertEqual(later.hitTest(SIMD2(50, 30)), .background)

        // Enlarged, as in the window: the line where the two gaps were told apart ran
        // under the bar, and must leave no trace of the locked gap's colour there.
        let big = try XCTUnwrap(makeCGImage(later, pixelSize: CGSize(width: 256, height: 256)))
        let enlarged = TargetImage(width: 256, height: 256, pixels: rgbPixels(of: big, width: 256, height: 256))
        var worst: Float = 0
        for y in stride(from: 8, to: 248, by: 3) {
            for x in 118..<140 {  // within the bar, which spans 112..<144
                let c = enlarged.color(x: x, y: y)
                worst = max(worst, abs(c.r - yellow.r), abs(c.g - yellow.g), abs(c.b - yellow.b))
            }
        }
        XCTAssertLessThan(worst, 0.02, "a seam under the bar")
        let text = svg(later, outputSize: CGSize(width: 64, height: 64))
        XCTAssertNoThrow(try XMLDocument(xmlString: text))
        XCTAssertTrue(text.contains("<mask"))
    }

    func testRefinePlanZoomsToTheLockedShape() {
        let own = refinePlan(
            picture: treePicture(), node: .shape([0]), originalPixelSize: CGSize(width: 640, height: 640),
            workingSize: 256)
        let locked = refinePlan(
            picture: laterPicture(), node: NodeID.shape([0]).inLocked(0),
            originalPixelSize: CGSize(width: 640, height: 640), workingSize: 256)
        XCTAssertNotNil(locked)
        XCTAssertEqual(locked, own)
    }

    func testSVGMasksALockedAreaToWhatShowed() throws {
        let text = svg(laterPicture(), outputSize: CGSize(width: 640, height: 640))
        let root = try XCTUnwrap(XMLDocument(xmlString: text).rootElement())
        let masks = root.elements(forName: "mask")
        XCTAssertEqual(masks.count, 1)
        // The area's outline in white, and in black the one shape that covered it.
        XCTAssertEqual(masks[0].elements(forName: "path").count, 2)
        let groups = root.elements(forName: "g").filter { $0.attribute(forName: "mask") != nil }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].elements(forName: "path").count, 1)  // the red shape
        // The mask and the group come after the picture's own shapes.
        let names = (root.children ?? []).compactMap(\.name)
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "path")), try XCTUnwrap(names.firstIndex(of: "mask")))
        XCTAssertFalse(svg(laterPicture(), outputSize: CGSize(width: 640, height: 640), maxDepth: 0).contains("clipPath"))
    }
}
