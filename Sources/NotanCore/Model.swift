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
/// region then was from the photo. For a refined tile, the tiles it is cut into, which
/// take its place.
public struct InnerLevel: Equatable, Sendable {
    public var shapes: [Shape]
    public var mse: Float
    public var tiles: [Tile]

    public init(shapes: [Shape], mse: Float, tiles: [Tile] = []) {
        self.shapes = shapes
        self.mse = mse
        self.tiles = tiles
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

    /// The tiles of the level shown.
    public var tiles: [Tile] { levels.isEmpty ? [] : levels[shownIndex].tiles }
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
    /// True for a tile of a tiling. `path` is then the tile's place in the tree of cuts
    /// (see `Tile.path`), and an empty path is the whole picture.
    public var isTile = false

    public init(
        inBackground: Bool, gap: Int = 0, path: [Int], locked: Int? = nil, isTile: Bool = false
    ) {
        self.inBackground = inBackground
        self.gap = inBackground ? gap : 0
        self.path = path
        self.locked = locked
        self.isTile = isTile
    }

    /// The same region of the picture of locked area `index`; nil for a picture's own.
    public func inLocked(_ index: Int?) -> NodeID {
        NodeID(inBackground: inBackground, gap: gap, path: path, locked: index, isTile: isTile)
    }

    /// The tile at `path` in the tree of cuts, or the group of tiles it has been cut into.
    public static func tile(_ path: [Int]) -> NodeID {
        NodeID(inBackground: false, path: path, isTile: true)
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
        NodeID(
            inBackground: inBackground, gap: gap, path: path + [index], locked: locked,
            isTile: isTile)
    }

    /// The region this one was fitted inside; nil for a gap and for the picture's own shapes.
    /// For a tile, the tile it was cut from; nil for the whole picture.
    public var parent: NodeID? {
        guard !path.isEmpty else { return nil }
        if isTile { return .tile(Array(path.dropLast())) }
        if path.count == 1 { return inBackground ? NodeID.gap(gap).inLocked(locked) : nil }
        return NodeID(
            inBackground: inBackground, gap: gap, path: Array(path.dropLast()), locked: locked)
    }

    /// True if `other` is this node or lies inside it.
    public func contains(_ other: NodeID) -> Bool {
        locked == other.locked && inBackground == other.inBackground && gap == other.gap
            && isTile == other.isTile
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
    /// The tiles of a tiling, which between them cover the picture. A picture fitted with
    /// tiles has these and no shapes.
    public var tiles: [Tile] = []

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
        3 + (shapeCount(maxDepth: maxDepth) - tiles.count) * 51
            + gradientCount(maxDepth: maxDepth) * 11 + (gaps.count > 1 ? gaps.count * 3 : 0)
            + tileBytes
    }

    /// A tile costs its 3 colour bytes; each corner, stored once however many tiles share
    /// it, costs 2 coordinates of 2 bytes.
    private var tileBytes: Int {
        guard !tiles.isEmpty else { return 0 }
        var corners = Set<SIMD2<Float>>()
        for tile in tiles { corners.formUnion(tile.corners) }
        return tiles.count * 3 + corners.count * 4
    }

    /// The tiles a tile address stands for in this picture: those cut from it, or itself;
    /// failing that, the one tile it would be cut from. None for any other kind of region.
    public func tiles(under node: NodeID) -> [Tile] {
        guard node.isTile else { return [] }
        let below = tiles.filter { $0.path.starts(with: node.path) }
        if !below.isEmpty { return below }
        return tiles.filter { node.path.starts(with: $0.path) }
    }

    /// Puts `finer` in place of the tile at `path`, or of the pieces it has been cut into.
    /// False, and nothing changes, if this picture has no tile there.
    @discardableResult
    public mutating func replaceTiles(under path: [Int], with finer: [Tile]) -> Bool {
        guard let first = tiles.firstIndex(where: { $0.path.starts(with: path) }) else { return false }
        var kept = tiles
        kept.removeAll { $0.path.starts(with: path) }
        kept.insert(contentsOf: finer, at: min(first, kept.count))
        tiles = kept
        return true
    }

    /// The address to show for a tile address in this picture: itself when it names a tile
    /// or a group of tiles here, else the tile that contains it, else nil.
    public func resolved(_ node: NodeID) -> NodeID? {
        guard let first = tiles(under: node).first else { return nil }
        return first.path.starts(with: node.path) ? node : .tile(first.path)
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
        var total = Picture.count(shapes, depthLeft: maxDepth) + tiles.count
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

public enum ShapeKind: String, Sendable, CaseIterable {
    /// Closed Bézier curves painted back to front, free to overlap.
    case curves
    /// Straight-edged tiles that share edges and never overlap, made by cutting the
    /// picture again and again.
    case tiles
}

public enum TileOrder: String, Sendable, CaseIterable {
    /// Every tile is cut once more at each stage: a strict tree, with 1, 2, 4, 8… tiles.
    case tree
    /// Only the tiles with the most to gain are cut at each stage.
    case worst
}

/// How many tiles are cut at each stage, so that `totalTiles` tiles are reached: each cut
/// adds one. In tree order every tile is cut, so the counts double; worst first follows
/// the curve fitter's schedule. The last stage is cut short if need be.
public func tileSchedule(totalTiles: Int, order: TileOrder) -> [Int] {
    let cuts = max(totalTiles - 1, 0)
    switch order {
    case .worst: return stageSchedule(totalShapes: cuts)
    case .tree:
        var schedule: [Int] = []
        var remaining = cuts
        var size = 1
        while remaining > 0 {
            schedule.append(min(size, remaining))
            remaining -= min(size, remaining)
            size *= 2
        }
        return schedule
    }
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
    /// How far a shape may fold over itself (bow-ties, loops, lobes folded back): the
    /// share of its outline's sweep that may run backward, from 0, no fold, to
    /// `maxFoldTolerance`, where anything goes. See `foldRatio`.
    public var foldTolerance: Float = 0
    /// The fold ratio of a bow-tie, the most a shape can have. At this tolerance folds are
    /// not checked at all.
    public static let maxFoldTolerance: Float = 0.5
    /// Whether folding is limited at all. Off, shapes may fold and cross as they like,
    /// whatever the tolerance and strength, and the fit does not spend time checking.
    public var limitsFolds = true
    public var allowsAnyFold: Bool { !limitsFolds || foldTolerance >= FitSettings.maxFoldTolerance }
    /// With no fold allowed at all, outlines are also kept from crossing themselves
    /// outright: a step that makes one cross is undone. See `undoingCrossings`.
    public var forbidsCrossings: Bool { limitsFolds && foldTolerance <= 0 }
    /// How strongly folding beyond the tolerance is held back: the weight of the fold
    /// penalty. The penalty also discourages shapes that curl round something without
    /// crossing, so a high weight costs fit. With crossings forbidden it has little left
    /// to do, and 1 gave the best fit on the test photo; with a tolerance it is what
    /// holds folds to it. See `LossConfig.foldWeight`.
    public var foldStrength: Float = 1

    /// `loss` with these settings' fold tolerance and strength in place.
    public func withFolds(_ loss: LossConfig) -> LossConfig {
        var loss = loss
        loss.foldTolerance = foldTolerance
        loss.foldWeight = allowsAnyFold ? 0 : foldStrength
        return loss
    }
    /// Whether each shape is filled with a linear gradient instead of one flat colour.
    public var gradients = false
    /// What the picture is built from: curved shapes laid over one another, or tiles.
    public var kind = ShapeKind.curves
    /// For tiles: which tiles are cut at each stage.
    public var tileOrder = TileOrder.worst

    public init(
        totalShapes: Int = 128, workingSize: Int = 256, stepsPerStage: Int = 150,
        mode: LevelMode = .refit, minWidth: Float = 0, foldTolerance: Float = 0
    ) {
        self.foldTolerance = foldTolerance
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
