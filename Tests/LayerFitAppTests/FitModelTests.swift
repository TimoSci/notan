import LayerFitCore
import XCTest
@testable import LayerFitUI

@MainActor
final class FitModelTests: XCTestCase {
    let photoURL = URL(fileURLWithPath: "/tmp/photo.jpg")

    // MARK: Fakes

    nonisolated static func picture(shapes: Int) -> LayerFitCore.Picture {
        let shape = LayerFitCore.Shape.circle(
            center: SIMD2(4, 4), radius: 2, color: RGB(r: 1, g: 0, b: 0))
        return LayerFitCore.Picture(
            width: 8, height: 8, background: RGB(r: 0, g: 0, b: 0),
            shapes: Array(repeating: shape, count: shapes))
    }

    nonisolated static func finished(stage: Int, of stageCount: Int, shapes: Int) -> FitProgress {
        let p = picture(shapes: shapes)
        return FitProgress(
            stage: stage, stageCount: stageCount, step: 10, stepCount: 10, picture: p,
            finishedLevel: Level(picture: p, mse: 0.1))
    }

    nonisolated static func fakeLoad(_ url: URL, _ workingSize: Int) throws -> LoadedPhoto {
        if url.lastPathComponent == "bad.jpg" { throw PhotoError.unreadable(url) }
        return LoadedPhoto(
            target: TargetImage(width: 8, height: 8, pixels: [Float](repeating: 0.5, count: 192)),
            originalPixelSize: CGSize(width: 4000, height: 3000), fileBytes: 3_276_000)
    }

    /// Finishes `stages` stages at once; level k has k shapes.
    nonisolated static func instantRunner(stages: Int) -> FitRunner {
        { _, _, progress, _ in
            var levels: [Level] = []
            for stage in 0...stages {
                let p = finished(stage: stage, of: stages, shapes: stage)
                levels.append(p.finishedLevel!)
                progress(p)
            }
            return levels
        }
    }

    /// Finishes level 0 and stage 1, reports stage 2 under way, then hangs until cancelled.
    /// With `lateLevel`, it then misbehaves and reports one more finished level.
    nonisolated static func hangingRunner(lateLevel: Bool = false) -> FitRunner {
        { _, _, progress, isCancelled in
            progress(finished(stage: 0, of: 4, shapes: 0))
            progress(finished(stage: 1, of: 4, shapes: 1))
            progress(
                FitProgress(
                    stage: 2, stageCount: 4, step: 5, stepCount: 10, picture: picture(shapes: 2),
                    finishedLevel: nil))
            while !isCancelled() { Thread.sleep(forTimeInterval: 0.002) }
            if lateLevel { progress(finished(stage: 2, of: 4, shapes: 99)) }
            return []
        }
    }

    func makeModel(_ runner: @escaping FitRunner) -> FitModel {
        FitModel(runFit: runner, loadPhoto: Self.fakeLoad)
    }

    func waitFor(_ what: String, _ condition: @escaping () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: Opening

    func testOpenLoadsPhoto() {
        let model = makeModel(Self.instantRunner(stages: 3))
        model.open(photoURL)
        XCTAssertEqual(model.photoURL, photoURL)
        XCTAssertNotNil(model.photo)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.shownPicture)
    }

    func testOpenBadFileSetsErrorMessageAndKeepsPhoto() {
        let model = makeModel(Self.instantRunner(stages: 3))
        model.open(photoURL)
        model.open(URL(fileURLWithPath: "/tmp/bad.jpg"))
        XCTAssertEqual(model.errorMessage, "“bad.jpg” could not be read as an image.")
        XCTAssertEqual(model.photoURL, photoURL)
    }

    func testStartWithoutPhotoDoesNothing() {
        let model = makeModel(Self.instantRunner(stages: 3))
        model.start()
        XCTAssertEqual(model.status, .idle)
    }

    func testStartKeepsStepsWithinRange() async {
        var seen: [Int] = []
        let model = makeModel { target, settings, progress, isCancelled in
            seen.append(settings.stepsPerStage)
            return Self.instantRunner(stages: 1)(target, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.settings.stepsPerStage = 3
        model.start()
        await waitFor("done") { model.status == .done }
        model.settings.stepsPerStage = 50_000
        model.start()
        await waitFor("second run") { seen.count == 2 && model.status == .done }
        XCTAssertEqual(seen, [10, 1000])
        XCTAssertEqual(model.settings.stepsPerStage, 1000)
    }

    // MARK: Fitting

    func testStartPublishesLevelsAsStagesFinish() async {
        let model = makeModel(Self.instantRunner(stages: 3))
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        XCTAssertEqual(model.levels.map { $0.picture.shapes.count }, [0, 1, 2, 3])
        XCTAssertEqual(model.shownStop, 3)
        XCTAssertEqual(model.shownPicture?.shapes.count, 3)
    }

    func testStatusReportsStageWhileFitting() async {
        let model = makeModel(Self.hangingRunner())
        model.open(photoURL)
        model.start()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 4) }
        XCTAssertTrue(model.isFitting)
        // Following the newest state: the unfinished stage's picture is shown.
        XCTAssertEqual(model.shownPicture?.shapes.count, 2)
        model.cancel()
        await waitFor("cancelled") { model.status == .cancelled }
    }

    func testSliderFollowsLatestUntilUserMovesIt() async {
        let model = makeModel(Self.hangingRunner())
        model.open(photoURL)
        model.start()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 4) }
        XCTAssertEqual(model.shownStop, 1)
        model.userMovedSlider(to: 0)
        XCTAssertFalse(model.followsLatest)
        XCTAssertEqual(model.shownStop, 0)
        XCTAssertEqual(model.shownPicture?.shapes.count, 0)
        // Dragging back to the newest stop resumes following.
        model.userMovedSlider(to: 1)
        XCTAssertTrue(model.followsLatest)
        model.cancel()
        await waitFor("cancelled") { model.status == .cancelled }
    }

    func testSliderIsClampedToAvailableLevels() async {
        let model = makeModel(Self.instantRunner(stages: 3))
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        model.userMovedSlider(to: 99)
        XCTAssertEqual(model.shownStop, 3)
        model.userMovedSlider(to: -5)
        XCTAssertEqual(model.shownStop, 0)
    }

    func testCancelKeepsFinishedLevels() async {
        let model = makeModel(Self.hangingRunner())
        model.open(photoURL)
        model.start()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 4) }
        model.cancel()
        await waitFor("cancelled") { model.status == .cancelled }
        XCTAssertEqual(model.levels.count, 2)
        XCTAssertFalse(model.isFitting)
        // The unfinished stage's picture is no longer shown.
        XCTAssertEqual(model.shownPicture?.shapes.count, 1)
    }

    func testStartWhileFittingDropsOldRunProgress() async {
        var starts = 0
        let model = makeModel { target, settings, progress, isCancelled in
            starts += 1
            let runner = starts == 1 ? Self.hangingRunner(lateLevel: true) : Self.instantRunner(stages: 3)
            return runner(target, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 4) }
        model.start()
        await waitFor("done") { model.status == .done }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.status, .done)
        XCTAssertEqual(model.levels.map { $0.picture.shapes.count }, [0, 1, 2, 3])
    }

    func testOpenWhileFittingClearsBothModes() async {
        var starts = 0
        let model = makeModel { target, settings, progress, isCancelled in
            starts += 1
            let runner = starts == 1 ? Self.instantRunner(stages: 3) : Self.hangingRunner(lateLevel: true)
            return runner(target, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        model.settings.mode = .prefix
        model.start()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 4) }
        model.open(URL(fileURLWithPath: "/tmp/other.jpg"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.status, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.shownPicture)
        XCTAssertEqual(model.photoURL?.lastPathComponent, "other.jpg")
    }

    func testFitsNeverRunAtTheSameTime() async {
        // MLX must not be driven by two fits at once: a new fit waits for the old one to stop.
        let lock = NSLock()
        var active = 0
        var mostAtOnce = 0
        var starts = 0
        let model = makeModel { target, settings, progress, isCancelled in
            lock.lock()
            active += 1
            mostAtOnce = max(mostAtOnce, active)
            starts += 1
            let first = starts == 1
            lock.unlock()
            defer {
                lock.lock()
                active -= 1
                lock.unlock()
            }
            if first {
                // Slow to notice it was cancelled.
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.002) }
                Thread.sleep(forTimeInterval: 0.1)
                return []
            }
            return Self.instantRunner(stages: 2)(target, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("first fit running") { lock.withLock { starts } == 1 }
        model.start()
        await waitFor("done") { model.status == .done }
        XCTAssertEqual(lock.withLock { mostAtOnce }, 1)
        XCTAssertEqual(model.levels.count, 3)
    }

    // MARK: Launch arguments

    func testInitialPhotoIsFirstArgumentThatIsAFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("layerfit-arg-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(
            initialPhotoURL(arguments: ["/path/LayerFit", file.path])?.path, file.path)
        // Xcode launches apps with debug flags and their values; neither is a photo.
        XCTAssertNil(initialPhotoURL(arguments: ["/path/LayerFit", "-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(initialPhotoURL(arguments: ["/path/LayerFit", "/no/such/photo.jpg"]))
        XCTAssertNil(initialPhotoURL(arguments: ["/path/LayerFit", FileManager.default.temporaryDirectory.path]))
        XCTAssertNil(initialPhotoURL(arguments: ["/path/LayerFit"]))
    }

    // MARK: Modes

    func testFittingOneModeKeepsTheOther() async {
        var starts = 0
        let model = makeModel { target, settings, progress, isCancelled in
            starts += 1
            return Self.instantRunner(stages: starts == 1 ? 5 : 2)(target, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("refit done") { model.status == .done }
        model.settings.mode = .prefix
        model.start()
        await waitFor("prefix done") { model.results[.prefix]?.count == 3 && model.status == .done }
        XCTAssertEqual(model.results[.refit]?.count, 6)
        XCTAssertEqual(model.results[.prefix]?.count, 3)
    }

    func testSwitchingModeKeepsStopClampedToAvailableLevels() async {
        var starts = 0
        let model = makeModel { target, settings, progress, isCancelled in
            starts += 1
            return Self.instantRunner(stages: starts == 1 ? 5 : 2)(target, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("refit done") { model.status == .done }
        model.settings.mode = .prefix
        model.start()
        await waitFor("prefix done") { model.results[.prefix]?.count == 3 && model.status == .done }

        model.settings.mode = .refit
        model.userMovedSlider(to: 5)
        XCTAssertEqual(model.shownPicture?.shapes.count, 5)
        model.settings.mode = .prefix
        XCTAssertEqual(model.shownStop, 2)
        XCTAssertEqual(model.shownPicture?.shapes.count, 2)
        model.settings.mode = .refit
        XCTAssertEqual(model.shownStop, 5)
    }

    func testViewingOtherModeWhileFittingShowsItsLevels() async {
        var starts = 0
        let model = makeModel { target, settings, progress, isCancelled in
            starts += 1
            let runner = starts == 1 ? Self.instantRunner(stages: 3) : Self.hangingRunner()
            return runner(target, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("refit done") { model.status == .done }
        model.settings.mode = .prefix
        model.start()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 4) }
        // Looking back at the finished Re-fit result must not show the Prefix run's live
        // picture (2 shapes): it shows Re-fit's level at the same stop, which is stop 1.
        model.settings.mode = .refit
        XCTAssertEqual(model.shownStop, 1)
        XCTAssertEqual(model.shownPicture?.shapes.count, 1)
        XCTAssertEqual(model.levels.count, 4)
        model.cancel()
        await waitFor("cancelled") { model.status == .cancelled }
        XCTAssertEqual(model.results[.prefix]?.count, 2)
    }

    // MARK: Caption and export

    func testCaptionFormat() async {
        let model = makeModel { _, _, progress, _ in
            let p = Self.finished(stage: 0, of: 1, shapes: 16)
            progress(p)
            return [p.finishedLevel!]
        }
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        XCTAssertEqual(model.caption, "16 shapes · 819 B · 1/4,000 of original")
    }

    func testCaptionSizes() {
        XCTAssertEqual(FitModel.caption(shapes: 0, bytes: 3, fileBytes: 3_000_000), "0 shapes · 3 B · 1/1,000,000 of original")
        XCTAssertEqual(FitModel.caption(shapes: 1, bytes: 54, fileBytes: 5400), "1 shape · 54 B · 1/100 of original")
        XCTAssertEqual(FitModel.caption(shapes: 128, bytes: 6531, fileBytes: 6_531_000), "128 shapes · 6.5 kB · 1/1,000 of original")
        XCTAssertEqual(FitModel.caption(shapes: 128, bytes: 6531, fileBytes: 0), "128 shapes · 6.5 kB")
        XCTAssertEqual(FitModel.caption(shapes: 128, bytes: 6531, fileBytes: 4000), "128 shapes · 6.5 kB · larger than the original")
    }

    func testCaptionEmptyWithoutLevels() {
        XCTAssertEqual(makeModel(Self.instantRunner(stages: 1)).caption, "")
    }

    func testExportWritesShownLevel() async throws {
        let model = makeModel(Self.instantRunner(stages: 3))
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        model.userMovedSlider(to: 2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layerfit-export-\(UUID().uuidString).svg")
        try model.exportSVG(to: url)
        let root = try XCTUnwrap(XMLDocument(contentsOf: url).rootElement())
        XCTAssertEqual(root.elements(forName: "path").count, 2)
        XCTAssertEqual(root.attribute(forName: "width")?.stringValue, "4000")
        XCTAssertEqual(root.attribute(forName: "height")?.stringValue, "3000")
    }

    func testExportWithoutLevelsThrows() {
        let model = makeModel(Self.instantRunner(stages: 3))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("never.svg")
        XCTAssertThrowsError(try model.exportSVG(to: url))
    }
}
