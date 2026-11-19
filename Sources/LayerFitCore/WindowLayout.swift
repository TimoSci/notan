import Foundation

/// Where each shape of one render is rasterised: a window of pixels around it, in place of
/// the whole picture. Windows come in a few fixed sizes, and shapes whose windows are the
/// same size are grouped into batches, each rasterised in one go.
///
/// The rasterised windows are then laid end to end in one strip, each with a spare last
/// row and a spare last column that stand for "outside this window". `rows` and `columns`
/// say where in that strip every picture pixel of every drawn shape is found.
struct WindowLayout {
    /// Shapes rasterised together, each over its own window of the same size.
    struct Batch: Equatable {
        /// Which shapes, as indices into the render's shapes.
        var shapes: [Int]
        var width: Int
        var height: Int
        /// The top-left pixel of each shape's window.
        var originsX: [Int]
        var originsY: [Int]
    }

    let batches: [Batch]
    /// The shapes that are drawn at all, in paint order.
    let drawn: [Int]
    /// Picture pixel (y, x) of the i-th drawn shape is strip element
    /// `rows[i * pictureHeight + y] + columns[i * pictureWidth + x]`.
    let rows: [Int32]
    let columns: [Int32]
    let stripLength: Int

    /// The smallest window side that covers `need` pixels and is no more than `limit`, or
    /// nil if there is none. Sides run 16, 24, 32, 48, 64, 96 and so on. Each is at most
    /// half again the one before, so a window is never much bigger than its shape needs,
    /// yet few enough sizes are in use at once for the batches to stay large.
    static func side(covering need: Int, limit: Int) -> Int? {
        var power = 16
        while true {
            for side in [power, power + power / 2] {
                if side > limit { return nil }
                if side >= need { return side }
            }
            power *= 2
        }
    }

    /// `crops` holds one rectangle per shape; a shape with an empty one is not drawn. Each
    /// window covers its shape's rectangle, and usually a little more. A shape too big for
    /// any square window that fits in the picture gets the whole picture.
    /// `budget` is the most window pixels one batch may hold, unless it holds one shape.
    init(crops: [PixelRect], width: Int, height: Int, budget: Int) {
        let wholePicture = Int.max
        var groups: [Int: [Int]] = [:]
        for (shape, crop) in crops.enumerated() where !crop.isEmpty {
            let need = max(crop.x1 - crop.x0, crop.y1 - crop.y0)
            let side = WindowLayout.side(covering: need, limit: min(width, height)) ?? wholePicture
            groups[side, default: []].append(shape)
        }

        struct Placement {
            var x0 = 0, y0 = 0, width = 0, height = 0, offset = 0
        }
        var placements = [Placement](repeating: Placement(), count: crops.count)
        var batches: [Batch] = []
        var length = 0
        for side in groups.keys.sorted() {
            let windowWidth = side == wholePicture ? width : side
            let windowHeight = side == wholePicture ? height : side
            let padded = (windowWidth + 1) * (windowHeight + 1)
            let members = groups[side]!
            let perBatch = max(1, budget / (windowWidth * windowHeight))
            for start in stride(from: 0, to: members.count, by: perBatch) {
                let shapes = Array(members[start..<min(start + perBatch, members.count)])
                // Pushed back inside the picture where the rectangle is near its far edges.
                let originsX = shapes.map { min(crops[$0].x0, width - windowWidth) }
                let originsY = shapes.map { min(crops[$0].y0, height - windowHeight) }
                for (position, shape) in shapes.enumerated() {
                    placements[shape] = Placement(
                        x0: originsX[position], y0: originsY[position], width: windowWidth,
                        height: windowHeight, offset: length + position * padded)
                }
                length += shapes.count * padded
                batches.append(
                    Batch(
                        shapes: shapes, width: windowWidth, height: windowHeight,
                        originsX: originsX, originsY: originsY))
            }
        }
        precondition(length <= Int(Int32.max), "too many window pixels for one render")

        let drawn = crops.indices.filter { !crops[$0].isEmpty }
        var rows: [Int32] = []
        var columns: [Int32] = []
        rows.reserveCapacity(drawn.count * height)
        columns.reserveCapacity(drawn.count * width)
        for shape in drawn {
            let place = placements[shape]
            for y in 0..<height {
                let row = y >= place.y0 && y < place.y0 + place.height ? y - place.y0 : place.height
                rows.append(Int32(place.offset + row * (place.width + 1)))
            }
            for x in 0..<width {
                columns.append(
                    Int32(x >= place.x0 && x < place.x0 + place.width ? x - place.x0 : place.width))
            }
        }
        self.batches = batches
        self.drawn = drawn
        self.rows = rows
        self.columns = columns
        self.stripLength = length
    }
}
