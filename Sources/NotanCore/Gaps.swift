import CoreGraphics
import Foundation

// Gaps: the patches of a picture that no shape covers. Each connected patch is a region of
// its own, with its own colour. A gap has no outline: its edge is whatever its neighbours
// leave, so it can be recomputed from the shapes and costs only a colour to store.

/// Which gap each pixel of a picture belongs to.
public struct GapMap: Sendable {
    public let width: Int
    public let height: Int
    /// Per pixel, row-major: the gap's number, or -1 where a shape covers the pixel (or
    /// the patch is too small to count).
    public let labels: [Int32]
    /// Per pixel: the number of the nearest gap. Under a shape's edge this is the gap that
    /// shows beside it. -1 everywhere when there are no gaps.
    public let nearestLabels: [Int32]
    /// Pixels in each gap.
    public let areas: [Int]

    /// Patches smaller than this many pixels are not gaps; they take a neighbour's colour.
    public static let minimumArea = 4

    public var count: Int { areas.count }

    public func label(x: Int, y: Int) -> Int { Int(labels[y * width + x]) }

    public func nearest(x: Int, y: Int) -> Int { Int(nearestLabels[y * width + x]) }

    /// The smallest pixel rectangle containing a gap.
    public func box(of gap: Int) -> CGRect? {
        guard (0..<count).contains(gap) else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where labels[y * width + x] == Int32(gap) {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Finds the gaps of a picture at its own resolution: the 4-connected patches of pixels
/// that its shapes (ignoring any refinements) leave uncovered. Gaps are numbered in
/// reading order of their first pixel, so the numbering can be recomputed from the shapes.
public func gapMap(of picture: Picture) -> GapMap {
    let width = picture.width
    let height = picture.height
    let uncovered = uncoveredPixels(of: picture)

    var labels = [Int32](repeating: -1, count: width * height)
    var areas: [Int] = []
    var visited = [Bool](repeating: false, count: width * height)
    var stack: [Int] = []
    for start in 0..<(width * height) where uncovered[start] && !visited[start] {
        var members: [Int] = []
        visited[start] = true
        stack.append(start)
        while let i = stack.popLast() {
            members.append(i)
            let x = i % width
            let y = i / width
            for j in [x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1, y > 0 ? i - width : -1, y < height - 1 ? i + width : -1]
            where j >= 0 && uncovered[j] && !visited[j] {
                visited[j] = true
                stack.append(j)
            }
        }
        guard members.count >= GapMap.minimumArea else { continue }
        for i in members { labels[i] = Int32(areas.count) }
        areas.append(members.count)
    }

    // Spread each gap's number outward, breadth first, to label covered pixels by the
    // nearest gap.
    var nearest = labels
    var frontier = (0..<(width * height)).filter { labels[$0] >= 0 }
    while !frontier.isEmpty {
        var next: [Int] = []
        for i in frontier {
            let x = i % width
            let y = i / width
            for j in [x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1, y > 0 ? i - width : -1, y < height - 1 ? i + width : -1]
            where j >= 0 && nearest[j] < 0 {
                nearest[j] = nearest[i]
                next.append(j)
            }
        }
        frontier = next
    }
    return GapMap(width: width, height: height, labels: labels, nearestLabels: nearest, areas: areas)
}

extension Picture {
    /// True when `gaps` matches the patches the shapes actually leave, so each gap can be
    /// drawn and selected on its own.
    public func gapsMatch(_ map: GapMap) -> Bool { !gaps.isEmpty && gaps.count == map.count }

    /// Replaces `gaps` with the picture's current gaps, each in the mean colour of the
    /// target under it. The target must be the picture's size. Refinements of earlier
    /// gaps are dropped: they belonged to patches that may no longer exist.
    public mutating func assignGaps(from target: TargetImage) {
        precondition(target.width == width && target.height == height)
        let map = gapMap(of: self)
        var sums = [SIMD3<Double>](repeating: .zero, count: map.count)
        for (i, label) in map.labels.enumerated() where label >= 0 {
            sums[Int(label)] += SIMD3(
                Double(target.pixels[i * 3]), Double(target.pixels[i * 3 + 1]),
                Double(target.pixels[i * 3 + 2]))
        }
        gaps = sums.enumerated().map { index, sum in
            let mean = sum / Double(map.areas[index])
            return Gap(color: RGB(r: Float(mean.x), g: Float(mean.y), b: Float(mean.z)))
        }
    }

    /// The gaps' colours as one colour per pixel (row-major RGB 0…1), with covered pixels
    /// in the colour of the nearest gap: what lies underneath the shapes. Nil when the
    /// gaps are not told apart.
    public func gapLayer(_ map: GapMap) -> [Float]? {
        guard gapsMatch(map) else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for (i, label) in map.nearestLabels.enumerated() {
            let color = label >= 0 ? gaps[Int(label)].color : background
            pixels[i * 3] = color.r
            pixels[i * 3 + 1] = color.g
            pixels[i * 3 + 2] = color.b
        }
        return pixels
    }
}

/// An image of width × height from one RGB colour per pixel (row-major, 0…1).
func cgImage(rgb: [Float], width: Int, height: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        for channel in 0..<3 {
            bytes[i * 4 + channel] = UInt8((min(max(rgb[i * 3 + channel], 0), 1) * 255).rounded())
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}
