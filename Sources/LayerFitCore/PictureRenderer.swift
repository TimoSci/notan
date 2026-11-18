import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The closed outline of a shape, in the picture's own pixel coordinates.
public func outline(of shape: Shape) -> CGPath {
    let path = CGMutablePath()
    func point(_ index: Int) -> CGPoint {
        let p = shape.points[index % Shape.pointCount]
        return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }
    path.move(to: point(0))
    for segment in 0..<(Shape.pointCount / 3) {
        path.addCurve(
            to: point(3 * segment + 3), control1: point(3 * segment + 1),
            control2: point(3 * segment + 2))
    }
    path.closeSubpath()
    return path
}

private func cgColor(_ color: RGB) -> CGColor {
    func unit(_ v: Float) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
    return CGColor(srgbRed: unit(color.r), green: unit(color.g), blue: unit(color.b), alpha: 1)
}

/// Draws the picture as hard-edged, antialiased vectors filling `size`. The context must
/// have a y-down coordinate system with (0, 0) at the top-left of the destination.
public func draw(_ picture: Picture, in context: CGContext, size: CGSize) {
    context.saveGState()
    defer { context.restoreGState() }
    context.setShouldAntialias(true)
    context.setFillColor(cgColor(picture.background))
    context.fill(CGRect(origin: .zero, size: size))
    context.clip(to: CGRect(origin: .zero, size: size))
    context.scaleBy(
        x: size.width / CGFloat(picture.width), y: size.height / CGFloat(picture.height))
    for shape in picture.shapes {
        context.setFillColor(cgColor(shape.color))
        context.addPath(outline(of: shape))
        context.fillPath(using: .evenOdd)
    }
}

public func makeCGImage(_ picture: Picture, pixelSize: CGSize) -> CGImage? {
    let width = max(1, Int(pixelSize.width.rounded()))
    let height = max(1, Int(pixelSize.height.rounded()))
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    draw(picture, in: context, size: CGSize(width: width, height: height))
    return context.makeImage()
}

public enum RenderError: Error, LocalizedError {
    case cannotWrite(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotWrite(let url): return "Could not write “\(url.lastPathComponent)”."
        }
    }
}

public func writePNG(_ picture: Picture, pixelSize: CGSize, to url: URL) throws {
    guard let image = makeCGImage(picture, pixelSize: pixelSize),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw RenderError.cannotWrite(url) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotWrite(url) }
}
