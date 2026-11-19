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

    func makeModel(
        _ runner: @escaping FitRunner, refine: @escaping RefineRunner = FitModelTests.instantRefiner()
    ) -> FitModel {
        FitModel(runFit: runner, loadPhoto: Self.fakeLoad, runRefine: refine)
    }

    nonisolated static func innerLevel(children: Int) -> InnerLevel {
        let child = LayerFitCore.Shape.circle(
            center: SIMD2(4, 4), radius: 1, color: RGB(r: 0, g: 0, b: 1))
        return InnerLevel(shapes: Array(repeating: child, count: children), mse: 0.05)
    }

    /// Finishes `stages` refinement stages at once; level k has k children.
    nonisolated static func instantRefiner(stages: Int = 2) -> RefineRunner {
        { _, _, _, _, progress, _ in
            var levels: [InnerLevel] = []
            for stage in 0...stages {
                let level = innerLevel(children: stage)
                levels.append(level)
                progress(RefineProgress(stage: stage, stageCount: stages, finishedLevel: level))
            }
            return levels
        }
    }

    /// Finishes level 0 and stage 1, then hangs until cancelled.
    nonisolated static func hangingRefiner() -> RefineRunner {
        { _, _, _, _, progress, isCancelled in
            progress(RefineProgress(stage: 0, stageCount: 3, finishedLevel: innerLevel(children: 0)))
            progress(RefineProgress(stage: 1, stageCount: 3, finishedLevel: innerLevel(children: 1)))
            progress(RefineProgress(stage: 2, stageCount: 3, finishedLevel: nil))
            while !isCancelled() { Thread.sleep(forTimeInterval: 0.002) }
            return []
        }
    }

    /// A model with a finished 3-stage fit; level k has k circles, all at (4, 4), so a
    /// click there hits the last one.
    func fittedModel(
        mode: LevelMode = .refit, refine: @escaping RefineRunner = FitModelTests.instantRefiner()
    ) async -> FitModel {
        let model = makeModel(Self.instantRunner(stages: 3), refine: refine)
        model.open(photoURL)
        model.settings.mode = mode
        model.start()
        await waitFor("done") { model.status == .done }
        return model
    }

    let centre = SIMD2<Float>(4, 4)
    let corner = SIMD2<Float>(0.5, 0.5)

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

    // MARK: Selecting

    func testClickSelectsTheShapeUnderIt() async {
        let model = await fittedModel()
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.selectionLabel, "Whole picture")
        model.select(at: centre)
        XCTAssertEqual(model.selection, .shape([2]))
        XCTAssertEqual(model.selectionLabel, "Shape 3")
        XCTAssertNotNil(model.selectedShape)
        model.select(at: corner)
        XCTAssertEqual(model.selection, .background)
        XCTAssertEqual(model.selectionLabel, "Background")
        XCTAssertNil(model.selectedShape)
        model.select(at: nil)
        XCTAssertNil(model.selection)
    }

    func testSelectionIsClearedByModeChangeStartAndOpen() async {
        let model = await fittedModel()
        model.select(at: centre)
        model.settings.mode = .prefix
        XCTAssertNil(model.selection)
        model.settings.mode = .refit
        model.select(at: centre)
        model.start()
        XCTAssertNil(model.selection)
        await waitFor("done") { model.status == .done }
        model.select(at: centre)
        model.open(photoURL)
        XCTAssertNil(model.selection)
    }

    func testCannotSelectWhileFitting() async {
        let model = makeModel(Self.hangingRunner())
        model.open(photoURL)
        model.start()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 4) }
        model.select(at: centre)
        XCTAssertNil(model.selection)
        model.cancel()
        await waitFor("cancelled") { model.status == .cancelled }
    }

    // MARK: Refining

    func testRefineAddsLevelsInsideTheSelectedShape() async {
        let model = await fittedModel()
        XCTAssertFalse(model.canRefine)
        model.select(at: centre)
        XCTAssertTrue(model.canRefine)
        model.refine()
        await waitFor("refined") { model.status == .done && model.sliderLast == 2 }
        // The selection stays on the refined shape, showing its finest level.
        XCTAssertEqual(model.selection, .shape([2]))
        XCTAssertEqual(model.sliderStop, 2)
        let inner = model.shownPicture?.inner(at: .shape([2]))
        XCTAssertEqual(inner?.levels.map { $0.shapes.count }, [0, 1, 2])
        XCTAssertEqual(model.shownPicture?.shapeCount(maxDepth: .max), 5)
        XCTAssertEqual(model.maxDepth, 1)
    }

    func testRefineGetsThePictureNodeAndSettings() async {
        var seen: (picture: LayerFitCore.Picture, node: NodeID, settings: FitSettings)?
        let model = await fittedModel { url, picture, node, settings, progress, isCancelled in
            seen = (picture, node, settings)
            return try Self.instantRefiner()(url, picture, node, settings, progress, isCancelled)
        }
        model.userMovedSlider(to: 2)
        model.select(at: centre)
        model.settings.totalShapes = 32
        model.refine()
        await waitFor("refined") { model.status == .done && seen != nil }
        XCTAssertEqual(seen?.picture.shapes.count, 2)
        XCTAssertEqual(seen?.node, .shape([1]))
        XCTAssertEqual(seen?.settings.totalShapes, 32)
    }

    func testRefineWithoutSelectionDoesNothing() async {
        let model = await fittedModel()
        model.refine()
        XCTAssertEqual(model.status, .done)
        XCTAssertEqual(model.maxDepth, 0)
    }

    func testRefinementBelongsToTheLevelItWasMadeOn() async {
        let model = await fittedModel()
        model.select(at: centre)
        model.refine()
        await waitFor("refined") { model.status == .done && model.maxDepth == 1 }
        model.select(at: nil)
        model.userMovedSlider(to: 2)
        XCTAssertEqual(model.maxDepth, 0)
        model.userMovedSlider(to: 3)
        XCTAssertEqual(model.maxDepth, 1)
    }

    func testRefineTheBackground() async {
        let model = await fittedModel()
        model.select(at: corner)
        model.refine()
        await waitFor("refined") { model.status == .done && model.sliderLast == 2 }
        XCTAssertEqual(model.shownPicture?.backgroundInner?.levels.count, 3)
    }

    func testRefineAgainReplacesTheEarlierRefinement() async {
        var runs = 0
        let model = await fittedModel { url, picture, node, settings, progress, isCancelled in
            runs += 1
            return try Self.instantRefiner(stages: runs == 1 ? 2 : 1)(
                url, picture, node, settings, progress, isCancelled)
        }
        model.select(at: centre)
        model.refine()
        await waitFor("first") { model.status == .done && model.sliderLast == 2 }
        // The first refinement's children now cover the centre, so the click goes to one of
        // them; go back up to the refined shape.
        model.select(at: centre)
        XCTAssertEqual(model.selection, .shape([2, 1]))
        model.selectParent()
        XCTAssertEqual(model.selection, .shape([2]))
        model.refine()
        await waitFor("second") { runs == 2 && model.status == .done && model.sliderLast == 1 }
        XCTAssertEqual(model.shownPicture?.inner(at: .shape([2]))?.levels.count, 2)
    }

    func testCancelDuringRefineKeepsFinishedLevels() async {
        let model = await fittedModel(refine: Self.hangingRefiner())
        model.select(at: centre)
        model.refine()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 3) }
        XCTAssertTrue(model.isRefining)
        model.cancel()
        await waitFor("cancelled") { model.status == .cancelled }
        XCTAssertFalse(model.isRefining)
        XCTAssertEqual(model.shownPicture?.inner(at: .shape([2]))?.levels.count, 2)
    }

    func testViewIsLockedWhileRefining() async {
        let model = await fittedModel(refine: Self.hangingRefiner())
        model.select(at: centre)
        model.refine()
        await waitFor("stage 2") { model.status == .fitting(stage: 2, stageCount: 3) }
        model.select(at: corner)
        XCTAssertEqual(model.selection, .shape([2]))
        model.select(at: nil)
        XCTAssertEqual(model.selection, .shape([2]))
        model.userMovedSlider(to: 0)
        XCTAssertEqual(model.sliderStop, 1)
        XCTAssertFalse(model.canRefine)
        model.cancel()
        await waitFor("cancelled") { model.status == .cancelled }
    }

    func testRefineErrorIsReportedAndNothingChanges() async {
        let model = await fittedModel { _, _, _, _, _, _ in throw RefineError.regionNotVisible }
        model.select(at: centre)
        model.refine()
        await waitFor("error") { model.errorMessage != nil }
        XCTAssertEqual(model.status, .done)
        XCTAssertFalse(model.isRefining)
        XCTAssertEqual(model.maxDepth, 0)
        XCTAssertTrue(model.errorMessage?.contains("hidden") ?? false)
    }

    // MARK: Refinements across levels

    /// Goes to a root level, clicks the centre (hitting that level's last shape) and refines.
    func refineTopShape(_ model: FitModel, atLevel level: Int) async {
        model.select(at: nil)
        model.userMovedSlider(to: level)
        model.select(at: centre)
        model.refine()
        await waitFor("refined at level \(level)") { model.status == .done && !model.isRefining && model.sliderLast >= 1 }
        model.select(at: nil)
    }

    func refinedShapes(_ model: FitModel, atLevel level: Int) -> [Int] {
        model.select(at: nil)
        model.userMovedSlider(to: level)
        guard let picture = model.shownPicture else { return [] }
        return picture.shapes.indices.filter { picture.shapes[$0].inner != nil }
    }

    func testPrefixRefinementsShowAtEveryLevelThatHasTheShape() async {
        let model = await fittedModel(mode: .prefix)
        await refineTopShape(model, atLevel: 2)  // shape 2 of 2 (index 1)
        await refineTopShape(model, atLevel: 3)  // shape 3 of 3 (index 2)
        XCTAssertEqual(refinedShapes(model, atLevel: 3), [1, 2])
        XCTAssertEqual(refinedShapes(model, atLevel: 2), [1])
        XCTAssertEqual(refinedShapes(model, atLevel: 1), [])
        model.userMovedSlider(to: 3)
        XCTAssertEqual(model.maxDepth, 1)
        XCTAssertEqual(model.shownPicture?.shapeCount(maxDepth: .max), 3 + 2 + 2)
    }

    func testPrefixRefinementIsOneObjectSharedByAllLevels() async {
        let model = await fittedModel(mode: .prefix)
        await refineTopShape(model, atLevel: 2)
        // Scrub the refinement while looking at level 3 …
        model.userMovedSlider(to: 3)
        model.select(at: centre)  // shape 3 is on top there
        XCTAssertEqual(model.selection, .shape([2]))
        model.select(at: nil)
        model.userMovedSlider(to: 2)
        model.select(at: centre)
        model.selectParent()
        XCTAssertEqual(model.selection, .shape([1]))
        model.userMovedSlider(to: 1)
        model.select(at: nil)
        // … and it is at that position on every level.
        model.userMovedSlider(to: 3)
        XCTAssertEqual(model.shownPicture?.inner(at: .shape([1]))?.shownIndex, 1)
    }

    func testPrefixRefiningAgainReplacesWhateverLevelItWasMadeOn() async {
        var runs = 0
        let model = await fittedModel(mode: .prefix) { url, picture, node, settings, progress, isCancelled in
            runs += 1
            return try Self.instantRefiner(stages: runs == 1 ? 2 : 1)(
                url, picture, node, settings, progress, isCancelled)
        }
        await refineTopShape(model, atLevel: 2)
        model.userMovedSlider(to: 3)
        // Shape index 1 is under shape index 2 at level 3; reach it through its child.
        model.setDepth(1)
        XCTAssertEqual(model.shownPicture?.inner(at: .shape([1]))?.levels.count, 3)
        model.userMovedSlider(to: 2)
        model.select(at: centre)
        model.selectParent()
        model.refine()
        await waitFor("second") { runs == 2 && model.status == .done }
        XCTAssertEqual(model.shownPicture?.inner(at: .shape([1]))?.levels.count, 2)
        model.select(at: nil)
        model.userMovedSlider(to: 3)
        XCTAssertEqual(model.shownPicture?.inner(at: .shape([1]))?.levels.count, 2)
    }

    func testPrefixNestedRefinementIsSharedToo() async {
        let model = await fittedModel(mode: .prefix)
        await refineTopShape(model, atLevel: 2)
        model.userMovedSlider(to: 2)
        model.select(at: centre)
        XCTAssertEqual(model.selection, .shape([1, 1]))
        model.refine()
        await waitFor("nested") { model.status == .done && model.maxDepth == 2 }
        model.select(at: nil)
        model.userMovedSlider(to: 3)
        XCTAssertEqual(model.maxDepth, 2)
        XCTAssertNotNil(model.shownPicture?.inner(at: .shape([1, 1])))
    }

    func testGapRefinementsStayOnTheirLevelEvenWhenShared() async {
        // Gaps are different patches on every level, so their refinements never travel.
        let model = await fittedModel(mode: .prefix)
        model.userMovedSlider(to: 1)
        model.select(at: corner)
        model.refine()
        await waitFor("refined") { model.status == .done && model.sliderLast == 2 }
        model.select(at: nil)
        XCTAssertEqual(model.shownPicture?.backgroundInner?.levels.count, 3)
        model.userMovedSlider(to: 3)
        XCTAssertNil(model.shownPicture?.backgroundInner)
        model.userMovedSlider(to: 1)
        XCTAssertEqual(model.shownPicture?.backgroundInner?.levels.count, 3)
    }

    func testRefitRefinementsStayOnTheirLevelUnlessCarried() async {
        let model = await fittedModel()
        XCTAssertFalse(model.carryRefinements)
        await refineTopShape(model, atLevel: 2)
        XCTAssertEqual(refinedShapes(model, atLevel: 2), [1])
        XCTAssertEqual(refinedShapes(model, atLevel: 3), [])

        model.carryRefinements = true
        XCTAssertEqual(refinedShapes(model, atLevel: 3), [1])
        XCTAssertEqual(refinedShapes(model, atLevel: 2), [1])
        XCTAssertEqual(refinedShapes(model, atLevel: 1), [])  // level 1 has no shape 2

        model.carryRefinements = false
        XCTAssertEqual(refinedShapes(model, atLevel: 3), [])
    }

    func testRefitCarryShowsBothRefinementsMadeOnDifferentLevels() async {
        let model = await fittedModel()
        model.carryRefinements = true
        await refineTopShape(model, atLevel: 2)
        await refineTopShape(model, atLevel: 3)
        XCTAssertEqual(refinedShapes(model, atLevel: 3), [1, 2])
        XCTAssertEqual(refinedShapes(model, atLevel: 2), [1])
    }

    /// Level k has k small circles side by side, so each can be clicked on its own:
    /// shape i is at x = 1.5 + 2i.
    nonisolated static func spreadRunner(stages: Int) -> FitRunner {
        { _, _, progress, _ in
            var levels: [Level] = []
            for stage in 0...stages {
                let shapes = (0..<stage).map {
                    LayerFitCore.Shape.circle(
                        center: SIMD2(1.5 + 2 * Float($0), 4), radius: 0.9,
                        color: RGB(r: 1, g: 0, b: 0))
                }
                let picture = LayerFitCore.Picture(
                    width: 8, height: 8, background: RGB(r: 0, g: 0, b: 0), shapes: shapes)
                let level = Level(picture: picture, mse: 0.1)
                levels.append(level)
                progress(
                    FitProgress(
                        stage: stage, stageCount: stages, step: 1, stepCount: 1, picture: picture,
                        finishedLevel: level))
            }
            return levels
        }
    }

    func testRefitCarryPrefersTheRefinementMadeNearestTheLevelShown() async {
        var runs = 0
        let model = makeModel(Self.spreadRunner(stages: 4)) { url, picture, node, settings, progress, isCancelled in
            runs += 1
            return try Self.instantRefiner(stages: runs == 1 ? 2 : 1)(
                url, picture, node, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        model.carryRefinements = true
        // Refine the second shape on level 2 (three levels) and again on level 4 (two levels).
        let second = SIMD2<Float>(3.5, 4)
        for level in [2, 4] {
            model.select(at: nil)
            model.userMovedSlider(to: level)
            model.select(at: second)
            if model.selection != .shape([1]) { model.selectParent() }
            XCTAssertEqual(model.selection, .shape([1]))
            model.refine()
            let expected = level == 2 ? 1 : 2
            await waitFor("refined on \(level)") { runs == expected && model.status == .done }
        }
        func levelsOfSecondShape(at level: Int) -> Int? {
            model.select(at: nil)
            model.userMovedSlider(to: level)
            return model.shownPicture?.inner(at: .shape([1]))?.levels.count
        }
        XCTAssertEqual(levelsOfSecondShape(at: 2), 3)  // its own
        XCTAssertEqual(levelsOfSecondShape(at: 4), 2)  // its own, not the one carried from level 2
        XCTAssertEqual(levelsOfSecondShape(at: 3), 3)  // equally near both: the earlier one
        XCTAssertNil(levelsOfSecondShape(at: 1))  // level 1 has no second shape
        model.carryRefinements = false
        XCTAssertNil(levelsOfSecondShape(at: 3))
        XCTAssertEqual(levelsOfSecondShape(at: 4), 2)
    }

    // MARK: Gaps

    /// One level: a bar down the middle of an 8×8 picture, leaving a red gap on the left
    /// and a blue gap on the right.
    nonisolated static func barRunner() -> FitRunner {
        { _, _, progress, _ in
            let corners: [SIMD2<Float>] = [SIMD2(3, -1), SIMD2(5, -1), SIMD2(5, 9), SIMD2(3, 9)]
            var points: [SIMD2<Float>] = []
            for i in 0..<4 {
                let a = corners[i]
                let b = corners[(i + 1) % 4]
                points += [a, a + (b - a) / 3, a + (b - a) * 2 / 3]
            }
            let bar = LayerFitCore.Shape(points: points, color: RGB(r: 0.5, g: 0.5, b: 0.5))
            let empty = LayerFitCore.Picture(
                width: 8, height: 8, background: RGB(r: 0.5, g: 0.5, b: 0.5), shapes: [],
                gaps: [Gap(color: RGB(r: 0.5, g: 0.5, b: 0.5))])
            let split = LayerFitCore.Picture(
                width: 8, height: 8, background: RGB(r: 0.5, g: 0.5, b: 0.5), shapes: [bar],
                gaps: [Gap(color: RGB(r: 1, g: 0, b: 0)), Gap(color: RGB(r: 0, g: 0, b: 1))])
            let levels = [Level(picture: empty, mse: 0.2), Level(picture: split, mse: 0.05)]
            for (stage, level) in levels.enumerated() {
                progress(
                    FitProgress(
                        stage: stage, stageCount: 1, step: 1, stepCount: 1, picture: level.picture,
                        finishedLevel: level))
            }
            return levels
        }
    }

    func barModel() async -> FitModel {
        let model = makeModel(Self.barRunner())
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        return model
    }

    func testClickingBetweenShapesSelectsThatGap() async {
        let model = await barModel()
        model.select(at: SIMD2(1, 4))
        XCTAssertEqual(model.selection, .gap(0))
        XCTAssertEqual(model.selectionLabel, "Gap 1")
        XCTAssertNotNil(model.selectedGapMask)
        model.select(at: SIMD2(7, 4))
        XCTAssertEqual(model.selection, .gap(1))
        XCTAssertEqual(model.selectionLabel, "Gap 2")
        model.select(at: SIMD2(4, 4))
        XCTAssertEqual(model.selection, .shape([0]))
        XCTAssertNil(model.selectedGapMask)
    }

    func testASingleGapIsCalledTheBackground() async {
        let model = await barModel()
        model.userMovedSlider(to: 0)
        model.select(at: SIMD2(1, 4))
        XCTAssertEqual(model.selection, .gap(0))
        XCTAssertEqual(model.selectionLabel, "Background")
    }

    func testRefiningOneGapLeavesTheOtherAlone() async {
        var seen: NodeID?
        let model = makeModel(Self.barRunner()) { url, picture, node, settings, progress, isCancelled in
            seen = node
            return try Self.instantRefiner()(url, picture, node, settings, progress, isCancelled)
        }
        model.open(photoURL)
        model.start()
        await waitFor("done") { model.status == .done }
        model.select(at: SIMD2(7, 4))
        model.refine()
        await waitFor("refined") { model.status == .done && model.sliderLast == 2 }
        XCTAssertEqual(seen, .gap(1))
        XCTAssertEqual(model.shownPicture?.inner(at: .gap(1))?.levels.count, 3)
        XCTAssertNil(model.shownPicture?.inner(at: .gap(0)))
        // The gap's own slider scrubs its refinement.
        model.userMovedSlider(to: 1)
        XCTAssertEqual(model.shownPicture?.inner(at: .gap(1))?.shapes.count, 1)
        // Its children are shapes under the gap.
        XCTAssertEqual(model.caption.hasPrefix("2 shapes"), true)
        model.select(at: nil)
        model.userMovedSlider(to: 0)
        XCTAssertNil(model.shownPicture?.inner(at: .gap(0)))
    }

    func testChangingCarryClearsTheSelection() async {
        let model = await fittedModel()
        model.select(at: centre)
        model.carryRefinements = true
        XCTAssertNil(model.selection)
    }

    func testStartDiscardsThatModesRefinements() async {
        let model = await fittedModel(mode: .prefix)
        await refineTopShape(model, atLevel: 2)
        model.start()
        await waitFor("refit") { model.status == .done }
        XCTAssertEqual(refinedShapes(model, atLevel: 3), [])
        XCTAssertEqual(refinedShapes(model, atLevel: 2), [])
    }

    // MARK: The two sliders

    func testLevelSliderFollowsTheSelection() async {
        let model = await fittedModel()
        XCTAssertEqual(model.sliderLast, 3)  // whole picture: the root levels
        model.select(at: centre)
        XCTAssertEqual(model.sliderLast, 0)  // a shape with no refinement yet
        model.refine()
        await waitFor("refined") { model.status == .done && model.sliderLast == 2 }
        model.userMovedSlider(to: 1)
        XCTAssertEqual(model.sliderStop, 1)
        XCTAssertEqual(model.shownPicture?.inner(at: .shape([2]))?.shapes.count, 1)
        XCTAssertEqual(model.shownStop, 3)  // the root level did not move
        model.userMovedSlider(to: 99)
        XCTAssertEqual(model.sliderStop, 2)
        model.select(at: nil)
        XCTAssertEqual(model.sliderLast, 3)
        XCTAssertEqual(model.sliderStop, 3)
    }

    func testDepthSliderHidesDeeperRefinements() async {
        let model = await fittedModel()
        XCTAssertEqual(model.maxDepth, 0)
        model.select(at: centre)
        model.refine()
        await waitFor("refined") { model.status == .done && model.maxDepth == 1 }
        XCTAssertEqual(model.shownDepth, 1)
        XCTAssertEqual(model.caption, "5 shapes · 258 B · 1/12,698 of original")
        model.setDepth(0)
        XCTAssertEqual(model.shownDepth, 0)
        XCTAssertEqual(model.caption, "3 shapes · 156 B · 1/21,000 of original")
        // Clicks only reach what is shown.
        model.select(at: centre)
        XCTAssertEqual(model.selection, .shape([2]))
        model.setDepth(5)  // clamped
        XCTAssertEqual(model.shownDepth, 1)
        model.select(at: centre)
        XCTAssertEqual(model.selection, .shape([2, 1]))
        // Hiding the depth a selected shape lives at deselects it.
        model.setDepth(0)
        XCTAssertNil(model.selection)
    }

    func testRefiningShowsEveryDepthAgain() async {
        let model = await fittedModel()
        model.select(at: centre)
        model.refine()
        await waitFor("refined") { model.status == .done && model.maxDepth == 1 }
        model.setDepth(0)
        model.select(at: centre)
        model.refine()
        await waitFor("refined again") { model.status == .done && model.shownDepth == 1 }
        XCTAssertEqual(model.shownDepth, 1)
    }

    func testSelectParentWalksUpAndThenDeselects() async {
        let model = await fittedModel()
        model.select(at: centre)
        model.refine()
        await waitFor("refined") { model.status == .done && model.maxDepth == 1 }
        model.select(at: centre)
        XCTAssertEqual(model.selection, .shape([2, 1]))
        XCTAssertEqual(model.selectionLabel, "Shape 3 › 2")
        model.selectParent()
        XCTAssertEqual(model.selection, .shape([2]))
        model.selectParent()
        XCTAssertNil(model.selection)
    }

    func testExportRespectsDepth() async throws {
        let model = await fittedModel()
        model.select(at: centre)
        model.refine()
        await waitFor("refined") { model.status == .done && model.maxDepth == 1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layerfit-depth-\(UUID().uuidString).svg")
        try model.exportSVG(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "<clipPath").count - 1, 1)
        model.setDepth(0)
        try model.exportSVG(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "<clipPath").count - 1, 0)
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
