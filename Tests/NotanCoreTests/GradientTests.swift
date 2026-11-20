import CoreGraphics
import MLX
import XCTest
@testable import NotanCore

final class GradientTests: XCTestCase {
    /// A shape covering a 64×64 picture, red at x = 16 running to blue at x = 48.
    func ramp() -> NotanCore.Shape {
        var shape = Shape.circle(center: SIMD2(32, 32), radius: 80, color: .red)
        shape.gradient = Gradient(from: SIMD2(16, 32), to: SIMD2(48, 32), endColor: .blue)
        return shape
    }

    /// A 48×48 target running from black on the left to white on the right.
    func rampTarget() -> TargetImage {
        makeTarget(width: 48, height: 48) { x, _ in RGB(r: x / 48, g: x / 48, b: x / 48) }
    }

    // MARK: Model

    func testShapesAreFlatUnlessGivenAGradient() {
        XCTAssertNil(Shape.circle(center: SIMD2(1, 1), radius: 1, color: .red).gradient)
    }

    func testAGradientCostsElevenMoreBytes() {
        let flat = Shape.circle(center: SIMD2(10, 10), radius: 5, color: .red)
        var picture = Picture(width: 32, height: 32, background: .black, shapes: [flat, flat])
        XCTAssertEqual(picture.estimatedBytes, 3 + 2 * 51)
        picture.shapes[1].gradient = Gradient(from: SIMD2(5, 10), to: SIMD2(15, 10), endColor: .blue)
        // A second colour (3 bytes) and two points (4 coordinates of 2 bytes).
        XCTAssertEqual(picture.estimatedBytes, 3 + 2 * 51 + 11)
    }

    func testGradientsInsideRefinementsAreCounted() {
        var child = Shape.circle(center: SIMD2(10, 10), radius: 2, color: .red)
        child.gradient = Gradient(from: SIMD2(8, 10), to: SIMD2(12, 10), endColor: .blue)
        var parent = Shape.circle(center: SIMD2(10, 10), radius: 5, color: .red)
        parent.inner = Inner(levels: [InnerLevel(shapes: [child], mse: 0)], shown: 0)
        let picture = Picture(width: 32, height: 32, background: .black, shapes: [parent])
        XCTAssertEqual(picture.estimatedBytes(maxDepth: 0), 3 + 51)
        XCTAssertEqual(picture.estimatedBytes(maxDepth: 1), 3 + 2 * 51 + 11)
    }

    // MARK: Soft raster

    func renderRamp() -> MLXArray {
        let shapes = [ramp()]
        return Rasterizer(width: 64, height: 64, softness: 0.25).render(
            points: pointsArray(shapes), colors: colorsArray(shapes),
            background: colorArray(.black), gradients: gradientArrays(shapes)
        ).image
    }

    func testRasteriserBlendsAlongTheAxis() {
        let image = renderRamp()
        func pixel(_ x: Int, _ y: Int) -> [Float] { image[y, x].asArray(Float.self) }
        // Pixel centres are at x + 0.5: x = 31.5 is 15.5/32 of the way along.
        XCTAssertEqual(pixel(31, 10)[0], 1 - 15.5 / 32, accuracy: 1e-3)
        XCTAssertEqual(pixel(31, 10)[2], 15.5 / 32, accuracy: 1e-3)
        XCTAssertEqual(pixel(31, 10)[1], 0, accuracy: 1e-3)
        XCTAssertEqual(pixel(23, 50)[2], 7.5 / 32, accuracy: 1e-3)
        // The same along the whole column: the colour depends only on the position along the axis.
        XCTAssertEqual(pixel(31, 60), pixel(31, 3))
    }

    func testRasteriserHoldsTheEndColoursBeyondTheAxis() {
        let image = renderRamp()
        XCTAssertEqual(image[32, 4].asArray(Float.self), [1, 0, 0])
        XCTAssertEqual(image[32, 60].asArray(Float.self), [0, 0, 1])
    }

    func testFlatShapesAreUnchangedAmongGradients() {
        let flat = Shape.circle(center: SIMD2(32, 32), radius: 10, color: .white)
        let shapes = [ramp(), flat]
        let image = Rasterizer(width: 64, height: 64, softness: 0.25).render(
            points: pointsArray(shapes), colors: colorsArray(shapes),
            background: colorArray(.black), gradients: gradientArrays(shapes)
        ).image
        XCTAssertEqual(image[32, 28].asArray(Float.self), [1, 1, 1])
        XCTAssertEqual(image[32, 36].asArray(Float.self), [1, 1, 1])
    }

    func testEndColourAndAxisReceiveGradient() {
        let shapes = [ramp()]
        let rasterizer = Rasterizer(width: 64, height: 64, softness: 0.5)
        let arrays = gradientArrays(shapes)
        let target = MLXArray.zeros([64, 64, 3])
        let lossAndGradient = valueAndGrad(
            { (inputs: [MLXArray]) -> [MLXArray] in
                let image = rasterizer.render(
                    points: pointsArray(shapes), colors: colorsArray(shapes),
                    background: colorArray(.black), gradients: (inputs[1], inputs[0])
                ).image
                return [plainMSE(image: image, target: target)]
            }, argumentNumbers: [0, 1])
        let (_, gradients) = lossAndGradient([arrays.endColors, arrays.axes])
        XCTAssertGreaterThan(abs(gradients[0]).sum().item(Float.self), 1e-4)
        XCTAssertGreaterThan(abs(gradients[1]).sum().item(Float.self), 1e-6)
    }

    // MARK: Fitting

    func fit(_ target: TargetImage, gradients: Bool, mode: LevelMode = .refit, shapes: Int = 2) -> [Level] {
        var settings = FitSettings(totalShapes: shapes, workingSize: 48, stepsPerStage: 80, mode: mode)
        settings.gradients = gradients
        return Fitter(target: target, settings: settings).run(progress: { _ in }, isCancelled: { false })
    }

    func testFlatFitHasNoGradients() {
        let levels = fit(rampTarget(), gradients: false)
        XCTAssertTrue(levels.last!.picture.shapes.allSatisfy { $0.gradient == nil })
    }

    func testGradientFitGivesEveryShapeAGradient() {
        let levels = fit(rampTarget(), gradients: true)
        XCTAssertEqual(levels.last!.picture.shapes.count, 2)
        XCTAssertTrue(levels.last!.picture.shapes.allSatisfy { $0.gradient != nil })
    }

    func testGradientFitFollowsARampFarBetterThanFlat() {
        let flat = fit(rampTarget(), gradients: false).last!.mse
        let graded = fit(rampTarget(), gradients: true).last!.mse
        XCTAssertLessThan(graded, flat * 0.4)
    }

    func testGradientColoursStayInRange() {
        for shape in fit(rampTarget(), gradients: true).last!.picture.shapes {
            let end = shape.gradient!.endColor
            for value in [end.r, end.g, end.b, shape.color.r, shape.color.g, shape.color.b] {
                XCTAssertTrue((0...1).contains(value))
            }
        }
    }

    func testPrefixPropertyHoldsWithGradients() {
        let levels = fit(rampTarget(), gradients: true, mode: .prefix, shapes: 4)
        for k in 0..<(levels.count - 1) {
            let earlier = levels[k].picture.shapes
            XCTAssertEqual(Array(levels[k + 1].picture.shapes.prefix(earlier.count)), earlier, "level \(k)")
        }
    }

    // MARK: Drawing and export

    func testDrawnPictureMatchesTheSoftRaster() throws {
        let picture = Picture(width: 64, height: 64, background: .black, shapes: [ramp()])
        let image = try XCTUnwrap(makeCGImage(picture, pixelSize: CGSize(width: 64, height: 64)))
        let hard = MLXArray(rgbPixels(of: image, width: 64, height: 64), [64, 64, 3])
        XCTAssertLessThan(abs(hard - renderRamp()).max().item(Float.self), 0.02)
    }

    func testMasksIgnoreGradients() {
        let picture = Picture(width: 64, height: 64, background: .black, shapes: [ramp()])
        let mask = renderRegion(
            picture, region: CGRect(x: 0, y: 0, width: 64, height: 64), width: 64, height: 64,
            style: .mask(of: .shape([0])))
        XCTAssertEqual(mask.min(), 1)
    }

    func testSVGWritesALinearGradient() throws {
        var flat = Shape.circle(center: SIMD2(10, 10), radius: 5, color: .white)
        flat.inner = Inner(levels: [InnerLevel(shapes: [ramp()], mse: 0)], shown: 0)
        let picture = Picture(width: 64, height: 64, background: .black, shapes: [ramp(), flat])
        let text = svg(picture, outputSize: CGSize(width: 640, height: 640))
        let root = try XCTUnwrap(XMLDocument(xmlString: text).rootElement())

        let gradients = root.elements(forName: "linearGradient")
        XCTAssertEqual(gradients.count, 1)  // the second is inside the refinement's group
        let gradient = gradients[0]
        XCTAssertEqual(gradient.attribute(forName: "gradientUnits")?.stringValue, "userSpaceOnUse")
        XCTAssertEqual(gradient.attribute(forName: "x1")?.stringValue, "16")
        XCTAssertEqual(gradient.attribute(forName: "y1")?.stringValue, "32")
        XCTAssertEqual(gradient.attribute(forName: "x2")?.stringValue, "48")
        XCTAssertEqual(gradient.attribute(forName: "y2")?.stringValue, "32")
        let stops = gradient.elements(forName: "stop")
        XCTAssertEqual(stops.map { $0.attribute(forName: "stop-color")?.stringValue }, ["#ff0000", "#0000ff"])
        XCTAssertEqual(stops.map { $0.attribute(forName: "offset")?.stringValue }, ["0", "1"])

        let paths = root.elements(forName: "path")
        let id = try XCTUnwrap(gradient.attribute(forName: "id")?.stringValue)
        XCTAssertEqual(paths[0].attribute(forName: "fill")?.stringValue, "url(#\(id))")
        XCTAssertEqual(paths[1].attribute(forName: "fill")?.stringValue, "#ffffff")
        // Every gradient has its own id.
        XCTAssertEqual(text.components(separatedBy: "<linearGradient id=\"g1\"").count, 2)
        XCTAssertEqual(text.components(separatedBy: "<linearGradient id=\"g2\"").count, 2)
    }

    // MARK: Refining

    func testRefinedGradientsAreInPictureCoordinates() throws {
        // A 256×256 photo: white, with a disc in its lower-right quarter that runs from
        // black on its left to red on its right.
        let image = Fixtures.image(width: 256, height: 256) { context in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.addEllipse(in: CGRect(x: 136, y: 136, width: 104, height: 104))
            context.clip()
            let colors =
                [
                    CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                    CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                ] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 136, y: 0), end: CGPoint(x: 240, y: 0), options: [])
        }
        let photo = Fixtures.write(image, name: "ramp-disc.png")
        // The picture is 64×64: the disc is centred on (47, 47) with radius 13.
        let picture = Picture(
            width: 64, height: 64, background: .white,
            shapes: [Shape.circle(center: SIMD2(47, 47), radius: 13, color: RGB(r: 0.5, g: 0, b: 0))])
        var settings = FitSettings(totalShapes: 1, workingSize: 64, stepsPerStage: 80)
        settings.gradients = true
        let levels = try Refiner(photoURL: photo, picture: picture, node: .shape([0]), settings: settings)
            .run(progress: { _ in }, isCancelled: { false })

        let gradient = try XCTUnwrap(levels[1].shapes[0].gradient)
        // Both ends lie near the disc, not near where it sat in the zoomed fit.
        for point in [gradient.from, gradient.to] {
            XCTAssertTrue((30...64).contains(point.x), "\(point)")
            XCTAssertTrue((30...64).contains(point.y), "\(point)")
        }
        // Redder toward the right.
        let (left, right) =
            gradient.from.x < gradient.to.x
            ? (levels[1].shapes[0].color, gradient.endColor)
            : (gradient.endColor, levels[1].shapes[0].color)
        XCTAssertGreaterThan(right.r, left.r + 0.1)
    }
}
