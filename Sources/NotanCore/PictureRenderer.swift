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

/// The closed outline of a tile, in the picture's own pixel coordinates.
public func outline(of tile: Tile) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: tile.corners.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
    path.closeSubpath()
    return path
}

/// Each tile is drawn grown by half this much, in output pixels: as if outlined this wide
/// in its own colour. Two antialiased fills that meet along an edge each cover only part
/// of the pixels on it, and would let what lies beneath show through as a hairline. Grown,
/// neighbours overlap by half a pixel each way, so every pixel on a shared edge is wholly
/// covered by one of the two and nothing shows through.
public let tileSeamWidth: CGFloat = 1

private func cgColor(_ color: RGB) -> CGColor {
    func unit(_ v: Float) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
    return CGColor(srgbRed: unit(color.r), green: unit(color.g), blue: unit(color.b), alpha: 1)
}

public enum RenderStyle: Equatable, Sendable {
    /// The picture in its own colours.
    case normal
    /// White where the given region is visible (not covered by anything painted over it,
    /// ignoring its own children), black everywhere else.
    case mask(of: NodeID)
    /// White wherever no shape covers the picture (every gap), black on the shapes.
    case backgroundMask
}

/// For each pixel of the picture, whether its shapes (ignoring refinements) leave it
/// uncovered: less than half covered counts as uncovered.
func uncoveredPixels(of picture: Picture) -> [Bool] {
    let width = picture.width
    let height = picture.height
    guard let context = bitmap(width: width, height: height) else {
        return [Bool](repeating: false, count: width * height)
    }
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    for shape in picture.shapes {
        context.addPath(outline(of: shape))
        context.fillPath(using: .winding)
    }
    guard let image = context.makeImage() else {
        return [Bool](repeating: false, count: width * height)
    }
    let rgb = rgbPixels(of: image, width: width, height: height)
    return (0..<(width * height)).map { rgb[$0 * 3] >= 0.5 }
}

private struct Painter {
    var style: RenderStyle
    var omittingInnerOf: NodeID?

    func color(_ own: RGB, for node: NodeID) -> CGColor {
        switch style {
        case .normal: return cgColor(own)
        case .mask(let target): return cgColor(node == target ? .init(r: 1, g: 1, b: 1) : .init(r: 0, g: 0, b: 0))
        case .backgroundMask: return cgColor(.init(r: 0, g: 0, b: 0))
        }
    }

    /// Whether a region's children are drawn.
    func descends(into node: NodeID) -> Bool {
        if node == omittingInnerOf { return false }
        switch style {
        case .normal: return true
        // Children lie inside their parent, so for a mask only the target's ancestors matter.
        case .mask(let target): return node != target && node.contains(target)
        case .backgroundMask: return false
        }
    }

    /// Draws one colour per picture pixel, enlarged without smoothing. Its blocky edges
    /// never show: they lie under the shapes, which are drawn over it as vectors.
    private func paintLayer(_ rgb: [Float], of picture: Picture, in context: CGContext) {
        guard let image = cgImage(rgb: rgb, width: picture.width, height: picture.height) else {
            return
        }
        context.saveGState()
        context.interpolationQuality = .none
        // Images draw bottom-up; the context is top-down.
        context.translateBy(x: 0, y: CGFloat(picture.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        context.restoreGState()
    }

    /// What lies under the shapes: the gaps in their own colours, or for a mask, white
    /// where the masked gap is.
    private func paintGround(_ picture: Picture, in context: CGContext) {
        let frame = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        switch style {
        case .backgroundMask:
            context.setFillColor(white)
            context.fill(frame)
        case .normal:
            context.setFillColor(cgColor(picture.background))
            context.fill(frame)
            guard !picture.gaps.isEmpty else { return }
            let map = gapMap(of: picture)
            if let layer = picture.gapLayer(map) { paintLayer(layer, of: picture, in: context) }
        case .mask(let target):
            context.setFillColor(black)
            context.fill(frame)
            guard target.isBackground else { return }
            let map = picture.gaps.isEmpty ? nil : gapMap(of: picture)
            guard let map, picture.gapsMatch(map) else {
                // Gaps not told apart: the whole uncovered area is gap 0.
                if target.gap == 0 {
                    context.setFillColor(white)
                    context.fill(frame)
                }
                return
            }
            var layer = [Float](repeating: 0, count: picture.width * picture.height * 3)
            for (i, label) in map.nearestLabels.enumerated() where Int(label) == target.gap {
                layer[i * 3] = 1
                layer[i * 3 + 1] = 1
                layer[i * 3 + 2] = 1
            }
            paintLayer(layer, of: picture, in: context)
        }
    }

    func paint(_ picture: Picture, in context: CGContext, maxDepth: Int) {
        context.setShouldAntialias(true)
        paintGround(picture, in: context)
        if maxDepth > 0 {
            for (index, gap) in picture.gaps.enumerated() {
                guard descends(into: .gap(index)), let children = gap.inner?.shapes else { continue }
                paint(children, parent: .gap(index), in: context, depthLeft: maxDepth - 1)
            }
        }
        for (index, shape) in picture.shapes.enumerated() {
            paint(shape, node: .shape([index]), in: context, depthLeft: maxDepth)
        }
        paint(picture.tiles, in: context)
        for (index, area) in picture.locked.enumerated() {
            paint(area, number: index, in: context, maxDepth: maxDepth)
        }
    }

    private func paint(_ tiles: [Tile], in context: CGContext) {
        guard !tiles.isEmpty else { return }
        // The outline's width is given in output pixels; the context is scaled to the picture's.
        let matrix = context.ctm
        let scale = max(hypot(matrix.a, matrix.b), hypot(matrix.c, matrix.d), 1e-6)
        for tile in tiles {
            // Tile and outline as one area, filled once. Filling and then stroking would
            // be two antialiased layers, and a little would still show through between them.
            let path = outline(of: tile)
            let band = path.copy(
                strokingWithWidth: tileSeamWidth / scale, lineCap: .butt, lineJoin: .round,
                miterLimit: 1)
            context.setFillColor(color(tile.color, for: .tile(tile.path)))
            context.addPath(path.union(band, using: .winding))
            context.fillPath(using: .winding)
        }
    }

    /// Paints a locked area over what is there: the part of its region that showed in its
    /// own picture, and nothing else.
    private func paint(_ area: LockedArea, number: Int, in context: CGContext, maxDepth: Int) {
        // Within the area, nodes are named as in its own picture.
        let nowhere = NodeID.shape([-1])
        let inside: Painter
        switch style {
        case .normal:
            inside = Painter(style: .normal, omittingInnerOf: nil)
        case .mask(let target):
            // For a mask the area is black, hiding what is under it, unless the target
            // lies in it.
            inside = Painter(
                style: .mask(of: target.locked == number ? target.inLocked(nil) : nowhere),
                omittingInnerOf: nil)
        case .backgroundMask:
            inside = Painter(style: .mask(of: nowhere), omittingInnerOf: nil)
        }
        var painter = inside
        if let omitted = omittingInnerOf, omitted.locked == number {
            painter.omittingInnerOf = omitted.inLocked(nil)
        }

        let source = area.picture
        let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let covering: ArraySlice<Shape>
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if area.node.isBackground {
            // One gap among several is told from the others pixel by pixel; the blocky
            // edge of that lies under the shapes, which are cut out again below.
            let map = source.gaps.isEmpty ? nil : gapMap(of: source)
            var color = source.background
            // The clip to the gap's pixels ends before the shapes are cut out. Enlarged,
            // its edge is soft, and a cut made through the same soft edge would leave a
            // faint line of the gap's colour along it.
            context.saveGState()
            if let map, source.gapsMatch(map) {
                guard source.gaps.indices.contains(area.node.gap),
                    let mask = grayImage(
                        map.nearestLabels.map { Int($0) == area.node.gap ? UInt8(255) : 0 },
                        width: source.width, height: source.height)
                else {
                    context.restoreGState()
                    context.endTransparencyLayer()
                    context.restoreGState()
                    return
                }
                color = source.gaps[area.node.gap].color
                // Images, and so masks, are bottom-up; flipping twice leaves the
                // coordinates as they were and the clip in place.
                context.translateBy(x: 0, y: frame.height)
                context.scaleBy(x: 1, y: -1)
                context.clip(to: frame, mask: mask)
                context.translateBy(x: 0, y: frame.height)
                context.scaleBy(x: 1, y: -1)
            }
            context.setFillColor(painter.color(color, for: area.node))
            context.fill(frame)
            if maxDepth > 0, painter.descends(into: area.node),
                let children = source.inner(at: area.node)?.shapes
            {
                painter.paint(children, parent: area.node, in: context, depthLeft: maxDepth - 1)
            }
            context.restoreGState()
            covering = source.shapes[...]
        } else if let root = area.node.path.first, source.shapes.indices.contains(root) {
            painter.paint(source.shapes[root], node: .shape([root]), in: context, depthLeft: maxDepth)
            covering = source.shapes[(root + 1)...]
        } else {
            covering = []
        }
        // Cut out what covered the region in its own picture.
        context.setBlendMode(.destinationOut)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for shape in covering {
            context.addPath(outline(of: shape))
            context.fillPath(using: .winding)
        }
        context.setBlendMode(.normal)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    fileprivate func paint(_ shapes: [Shape], parent: NodeID, in context: CGContext, depthLeft: Int) {
        for (index, shape) in shapes.enumerated() {
            paint(shape, node: parent.child(index), in: context, depthLeft: depthLeft)
        }
    }

    fileprivate func paint(_ shape: Shape, node: NodeID, in context: CGContext, depthLeft: Int) {
        let path = outline(of: shape)
        if case .normal = style, let gradient = shape.gradient,
            let ramp = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [cgColor(shape.color), cgColor(gradient.endColor)] as CFArray,
                locations: [0, 1])
        {
            context.saveGState()
            context.addPath(path)
            context.clip(using: .winding)
            context.drawLinearGradient(
                ramp, start: CGPoint(x: CGFloat(gradient.from.x), y: CGFloat(gradient.from.y)),
                end: CGPoint(x: CGFloat(gradient.to.x), y: CGFloat(gradient.to.y)),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        } else {
            context.setFillColor(color(shape.color, for: node))
            context.addPath(path)
            context.fillPath(using: .winding)
        }
        guard depthLeft > 0, descends(into: node), let children = shape.inner?.shapes,
            !children.isEmpty
        else { return }
        context.saveGState()
        context.addPath(path)
        context.clip(using: .winding)
        paint(children, parent: node, in: context, depthLeft: depthLeft - 1)
        context.restoreGState()
    }
}

/// Draws the picture as hard-edged, antialiased vectors filling `size`. The context must
/// have a y-down coordinate system with (0, 0) at the top-left of the destination.
/// Refinements nested deeper than `maxDepth` are left out.
public func draw(_ picture: Picture, in context: CGContext, size: CGSize, maxDepth: Int = .max) {
    drawRegion(
        picture, region: CGRect(x: 0, y: 0, width: picture.width, height: picture.height),
        in: context, size: size, maxDepth: maxDepth, omittingInnerOf: nil, style: .normal)
}

/// Draws the part of the picture inside `region` (in picture coordinates) so that it fills
/// `size` in a y-down context.
private func drawRegion(
    _ picture: Picture, region: CGRect, in context: CGContext, size: CGSize, maxDepth: Int,
    omittingInnerOf: NodeID?, style: RenderStyle
) {
    guard region.width > 0, region.height > 0 else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: CGRect(origin: .zero, size: size))
    context.scaleBy(x: size.width / region.width, y: size.height / region.height)
    context.translateBy(x: -region.minX, y: -region.minY)
    Painter(style: style, omittingInnerOf: omittingInnerOf)
        .paint(picture, in: context, maxDepth: maxDepth)
}

/// A greyscale image from one byte per pixel, top row first.
func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard bytes.count == width * height, let provider = CGDataProvider(data: Data(bytes) as CFData)
    else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

private func bitmap(width: Int, height: Int) -> CGContext? {
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    return context
}

public func makeCGImage(
    _ picture: Picture, pixelSize: CGSize, maxDepth: Int = .max, dimmingAllBut selected: [Tile] = []
) -> CGImage? {
    let width = max(1, Int(pixelSize.width.rounded()))
    let height = max(1, Int(pixelSize.height.rounded()))
    guard let context = bitmap(width: width, height: height) else { return nil }
    let size = CGSize(width: width, height: height)
    draw(picture, in: context, size: size, maxDepth: maxDepth)
    dim(picture, allBut: selected, in: context, size: size)
    return context.makeImage()
}

/// The outline of the area a group of tiles covers between them, as one polygon with its
/// corners in the order of a sound tile. Nil if they do not form one piece without holes.
/// One tile's outline is its own; a group's is a hundredth of a pixel outside the tiles,
/// which are grown by that much so that they join.
public func groupOutline(_ tiles: [Tile]) -> [SIMD2<Float>]? {
    guard let first = tiles.first else { return nil }
    if tiles.count == 1 { return first.corners }
    var joined: CGPath = CGMutablePath()
    for tile in tiles {
        let grown = Tile(corners: grownPolygon(tile.corners, by: 0.01), color: tile.color, path: tile.path)
        joined = joined.union(outline(of: grown), using: .winding)
    }
    var rings: [[SIMD2<Float>]] = []
    var straight = true
    joined.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: rings.append([SIMD2(Float(points[0].x), Float(points[0].y))])
        case .addLineToPoint:
            rings[rings.count - 1].append(SIMD2(Float(points[0].x), Float(points[0].y)))
        case .closeSubpath: break
        default: straight = false
        }
    }
    guard straight, rings.count == 1 else { return nil }
    // Drop a point that repeats the one before it (the ring closes on its first point).
    var ring: [SIMD2<Float>] = []
    for point in rings[0] {
        if let last = ring.last, abs(last.x - point.x) < 1e-4, abs(last.y - point.y) < 1e-4 { continue }
        ring.append(point)
    }
    if let start = ring.first, let last = ring.last, ring.count > 1,
        abs(last.x - start.x) < 1e-4, abs(last.y - start.y) < 1e-4
    {
        ring.removeLast()
    }
    guard ring.count >= 3 else { return nil }
    if polygonArea(ring) < 0 { ring.reverse() }
    return isSimplePolygon(ring) ? ring : nil
}

/// How dark the rest of the picture is made when tiles are selected: the share of black.
public let selectionDimming: CGFloat = 0.45

/// Shows which tiles are selected by darkening the rest of a picture drawn to fill `size`
/// (see `draw`) and drawing a line round them. A tile cut into pieces is a group: the
/// line goes round the group, not between its pieces. Nothing is drawn when no tile is
/// given.
public func dim(_ picture: Picture, allBut tiles: [Tile], in context: CGContext, size: CGSize) {
    guard !tiles.isEmpty else { return }
    var transform = CGAffineTransform(
        scaleX: size.width / CGFloat(picture.width), y: size.height / CGFloat(picture.height))
    // The tiles as one area, so that the lines between neighbouring ones do not show;
    // then everything but that area.
    var kept: CGPath = CGMutablePath()
    for tile in tiles {
        // Grown by a hair, so that pieces sharing an edge overlap and join without a slit.
        let grown = Tile(corners: grownPolygon(tile.corners, by: 0.02), color: tile.color, path: tile.path)
        if let scaled = outline(of: grown).copy(using: &transform) {
            kept = kept.union(scaled, using: .winding)
        }
    }
    let rest = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        .subtracting(kept, using: .winding)
    context.saveGState()
    context.setFillColor(CGColor(gray: 0, alpha: selectionDimming))
    context.addPath(rest)
    context.fillPath(using: .winding)
    // And a line round the area, dark under light so that it shows on any colour: a dark
    // tile among dark ones is otherwise hard to tell from its dimmed neighbours.
    context.clip(to: CGRect(origin: .zero, size: size))
    context.setLineJoin(.round)
    for (width, color) in [(4.0, CGColor(gray: 0, alpha: 0.85)), (1.5, CGColor(gray: 1, alpha: 1))] {
        context.setLineWidth(width)
        context.setStrokeColor(color)
        context.addPath(kept)
        context.strokePath()
    }
    context.restoreGState()
}

/// How far the picture, drawn hard-edged, is from the target: the squared difference
/// averaged over every channel of every pixel, as `plainMSE` gives.
///
/// The picture is drawn at several times the target's size and averaged down, so that
/// what is measured is the shapes themselves. Drawn at the target's own size, the half
/// pixel by which tiles are grown to hide their seams would count as error. With
/// `counting`, one flag per target pixel, only the flagged pixels are measured.
public func measuredMSE(
    _ picture: Picture, against target: TargetImage, counting counted: [Bool]? = nil
) -> Float {
    let factor = 4
    let width = target.width * factor
    let drawn = renderRegion(
        picture, region: CGRect(x: 0, y: 0, width: picture.width, height: picture.height),
        width: width, height: target.height * factor)
    var sum: Double = 0
    var pixels = 0
    for y in 0..<target.height {
        for x in 0..<target.width {
            if let counted, !counted[y * target.width + x] { continue }
            pixels += 1
            for channel in 0..<3 {
                var mean: Float = 0
                for dy in 0..<factor {
                    let row = ((y * factor + dy) * width + x * factor) * 3 + channel
                    for dx in 0..<factor { mean += drawn[row + dx * 3] }
                }
                let difference = Double(
                    mean / Float(factor * factor) - target.pixels[(y * target.width + x) * 3 + channel])
                sum += difference * difference
            }
        }
    }
    return Float(sum / Double(max(pixels * 3, 1)))
}

/// The part of the picture inside `region` (picture coordinates), drawn at width × height
/// pixels: row-major RGB 0…1, top row first. Used to zoom into one region for refining.
public func renderRegion(
    _ picture: Picture, region: CGRect, width: Int, height: Int, maxDepth: Int = .max,
    omittingInnerOf: NodeID? = nil, style: RenderStyle = .normal
) -> [Float] {
    guard let context = bitmap(width: width, height: height) else {
        return [Float](repeating: 0, count: width * height * 3)
    }
    drawRegion(
        picture, region: region, in: context, size: CGSize(width: width, height: height),
        maxDepth: maxDepth, omittingInnerOf: omittingInnerOf, style: style)
    guard let image = context.makeImage() else {
        return [Float](repeating: 0, count: width * height * 3)
    }
    return rgbPixels(of: image, width: width, height: height)
}

/// A greyscale image, `scale` times the picture's size, that is white where a region is
/// visible: for highlighting a selection that has no outline of its own, such as a gap.
public func maskImage(_ picture: Picture, node: NodeID, scale: Int = 2) -> CGImage? {
    let width = picture.width * max(scale, 1)
    let height = picture.height * max(scale, 1)
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    drawRegion(
        picture, region: CGRect(x: 0, y: 0, width: picture.width, height: picture.height),
        in: context, size: CGSize(width: width, height: height), maxDepth: .max,
        omittingInnerOf: nil, style: .mask(of: node))
    return context.makeImage()
}

extension Picture {
    /// The region under a point (picture coordinates): the deepest shown shape there, the
    /// background if no shape is, or nil outside the picture. Shapes nested deeper than
    /// `maxDepth` are not considered.
    public func hitTest(_ point: SIMD2<Float>, maxDepth: Int = .max) -> NodeID? {
        guard point.x >= 0, point.y >= 0, point.x < Float(width), point.y < Float(height) else {
            return nil
        }
        // Locked areas are painted last, so they are found first: a point is in one if,
        // in the area's own picture, what shows there belongs to the locked region.
        for index in locked.indices.reversed() {
            let area = locked[index]
            if let hit = area.picture.hitTest(point, maxDepth: maxDepth), area.node.contains(hit) {
                return hit.inLocked(index)
            }
        }
        let location = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        if !tiles.isEmpty {
            if let tile = tiles.first(where: { outline(of: $0).contains(location, using: .winding) }) {
                return .tile(tile.path)
            }
            // On an edge, by rounding, in no tile: the tile whose middle is nearest.
            func distance(_ tile: Tile) -> Float {
                let middle = tile.corners.reduce(SIMD2<Float>(0, 0), +) / Float(max(tile.corners.count, 1))
                return ((middle - point) * (middle - point)).sum()
            }
            return tiles.min { distance($0) < distance($1) }.map { .tile($0.path) }
        }
        func find(in list: [Shape], parent: NodeID?, depthLeft: Int) -> NodeID? {
            for index in list.indices.reversed() {
                let shape = list[index]
                guard outline(of: shape).contains(location, using: .winding) else { continue }
                let node = parent?.child(index) ?? .shape([index])
                if depthLeft > 0, let children = shape.inner?.shapes,
                    let deeper = find(in: children, parent: node, depthLeft: depthLeft - 1)
                {
                    return deeper
                }
                return node
            }
            return nil
        }
        if let hit = find(in: shapes, parent: nil, depthLeft: maxDepth) { return hit }
        if maxDepth > 0 {
            // Shapes fitted inside gaps lie under the picture's own shapes.
            for index in gaps.indices.reversed() {
                if let children = gaps[index].inner?.shapes,
                    let hit = find(in: children, parent: .gap(index), depthLeft: maxDepth - 1)
                {
                    return hit
                }
            }
        }
        guard !gaps.isEmpty else { return .background }
        let map = gapMap(of: self)
        guard gapsMatch(map) else { return .background }
        let label = map.nearest(x: Int(point.x), y: Int(point.y))
        return label >= 0 ? .gap(label) : .background
    }
}

public enum RenderError: Error, LocalizedError {
    case cannotWrite(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotWrite(let url): return "Could not write “\(url.lastPathComponent)”."
        }
    }
}

public func writePNG(
    _ picture: Picture, pixelSize: CGSize, to url: URL, maxDepth: Int = .max
) throws {
    guard let image = makeCGImage(picture, pixelSize: pixelSize, maxDepth: maxDepth),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw RenderError.cannotWrite(url) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotWrite(url) }
}
