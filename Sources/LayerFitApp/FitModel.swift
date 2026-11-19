import CoreGraphics
import Foundation
import LayerFitCore
import Observation

/// Runs one fit to completion on the calling thread: target, settings, progress, isCancelled.
public typealias FitRunner = (
    TargetImage, FitSettings, @escaping (FitProgress) -> Void, @escaping () -> Bool
) -> [Level]

public typealias PhotoLoader = (URL, Int) throws -> LoadedPhoto

/// Runs one refinement to completion on the calling thread: photo, picture as shown, the
/// region to refine, settings, progress, isCancelled.
public typealias RefineRunner = (
    URL, LayerFitCore.Picture, NodeID, FitSettings, @escaping (RefineProgress) -> Void,
    @escaping () -> Bool
) throws -> [InnerLevel]

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ error: Error) {
        lock.lock()
        stored = error
        lock.unlock()
    }
}

public enum ExportError: Error, LocalizedError {
    case nothingToExport

    public var errorDescription: String? { "There is no fitted level to export yet." }
}

/// Everything the window shows: the loaded photo, the fitted levels of each mode, and the
/// fit in progress. Fitting runs off the main thread; its progress arrives here in order.
@MainActor @Observable
public final class FitModel {
    public enum Status: Equatable {
        case idle
        case fitting(stage: Int, stageCount: Int)
        case done
        case cancelled
    }

    public static let shapeChoices = [32, 64, 128, 256]
    public static let sizeChoices = [128, 256, 384, 512]
    public static let stepsRange = 10...1000
    /// Minimum shape width at the finest level, in pixels at 256 px; 0 is off.
    public static let minWidthChoices: [Float] = [0, 2, 4, 6, 8]

    public var settings = FitSettings() {
        didSet {
            // A selection names a shape of one mode's picture.
            if oldValue.mode != settings.mode, !isRefining { selection = nil }
        }
    }
    /// In Re-fit mode, whether a refinement made on one level is also shown on the other
    /// levels, on the shape with the same number. Re-fit moves every shape between levels,
    /// so a carried refinement is clipped to an outline it was not fitted for. Prefix mode
    /// always shares refinements, exactly, because there a shape is the same on every level.
    public var carryRefinements = false {
        didSet { if oldValue != carryRefinements, !isRefining { selection = nil } }
    }
    /// The region the Level slider and Refine act on; nil is the whole picture.
    public private(set) var selection: NodeID?
    /// True while a refinement inside a shape is running (as opposed to a whole-picture fit).
    public private(set) var isRefining = false
    public private(set) var photoURL: URL?
    public private(set) var photo: LoadedPhoto?
    /// Finished levels per mode, for the loaded photo. Level 0 is the background alone.
    public private(set) var results: [LevelMode: [Level]] = [:]
    /// The newest state of the fit in progress, including its unfinished stage.
    public private(set) var livePicture: LayerFitCore.Picture?
    public private(set) var status: Status = .idle
    /// True while the picture should track the fit; false once the user picks a level.
    public private(set) var followsLatest = true
    public var errorMessage: String?

    /// Refinements are kept beside the levels, not inside them, so that one refinement can
    /// be shown on several levels.
    private struct Refinement {
        /// The picture-level region it belongs to: a shape's number, or nil for the background.
        var rootShape: Int?
        var madeAtLevel: Int
        var inner: Inner
    }
    private var refinements: [LevelMode: [Refinement]] = [:]

    private var stop = 0
    /// How many layers of refinement to show; nil shows them all.
    private var depthLimit: Int?
    private var fittingMode: LevelMode?
    private var generation = 0
    private var cancelFlag: CancelFlag?

    /// Fits run one at a time: a new fit starts only once the one it replaced has noticed
    /// its cancellation and stopped, so MLX is never driven by two fits at once.
    private static let fitQueue = DispatchQueue(label: "LayerFit.fit", qos: .userInitiated)

    private let runFit: FitRunner
    private let loadPhotoFile: PhotoLoader
    private let runRefine: RefineRunner

    public init(
        runFit: @escaping FitRunner = { target, settings, progress, isCancelled in
            Fitter(target: target, settings: settings).run(progress: progress, isCancelled: isCancelled)
        },
        loadPhoto: @escaping PhotoLoader = { try LayerFitCore.loadPhoto(url: $0, workingSize: $1) },
        runRefine: @escaping RefineRunner = { url, picture, node, settings, progress, isCancelled in
            try Refiner(photoURL: url, picture: picture, node: node, settings: settings)
                .run(progress: progress, isCancelled: isCancelled)
        }
    ) {
        self.runFit = runFit
        self.loadPhotoFile = loadPhoto
        self.runRefine = runRefine
    }

    // MARK: What is shown

    /// The levels of the mode being viewed.
    public var levels: [Level] { results[settings.mode] ?? [] }

    public var isFitting: Bool {
        if case .fitting = status { return true }
        return false
    }

    /// The slider position, kept within the levels that exist for the viewed mode.
    public var shownStop: Int { max(0, min(stop, levels.count - 1)) }

    /// The level at the slider's position, with the refinements that apply to it.
    public var shownLevel: Level? {
        guard !levels.isEmpty else { return nil }
        var level = levels[shownStop]
        attachRefinements(to: &level.picture, mode: settings.mode, level: shownStop)
        return level
    }

    // MARK: Refinements across levels

    /// Whether refinements of this mode appear on levels other than the one they were made on.
    private func shares(_ mode: LevelMode) -> Bool { mode == .prefix || carryRefinements }

    /// The index in `refinements[mode]` of the refinement shown for a picture-level region
    /// on a level: the one made on that level, else (when shared) the one made nearest it.
    private func refinementIndex(rootShape: Int?, mode: LevelMode, level: Int) -> Int? {
        let all = refinements[mode] ?? []
        let candidates = all.indices.filter { all[$0].rootShape == rootShape }
        if let exact = candidates.first(where: { all[$0].madeAtLevel == level }) { return exact }
        guard shares(mode) else { return nil }
        return candidates.min {
            let a = abs(all[$0].madeAtLevel - level)
            let b = abs(all[$1].madeAtLevel - level)
            return a != b ? a < b : all[$0].madeAtLevel < all[$1].madeAtLevel
        }
    }

    private func attachRefinements(to picture: inout LayerFitCore.Picture, mode: LevelMode, level: Int) {
        guard let all = refinements[mode], !all.isEmpty else { return }
        if let index = refinementIndex(rootShape: nil, mode: mode, level: level) {
            picture.backgroundInner = all[index].inner
        }
        for shape in picture.shapes.indices {
            if let index = refinementIndex(rootShape: shape, mode: mode, level: level) {
                picture.shapes[shape].inner = all[index].inner
            }
        }
    }

    /// Sets the refinement of a region of the picture shown on `level`. For a picture-level
    /// region this replaces (or creates) its refinement; deeper, it edits the refinement
    /// that region lives in.
    private func writeInner(_ inner: Inner, at node: NodeID, mode: LevelMode, level: Int) {
        let rootShape: Int? = node.inBackground ? nil : node.path.first
        let isRoot = node.inBackground ? node.path.isEmpty : node.path.count == 1
        var all = refinements[mode] ?? []
        defer { refinements[mode] = all }

        if isRoot {
            // In Prefix mode a region has one refinement whatever level it was made on;
            // otherwise each level can have its own.
            let existing =
                mode == .prefix
                ? all.firstIndex { $0.rootShape == rootShape }
                : all.firstIndex { $0.rootShape == rootShape && $0.madeAtLevel == level }
            if let existing {
                all[existing].inner = inner
            } else {
                all.append(Refinement(rootShape: rootShape, madeAtLevel: level, inner: inner))
            }
            return
        }
        guard let index = refinementIndex(rootShape: rootShape, mode: mode, level: level) else {
            return
        }
        // Edit inside the refinement by hanging it on a stand-in picture.
        let placeholder = LayerFitCore.Shape.circle(
            center: SIMD2(0, 0), radius: 1, color: RGB(r: 0, g: 0, b: 0))
        var scratch = LayerFitCore.Picture(
            width: 1, height: 1, background: RGB(r: 0, g: 0, b: 0),
            shapes: [LayerFitCore.Shape(points: placeholder.points, color: placeholder.color, inner: all[index].inner)])
        let below = node.inBackground ? node.path : Array(node.path.dropFirst())
        guard scratch.setInner(inner, at: .shape([0] + below)), let edited = scratch.shapes[0].inner
        else { return }
        all[index].inner = edited
    }

    public var shownPicture: LayerFitCore.Picture? {
        if isFitting, followsLatest, fittingMode == settings.mode, let livePicture {
            return livePicture
        }
        return shownLevel?.picture
    }

    public var caption: String {
        guard let picture = shownPicture else { return "" }
        return FitModel.caption(
            shapes: picture.shapeCount(maxDepth: shownDepth),
            bytes: picture.estimatedBytes(maxDepth: shownDepth), fileBytes: photo?.fileBytes ?? 0)
    }

    // MARK: Depth

    /// How many layers of refinement the shown picture has.
    public var maxDepth: Int { shownPicture?.maxDepth ?? 0 }

    /// How many of them are drawn.
    public var shownDepth: Int { min(depthLimit ?? Int.max, maxDepth) }

    public func setDepth(_ depth: Int) {
        guard !isRefining else { return }
        let clamped = max(0, min(depth, maxDepth))
        depthLimit = clamped == maxDepth ? nil : clamped
        if let selection, FitModel.depth(of: selection) > shownDepth { self.selection = nil }
    }

    /// 0 for the picture's own shapes and the background, 1 for shapes fitted inside
    /// those, and so on.
    private static func depth(of node: NodeID) -> Int {
        node.inBackground ? node.path.count : node.path.count - 1
    }

    // MARK: Selection

    /// The selected shape, for outlining; nil when nothing or the background is selected.
    public var selectedShape: LayerFitCore.Shape? {
        guard let selection else { return nil }
        return shownLevel?.picture.shape(at: selection)
    }

    public var selectionLabel: String {
        guard let selection else { return "Whole picture" }
        let steps = selection.path.map { "\($0 + 1)" }.joined(separator: " › ")
        if selection.inBackground {
            return steps.isEmpty ? "Background" : "Background › \(steps)"
        }
        return "Shape \(steps)"
    }

    /// Selects what is under a click, given in picture coordinates; nil (a click outside
    /// the picture) selects the whole picture again.
    public func select(at point: SIMD2<Float>?) {
        guard !isFitting else { return }
        guard let point, let picture = shownLevel?.picture else {
            selection = nil
            return
        }
        selection = picture.hitTest(point, maxDepth: shownDepth)
    }

    /// Moves the selection to the region the selected shape was fitted inside, or to the
    /// whole picture if it has none.
    public func selectParent() {
        guard !isFitting else { return }
        selection = selection?.parent
    }

    // MARK: The Level slider

    private var selectedInner: Inner? {
        guard let selection else { return nil }
        return shownLevel?.picture.inner(at: selection)
    }

    /// The Level slider's position: within the selected region's refinement, or within the
    /// picture's own levels when nothing is selected.
    public var sliderStop: Int {
        selection == nil ? shownStop : (selectedInner?.shownIndex ?? 0)
    }

    /// The slider's last position.
    public var sliderLast: Int {
        selection == nil ? max(levels.count - 1, 0) : max((selectedInner?.levels.count ?? 1) - 1, 0)
    }

    public nonisolated static func caption(shapes: Int, bytes: Int, fileBytes: Int) -> String {
        let english = Locale(identifier: "en_US")
        var parts = ["\(shapes) \(shapes == 1 ? "shape" : "shapes")"]
        parts.append(
            bytes < 1000
                ? "\(bytes) B"
                : (Double(bytes) / 1000).formatted(
                    .number.precision(.fractionLength(1)).locale(english)) + " kB")
        if fileBytes > 0 {
            if bytes >= fileBytes {
                parts.append("larger than the original")
            } else {
                let ratio = Int((Double(fileBytes) / Double(bytes)).rounded())
                parts.append("1/\(ratio.formatted(.number.locale(english))) of original")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Loads a photo. Stops any fit and discards the results of both modes. If the file
    /// cannot be read, the current photo and results are kept and `errorMessage` is set.
    public func open(_ url: URL) {
        let loaded: LoadedPhoto
        do {
            loaded = try loadPhotoFile(url, settings.workingSize)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        abandonRun()
        selection = nil
        depthLimit = nil
        photoURL = url
        photo = loaded
        results = [:]
        refinements = [:]
        stop = 0
        followsLatest = true
        status = .idle
    }

    /// Fits the loaded photo in the mode currently selected, replacing that mode's result.
    public func start() {
        guard let url = photoURL else { return }
        settings.stepsPerStage = min(max(settings.stepsPerStage, FitModel.stepsRange.lowerBound), FitModel.stepsRange.upperBound)
        let loaded: LoadedPhoto
        do {
            // Reload: the working size may have changed since the photo was opened.
            loaded = try loadPhotoFile(url, settings.workingSize)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        abandonRun()
        selection = nil
        depthLimit = nil
        photo = loaded

        let mode = settings.mode
        let runSettings = settings
        let stageCount = stageSchedule(totalShapes: runSettings.totalShapes).count
        results[mode] = []
        refinements[mode] = []
        stop = 0
        followsLatest = true
        fittingMode = mode
        status = .fitting(stage: 0, stageCount: stageCount)

        generation += 1
        let run = generation
        let flag = CancelFlag()
        cancelFlag = flag
        let runFit = self.runFit
        let target = loaded.target

        // The fit reports from its own thread; the stream hands its reports to the main
        // actor one at a time, in order.
        let (stream, continuation) = AsyncStream.makeStream(of: FitProgress.self)
        FitModel.fitQueue.async {
            _ = runFit(target, runSettings, { continuation.yield($0) }, { flag.isCancelled })
            continuation.finish()
        }
        Task { [weak self] in
            for await progress in stream {
                guard let self, self.generation == run else { continue }
                self.receive(progress, mode: mode)
            }
            guard let self, self.generation == run else { return }
            self.livePicture = nil
            self.fittingMode = nil
            self.cancelFlag = nil
            self.status = flag.isCancelled ? .cancelled : .done
        }
    }

    public var canRefine: Bool {
        selection != nil && !isFitting && shownLevel != nil && photoURL != nil
    }

    /// Fits finer shapes inside the selected region of the level shown, using the current
    /// settings, and attaches them to it. Any refinement that region already has is
    /// replaced. The view is locked until it finishes or is cancelled.
    public func refine() {
        guard canRefine, let node = selection, let url = photoURL, let level = shownLevel else {
            return
        }
        settings.stepsPerStage = min(
            max(settings.stepsPerStage, FitModel.stepsRange.lowerBound), FitModel.stepsRange.upperBound)
        abandonRun()

        let mode = settings.mode
        let rootStop = shownStop
        let runSettings = settings
        let picture = level.picture
        depthLimit = nil
        isRefining = true
        status = .fitting(stage: 0, stageCount: stageSchedule(totalShapes: runSettings.totalShapes).count)

        generation += 1
        let run = generation
        let flag = CancelFlag()
        cancelFlag = flag
        let runRefine = self.runRefine
        let failure = FailureBox()

        let (stream, continuation) = AsyncStream.makeStream(of: RefineProgress.self)
        FitModel.fitQueue.async {
            do {
                _ = try runRefine(
                    url, picture, node, runSettings, { continuation.yield($0) }, { flag.isCancelled })
            } catch {
                failure.set(error)
            }
            continuation.finish()
        }
        Task { [weak self] in
            var finished: [InnerLevel] = []
            for await progress in stream {
                guard let self, self.generation == run, !flag.isCancelled else { continue }
                self.status = .fitting(stage: progress.stage, stageCount: progress.stageCount)
                if let level = progress.finishedLevel {
                    finished.append(level)
                    self.writeInner(
                        Inner(levels: finished, shown: finished.count - 1), at: node, mode: mode,
                        level: rootStop)
                }
            }
            guard let self, self.generation == run else { return }
            self.isRefining = false
            self.cancelFlag = nil
            if let error = failure.error {
                self.errorMessage = error.localizedDescription
                self.status = .done
            } else {
                self.status = flag.isCancelled ? .cancelled : .done
            }
        }
    }

    /// Stops the fit at its next step and keeps the levels finished so far.
    public func cancel() {
        cancelFlag?.cancel()
    }

    public func userMovedSlider(to newStop: Int) {
        guard !isRefining else { return }
        if let selection {
            guard var inner = selectedInner, !inner.levels.isEmpty, levels.indices.contains(shownStop)
            else { return }
            inner.shown = max(0, min(newStop, inner.levels.count - 1))
            writeInner(inner, at: selection, mode: settings.mode, level: shownStop)
            return
        }
        stop = max(0, min(newStop, levels.count - 1))
        // Parking on the newest level means "keep following".
        followsLatest = stop == levels.count - 1
    }

    /// Writes the level shown on the slider as SVG, at the original photo's pixel size.
    public func exportSVG(to url: URL) throws {
        guard let level = shownLevel, let photo else { throw ExportError.nothingToExport }
        try svg(level.picture, outputSize: photo.originalPixelSize, maxDepth: shownDepth)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Internals

    /// Stops the current run, if any, and makes sure nothing it reports later is applied.
    private func abandonRun() {
        cancelFlag?.cancel()
        cancelFlag = nil
        generation += 1
        livePicture = nil
        fittingMode = nil
        isRefining = false
    }

    private func receive(_ progress: FitProgress, mode: LevelMode) {
        // A fit told to stop may still report what it had in hand; it no longer counts.
        guard cancelFlag?.isCancelled == false else { return }
        livePicture = progress.picture
        status = .fitting(stage: progress.stage, stageCount: progress.stageCount)
        if let level = progress.finishedLevel {
            results[mode, default: []].append(level)
            if followsLatest && settings.mode == mode {
                stop = (results[mode]?.count ?? 1) - 1
            }
        }
    }
}
