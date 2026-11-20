import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image files generated on the fly into a temporary directory.
enum Fixtures {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotanTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Draws with a y-down coordinate system: (0, 0) is the top-left of the image.
    static func image(
        width: Int, height: Int, colorSpace: CFString = CGColorSpace.sRGB,
        draw: (CGContext) -> Void
    ) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: colorSpace)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()!
    }

    static func write(
        _ image: CGImage, name: String, type: UTType = .png, orientation: Int? = nil
    ) -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    static func solid(width: Int, height: Int, name: String) -> URL {
        write(
            image(width: width, height: height) { context in
                context.setFillColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }, name: name)
    }
}
