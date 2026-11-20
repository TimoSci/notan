import XCTest

@testable import LayerFitCore

final class WindowLayoutTests: XCTestCase {
    func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> PixelRect {
        PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Crops of many sizes on a 96 × 64 picture, some of them empty.
    var crops: [PixelRect] {
        [
            rect(10, 10, 20, 22), rect(0, 0, 96, 64), rect(40, 5, 45, 9), rect(0, 0, 0, 0),
            rect(80, 50, 96, 64), rect(30, 20, 70, 60), rect(5, 0, 90, 30), rect(50, 50, 50, 60),
            rect(12, 12, 21, 21), rect(60, 30, 84, 54),
        ]
    }

    func testEmptyCropsAreLeftOut() {
        let layout = WindowLayout(crops: crops, width: 96, height: 64)
        XCTAssertEqual(layout.drawn, [0, 1, 2, 4, 5, 6, 8, 9])
        let none = WindowLayout(crops: [rect(0, 0, 0, 0)], width: 96, height: 64)
        XCTAssertTrue(none.drawn.isEmpty)
        XCTAssertTrue(none.table.isEmpty)
        XCTAssertEqual(none.stripLength, 0)
        XCTAssertEqual(none.rowCount, 0)
    }

    func testEachDrawnShapeGetsItsCropAsItsWindow() {
        let layout = WindowLayout(crops: crops, width: 96, height: 64)
        XCTAssertEqual(layout.windows, layout.drawn.map { crops[$0] })
    }

    func testWindowsAreCutToThePicture() {
        let layout = WindowLayout(
            crops: [rect(-5, -7, 10, 12), rect(90, 60, 120, 80), rect(100, 10, 110, 20)],
            width: 96, height: 64)
        XCTAssertEqual(layout.drawn, [0, 1])  // the last lies wholly outside
        XCTAssertEqual(layout.windows, [rect(0, 0, 10, 12), rect(90, 60, 96, 64)])
    }

    /// The table has, for each drawn shape: left, top, width, height, the strip element
    /// of its first pixel and the number of window rows before it.
    func testTableSaysWhereEachWindowLies() {
        let layout = WindowLayout(
            crops: [rect(2, 3, 6, 5), rect(0, 0, 0, 0), rect(0, 0, 3, 2), rect(7, 1, 8, 6)],
            width: 16, height: 16)
        XCTAssertEqual(WindowLayout.fields, 6)
        XCTAssertEqual(
            layout.table,
            [
                2, 3, 4, 2, 0, 0,
                0, 0, 3, 2, 8, 2,
                7, 1, 1, 5, 14, 4,
            ])
        XCTAssertEqual(layout.stripLength, 19)
        XCTAssertEqual(layout.rowCount, 9)
    }

    func testWindowsFollowOneAnotherInTheStrip() {
        let layout = WindowLayout(crops: crops, width: 96, height: 64)
        var element = 0
        var row = 0
        for (index, window) in layout.windows.enumerated() {
            let entry = Array(layout.table[(index * 6)..<(index * 6 + 6)]).map { Int($0) }
            let width = window.x1 - window.x0
            let height = window.y1 - window.y0
            XCTAssertEqual(entry, [window.x0, window.y0, width, height, element, row])
            element += width * height
            row += height
        }
        XCTAssertEqual(layout.stripLength, element)
        XCTAssertEqual(layout.rowCount, row)
    }
}
