import CoreGraphics
import MLX
import XCTest
@testable import LayerFitCore

final class PictureRendererTests: XCTestCase {
    let picture = Picture(
        width: 64, height: 48, background: .white,
        shapes: [Shape.circle(center: SIMD2(40, 16), radius: 12, color: .red)])

    func testRenderIsHardEdged() throws {
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: 256, height: 192)))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 192)
        let pixels = rgbPixels(of: image, width: 256, height: 192)
        var mixed = 0
        var red = 0
        for i in 0..<(256 * 192) {
            let (r, g, b) = (pixels[i * 3], pixels[i * 3 + 1], pixels[i * 3 + 2])
            if r > 0.99 && g < 0.01 && b < 0.01 {
                red += 1
            } else if !(r > 0.99 && g > 0.99 && b > 0.99) {
                mixed += 1
            }
        }
        XCTAssertLessThan(Double(mixed) / Double(256 * 192), 0.03)
        let expected = Double.pi * 48 * 48
        XCTAssertEqual(Double(red), expected, accuracy: expected * 0.05)
    }

    func testRenderIsUpright() throws {
        // The circle is in the top-right of the picture.
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: 64, height: 48)))
        let target = TargetImage(width: 64, height: 48, pixels: rgbPixels(of: image, width: 64, height: 48))
        XCTAssertEqual(target.color(x: 40, y: 16), .red)
        XCTAssertEqual(target.color(x: 40, y: 40), .white)
        XCTAssertEqual(target.color(x: 10, y: 16), .white)
    }

    func testRenderMatchesSoftRaster() throws {
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: 64, height: 48)))
        let hard = MLXArray(rgbPixels(of: image, width: 64, height: 48), [48, 64, 3])
        let soft = Rasterizer(width: 64, height: 48, softness: 0.25).render(
            points: pointsArray(picture.shapes), colors: colorsArray(picture.shapes),
            background: colorArray(picture.background)
        ).image
        XCTAssertLessThan(abs(hard - soft).mean().item(Float.self), 0.02)
    }

    func testWritePNGRoundTrips() throws {
        let url = Fixtures.directory.appendingPathComponent("picture.png")
        try writePNG(picture, pixelSize: CGSize(width: 128, height: 96), to: url)
        let photo = try loadPhoto(url: url, workingSize: 256)
        XCTAssertEqual(photo.target.width, 128)
        XCTAssertEqual(photo.target.height, 96)
        XCTAssertEqual(photo.target.color(x: 80, y: 32), .red)
    }
}
