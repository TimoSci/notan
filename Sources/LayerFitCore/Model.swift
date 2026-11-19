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

    public init(points: [SIMD2<Float>], color: RGB) {
        precondition(points.count == Shape.pointCount, "a shape has exactly 12 control points")
        self.points = points
        self.color = color
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

/// A background colour plus shapes painted back to front, in working-image pixels.
public struct Picture: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var background: RGB
    public var shapes: [Shape]

    public init(width: Int, height: Int, background: RGB, shapes: [Shape]) {
        self.width = width
        self.height = height
        self.background = background
        self.shapes = shapes
    }

    /// Background colour, then per shape 24 coordinates at 2 bytes plus 3 colour bytes.
    public var estimatedBytes: Int { 3 + shapes.count * 51 }
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
