import Foundation
@testable import LayerFitCore

extension RGB {
    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 1, g: 1, b: 1)
    static let grey = RGB(r: 0.5, g: 0.5, b: 0.5)
    static let red = RGB(r: 1, g: 0, b: 0)
    static let blue = RGB(r: 0, g: 0, b: 1)
}

/// A synthetic target: `paint` returns the colour of the pixel whose centre is (x + 0.5, y + 0.5).
func makeTarget(width: Int, height: Int, paint: (Float, Float) -> RGB) -> TargetImage {
    var pixels = [Float](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let c = paint(Float(x) + 0.5, Float(y) + 0.5)
            let i = (y * width + x) * 3
            pixels[i] = c.r
            pixels[i + 1] = c.g
            pixels[i + 2] = c.b
        }
    }
    return TargetImage(width: width, height: height, pixels: pixels)
}

func flatPixels(width: Int, height: Int, color: RGB) -> [Float] {
    makeTarget(width: width, height: height) { _, _ in color }.pixels
}

func inDisc(_ x: Float, _ y: Float, _ cx: Float, _ cy: Float, _ r: Float) -> Bool {
    (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
}

func centroid(_ shape: LayerFitCore.Shape) -> SIMD2<Float> {
    let polygon = samplePolygon(shape.points, samplesPerSegment: 8)
    return polygon.reduce(SIMD2<Float>(0, 0), +) / Float(polygon.count)
}
