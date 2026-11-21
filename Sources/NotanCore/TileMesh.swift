import Foundation

/// The area of a polygon, positive when its corners run the way a valid tile's do: the
/// picture's own go top left, top right, bottom right, bottom left.
public func polygonArea(_ polygon: [SIMD2<Float>]) -> Float {
    var twice: Float = 0
    for index in polygon.indices {
        let a = polygon[index]
        let b = polygon[(index + 1) % polygon.count]
        twice += a.x * b.y - b.x * a.y
    }
    return twice / 2
}

private func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }

/// Whether segments a–b and c–d meet anywhere, ends included.
func segmentsMeet(
    _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
) -> Bool {
    func side(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float { cross(q - p, r - p) }
    func within(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Bool {
        min(p.x, q.x) <= r.x && r.x <= max(p.x, q.x) && min(p.y, q.y) <= r.y && r.y <= max(p.y, q.y)
    }
    let d1 = side(c, d, a)
    let d2 = side(c, d, b)
    let d3 = side(a, b, c)
    let d4 = side(a, b, d)
    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
        return true
    }
    if d1 == 0 && within(c, d, a) { return true }
    if d2 == 0 && within(c, d, b) { return true }
    if d3 == 0 && within(a, b, c) { return true }
    if d4 == 0 && within(a, b, d) { return true }
    return false
}

/// Whether a polygon's outline never crosses or touches itself. Corners in a straight
/// line are fine; an edge doubling back along the one before it is not.
public func isSimplePolygon(_ polygon: [SIMD2<Float>]) -> Bool {
    let count = polygon.count
    guard count >= 3 else { return false }
    for i in 0..<count {
        let a = polygon[i]
        let b = polygon[(i + 1) % count]
        let c = polygon[(i + 2) % count]
        if a == b { return false }
        // The next edge folded back onto this one.
        if cross(b - a, c - b) == 0 && ((b - a) * (c - b)).sum() < 0 { return false }
        guard count > 3, i + 2 < count else { continue }
        for j in (i + 2)..<count where !(i == 0 && j == count - 1) {
            if segmentsMeet(a, b, polygon[j], polygon[(j + 1) % count]) { return false }
        }
    }
    return true
}

/// The polygon with every edge moved outward by `margin`, corners kept sharp. A very
/// sharp corner would shoot far out, so no corner moves more than three margins.
func grownPolygon(_ polygon: [SIMD2<Float>], by margin: Float) -> [SIMD2<Float>] {
    let count = polygon.count
    func outward(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float>? {
        let d = b - a
        let length = (d * d).sum().squareRoot()
        return length > 0 ? SIMD2(d.y, -d.x) / length : nil
    }
    return polygon.indices.map { index in
        let corner = polygon[index]
        let before = outward(polygon[(index + count - 1) % count], corner)
        let after = outward(corner, polygon[(index + 1) % count])
        guard let n1 = before ?? after, let n2 = after ?? before else { return corner }
        var offset = (n1 + n2) * (margin / max(1 + (n1 * n2).sum(), 1e-3))
        let length = (offset * offset).sum().squareRoot()
        if length > 3 * margin { offset *= 3 * margin / length }
        return corner + offset
    }
}

/// A point on a tile's outline: on the edge from corner `edge` to the next corner, the
/// fraction `t` of the way along, strictly between 0 and 1.
public struct CutEnd: Equatable, Sendable {
    public var edge: Int
    public var t: Float

    public init(edge: Int, t: Float) {
        self.edge = edge
        self.t = t
    }
}

/// How a corner may move while fitting.
public enum Freedom: Equatable, Sendable {
    /// Not at all: a corner of the picture.
    case fixed
    /// Along the top or bottom border.
    case alongX
    /// Along the left or right border.
    case alongY
    case free
    /// On the frozen straight line between two other points.
    case slide(from: Int, to: Int)
}

public struct TileNode: Equatable, Sendable {
    /// Indices into the mesh's points, in order round the tile. Empty once the tile has
    /// been cut: only the uncut tiles have outlines.
    public var corners: [Int]
    public var color: RGB
    /// 0 or 1 at each cut from the whole picture down to this tile.
    public var path: [Int]
    /// The two tiles it was cut into, or none.
    public var children: [Int]
    /// The stage that made it; 0 for the whole picture.
    public var stage: Int
}

/// A picture divided into tiles by repeated straight cuts. Tiles refer to their corners by
/// index, so that neighbours can share them. The uncut tiles, the leaves, always cover the
/// picture exactly once.
public struct TileMesh: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var points: [SIMD2<Float>]
    public private(set) var freedom: [Freedom]
    /// `nodes[0]` is the whole picture.
    public private(set) var nodes: [TileNode]

    public init(width: Int, height: Int, color: RGB) {
        precondition(width >= 1 && height >= 1)
        self.width = width
        self.height = height
        let w = Float(width)
        let h = Float(height)
        points = [SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)]
        freedom = [.fixed, .fixed, .fixed, .fixed]
        nodes = [TileNode(corners: [0, 1, 2, 3], color: color, path: [], children: [], stage: 0)]
    }

    /// The uncut tiles, by node index, ascending.
    public var leaves: [Int] { nodes.indices.filter { nodes[$0].children.isEmpty } }

    public func polygon(_ node: Int) -> [SIMD2<Float>] { nodes[node].corners.map { points[$0] } }

    /// Cuts a leaf in two with a straight line between points on two of its edges. The
    /// first piece runs from the first cut end forward round the tile to the second; the
    /// second piece is the rest. Both start in the leaf's colour.
    ///
    /// With `shareCorners`, a cut end on an edge shared with a neighbour becomes a corner
    /// of that neighbour as well, and is free to move (along the border, if it lies on
    /// it). Without, no other tile changes, and the cut end may only slide along the edge
    /// it was placed on.
    @discardableResult
    public mutating func cut(
        _ leaf: Int, from: CutEnd, to: CutEnd, stage: Int, shareCorners: Bool
    ) -> (first: Int, second: Int) {
        let corners = nodes[leaf].corners
        let count = corners.count
        precondition(nodes[leaf].children.isEmpty, "only an uncut tile can be cut")
        precondition(from.edge != to.edge && (0..<count).contains(from.edge) && (0..<count).contains(to.edge))
        precondition(from.t > 0 && from.t < 1 && to.t > 0 && to.t < 1)

        func place(_ end: CutEnd) -> Int {
            let start = corners[end.edge]
            let finish = corners[(end.edge + 1) % count]
            let a = points[start]
            let b = points[finish]
            let index = points.count
            points.append(a + (b - a) * end.t)
            guard shareCorners else {
                freedom.append(.slide(from: start, to: finish))
                return index
            }
            let w = Float(width)
            let h = Float(height)
            if (a.y == 0 && b.y == 0) || (a.y == h && b.y == h) {
                freedom.append(.alongX)
            } else if (a.x == 0 && b.x == 0) || (a.x == w && b.x == w) {
                freedom.append(.alongY)
            } else {
                freedom.append(.free)
            }
            // The neighbour across this edge has it the other way round.
            for other in nodes.indices where other != leaf && nodes[other].children.isEmpty {
                let theirs = nodes[other].corners
                for position in theirs.indices
                where theirs[position] == finish && theirs[(position + 1) % theirs.count] == start {
                    nodes[other].corners.insert(index, at: position + 1)
                    return index
                }
            }
            return index
        }
        let a = place(from)
        let b = place(to)

        /// The corners after edge `first`'s start, forward round the tile, up to edge `last`'s start.
        func run(after first: Int, through last: Int) -> [Int] {
            var result: [Int] = []
            var position = (first + 1) % count
            while true {
                result.append(corners[position])
                if position == last { break }
                position = (position + 1) % count
            }
            return result
        }
        let parent = nodes[leaf]
        let firstIndex = nodes.count
        nodes.append(
            TileNode(
                corners: [a] + run(after: from.edge, through: to.edge) + [b], color: parent.color,
                path: parent.path + [0], children: [], stage: stage))
        nodes.append(
            TileNode(
                corners: [b] + run(after: to.edge, through: from.edge) + [a], color: parent.color,
                path: parent.path + [1], children: [], stage: stage))
        nodes[leaf].children = [firstIndex, firstIndex + 1]
        nodes[leaf].corners = []
        return (firstIndex, firstIndex + 1)
    }

    public mutating func setPoint(_ index: Int, _ point: SIMD2<Float>) { points[index] = point }

    public mutating func setColor(_ node: Int, _ color: RGB) { nodes[node].color = color }

    /// The uncut tiles that are not sound: outline crossing itself, or area below `minArea`
    /// (which includes a tile turned inside out).
    public func invalidLeaves(minArea: Float) -> [Int] {
        leaves.filter {
            let polygon = polygon($0)
            return polygonArea(polygon) < minArea || !isSimplePolygon(polygon)
        }
    }

    /// The uncut tiles, in the order of `leaves`.
    public func tiles() -> [Tile] {
        leaves.map { Tile(corners: polygon($0), color: nodes[$0].color, path: nodes[$0].path) }
    }
}
