import CoreGraphics
import Foundation

private func number(_ value: Float) -> String {
    var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

private func hex(_ color: RGB) -> String {
    func byte(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", byte(color.r), byte(color.g), byte(color.b))
}

/// The picture as an SVG document. The viewBox is the working size, so the shapes'
/// coordinates are written as fitted; width and height are the size to display at.
public func svg(_ picture: Picture, outputSize: CGSize) -> String {
    var lines: [String] = []
    lines.append(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(outputSize.width.rounded()))\" "
            + "height=\"\(Int(outputSize.height.rounded()))\" "
            + "viewBox=\"0 0 \(picture.width) \(picture.height)\">")
    lines.append(
        "<rect width=\"\(picture.width)\" height=\"\(picture.height)\" "
            + "fill=\"\(hex(picture.background))\"/>")
    for shape in picture.shapes {
        func point(_ index: Int) -> String {
            let p = shape.points[index % Shape.pointCount]
            return "\(number(p.x)) \(number(p.y))"
        }
        var d = "M\(point(0)) "
        for segment in 0..<(Shape.pointCount / 3) {
            d += "C\(point(3 * segment + 1)) \(point(3 * segment + 2)) \(point(3 * segment + 3)) "
        }
        d += "Z"
        lines.append("<path d=\"\(d)\" fill=\"\(hex(shape.color))\" fill-rule=\"evenodd\"/>")
    }
    lines.append("</svg>")
    return lines.joined(separator: "\n") + "\n"
}
