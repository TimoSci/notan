import Foundation

public struct RGB: Equatable, Sendable {
    public var r, g, b: Float

    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// A straight colour ramp across a shape: the shape's own colour at `from`, running to
/// `endColor` at `to`, and held constant beyond either end. In working-image pixels.
public struct Gradient: Equatable, Sendable {
    public var from: SIMD2<Float>
    public var to: SIMD2<Float>
    public var endColor: RGB

    public init(from: SIMD2<Float>, to: SIMD2<Float>, endColor: RGB) {
        self.from = from
        self.to = to
        self.endColor = endColor
    }
}

/// One closed path of 4 cubic Bézier segments with an opaque fill (one flat colour, or a
/// linear gradient), filled by the
/// non-zero rule: where the outline overlaps itself the shape is still solid.
/// Segment i runs p[3i], p[3i+1], p[3i+2], p[(3i+3) % 12].
public struct Shape: Equatable, Sendable {
    public static let pointCount = 12

    public var points: [SIMD2<Float>]
    public var color: RGB
    /// Nil for a flat fill of `color`.
    public var gradient: Gradient?
    /// Finer shapes fitted inside this one and drawn clipped to its outline, if it has
    /// been refined.
    public var inner: Inner?

    public init(
        points: [SIMD2<Float>], color: RGB, gradient: Gradient? = nil, inner: Inner? = nil
    ) {
        precondition(points.count == Shape.pointCount, "a shape has exactly 12 control points")
        self.points = points
        self.color = color
        self.gradient = gradient
        self.inner = inner
    }

    public static func circle(center: SIMD2<Float>, radius: Float, color: RGB) -> Shape {
        let k: Float = 0.5522848 * radius
        let r = radius
        let offsets: [SIMD2<Float>] = [
            SIMD2(r, 0), SIMD2(r, k), SIMD2(k, r),
            SIMD2(0, r), SIMD2(-k, r), SIMD2(-r, k),
            SIMD2(-r, 0), SIMD2(-r, -k), SIMD2(-k, -r),
            SIMD2(0, -r), SIMD2(k, -r), SIMD2(r, -k),
        ]
        return Shape(points: offsets.map { center + $0 }, color: color)
    }
}

/// One level of a refinement: the shapes inside a region after a stage, and how far the
/// region then was from the photo.
public struct InnerLevel: Equatable, Sendable {
    public var shapes: [Shape]
    public var mse: Float

    public init(shapes: [Shape], mse: Float) {
        self.shapes = shapes
        self.mse = mse
    }
}

/// The refinement of one region (a shape, or the background): its levels, coarse to fine,
/// and which of them is shown. Level 0 is the bare region.
public struct Inner: Equatable, Sendable {
    public var levels: [InnerLevel]
    public var shown: Int

    public init(levels: [InnerLevel], shown: Int) {
        self.levels = levels
        self.shown = shown
    }

    /// `shown`, kept within the levels that exist.
    public var shownIndex: Int { max(0, min(shown, levels.count - 1)) }

    /// The shapes of the level shown.
    public var shapes: [Shape] { levels.isEmpty ? [] : levels[shownIndex].shapes }
}

/// Names a region of a picture: a gap (a patch no shape covers), or a shape reached by
/// indices through the levels currently shown. `path[0]` indexes the picture's shapes (or
/// the refinement of gap number `gap` when `inBackground`), `path[1]` that shape's
/// children, and so on.
///
/// With `locked` set, the region is not one of the picture's own but lies in that locked
/// area of it, and the rest names it within the locked area's picture.
public struct NodeID: Hashable, Sendable {
    public var inBackground: Bool
    /// Which gap, when `inBackground`; otherwise 0.
    public var gap: Int
    public var path: [Int]
    /// Which of the picture's locked areas the region lies in; nil for the picture itself.
    public var locked: Int?

    public init(inBackground: Bool, gap: Int = 0, path: [Int], locked: Int? = nil) {
        self.inBackground = inBackground
        self.gap = inBackground ? gap : 0
        self.path = path
        self.locked = locked
    }

    /// The same region of the picture of locked area `index`; nil for a picture's own.
    public func inLocked(_ index: Int?) -> NodeID {
        NodeID(inBackground: inBackground, gap: gap, path: path, locked: index)
    }

    /// The whole uncovered area, for a picture whose gaps are not told apart. Same as gap 0.
    public static let background = NodeID.gap(0)

    public static func gap(_ index: Int) -> NodeID {
        NodeID(inBackground: true, gap: index, path: [])
    }

    public static func shape(_ path: [Int]) -> NodeID { NodeID(inBackground: false, path: path) }

    /// True for a gap itself, as opposed to a shape fitted inside one.
    public var isBackground: Bool { inBackground && path.isEmpty }

    public func child(_ index: Int) -> NodeID {
        NodeID(inBackground: inBackground, gap: gap, path: path + [index], locked: locked)
    }

    /// The region this one was fitted inside; nil for a gap and for the picture's own shapes.
    public var parent: NodeID? {
        guard !path.isEmpty else { return nil }
        if path.count == 1 { return inBackground ? NodeID.gap(gap).inLocked(locked) : nil }
        return NodeID(
            inBackground: inBackground, gap: gap, path: Array(path.dropLast()), locked: locked)
    }

    /// True if `other` is this node or lies inside it.
    public func contains(_ other: NodeID) -> Bool {
        locked == other.locked && inBackground == other.inBackground && gap == other.gap
            && other.path.starts(with: path)
    }
}

/// A patch of the picture no shape covers. It has no outline of its own: its edge is
/// whatever its neighbours leave. It is stored as a colour only.
public struct Gap: Equatable, Sendable {
    public var color: RGB
    /// Finer shapes fitted inside this gap, drawn above its colour and below every shape.
    public var inner: Inner?

    public init(color: RGB, inner: Inner? = nil) {
        self.color = color
        self.inner = inner
    }
}

/// A region of an earlier level's picture, kept as it was there and painted on top of a
/// later level's picture: the part of `node` that showed in `picture`, with everything
/// fitted inside it. `node` is one of `picture`'s own shapes or gaps.
public struct LockedArea: Equatable, Sendable {
    public var picture: Picture
    public var node: NodeID

    public init(picture: Picture, node: NodeID) {
        self.picture = picture
        self.node = node
    }

    /// The shapes this area adds to what is drawn: the locked shape itself, or what was
    /// fitted in the locked gap. `depthUsed` is how many layers of refinement they are
    /// below the picture's own shapes.
    var drawn: (shapes: [Shape], depthUsed: Int) {
        if node.isBackground { return (picture.inner(at: node)?.shapes ?? [], 1) }
        return (picture.shape(at: node).map { [$0] } ?? [], 0)
    }
}

/// A background colour plus shapes painted back to front, in working-image pixels.
public struct Picture: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var background: RGB
    public var shapes: [Shape]
    /// The patches no shape covers, in reading order of their first pixel (see `gapMap`),
    /// each with its own colour. Empty, or out of step with the shapes, means the gaps are
    /// not told apart: the uncovered area is then one region in the background colour.
    public var gaps: [Gap]
    /// Areas of earlier levels painted over everything else, in order.
    public var locked: [LockedArea] = []

    public init(
        width: Int, height: Int, background: RGB, shapes: [Shape], backgroundInner: Inner? = nil,
        gaps: [Gap] = []
    ) {
        self.width = width
        self.height = height
        self.background = background
        self.shapes = shapes
        self.gaps = gaps
        if let backgroundInner { self.backgroundInner = backgroundInner }
    }

    /// The refinement of the uncovered area when gaps are not told apart: that of gap 0.
    public var backgroundInner: Inner? {
        get { gaps.first?.inner }
        set {
            if gaps.isEmpty {
                if let newValue { gaps = [Gap(color: background, inner: newValue)] }
            } else {
                gaps[0].inner = newValue
            }
        }
    }

    /// Background colour, then per shape 24 coordinates at 2 bytes plus 3 colour bytes,
    /// then 3 colour bytes per gap when the gaps have colours of their own.
    /// Clipping a child to its parent costs nothing: the parent's outline is already stored;
    /// likewise a gap's outline is given by the shapes around it.
    public var estimatedBytes: Int { estimatedBytes(maxDepth: .max) }

    public func estimatedBytes(maxDepth: Int) -> Int {
        // A gradient adds a second colour and two points.
        3 + shapeCount(maxDepth: maxDepth) * 51 + gradientCount(maxDepth: maxDepth) * 11
            + (gaps.count > 1 ? gaps.count * 3 : 0)
    }

    /// The number of shapes drawn with a gradient when refinements deeper than `maxDepth`
    /// are hidden.
    public func gradientCount(maxDepth: Int) -> Int {
        var total = Picture.count(shapes, depthLeft: maxDepth) { $0.gradient != nil }
        if maxDepth > 0 {
            for gap in gaps {
                total += Picture.count(gap.inner?.shapes ?? [], depthLeft: maxDepth - 1) {
                    $0.gradient != nil
                }
            }
        }
        for area in locked where maxDepth >= area.drawn.depthUsed {
            total += Picture.count(area.drawn.shapes, depthLeft: maxDepth - area.drawn.depthUsed) {
                $0.gradient != nil
            }
        }
        return total
    }

    /// How many layers of refinement are shown: 0 when no shape or gap has visible children.
    public var maxDepth: Int {
        let own = max(Picture.depth(of: shapes), gaps.map { Picture.innerDepth($0.inner) }.max() ?? 0)
        let inLocked = locked.map { area -> Int in
            let drawn = area.drawn
            return drawn.shapes.isEmpty ? 0 : drawn.depthUsed + Picture.depth(of: drawn.shapes)
        }
        return max(own, inLocked.max() ?? 0)
    }

    /// The number of shapes drawn when refinements deeper than `maxDepth` are hidden.
    public func shapeCount(maxDepth: Int) -> Int {
        var total = Picture.count(shapes, depthLeft: maxDepth)
        if maxDepth > 0 {
            for gap in gaps {
                total += Picture.count(gap.inner?.shapes ?? [], depthLeft: maxDepth - 1)
            }
        }
        for area in locked where maxDepth >= area.drawn.depthUsed {
            total += Picture.count(area.drawn.shapes, depthLeft: maxDepth - area.drawn.depthUsed)
        }
        return total
    }

    private static func innerDepth(_ inner: Inner?) -> Int {
        guard let children = inner?.shapes, !children.isEmpty else { return 0 }
        return 1 + depth(of: children)
    }

    private static func depth(of shapes: [Shape]) -> Int {
        shapes.map { innerDepth($0.inner) }.max() ?? 0
    }

    private static func count(
        _ shapes: [Shape], depthLeft: Int, where counted: (Shape) -> Bool = { _ in true }
    ) -> Int {
        shapes.reduce(0) { total, shape in
            total + (counted(shape) ? 1 : 0)
                + (depthLeft > 0
                    ? count(shape.inner?.shapes ?? [], depthLeft: depthLeft - 1, where: counted) : 0)
        }
    }

    // MARK: Regions

    /// The shape a node names, following the levels currently shown. Nil for the
    /// background or a path that no longer exists.
    public func shape(at node: NodeID) -> Shape? {
        if let index = node.locked {
            return locked.indices.contains(index)
                ? locked[index].picture.shape(at: node.inLocked(nil)) : nil
        }
        var list: [Shape]
        if node.inBackground {
            list = gaps.indices.contains(node.gap) ? (gaps[node.gap].inner?.shapes ?? []) : []
        } else {
            list = shapes
        }
        var found: Shape?
        for index in node.path {
            guard list.indices.contains(index) else { return nil }
            found = list[index]
            list = list[index].inner?.shapes ?? []
        }
        return found
    }

    public func inner(at node: NodeID) -> Inner? {
        if let index = node.locked {
            return locked.indices.contains(index)
                ? locked[index].picture.inner(at: node.inLocked(nil)) : nil
        }
        if node.isBackground {
            return gaps.indices.contains(node.gap) ? gaps[node.gap].inner : nil
        }
        return shape(at: node)?.inner
    }

    /// Replaces a region's refinement. Returns false if the node does not exist.
    @discardableResult
    public mutating func setInner(_ inner: Inner?, at node: NodeID) -> Bool {
        if let index = node.locked {
            guard locked.indices.contains(index) else { return false }
            return locked[index].picture.setInner(inner, at: node.inLocked(nil))
        }
        if node.isBackground {
            if gaps.indices.contains(node.gap) {
                gaps[node.gap].inner = inner
                return true
            }
            // Gaps not told apart: the uncovered area as a whole is gap 0.
            guard node.gap == 0, gaps.isEmpty else { return false }
            backgroundInner = inner
            return true
        }
        if node.inBackground {
            guard gaps.indices.contains(node.gap), var own = gaps[node.gap].inner,
                !own.levels.isEmpty
            else { return false }
            let done = Picture.setInner(inner, in: &own.levels[own.shownIndex].shapes, path: node.path[...])
            gaps[node.gap].inner = own
            return done
        }
        return Picture.setInner(inner, in: &shapes, path: node.path[...])
    }

    private static func setInner(_ inner: Inner?, in list: inout [Shape], path: ArraySlice<Int>) -> Bool {
        guard let first = path.first, list.indices.contains(first) else { return false }
        if path.count == 1 {
            list[first].inner = inner
            return true
        }
        guard var own = list[first].inner, !own.levels.isEmpty else { return false }
        let done = setInner(inner, in: &own.levels[own.shownIndex].shapes, path: path.dropFirst())
        list[first].inner = own
        return done
    }
}

public enum LevelMode: String, Sendable, CaseIterable {
    /// Every stage re-optimises all shapes (faithful to LIVE).
    case refit
    /// Shapes are frozen once their stage ends, so each level is a prefix of the next.
    case prefix
}

public struct Level: Sendable {
    public var picture: Picture
    public var mse: Float

    public init(picture: Picture, mse: Float) {
        self.picture = picture
        self.mse = mse
    }
}

public struct FitSettings: Sendable {
    public var totalShapes = 128
    public var workingSize = 256
    public var stepsPerStage = 150
    public var mode = LevelMode.refit
    /// The narrowest a shape may be at the finest level, in pixels at a 256 px working size
    /// (it scales with the working size). Earlier shapes must be wider; see
    /// `minWidthSchedule`. 0 switches the check off.
    public var minWidth: Float = 0
    /// Whether shapes are kept from folding over themselves (bow-ties, loops, lobes folded
    /// back). See `foldRatio`.
    public var avoidFolds = true
    /// Whether each shape is filled with a linear gradient instead of one flat colour.
    public var gradients = false

    public init(
        totalShapes: Int = 128, workingSize: Int = 256, stepsPerStage: Int = 150,
        mode: LevelMode = .refit, minWidth: Float = 0, avoidFolds: Bool = true
    ) {
        self.avoidFolds = avoidFolds
        self.totalShapes = totalShapes
        self.workingSize = workingSize
        self.stepsPerStage = stepsPerStage
        self.mode = mode
        self.minWidth = minWidth
    }
}

/// Shapes added per stage: 1, 1, 1, 1, 2, 2, 4, 4, 8, 8, … with the last stage cut to fit the total.
public func stageSchedule(totalShapes: Int) -> [Int] {
    var schedule: [Int] = []
    var remaining = totalShapes
    var index = 0
    while remaining > 0 {
        let size = index < 4 ? 1 : 1 << ((index - 4) / 2 + 1)
        let count = min(size, remaining)
        schedule.append(count)
        remaining -= count
        index += 1
    }
    return schedule
}

/// One tile of a tiling: a straight-edged polygon in one flat colour. Tiles share edges
/// with their neighbours and do not overlap.
public struct Tile: Equatable, Sendable {
    /// In order round the tile, in working-image pixels.
    public var corners: [SIMD2<Float>]
    public var color: RGB
    /// Where the tile sits in the tree of cuts: at each cut from the whole picture down,
    /// 0 for the first piece or 1 for the second. Empty for the whole picture.
    public var path: [Int]

    public init(corners: [SIMD2<Float>], color: RGB, path: [Int]) {
        self.corners = corners
        self.color = color
        self.path = path
    }
}
