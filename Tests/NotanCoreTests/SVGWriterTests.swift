import XCTest
@testable import NotanCore

final class SVGWriterTests: XCTestCase {
    let picture = Picture(
        width: 256, height: 192, background: RGB(r: 0.2, g: 0.4, b: 0.6),
        shapes: [
            Shape.circle(center: SIMD2(40, 16), radius: 12, color: .red),
            Shape.circle(center: SIMD2(100, 100), radius: 30, color: RGB(r: 0, g: 0.5, b: 1)),
        ])

    func parse(_ text: String) throws -> XMLElement {
        try XCTUnwrap(XMLDocument(xmlString: text).rootElement())
    }

    func testSVGParsesWithShapeCount() throws {
        let root = try parse(svg(picture, outputSize: CGSize(width: 4000, height: 3000)))
        XCTAssertEqual(root.name, "svg")
        XCTAssertEqual(root.elements(forName: "path").count, 2)
        XCTAssertEqual(root.elements(forName: "rect").count, 1)
    }

    func testSVGDimensions() throws {
        let root = try parse(svg(picture, outputSize: CGSize(width: 4000, height: 3000)))
        XCTAssertEqual(root.attribute(forName: "width")?.stringValue, "4000")
        XCTAssertEqual(root.attribute(forName: "height")?.stringValue, "3000")
        XCTAssertEqual(root.attribute(forName: "viewBox")?.stringValue, "0 0 256 192")
    }

    func testSVGColoursAndFillRule() throws {
        let root = try parse(svg(picture, outputSize: CGSize(width: 256, height: 192)))
        XCTAssertEqual(root.elements(forName: "rect")[0].attribute(forName: "fill")?.stringValue, "#336699")
        let paths = root.elements(forName: "path")
        XCTAssertEqual(paths[0].attribute(forName: "fill")?.stringValue, "#ff0000")
        XCTAssertEqual(paths[1].attribute(forName: "fill")?.stringValue, "#0080ff")
        XCTAssertEqual(paths[0].attribute(forName: "fill-rule")?.stringValue, "nonzero")
    }

    func testSVGPathHasFourCurvesAndCloses() throws {
        let root = try parse(svg(picture, outputSize: CGSize(width: 256, height: 192)))
        let d = try XCTUnwrap(root.elements(forName: "path")[0].attribute(forName: "d")?.stringValue)
        XCTAssertTrue(d.hasPrefix("M52 16 "), d)
        XCTAssertEqual(d.filter { $0 == "C" }.count, 4)
        XCTAssertTrue(d.hasSuffix("Z"))
        // The last curve ends back at the first anchor.
        XCTAssertTrue(d.contains(" 52 16 Z"), d)
    }

    func testSVGClampsOutOfRangeColour() throws {
        var odd = picture
        odd.background = RGB(r: 1.4, g: -0.2, b: 0.5)
        let root = try parse(svg(odd, outputSize: CGSize(width: 256, height: 192)))
        XCTAssertEqual(root.elements(forName: "rect")[0].attribute(forName: "fill")?.stringValue, "#ff0080")
    }
}
