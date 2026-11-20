import CoreGraphics
import MLX
import XCTest
@testable import LayerFitCore

final class RefineTests: XCTestCase {
    // MARK: Masking in the rasteriser, loss and seeds

    func testRasteriserMaskConfinesShapes() {
        let circle = Shape.circle(center: SIMD2(16, 16), radius: 10, color: .white)
        var mask = [Float](repeating: 0, count: 32 * 32)
        for y in 0..<32 { for x in 0..<16 { mask[y * 32 + x] = 1 } }  // left half only
        let image = Rasterizer(width: 32, height: 32).render(
            points: pointsArray([circle]), colors: colorsArray([circle]),
            background: colorArray(.black), mask: MLXArray(mask, [32, 32])
        ).image
        XCTAssertGreaterThan(image[16, 10, 0].item(Float.self), 0.95)
        XCTAssertEqual(image[16, 20, 0].item(Float.self), 0)
    }

    func testLossIgnoresErrorOutsideMask() {
        var mask = [Float](repeating: 0, count: 64)
        mask[0] = 1
        mask[1] = 1
        let maskArray = MLXArray(mask, [8, 8])
        let target = MLXArray.zeros([8, 8, 3])
        func loss(errorAt index: Int) -> Float {
            var pixels = [Float](repeating: 0, count: 64 * 3)
            pixels[index * 3] = 1
            return fitLoss(
                image: MLXArray(pixels, [8, 8, 3]), target: target,
                boundaryDistance: MLXArray.zeros([8, 8]) + Rasterizer.noBoundary,
                points: pointsArray([]), config: LossConfig(), mask: maskArray
            ).item(Float.self)
        }
        XCTAssertEqual(loss(errorAt: 40), 0)
        // One of the two masked pixels is wrong by 1 in one channel: floor term 1 / 2.
        XCTAssertEqual(loss(errorAt: 0), LossConfig().floorWeight * 0.5, accuracy: 1e-4)
    }

    func testMaskedMSE() {
        var mask = [Float](repeating: 0, count: 16)
        mask[0] = 1
        var pixels = [Float](repeating: 0.5, count: 48)
        pixels[0] = 1  // only the masked pixel's red channel is right
        let value = maskedMSE(
            image: MLXArray(pixels, [4, 4, 3]), target: MLXArray.ones([4, 4, 3]),
            mask: MLXArray(mask, [4, 4])
        ).item(Float.self)
        XCTAssertEqual(value, (0 + 0.25 + 0.25) / 3, accuracy: 1e-5)
    }

    /// Grey 64×64 with a red 20×20 square at (8...27, 8...27) and a blue 8×8 at (44...51, 44...51).
    func twoSquares() -> TargetImage {
        makeTarget(width: 64, height: 64) { x, y in
            if (8..<28).contains(x) && (8..<28).contains(y) { return .red }
            if (44..<52).contains(x) && (44..<52).contains(y) { return .blue }
            return .grey
        }
    }

    func testSeedsStayInsideMask() {
        // The red square holds more error, but only the bottom-right quarter is in play.
        var mask = [Float](repeating: 0, count: 64 * 64)
        for y in 32..<64 { for x in 32..<64 { mask[y * 64 + x] = 1 } }
        let seeds = findSeeds(
            target: twoSquares(), current: flatPixels(width: 64, height: 64, color: .grey),
            count: 1, mask: mask)
        XCTAssertEqual(seeds[0].color, .blue)
        XCTAssertTrue((44..<52).contains(seeds[0].center.x) && (44..<52).contains(seeds[0].center.y))
    }

    func testFallbackSeedsStayInsideMask() {
        let target = twoSquares()
        var mask = [Float](repeating: 0, count: 64 * 64)
        for y in 10..<30 { for x in 40..<60 { mask[y * 64 + x] = 1 } }
        let seeds = findSeeds(target: target, current: target.pixels, count: 3, mask: mask)
        XCTAssertEqual(seeds.count, 3)
        for seed in seeds {
            XCTAssertTrue((40..<60).contains(seed.center.x) && (10..<30).contains(seed.center.y), "\(seed.center)")
        }
    }

    // MARK: Fitting inside a region

    func testFitterWithRegionOnlyWorksInsideTheMask() {
        // Two discs on grey, an all-grey base, and only the right half in play: the fit must
        // find the blue disc and leave the red one alone.
        let target = makeTarget(width: 48, height: 48) { x, y in
            if inDisc(x, y, 12, 16, 8) { return .red }
            if inDisc(x, y, 35, 31, 9) { return .blue }
            return .grey
        }
        var mask = [Float](repeating: 0, count: 48 * 48)
        for y in 0..<48 { for x in 24..<48 { mask[y * 48 + x] = 1 } }
        let region = FitRegion(base: flatPixels(width: 48, height: 48, color: .grey), mask: mask)
        let settings = FitSettings(totalShapes: 2, workingSize: 48, stepsPerStage: 60, mode: .refit)
        let levels = Fitter(target: target, settings: settings, region: region)
            .run(progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(levels.map { $0.picture.shapes.count }, [0, 1, 2])
        XCTAssertLessThan(levels[2].mse, levels[0].mse * 0.3)
        let first = levels[1].picture.shapes[0]
        XCTAssertGreaterThan(first.color.b, 0.7)
        XCTAssertLessThan(first.color.r, 0.3)
        XCTAssertEqual(centroid(first).x, 35, accuracy: 3)
        XCTAssertEqual(centroid(first).y, 31, accuracy: 3)
    }

    func testFitterWithRegionInPrefixModeKeepsPrefixProperty() {
        let target = makeTarget(width: 48, height: 48) { x, y in
            inDisc(x, y, 30, 24, 10) ? .blue : .grey
        }
        let region = FitRegion(
            base: flatPixels(width: 48, height: 48, color: .grey),
            mask: [Float](repeating: 1, count: 48 * 48))
        let settings = FitSettings(totalShapes: 3, workingSize: 48, stepsPerStage: 30, mode: .prefix)
        let levels = Fitter(target: target, settings: settings, region: region)
            .run(progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(levels.count, 4)
        for k in 0..<3 {
            let earlier = levels[k].picture.shapes
            XCTAssertEqual(Array(levels[k + 1].picture.shapes.prefix(earlier.count)), earlier)
        }
    }

    // MARK: Planning the zoom

    func testPlanZoomsToTheShapeWithAMargin() throws {
        // Blue circle: centre (48, 32), radius 8 → box 40…56 × 24…40, plus 4% each side.
        let plan = try XCTUnwrap(
            refinePlan(
                picture: treePicture(), node: .shape([1]),
                originalPixelSize: CGSize(width: 6400, height: 6400), workingSize: 256))
        XCTAssertEqual(plan.viewport.minX, 39.36, accuracy: 0.05)
        XCTAssertEqual(plan.viewport.minY, 23.36, accuracy: 0.05)
        XCTAssertEqual(plan.viewport.width, 17.28, accuracy: 0.1)
        XCTAssertEqual(plan.viewport.height, 17.28, accuracy: 0.1)
        XCTAssertEqual(plan.width, 256)
        XCTAssertEqual(plan.height, 256)
    }

    func testPlanDoesNotZoomPastThePhotosOwnPixels() throws {
        // 10 photo pixels per picture pixel: the 17.28 px viewport has only ~173 real pixels.
        let plan = try XCTUnwrap(
            refinePlan(
                picture: treePicture(), node: .shape([1]),
                originalPixelSize: CGSize(width: 640, height: 640), workingSize: 256))
        XCTAssertEqual(plan.width, 173)
        XCTAssertEqual(plan.height, 173)
    }

    func testPlanClampsToThePicture() throws {
        var picture = treePicture()
        picture.shapes[1] = Shape.circle(center: SIMD2(60, 4), radius: 10, color: .blue)
        let plan = try XCTUnwrap(
            refinePlan(
                picture: picture, node: .shape([1]),
                originalPixelSize: CGSize(width: 6400, height: 6400), workingSize: 256))
        XCTAssertGreaterThanOrEqual(plan.viewport.minY, 0)
        XCTAssertLessThanOrEqual(plan.viewport.maxX, 64)
        XCTAssertEqual(plan.viewport.maxX, 64, accuracy: 1e-3)
        XCTAssertEqual(max(plan.width, plan.height), 256)
        XCTAssertLessThan(plan.width, plan.height + 1)
    }

    func testPlanForBackgroundIsTheWholePicture() throws {
        let plan = try XCTUnwrap(
            refinePlan(
                picture: treePicture(), node: .background,
                originalPixelSize: CGSize(width: 6400, height: 6400), workingSize: 128))
        XCTAssertEqual(plan.viewport, CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(plan.width, 128)
    }

    func testPlanForMissingNodeIsNil() {
        XCTAssertNil(
            refinePlan(
                picture: treePicture(), node: .shape([9]),
                originalPixelSize: CGSize(width: 640, height: 640), workingSize: 256))
    }

    // MARK: Loading part of the photo

    func testLoadPhotoRegionCropsInPictureCoordinates() throws {
        let image = Fixtures.image(width: 400, height: 200) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            context.fill(CGRect(x: 300, y: 80, width: 40, height: 40))
        }
        let url = Fixtures.write(image, name: "region.png")
        // The picture is 200×100, so the green square is at (150, 40), 20×20.
        let target = try loadPhotoRegion(
            url: url, region: CGRect(x: 150, y: 40, width: 20, height: 20),
            pictureWidth: 200, pictureHeight: 100, width: 32, height: 32)
        XCTAssertEqual(target.width, 32)
        XCTAssertEqual(target.color(x: 16, y: 16), RGB(r: 0, g: 1, b: 0))
        XCTAssertEqual(target.color(x: 1, y: 1), RGB(r: 0, g: 1, b: 0))
        let wider = try loadPhotoRegion(
            url: url, region: CGRect(x: 140, y: 40, width: 40, height: 20),
            pictureWidth: 200, pictureHeight: 100, width: 40, height: 20)
        XCTAssertEqual(wider.color(x: 2, y: 10), .red)
        XCTAssertEqual(wider.color(x: 20, y: 10), RGB(r: 0, g: 1, b: 0))
    }

    func testLoadPhotoRegionAppliesOrientation() throws {
        // Stored 200×100 with the left half red; orientation 6 puts red at the top of a
        // 100×200 upright picture.
        let image = Fixtures.image(width: 200, height: 100) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let url = Fixtures.write(image, name: "region-rotated.jpg", type: .jpeg, orientation: 6)
        let top = try loadPhotoRegion(
            url: url, region: CGRect(x: 10, y: 10, width: 30, height: 30),
            pictureWidth: 50, pictureHeight: 100, width: 16, height: 16)
        XCTAssertGreaterThan(top.color(x: 8, y: 8).r, 0.8)
        let bottom = try loadPhotoRegion(
            url: url, region: CGRect(x: 10, y: 60, width: 30, height: 30),
            pictureWidth: 50, pictureHeight: 100, width: 16, height: 16)
        XCTAssertGreaterThan(bottom.color(x: 8, y: 8).b, 0.8)
    }

    func testLoadPhotoRegionOfUnreadableFileThrows() throws {
        let url = Fixtures.directory.appendingPathComponent("region-junk.png")
        try Data("nope".utf8).write(to: url)
        XCTAssertThrowsError(
            try loadPhotoRegion(
                url: url, region: CGRect(x: 0, y: 0, width: 10, height: 10), pictureWidth: 20,
                pictureHeight: 20, width: 8, height: 8))
    }

    // MARK: Refining end to end

    /// A 256×256 photo: white, a red disc, and inside it a smaller blue disc.
    func discPhoto() -> URL {
        let image = Fixtures.image(width: 256, height: 256) { context in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fillEllipse(in: CGRect(x: 38, y: 38, width: 180, height: 180))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fillEllipse(in: CGRect(x: 125, y: 95, width: 50, height: 50))
        }
        return Fixtures.write(image, name: "disc-in-disc.png")
    }

    /// The 64×64 picture a first fit would give: the red disc only.
    func discPicture() -> LayerFitCore.Picture {
        LayerFitCore.Picture(
            width: 64, height: 64, background: .white,
            shapes: [Shape.circle(center: SIMD2(32, 32), radius: 22.5, color: .red)])
    }

    func testRefinerFindsDetailInsideTheShape() throws {
        var reports: [RefineProgress] = []
        let settings = FitSettings(totalShapes: 1, workingSize: 64, stepsPerStage: 80)
        let levels = try Refiner(
            photoURL: discPhoto(), picture: discPicture(), node: .shape([0]), settings: settings
        ).run(progress: { reports.append($0) }, isCancelled: { false })

        XCTAssertEqual(levels.map { $0.shapes.count }, [0, 1])
        XCTAssertLessThan(levels[1].mse, levels[0].mse * 0.3)
        let child = levels[1].shapes[0]
        XCTAssertGreaterThan(child.color.b, 0.7)
        XCTAssertLessThan(child.color.r, 0.3)
        // The blue disc's centre is (150, 120) in the photo: (37.5, 30) in picture coordinates.
        XCTAssertEqual(centroid(child).x, 37.5, accuracy: 2)
        XCTAssertEqual(centroid(child).y, 30, accuracy: 2)
        XCTAssertEqual(meanWidth(of: child), 6.25, accuracy: 1.5)  // radius 25 / 4
        XCTAssertEqual(reports.compactMap { $0.finishedLevel?.shapes.count }, [0, 1])
        XCTAssertEqual(reports.last?.stageCount, 1)
    }

    /// The same, but the red disc is a locked area on top of a later level whose own
    /// shape, a black disc, would hide it.
    func testRefinerWorksInsideALockedArea() throws {
        var later = LayerFitCore.Picture(
            width: 64, height: 64, background: .white,
            shapes: [Shape.circle(center: SIMD2(32, 32), radius: 40, color: .black)])
        later.locked = [LockedArea(picture: discPicture(), node: .shape([0]))]
        let settings = FitSettings(totalShapes: 1, workingSize: 64, stepsPerStage: 80)
        let levels = try Refiner(
            photoURL: discPhoto(), picture: later, node: NodeID.shape([0]).inLocked(0),
            settings: settings
        ).run(progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(levels.map { $0.shapes.count }, [0, 1])
        XCTAssertLessThan(levels[1].mse, levels[0].mse * 0.3)
        let child = levels[1].shapes[0]
        XCTAssertGreaterThan(child.color.b, 0.7)
        XCTAssertEqual(centroid(child).x, 37.5, accuracy: 2)
        XCTAssertEqual(centroid(child).y, 30, accuracy: 2)
    }

    func testRefinerRefusesAHiddenShape() {
        var picture = discPicture()
        picture.shapes.append(Shape.circle(center: SIMD2(32, 32), radius: 40, color: .black))
        let settings = FitSettings(totalShapes: 1, workingSize: 64, stepsPerStage: 10)
        XCTAssertThrowsError(
            try Refiner(photoURL: discPhoto(), picture: picture, node: .shape([0]), settings: settings)
                .run(progress: { _ in }, isCancelled: { false })
        ) { error in
            XCTAssertEqual(error as? RefineError, .regionNotVisible)
        }
    }

    func testRefinerRefusesAMissingShape() {
        let settings = FitSettings(totalShapes: 1, workingSize: 64, stepsPerStage: 10)
        XCTAssertThrowsError(
            try Refiner(photoURL: discPhoto(), picture: discPicture(), node: .shape([4]), settings: settings)
                .run(progress: { _ in }, isCancelled: { false })
        ) { error in
            XCTAssertEqual(error as? RefineError, .regionNotFound)
        }
    }

    /// 256×256: red left of a grey band, blue right of it; a white dot in the red and a
    /// yellow dot in the blue.
    func twoSidesPhoto() -> URL {
        let image = Fixtures.image(width: 256, height: 256) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 112, height: 256))
            context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 112, y: 0, width: 32, height: 256))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 144, y: 0, width: 112, height: 256))
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fillEllipse(in: CGRect(x: 36, y: 100, width: 40, height: 40))
            context.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)
            context.fillEllipse(in: CGRect(x: 180, y: 60, width: 40, height: 40))
        }
        return Fixtures.write(image, name: "two-sides.png")
    }

    /// The 64×64 picture a first fit would give: the grey band, with a red and a blue gap.
    func twoSidesPicture() -> LayerFitCore.Picture {
        LayerFitCore.Picture(
            width: 64, height: 64, background: .grey,
            shapes: [rectangle(x: 28, y: -4, width: 8, height: 72, color: .grey)],
            gaps: [Gap(color: .red), Gap(color: .blue)])
    }

    func testPlanForOneGapZoomsToThatGap() throws {
        let plan = try XCTUnwrap(
            refinePlan(
                picture: twoSidesPicture(), node: .gap(1),
                originalPixelSize: CGSize(width: 256, height: 256), workingSize: 64))
        // The right gap is x 36…64; with the 4% margin it starts just left of 36.
        XCTAssertEqual(plan.viewport.minX, 36 - 0.04 * 28, accuracy: 0.05)
        XCTAssertEqual(plan.viewport.maxX, 64, accuracy: 1e-3)
        XCTAssertEqual(plan.viewport.minY, 0, accuracy: 1e-3)
        XCTAssertEqual(plan.height, 64)
        XCTAssertNil(
            refinePlan(
                picture: twoSidesPicture(), node: .gap(4),
                originalPixelSize: CGSize(width: 256, height: 256), workingSize: 64))
    }

    func testRefinerWorksInsideOneGapOnly() throws {
        let settings = FitSettings(totalShapes: 1, workingSize: 64, stepsPerStage: 80)
        let levels = try Refiner(
            photoURL: twoSidesPhoto(), picture: twoSidesPicture(), node: .gap(1), settings: settings
        ).run(progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(levels.map { $0.shapes.count }, [0, 1])
        let child = levels[1].shapes[0]
        // The yellow dot in the blue gap, not the white one in the red gap.
        XCTAssertGreaterThan(child.color.g, 0.7)
        XCTAssertLessThan(child.color.b, 0.3)
        // Its centre is (200, 80) in the photo: (50, 20) in picture coordinates.
        XCTAssertEqual(centroid(child).x, 50, accuracy: 2)
        XCTAssertEqual(centroid(child).y, 20, accuracy: 2)
        XCTAssertLessThan(levels[1].mse, levels[0].mse * 0.4)
    }

    func testRefinerCanRefineTheBackground() throws {
        // The background region is white in the photo and in the picture: nothing to find,
        // but it must run and keep its shapes off the red disc.
        let settings = FitSettings(totalShapes: 2, workingSize: 64, stepsPerStage: 20)
        let levels = try Refiner(
            photoURL: discPhoto(), picture: discPicture(), node: .background, settings: settings
        ).run(progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(levels.map { $0.shapes.count }, [0, 1, 2])
        XCTAssertTrue(levels.allSatisfy { $0.mse.isFinite })
    }
}
