import Foundation
import MLX

/// Turns the corners of a set of tiles into the array of edges the rasteriser takes.
///
/// The rasteriser wants the same number of edges for every shape, and its GPU programs
/// are compiled once for each number, so the number is the most corners any tile has,
/// rounded up to a multiple of 4. A tile with fewer corners has its first edge divided
/// into equal parts to make up the difference; no edge is ever a point.
public struct TileEdgeLayout {
    public let tileCount: Int
    public let edgeCount: Int

    // Each tile's outline as `edgeCount` points: point k lies the fraction `weight` of the
    // way from the mesh point `from` to the mesh point `to`. All [T, E].
    private let from: MLXArray
    private let to: MLXArray
    private let weight: MLXArray  // [T, E, 1]

    /// `tiles` holds each tile's corners, as indices into the mesh's points, in order.
    public init(tiles: [[Int]]) {
        let most = tiles.map(\.count).max() ?? 0
        let edges = max(8, (most + 3) / 4 * 4)
        var from: [Int32] = []
        var to: [Int32] = []
        var weight: [Float] = []
        for corners in tiles {
            precondition(corners.count >= 3, "a tile has at least three corners")
            let parts = edges - corners.count + 1
            for part in 0..<parts {
                from.append(Int32(corners[0]))
                to.append(Int32(corners[1]))
                weight.append(Float(part) / Float(parts))
            }
            for corner in corners.dropFirst() {
                from.append(Int32(corner))
                to.append(Int32(corner))
                weight.append(0)
            }
        }
        tileCount = tiles.count
        edgeCount = edges
        self.from = MLXArray(from, [tiles.count, edges])
        self.to = MLXArray(to, [tiles.count, edges])
        self.weight = MLXArray(weight, [tiles.count, edges, 1])
    }

    /// `points` [V, 2] are the mesh's points. Returns [T, E, 4]: for every edge of every
    /// tile its start x, start y, end x and end y. Differentiable by `points`.
    public func edges(points: MLXArray) -> MLXArray {
        let start = take(points, from, axis: 0)  // [T, E, 2]
        let outline = start + (take(points, to, axis: 0) - start) * weight
        let next = concatenated([outline[0..., 1..., 0...], outline[0..., 0..<1, 0...]], axis: 1)
        return concatenated([outline, next], axis: -1)
    }

    /// Each tile's area [T], positive for a sound tile (see `polygonArea`). Differentiable
    /// by `points`.
    public func areas(points: MLXArray) -> MLXArray {
        let edges = edges(points: points)
        let twice = edges[0..., 0..., 0] * edges[0..., 0..., 3] - edges[0..., 0..., 2] * edges[0..., 0..., 1]
        return twice.sum(axis: 1) / 2
    }
}
