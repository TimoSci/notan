import CoreGraphics
import Foundation
import ImageIO

/// The picture being fitted, at working resolution.
public struct TargetImage: Sendable {
    public var width: Int
    public var height: Int
    /// Row-major RGB, sRGB 0…1; count == width * height * 3.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width >= 1 && height >= 1 && pixels.count == width * height * 3)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func color(x: Int, y: Int) -> RGB {
        let i = (y * width + x) * 3
        return RGB(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
    }

    public var meanColor: RGB {
        var sum = [Double](repeating: 0, count: 3)
        for (i, value) in pixels.enumerated() { sum[i % 3] += Double(value) }
        let n = Double(width * height)
        return RGB(r: Float(sum[0] / n), g: Float(sum[1] / n), b: Float(sum[2] / n))
    }
}

public struct LoadedPhoto: Sendable {
    public var target: TargetImage
    /// Pixel size of the photo as displayed, after its orientation is applied.
    public var originalPixelSize: CGSize
    public var fileBytes: Int

    public init(target: TargetImage, originalPixelSize: CGSize, fileBytes: Int) {
        self.target = target
        self.originalPixelSize = originalPixelSize
        self.fileBytes = fileBytes
    }
}

public enum PhotoError: Error, LocalizedError {
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "“\(url.lastPathComponent)” could not be read as an image."
        }
    }
}

/// Loads a photo upright, in sRGB, over white, with its long side scaled down to
/// `workingSize`. Never scales up; each side is at least 1 pixel.
public func loadPhoto(url: URL, workingSize: Int) throws -> LoadedPhoto {
    precondition(workingSize >= 1)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let storedWidth = properties[kCGImagePropertyPixelWidth] as? Int,
        let storedHeight = properties[kCGImagePropertyPixelHeight] as? Int,
        storedWidth >= 1, storedHeight >= 1
    else { throw PhotoError.unreadable(url) }

    // Orientations 5…8 are rotated a quarter turn: displayed width and height swap.
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let turned = (5...8).contains(orientation)
    let fullWidth = turned ? storedHeight : storedWidth
    let fullHeight = turned ? storedWidth : storedHeight
    let longSide = max(fullWidth, fullHeight)

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(workingSize, longSide),
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { throw PhotoError.unreadable(url) }

    let scale = min(1, Double(workingSize) / Double(longSide))
    let width = max(1, Int((Double(fullWidth) * scale).rounded()))
    let height = max(1, Int((Double(fullHeight) * scale).rounded()))
    let pixels = rgbPixels(of: image, width: width, height: height)

    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let fileBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    return LoadedPhoto(
        target: TargetImage(width: width, height: height, pixels: pixels),
        originalPixelSize: CGSize(width: fullWidth, height: fullHeight), fileBytes: fileBytes)
}

/// The image resampled to width × height as sRGB 0…1 over white: row-major RGB, top row first.
func rgbPixels(of image: CGImage, width: Int, height: Int) -> [Float] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        guard
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }
    var pixels = [Float](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) {
        pixels[i * 3] = Float(bytes[i * 4]) / 255
        pixels[i * 3 + 1] = Float(bytes[i * 4 + 1]) / 255
        pixels[i * 3 + 2] = Float(bytes[i * 4 + 2]) / 255
    }
    return pixels
}

/// The photo upright, with its long side at most `maxPixelSize`, for showing next to the
/// fitted picture. Nil if the file cannot be read as an image.
public func loadPreview(url: URL, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
