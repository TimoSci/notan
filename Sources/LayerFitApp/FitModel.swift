import CoreGraphics
import Foundation
import LayerFitCore
import Observation

/// Runs one fit to completion on the calling thread: target, settings, progress, isCancelled.
public typealias FitRunner = (
    TargetImage, FitSettings, @escaping (FitProgress) -> Void, @escaping () -> Bool
) -> [Level]

public typealias PhotoLoader = (URL, Int) throws -> LoadedPhoto

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

    public var settings = FitSettings()
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

    private var stop = 0
    private var fittingMode: LevelMode?
    private var generation = 0
    private var cancelFlag: CancelFlag?

    private let runFit: FitRunner
    private let loadPhotoFile: PhotoLoader

    public init(
        runFit: @escaping FitRunner = { target, settings, progress, isCancelled in
            Fitter(target: target, settings: settings).run(progress: progress, isCancelled: isCancelled)
        },
        loadPhoto: @escaping PhotoLoader = { try LayerFitCore.loadPhoto(url: $0, workingSize: $1) }
    ) {
        self.runFit = runFit
        self.loadPhotoFile = loadPhoto
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

    public var shownLevel: Level? { levels.isEmpty ? nil : levels[shownStop] }

    public var shownPicture: LayerFitCore.Picture? {
        if isFitting, followsLatest, fittingMode == settings.mode, let livePicture {
            return livePicture
        }
        return shownLevel?.picture
    }

    public var caption: String {
        guard let picture = shownPicture else { return "" }
        return FitModel.caption(
            shapes: picture.shapes.count, bytes: picture.estimatedBytes,
            fileBytes: photo?.fileBytes ?? 0)
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
        photoURL = url
        photo = loaded
        results = [:]
        stop = 0
        followsLatest = true
        status = .idle
    }

    /// Fits the loaded photo in the mode currently selected, replacing that mode's result.
    public func start() {
        guard let url = photoURL else { return }
        let loaded: LoadedPhoto
        do {
            // Reload: the working size may have changed since the photo was opened.
            loaded = try loadPhotoFile(url, settings.workingSize)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        abandonRun()
        photo = loaded

        let mode = settings.mode
        let runSettings = settings
        let stageCount = stageSchedule(totalShapes: runSettings.totalShapes).count
        results[mode] = []
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
        Task.detached(priority: .userInitiated) {
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

    /// Stops the fit at its next step and keeps the levels finished so far.
    public func cancel() {
        cancelFlag?.cancel()
    }

    public func userMovedSlider(to newStop: Int) {
        stop = max(0, min(newStop, levels.count - 1))
        // Parking on the newest level means "keep following".
        followsLatest = stop == levels.count - 1
    }

    /// Writes the level shown on the slider as SVG, at the original photo's pixel size.
    public func exportSVG(to url: URL) throws {
        guard let level = shownLevel, let photo else { throw ExportError.nothingToExport }
        try svg(level.picture, outputSize: photo.originalPixelSize)
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
