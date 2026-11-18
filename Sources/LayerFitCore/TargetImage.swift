import Foundation

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
