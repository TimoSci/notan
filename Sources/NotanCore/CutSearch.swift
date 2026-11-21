import Foundation

/// A straight cut of a tile, and what it gains.
public struct CutChoice: Equatable, Sendable {
    public var from: CutEnd
    public var to: CutEnd
    /// How much the squared error, summed over the tile's pixels and the three channels,
    /// falls when each piece takes its own mean colour in place of the tile's. Never negative.
    public var gain: Float
    /// The mean colour of the piece `TileMesh.cut` makes first, and of the other.
    public var firstColor: RGB
    public var secondColor: RGB
}

/// How wide a polygon is, roughly: twice its area over its perimeter. A long strip scores
/// its width, a square half its side.
public func thickness(of polygon: [SIMD2<Float>]) -> Float {
    var perimeter: Float = 0
    for index in polygon.indices {
        let edge = polygon[(index + 1) % polygon.count] - polygon[index]
        perimeter += (edge * edge).sum().squareRoot()
    }
    return perimeter > 0 ? 2 * abs(polygonArea(polygon)) / perimeter : 0
}

/// No piece of a cut may be smaller than this, in pixels of area.
public let minTileArea: Float = 4

private func contains(_ polygon: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
    var inside = false
    var previous = polygon[polygon.count - 1]
    for corner in polygon {
        if (corner.y > point.y) != (previous.y > point.y) {
            let x = corner.x + (point.y - corner.y) / (previous.y - corner.y) * (previous.x - corner.x)
            if point.x < x { inside.toggle() }
        }
        previous = corner
    }
    return inside
}

private func isConvex(_ polygon: [SIMD2<Float>]) -> Bool {
    let count = polygon.count
    for index in 0..<count {
        let a = polygon[index]
        let b = polygon[(index + 1) % count]
        let c = polygon[(index + 2) % count]
        if (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) < 0 { return false }
    }
    return true
}

/// The straight cut of `polygon`, between points on two of its edges, that lowers the
/// squared error against `target` the most when each piece is given its mean colour.
///
/// About `candidates` points spread round the outline are tried in pairs. A cut is left
/// out if it would leave the tile, or leave a piece under `minTileArea` in area or under
/// `minThickness` in thickness. Nil when no cut is allowed. The tile's pixels are those
/// whose centres lie inside it.
public func bestCut(
    of polygon: [SIMD2<Float>], in target: TargetImage, minThickness: Float, candidates: Int = 32
) -> CutChoice? {
    let count = polygon.count
    guard count >= 3 else { return nil }

    // The tile's pixels: centre and colour.
    var low = polygon[0]
    var high = polygon[0]
    for corner in polygon {
        low = pointwiseMin(low, corner)
        high = pointwiseMax(high, corner)
    }
    let x0 = max(0, Int(low.x.rounded(.down)))
    let y0 = max(0, Int(low.y.rounded(.down)))
    let x1 = min(target.width, Int(high.x.rounded(.up)))
    let y1 = min(target.height, Int(high.y.rounded(.up)))
    guard x0 < x1, y0 < y1 else { return nil }
    var centres: [SIMD2<Float>] = []
    var colours: [SIMD3<Double>] = []
    var total = SIMD3<Double>(0, 0, 0)
    for y in y0..<y1 {
        for x in x0..<x1 {
            let centre = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
            guard contains(polygon, centre) else { continue }
            let base = (y * target.width + x) * 3
            let colour = SIMD3(
                Double(target.pixels[base]), Double(target.pixels[base + 1]),
                Double(target.pixels[base + 2]))
            centres.append(centre)
            colours.append(colour)
            total += colour
        }
    }
    guard centres.count >= 2 else { return nil }
    let whole = (total * total).sum() / Double(centres.count)

    // Points to cut between: on each edge in proportion to its length, at least one.
    var lengths: [Float] = []
    for index in 0..<count {
        let edge = polygon[(index + 1) % count] - polygon[index]
        lengths.append((edge * edge).sum().squareRoot())
    }
    let perimeter = lengths.reduce(0, +)
    guard perimeter > 0 else { return nil }
    var ends: [(end: CutEnd, point: SIMD2<Float>)] = []
    for index in 0..<count {
        let onEdge = max(1, Int((Float(candidates) * lengths[index] / perimeter).rounded()))
        for k in 0..<onEdge {
            let t = (Float(k) + 0.5) / Float(onEdge)
            let a = polygon[index]
            let b = polygon[(index + 1) % count]
            ends.append((CutEnd(edge: index, t: t), a + (b - a) * t))
        }
    }

    func run(after first: Int, through last: Int) -> [SIMD2<Float>] {
        var result: [SIMD2<Float>] = []
        var position = (first + 1) % count
        while true {
            result.append(polygon[position])
            if position == last { break }
            position = (position + 1) % count
        }
        return result
    }

    let convex = isConvex(polygon)
    var best: CutChoice?
    for i in ends.indices {
        for j in (i + 1)..<ends.count where ends[j].end.edge != ends[i].end.edge {
            let from = ends[i]
            let to = ends[j]
            let p = from.point
            let q = to.point
            if !convex {
                guard contains(polygon, (p + q) / 2) else { continue }
                var leaves = false
                for edge in 0..<count where edge != from.end.edge && edge != to.end.edge {
                    if segmentsMeet(p, q, polygon[edge], polygon[(edge + 1) % count]) {
                        leaves = true
                        break
                    }
                }
                if leaves { continue }
            }
            let first = [p] + run(after: from.end.edge, through: to.end.edge) + [q]
            let second = [q] + run(after: to.end.edge, through: from.end.edge) + [p]
            guard polygonArea(first) >= minTileArea, polygonArea(second) >= minTileArea,
                thickness(of: first) >= minThickness, thickness(of: second) >= minThickness
            else { continue }

            // Sum the colours of the first piece; the second has the rest.
            var sum = SIMD3<Double>(0, 0, 0)
            var number = 0
            if convex {
                // The first piece holds the corner after the first cut end.
                let direction = q - p
                let corner = polygon[(from.end.edge + 1) % count] - p
                let firstSide: Float = direction.x * corner.y - direction.y * corner.x >= 0 ? 1 : -1
                for index in centres.indices {
                    let offset = centres[index] - p
                    if (direction.x * offset.y - direction.y * offset.x) * firstSide > 0 {
                        sum += colours[index]
                        number += 1
                    }
                }
            } else {
                for index in centres.indices where contains(first, centres[index]) {
                    sum += colours[index]
                    number += 1
                }
            }
            let others = centres.count - number
            guard number > 0, others > 0 else { continue }
            let rest = total - sum
            let gain = (sum * sum).sum() / Double(number) + (rest * rest).sum() / Double(others) - whole
            if best == nil || Float(max(gain, 0)) > best!.gain {
                func colour(_ sum: SIMD3<Double>, _ number: Int) -> RGB {
                    let mean = sum / Double(number)
                    return RGB(r: Float(mean.x), g: Float(mean.y), b: Float(mean.z))
                }
                best = CutChoice(
                    from: from.end, to: to.end, gain: Float(max(gain, 0)),
                    firstColor: colour(sum, number), secondColor: colour(rest, others))
            }
        }
    }
    return best
}
