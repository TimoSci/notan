import XCTest

@testable import LayerFitCore

final class WindowLayoutTests: XCTestCase {
    func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> PixelRect {
        PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Crops of many sizes on a 96 × 64 picture: some empty, some at the borders, two too
    /// big for any square window.
    var crops: [PixelRect] {
        [
            rect(10, 10, 20, 22), rect(0, 0, 96, 64), rect(40, 5, 45, 9), rect(0, 0, 0, 0),
            rect(80, 50, 96, 64), rect(30, 20, 70, 60), rect(5, 0, 90, 30), rect(50, 50, 50, 60),
            rect(12, 12, 21, 21), rect(60, 30, 84, 54),
        ]
    }

    func testSideIsTheSmallestWindowThatCovers() {
        XCTAssertEqual(WindowLayout.side(covering: 1, limit: 256), 16)
        XCTAssertEqual(WindowLayout.side(covering: 16, limit: 256), 16)
        XCTAssertEqual(WindowLayout.side(covering: 17, limit: 256), 24)
        XCTAssertEqual(WindowLayout.side(covering: 25, limit: 256), 32)
        XCTAssertEqual(WindowLayout.side(covering: 100, limit: 256), 128)
        XCTAssertEqual(WindowLayout.side(covering: 129, limit: 256), 192)
        XCTAssertEqual(WindowLayout.side(covering: 256, limit: 256), 256)
        XCTAssertEqual(WindowLayout.side(covering: 300, limit: 512), 384)
    }

    func testNoWindowWhenNoneFitsInThePicture() {
        // The next size up from 150 is 192, which a picture 170 pixels high cannot hold.
        XCTAssertNil(WindowLayout.side(covering: 150, limit: 170))
        XCTAssertNil(WindowLayout.side(covering: 257, limit: 256))
        XCTAssertNil(WindowLayout.side(covering: 5, limit: 10))
        XCTAssertEqual(WindowLayout.side(covering: 128, limit: 170), 128)
    }

    func testEveryWindowHoldsItsCropInsideThePicture() {
        let layout = WindowLayout(crops: crops, width: 96, height: 64, budget: 1 << 20)
        var seen: [Int] = []
        for batch in layout.batches {
            XCTAssertEqual(batch.originsX.count, batch.shapes.count)
            XCTAssertEqual(batch.originsY.count, batch.shapes.count)
            for (position, shape) in batch.shapes.enumerated() {
                let crop = crops[shape]
                let x0 = batch.originsX[position]
                let y0 = batch.originsY[position]
                XCTAssertLessThanOrEqual(x0, crop.x0)
                XCTAssertLessThanOrEqual(y0, crop.y0)
                XCTAssertGreaterThanOrEqual(x0 + batch.width, crop.x1)
                XCTAssertGreaterThanOrEqual(y0 + batch.height, crop.y1)
                XCTAssertGreaterThanOrEqual(x0, 0)
                XCTAssertGreaterThanOrEqual(y0, 0)
                XCTAssertLessThanOrEqual(x0 + batch.width, 96)
                XCTAssertLessThanOrEqual(y0 + batch.height, 64)
                seen.append(shape)
            }
        }
        XCTAssertEqual(seen.sorted(), layout.drawn)
    }

    func testEmptyCropsAreLeftOut() {
        let layout = WindowLayout(crops: crops, width: 96, height: 64, budget: 1 << 20)
        XCTAssertEqual(layout.drawn, [0, 1, 2, 4, 5, 6, 8, 9])
        let none = WindowLayout(crops: [rect(0, 0, 0, 0)], width: 96, height: 64, budget: 1 << 20)
        XCTAssertTrue(none.drawn.isEmpty)
        XCTAssertTrue(none.batches.isEmpty)
    }

    func testWindowsAreNoBiggerThanNeeded() {
        let layout = WindowLayout(crops: crops, width: 96, height: 64, budget: 1 << 20)
        var sizes: [Int: [Int]] = [:]
        for batch in layout.batches {
            for shape in batch.shapes { sizes[shape] = [batch.width, batch.height] }
        }
        XCTAssertEqual(sizes[0], [16, 16])  // 10 × 12
        XCTAssertEqual(sizes[2], [16, 16])  // 5 × 4
        XCTAssertEqual(sizes[4], [16, 16])  // 16 × 14, in the corner
        XCTAssertEqual(sizes[8], [16, 16])  // 9 × 9
        XCTAssertEqual(sizes[9], [24, 24])  // 24 × 24
        XCTAssertEqual(sizes[5], [48, 48])  // 40 × 40
        XCTAssertEqual(sizes[1], [96, 64])  // the whole picture
        XCTAssertEqual(sizes[6], [96, 64])  // 85 wide: no square window fits in 64 rows
    }

    func testShapesWithTheSameWindowSizeShareABatch() {
        let layout = WindowLayout(crops: crops, width: 96, height: 64, budget: 1 << 20)
        XCTAssertEqual(layout.batches.count, 4)
        XCTAssertEqual(layout.batches.first { $0.width == 16 }?.shapes, [0, 2, 4, 8])
    }

    func testBatchesStayWithinTheBudget() {
        // Room for two 16 × 16 windows, and for less than one of anything bigger.
        let layout = WindowLayout(crops: crops, width: 96, height: 64, budget: 600)
        for batch in layout.batches {
            let pixels = batch.shapes.count * batch.width * batch.height
            XCTAssertTrue(pixels <= 600 || batch.shapes.count == 1, "\(batch)")
        }
        XCTAssertEqual(layout.batches.filter { $0.width == 16 }.map(\.shapes), [[0, 2], [4, 8]])
        XCTAssertEqual(layout.drawn, [0, 1, 2, 4, 5, 6, 8, 9])
    }

    /// The windows are laid end to end in one strip, each with a spare row and column that
    /// stand for "outside this window". Looking a picture pixel up through `rows` and
    /// `columns` must land on that shape's own window pixel, or on a spare one.
    func testPicturePixelsReadTheirOwnWindowPixel() {
        for budget in [1 << 20, 600] {
            let layout = WindowLayout(crops: crops, width: 96, height: 64, budget: budget)
            // Each strip element is labelled with the shape and picture pixel it holds.
            var strip: [Int] = []
            for batch in layout.batches {
                for (position, shape) in batch.shapes.enumerated() {
                    for row in 0...batch.height {
                        for column in 0...batch.width {
                            let spare = row == batch.height || column == batch.width
                            let y = batch.originsY[position] + row
                            let x = batch.originsX[position] + column
                            strip.append(spare ? -1 : shape * 1_000_000 + y * 1000 + x)
                        }
                    }
                }
            }
            XCTAssertEqual(layout.stripLength, strip.count)
            XCTAssertEqual(layout.rows.count, layout.drawn.count * 64)
            XCTAssertEqual(layout.columns.count, layout.drawn.count * 96)
            var windows: [Int: PixelRect] = [:]
            for batch in layout.batches {
                for (position, shape) in batch.shapes.enumerated() {
                    let x0 = batch.originsX[position]
                    let y0 = batch.originsY[position]
                    windows[shape] = rect(x0, y0, x0 + batch.width, y0 + batch.height)
                }
            }
            for (index, shape) in layout.drawn.enumerated() {
                let window = windows[shape]!
                var wrong = 0
                for y in 0..<64 {
                    for x in 0..<96 {
                        let found =
                            strip[Int(layout.rows[index * 64 + y] + layout.columns[index * 96 + x])]
                        let inside = x >= window.x0 && x < window.x1 && y >= window.y0 && y < window.y1
                        if found != (inside ? shape * 1_000_000 + y * 1000 + x : -1) { wrong += 1 }
                    }
                }
                XCTAssertEqual(wrong, 0, "shape \(shape), budget \(budget)")
            }
        }
    }
}
