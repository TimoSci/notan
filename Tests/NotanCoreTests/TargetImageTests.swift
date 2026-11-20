import CoreGraphics
import XCTest
@testable import NotanCore

final class TargetImageTests: XCTestCase {
    func testDownscalesLongSide() throws {
        let photo = try loadPhoto(url: Fixtures.solid(width: 1000, height: 500, name: "wide.png"), workingSize: 256)
        XCTAssertEqual(photo.target.width, 256)
        XCTAssertEqual(photo.target.height, 128)
        XCTAssertEqual(photo.originalPixelSize, CGSize(width: 1000, height: 500))
        XCTAssertGreaterThan(photo.fileBytes, 0)
        let c = photo.target.color(x: 100, y: 60)
        XCTAssertEqual(c.r, 0.2, accuracy: 0.01)
        XCTAssertEqual(c.g, 0.6, accuracy: 0.01)
        XCTAssertEqual(c.b, 0.4, accuracy: 0.01)
    }

    func testDoesNotUpscale() throws {
        let photo = try loadPhoto(url: Fixtures.solid(width: 40, height: 30, name: "small.png"), workingSize: 256)
        XCTAssertEqual(photo.target.width, 40)
        XCTAssertEqual(photo.target.height, 30)
    }

    func testOnePixelWide() throws {
        let photo = try loadPhoto(url: Fixtures.solid(width: 1, height: 300, name: "thin.png"), workingSize: 256)
        XCTAssertEqual(photo.target.width, 1)
        XCTAssertEqual(photo.target.height, 256)
    }

    func testRowsAreTopFirst() throws {
        let image = Fixtures.image(width: 100, height: 100) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))  // top half
        }
        let photo = try loadPhoto(url: Fixtures.write(image, name: "topred.png"), workingSize: 256)
        XCTAssertGreaterThan(photo.target.color(x: 50, y: 10).r, 0.9)
        XCTAssertGreaterThan(photo.target.color(x: 50, y: 90).b, 0.9)
    }

    func testAppliesExifOrientation() throws {
        // Stored 200×100 with the left half red; orientation 6 means the stored left edge
        // is the visual top, so the upright picture is 100×200 with its top half red.
        let image = Fixtures.image(width: 200, height: 100) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let url = Fixtures.write(image, name: "rotated.jpg", type: .jpeg, orientation: 6)
        let photo = try loadPhoto(url: url, workingSize: 256)
        XCTAssertEqual(photo.target.width, 100)
        XCTAssertEqual(photo.target.height, 200)
        XCTAssertEqual(photo.originalPixelSize, CGSize(width: 100, height: 200))
        XCTAssertGreaterThan(photo.target.color(x: 50, y: 40).r, 0.8)
        XCTAssertLessThan(photo.target.color(x: 50, y: 40).b, 0.2)
        XCTAssertGreaterThan(photo.target.color(x: 50, y: 160).b, 0.8)
    }

    func testConvertsDisplayP3ToSRGB() throws {
        // sRGB pure red, written as its Display P3 coordinates. Read back it must be
        // (1, 0, 0) again; left unconverted the green channel would be 0.2.
        let image = Fixtures.image(width: 20, height: 20, colorSpace: CGColorSpace.displayP3) { context in
            // The colour must be given in P3 explicitly; a bare RGB fill is taken as sRGB.
            context.setFillColor(
                CGColor(
                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                    components: [0.9175, 0.2003, 0.1387, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let photo = try loadPhoto(url: Fixtures.write(image, name: "p3.png"), workingSize: 256)
        let c = photo.target.color(x: 10, y: 10)
        XCTAssertEqual(c.r, 1, accuracy: 0.03)
        XCTAssertEqual(c.g, 0, accuracy: 0.03)
        XCTAssertEqual(c.b, 0, accuracy: 0.03)
    }

    func testAlphaCompositesOverWhite() throws {
        let image = Fixtures.image(width: 20, height: 20) { _ in }  // fully transparent
        let photo = try loadPhoto(url: Fixtures.write(image, name: "clear.png"), workingSize: 256)
        XCTAssertTrue(photo.target.pixels.allSatisfy { $0 == 1 })
    }

    func testUnreadableFileThrows() throws {
        let url = Fixtures.directory.appendingPathComponent("notes.jpg")
        try Data("this is not an image".utf8).write(to: url)
        XCTAssertThrowsError(try loadPhoto(url: url, workingSize: 256)) { error in
            guard case PhotoError.unreadable(let failed) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failed, url)
            XCTAssertTrue(error.localizedDescription.contains("notes.jpg"))
        }
    }

    func testPreviewIsUprightAndBounded() throws {
        let image = Fixtures.image(width: 200, height: 100) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let url = Fixtures.write(image, name: "preview.jpg", type: .jpeg, orientation: 6)
        let preview = try XCTUnwrap(loadPreview(url: url, maxPixelSize: 80))
        XCTAssertEqual(preview.width, 40)
        XCTAssertEqual(preview.height, 80)
    }

    func testPreviewOfUnreadableFileIsNil() throws {
        let url = Fixtures.directory.appendingPathComponent("junk.png")
        try Data("nope".utf8).write(to: url)
        XCTAssertNil(loadPreview(url: url, maxPixelSize: 80))
    }

    func testMissingFileThrows() {
        let url = Fixtures.directory.appendingPathComponent("nope.png")
        XCTAssertThrowsError(try loadPhoto(url: url, workingSize: 256))
    }
}
