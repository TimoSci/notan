import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

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
/// A refined shape is followed by a group of its children clipped to its outline.
/// A locked area comes last, in a group masked to the part of it that showed in its own
/// picture. Refinements nested deeper than `maxDepth` are left out.
public func svg(_ picture: Picture, outputSize: CGSize, maxDepth: Int = .max) -> String {
    var lines: [String] = []
    var clipCount = 0
    var gradientCount = 0
    var maskCount = 0

    func pathData(_ shape: Shape) -> String {
        func point(_ index: Int) -> String {
            let p = shape.points[index % Shape.pointCount]
            return "\(number(p.x)) \(number(p.y))"
        }
        var d = "M\(point(0)) "
        for segment in 0..<(Shape.pointCount / 3) {
            d += "C\(point(3 * segment + 1)) \(point(3 * segment + 2)) \(point(3 * segment + 3)) "
        }
        return d + "Z"
    }

    func write(_ shapes: [Shape], depthLeft: Int) {
        for shape in shapes {
            let d = pathData(shape)
            var fill = hex(shape.color)
            if let gradient = shape.gradient {
                gradientCount += 1
                let id = "g\(gradientCount)"
                lines.append(
                    "<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" "
                        + "x1=\"\(number(gradient.from.x))\" y1=\"\(number(gradient.from.y))\" "
                        + "x2=\"\(number(gradient.to.x))\" y2=\"\(number(gradient.to.y))\">"
                        + "<stop offset=\"0\" stop-color=\"\(hex(shape.color))\"/>"
                        + "<stop offset=\"1\" stop-color=\"\(hex(gradient.endColor))\"/>"
                        + "</linearGradient>")
                fill = "url(#\(id))"
            }
            lines.append("<path d=\"\(d)\" fill=\"\(fill)\" fill-rule=\"nonzero\"/>")
            guard depthLeft > 0, let children = shape.inner?.shapes, !children.isEmpty else {
                continue
            }
            clipCount += 1
            let id = "c\(clipCount)"
            lines.append("<clipPath id=\"\(id)\"><path d=\"\(d)\" clip-rule=\"nonzero\"/></clipPath>")
            lines.append("<g clip-path=\"url(#\(id))\">")
            write(children, depthLeft: depthLeft - 1)
            lines.append("</g>")
        }
    }

    lines.append(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(outputSize.width.rounded()))\" "
            + "height=\"\(Int(outputSize.height.rounded()))\" "
            + "viewBox=\"0 0 \(picture.width) \(picture.height)\">")
    lines.append(
        "<rect width=\"\(picture.width)\" height=\"\(picture.height)\" "
            + "fill=\"\(hex(picture.background))\"/>")
    // The gaps' colours, one per picture pixel, under everything else. The shapes are
    // drawn over its blocky edges, so only whole gaps show.
    if picture.gaps.count > 1, let layer = picture.gapLayer(gapMap(of: picture)),
        let image = cgImage(rgb: layer, width: picture.width, height: picture.height),
        let png = pngData(image)
    {
        lines.append(
            "<image width=\"\(picture.width)\" height=\"\(picture.height)\" "
                + "preserveAspectRatio=\"none\" style=\"image-rendering:pixelated\" "
                + "href=\"data:image/png;base64,\(png.base64EncodedString())\"/>")
    } else if picture.gaps.count == 1, picture.gapsMatch(gapMap(of: picture)) {
        lines.append(
            "<rect width=\"\(picture.width)\" height=\"\(picture.height)\" "
                + "fill=\"\(hex(picture.gaps[0].color))\"/>")
    }
    if maxDepth > 0 {
        for gap in picture.gaps {
            write(gap.inner?.shapes ?? [], depthLeft: maxDepth - 1)
        }
    }
    write(picture.shapes, depthLeft: maxDepth)
    // Each tile is outlined in its own colour, so that neighbours overlap a little and no
    // hairline of the background shows between them. The width is in output pixels.
    let seam = Float(tileSeamWidth) * Float(picture.width) / Float(max(outputSize.width, 1))
    for tile in picture.tiles {
        let points = tile.corners.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ")
        let color = hex(tile.color)
        lines.append(
            "<polygon points=\"\(points)\" fill=\"\(color)\" stroke=\"\(color)\" "
                + "stroke-width=\"\(number(seam))\" stroke-linejoin=\"round\"/>")
    }

    let size = "width=\"\(picture.width)\" height=\"\(picture.height)\""
    for area in picture.locked {
        let source = area.picture
        maskCount += 1
        let id = "m\(maskCount)"
        let open = "<mask id=\"\(id)\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" \(size)>"
        if area.node.isBackground {
            // A gap has no outline of its own: it is what the shapes of its picture left
            // uncovered, so they are drawn in black. One gap among several is told from
            // the others by a picture with one value per pixel; its blocky edge lies
            // under those shapes.
            let map = source.gaps.isEmpty ? nil : gapMap(of: source)
            let told = map.map { source.gapsMatch($0) } ?? false
            var mask = open
            if told, let map {
                guard source.gaps.indices.contains(area.node.gap),
                    let image = grayImage(
                        map.nearestLabels.map { Int($0) == area.node.gap ? UInt8(255) : 0 },
                        width: source.width, height: source.height),
                    let png = pngData(image)
                else { continue }
                mask +=
                    "<image \(size) preserveAspectRatio=\"none\" style=\"image-rendering:pixelated\" "
                    + "href=\"data:image/png;base64,\(png.base64EncodedString())\"/>"
            } else {
                mask += "<rect \(size) fill=\"#fff\"/>"
            }
            for shape in source.shapes {
                mask += "<path d=\"\(pathData(shape))\" fill=\"#000\"/>"
            }
            lines.append(mask + "</mask>")
            let color = told ? source.gaps[area.node.gap].color : source.background
            lines.append("<g mask=\"url(#\(id))\">")
            lines.append("<rect \(size) fill=\"\(hex(color))\"/>")
            if maxDepth > 0 {
                write(source.inner(at: area.node)?.shapes ?? [], depthLeft: maxDepth - 1)
            }
            lines.append("</g>")
        } else if let root = area.node.path.first, source.shapes.indices.contains(root) {
            // White where the shape is, black where later shapes of its picture covered it.
            var mask = open + "<path d=\"\(pathData(source.shapes[root]))\" fill=\"#fff\"/>"
            for shape in source.shapes[(root + 1)...] {
                mask += "<path d=\"\(pathData(shape))\" fill=\"#000\"/>"
            }
            lines.append(mask + "</mask>")
            lines.append("<g mask=\"url(#\(id))\">")
            write([source.shapes[root]], depthLeft: maxDepth)
            lines.append("</g>")
        }
    }
    lines.append("</svg>")
    return lines.joined(separator: "\n") + "\n"
}
