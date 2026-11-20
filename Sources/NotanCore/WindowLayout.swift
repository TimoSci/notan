import Foundation

/// Where each shape of one render is rasterised: a window of pixels around it, in place of
/// the whole picture. A shape's window is its crop rectangle, cut to the picture.
///
/// The pixels of all the windows are laid end to end in one strip: window after window in
/// paint order, each window row by row. `table` tells the GPU where every window lies, in
/// the picture and in the strip.
struct WindowLayout {
    /// The shapes that are drawn at all, in paint order: those whose window is not empty.
    let drawn: [Int]
    /// The window of each drawn shape.
    let windows: [PixelRect]
    /// `fields` numbers for each drawn shape: its window's left column, top row, width and
    /// height, then the strip element of the window's first pixel, then how many window
    /// rows the drawn shapes before it have between them.
    let table: [Int32]
    static let fields = 6
    /// How many window pixels the drawn shapes have between them.
    let stripLength: Int
    /// How many window rows the drawn shapes have between them.
    let rowCount: Int

    /// `crops` holds one rectangle per shape.
    init(crops: [PixelRect], width: Int, height: Int) {
        var drawn: [Int] = []
        var windows: [PixelRect] = []
        var table: [Int32] = []
        var element = 0
        var row = 0
        for (shape, crop) in crops.enumerated() {
            let window = PixelRect(
                x0: max(crop.x0, 0), y0: max(crop.y0, 0), x1: min(crop.x1, width),
                y1: min(crop.y1, height))
            if window.isEmpty { continue }
            let across = window.x1 - window.x0
            let down = window.y1 - window.y0
            precondition(
                element + across * down <= Int(Int32.max), "too many window pixels for one render")
            drawn.append(shape)
            windows.append(window)
            table += [window.x0, window.y0, across, down, element, row].map { Int32($0) }
            element += across * down
            row += down
        }
        self.drawn = drawn
        self.windows = windows
        self.table = table
        self.stripLength = element
        self.rowCount = row
    }
}
