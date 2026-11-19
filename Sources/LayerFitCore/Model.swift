import Foundation

public struct RGB: Equatable, Sendable {
    public var r, g, b: Float

    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// One closed path of 4 cubic Bézier segments with a flat opaque colour.
/// Segment i runs p[3i], p[3i+1], p[3i+2], p[(3i+3) % 12].
public struct Shape: Equatable, Sendable {
    public static let pointCount = 12

    public var points: [SIMD2<Float>]
    public var color: RGB
    /// Finer shapes fitted inside this one and drawn clipped to its outline, if it has
    /// been refined.
    public var inner: Inner?

    public init(points: [SIMD2<Float>], color: RGB, inner: Inner? = nil) {
        precondition(points.count == Shape.pointCount, "a shape has exactly 12 control points")
        self.points = points
        self.color = color
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

/// Names a region of a picture: the background, or a shape reached by indices through the
/// levels currently shown. `path[0]` indexes the picture's shapes (or the background's
/// refinement when `inBackground`), `path[1]` that shape's children, and so on.
public struct NodeID: Hashable, Sendable {
    public var inBackground: Bool
    public var path: [Int]

    public init(inBackground: Bool, path: [Int]) {
        self.inBackground = inBackground
        self.path = path
    }

    public static let background = NodeID(inBackground: true, path: [])

    public static func shape(_ path: [Int]) -> NodeID { NodeID(inBackground: false, path: path) }

    public var isBackground: Bool { inBackground && path.isEmpty }

    public func child(_ index: Int) -> NodeID {
        NodeID(inBackground: inBackground, path: path + [index])
    }

    /// The region this one was fitted inside; nil for the background and for the
    /// picture's own shapes.
    public var parent: NodeID? {
        guard !path.isEmpty else { return nil }
        if path.count == 1 { return inBackground ? .background : nil }
        return NodeID(inBackground: inBackground, path: Array(path.dropLast()))
    }

    /// True if `other` is this node or lies inside it.
    public func contains(_ other: NodeID) -> Bool {
        inBackground == other.inBackground && other.path.starts(with: path)
    }
}

/// A background colour plus shapes painted back to front, in working-image pixels.
public struct Picture: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var background: RGB
    public var shapes: [Shape]
    /// Finer shapes fitted in the part of the background no shape covers; drawn above the
    /// background colour and below every shape.
    public var backgroundInner: Inner?

    public init(
        width: Int, height: Int, background: RGB, shapes: [Shape], backgroundInner: Inner? = nil
    ) {
        self.width = width
        self.height = height
        self.background = background
        self.shapes = shapes
        self.backgroundInner = backgroundInner
    }

    /// Background colour, then per shape 24 coordinates at 2 bytes plus 3 colour bytes.
    /// Clipping a child to its parent costs nothing: the parent's outline is already stored.
    public var estimatedBytes: Int { estimatedBytes(maxDepth: .max) }

    public func estimatedBytes(maxDepth: Int) -> Int { 3 + shapeCount(maxDepth: maxDepth) * 51 }

    /// How many layers of refinement are shown: 0 when no shape or background has
    /// visible children.
    public var maxDepth: Int {
        max(Picture.depth(of: shapes), Picture.innerDepth(backgroundInner))
    }

    /// The number of shapes drawn when refinements deeper than `maxDepth` are hidden.
    public func shapeCount(maxDepth: Int) -> Int {
        Picture.count(shapes, depthLeft: maxDepth)
            + (maxDepth > 0 ? Picture.count(backgroundInner?.shapes ?? [], depthLeft: maxDepth - 1) : 0)
    }

    private static func innerDepth(_ inner: Inner?) -> Int {
        guard let children = inner?.shapes, !children.isEmpty else { return 0 }
        return 1 + depth(of: children)
    }

    private static func depth(of shapes: [Shape]) -> Int {
        shapes.map { innerDepth($0.inner) }.max() ?? 0
    }

    private static func count(_ shapes: [Shape], depthLeft: Int) -> Int {
        shapes.reduce(0) { total, shape in
            total + 1
                + (depthLeft > 0 ? count(shape.inner?.shapes ?? [], depthLeft: depthLeft - 1) : 0)
        }
    }

    // MARK: Regions

    /// The shape a node names, following the levels currently shown. Nil for the
    /// background or a path that no longer exists.
    public func shape(at node: NodeID) -> Shape? {
        var list = node.inBackground ? (backgroundInner?.shapes ?? []) : shapes
        var found: Shape?
        for index in node.path {
            guard list.indices.contains(index) else { return nil }
            found = list[index]
            list = list[index].inner?.shapes ?? []
        }
        return found
    }

    public func inner(at node: NodeID) -> Inner? {
        node.isBackground ? backgroundInner : shape(at: node)?.inner
    }

    /// Replaces a region's refinement. Returns false if the node does not exist.
    @discardableResult
    public mutating func setInner(_ inner: Inner?, at node: NodeID) -> Bool {
        if node.isBackground {
            backgroundInner = inner
            return true
        }
        if node.inBackground {
            guard var own = backgroundInner, !own.levels.isEmpty else { return false }
            let done = Picture.setInner(inner, in: &own.levels[own.shownIndex].shapes, path: node.path[...])
            backgroundInner = own
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

    public init(
        totalShapes: Int = 128, workingSize: Int = 256, stepsPerStage: Int = 150,
        mode: LevelMode = .refit, minWidth: Float = 0
    ) {
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
