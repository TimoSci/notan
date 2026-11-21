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
        fromIndex = from
        toIndex = to
        weights = weight
        self.from = MLXArray(from, [tiles.count, edges])
        self.to = MLXArray(to, [tiles.count, edges])
        self.weight = MLXArray(weight, [tiles.count, edges, 1])
    }

    // The same, for use on the CPU.
    private let fromIndex: [Int32]
    private let toIndex: [Int32]
    private let weights: [Float]

    /// `points` [V, 2] are the mesh's points. Returns each tile's outline [T, E, 2]: its
    /// corners, with the extra points along its first edge.
    public func outline(points: MLXArray) -> MLXArray {
        let start = take(points, from, axis: 0)  // [T, E, 2]
        return start + (take(points, to, axis: 0) - start) * weight
    }

    /// From outlines [T, E, 2] to [T, E, 4]: for every edge of every tile its start x,
    /// start y, end x and end y.
    public func edges(outline: MLXArray) -> MLXArray {
        let next = concatenated([outline[0..., 1..., 0...], outline[0..., 0..<1, 0...]], axis: 1)
        return concatenated([outline, next], axis: -1)
    }

    /// Each tile's area [T] from its outline, positive for a sound tile (see `polygonArea`).
    public func areas(outline: MLXArray) -> MLXArray {
        let edges = edges(outline: outline)
        let twice = edges[0..., 0..., 0] * edges[0..., 0..., 3] - edges[0..., 0..., 2] * edges[0..., 0..., 1]
        return twice.sum(axis: 1) / 2
    }

    /// `edges(outline:)` of `outline(points:)`. Differentiable by `points`, but see
    /// `pointGradient` before relying on that in a fit.
    public func edges(points: MLXArray) -> MLXArray { edges(outline: outline(points: points)) }

    /// `areas(outline:)` of `outline(points:)`.
    public func areas(points: MLXArray) -> MLXArray { areas(outline: outline(points: points)) }

    /// Carries a derivative by the outlines, `outlineGradient` (T × E × 2 numbers, as
    /// `outline(points:)` lays them out), back to the mesh's points: `pointCount` × 2
    /// numbers.
    ///
    /// MLX would do this itself, differentiating `outline(points:)`. But a point shared by
    /// several tiles collects a part from each, and on the GPU the order they are added
    /// in is not fixed, so the last digits differ from run to run, and a fit magnifies
    /// that into different tiles. Here they are added in one fixed order.
    public func pointGradient(outlineGradient: [Float], pointCount: Int) -> [Float] {
        precondition(outlineGradient.count == weights.count * 2)
        var gradient = [Float](repeating: 0, count: pointCount * 2)
        for index in weights.indices {
            let weight = weights[index]
            let a = Int(fromIndex[index]) * 2
            let b = Int(toIndex[index]) * 2
            for axis in 0..<2 {
                let part = outlineGradient[index * 2 + axis]
                gradient[a + axis] += (1 - weight) * part
                gradient[b + axis] += weight * part
            }
        }
        return gradient
    }
}
