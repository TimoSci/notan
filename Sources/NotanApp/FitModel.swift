import CoreGraphics
import Foundation
import NotanCore
import Observation

/// One way of fitting a photo, with a result of its own: curves or tiles, for tiles the
/// order of the cuts, and how the levels relate.
public struct Variant: Hashable, Sendable {
    public var kind: ShapeKind
    /// Which tiles are cut at each stage; nil for curves, which are not cut.
    public var order: TileOrder?
    public var mode: LevelMode

    public init(kind: ShapeKind, order: TileOrder?, mode: LevelMode) {
        self.kind = kind
        self.order = kind == .tiles ? order : nil
        self.mode = mode
    }

    public init(_ settings: FitSettings) {
        self.init(kind: settings.kind, order: settings.tileOrder, mode: settings.mode)
    }

    public static func curves(_ mode: LevelMode) -> Variant {
        Variant(kind: .curves, order: nil, mode: mode)
    }
}

/// Runs one fit to completion on the calling thread: target, settings, progress, isCancelled.
public typealias FitRunner = (
    TargetImage, FitSettings, @escaping (FitProgress) -> Void, @escaping () -> Bool
) -> [Level]

public typealias PhotoLoader = (URL, Int) throws -> LoadedPhoto

/// Runs one refinement to completion on the calling thread: photo, picture as shown, the
/// region to refine, settings, progress, isCancelled.
public typealias RefineRunner = (
    URL, NotanCore.Picture, NodeID, FitSettings, @escaping (RefineProgress) -> Void,
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
    private var stored: Error?  // the first one reported

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
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

    /// The stops of the fold strength slider, each about three times the one before.
    /// Below the first, folds are barely held back; at the last, no outline crosses
    /// itself, at a clear cost in fit.
    public static let foldStrengthChoices: [Float] = [0.3, 1, 3, 10, 30, 100]

    /// The stop nearest a strength, by ratio.
    public static func foldStrengthIndex(_ strength: Float) -> Int {
        let target = log(max(strength, 1e-6))
        return foldStrengthChoices.indices.min {
            abs(log(foldStrengthChoices[$0]) - target) < abs(log(foldStrengthChoices[$1]) - target)
        } ?? foldStrengthChoices.count - 1
    }

    public static func foldStrengthLabel(_ strength: Float) -> String {
        strength.formatted(.number.precision(.significantDigits(1)))
    }

    /// What the Folds slider reads at a tolerance: the two ends by name, the rest as a
    /// share of the most a shape can fold, which is a bow-tie.
    public static func foldLabel(_ tolerance: Float) -> String {
        if tolerance <= 0 { return "None" }
        if tolerance >= FitSettings.maxFoldTolerance { return "Any" }
        return "\(Int((tolerance / FitSettings.maxFoldTolerance * 100).rounded()))%"
    }

    public var settings = FitSettings() {
        didSet {
            // A selection names a shape of one variant's picture.
            if Variant(oldValue) != variant, !isRefining { selection = nil }
        }
    }
    /// The regions Refine acts on, in the order they were selected; none is the whole
    /// picture. No two of them lie one inside the other.
    public private(set) var selected: [NodeID] = []
    /// The region the Level slider and Parent act on: the selected one, when there is
    /// exactly one.
    public private(set) var selection: NodeID? {
        get { selected.count == 1 ? selected[0] : nil }
        set { selected = newValue.map { [$0] } ?? [] }
    }
    /// How many refinements run at the same time. Measured on fits of different pictures:
    /// four at once finish in 0.6 of the time they take one after another, with exactly
    /// the same results, and eight are no faster than four.
    public static let refinementsAtOnce = 4
    /// True while a refinement inside a shape is running (as opposed to a whole-picture fit).
    public private(set) var isRefining = false
    public private(set) var photoURL: URL?
    public private(set) var photo: LoadedPhoto?
    /// Finished levels per mode, for the loaded photo. Level 0 is the background alone.
    public private(set) var results: [Variant: [Level]] = [:]
    /// The newest state of the fit in progress, including its unfinished stage.
    public private(set) var livePicture: NotanCore.Picture?
    public private(set) var status: Status = .idle
    /// True while the picture should track the fit; false once the user picks a level.
    public private(set) var followsLatest = true
    public var errorMessage: String?

    /// Refinements are kept beside the levels, not inside them, so that one refinement can
    /// be shown on several levels.
    private struct Refinement {
        /// Stays the same for as long as the refinement exists; names it in the tree.
        let id: Int
        var root: Root
        var madeAtLevel: Int
        var inner: Inner
        /// A locked area is painted on top of every later level, as it was on its own.
        var isLocked = true
    }
    /// The picture-level region a refinement belongs to, by number.
    private enum Root: Equatable {
        case shape(Int)
        case gap(Int)

        init(_ node: NodeID) {
            self = node.inBackground ? .gap(node.gap) : .shape(node.path.first ?? 0)
        }

        var isGap: Bool {
            if case .gap = self { return true }
            return false
        }

        var node: NodeID {
            switch self {
            case .shape(let index): return .shape([index])
            case .gap(let index): return .gap(index)
            }
        }
    }
    private var refinements: [Variant: [Refinement]] = [:]
    private var nextRefinementID = 0

    /// A refined tile: the finer tiles that take its place. Kept beside the levels, as
    /// curve refinements are.
    private struct TileRefinement {
        let id: Int
        /// The tile's place in the tree of cuts.
        var path: [Int]
        var madeAtLevel: Int
        var inner: Inner
        /// In Prefix a tile has the same outline on every later level, and a locked
        /// refinement of it is shown on all of them. In Re-fit the outline differs from
        /// level to level, so a refinement shows where it was made and nowhere else.
        var isLocked = true
        /// For a tile refined inside another refinement: that refinement, and which of
        /// its levels this one was made on. It shows only while that level does.
        var parent: Int?
        var parentLevel = 0
    }
    private var tileRefinements: [Variant: [TileRefinement]] = [:]

    private var stop = 0
    /// How many layers of refinement to show; nil shows them all.
    private var depthLimit: Int?
    private var fittingMode: Variant?
    private var generation = 0
    private var cancelFlag: CancelFlag?

    /// Fits run one at a time: a new fit starts only once the one it replaced has noticed
    /// its cancellation and stopped, so MLX is never driven by two fits at once.
    private static let fitQueue = DispatchQueue(label: "Notan.fit", qos: .userInitiated)

    private let runFit: FitRunner
    private let loadPhotoFile: PhotoLoader
    private let runRefine: RefineRunner

    public init(
        runFit: @escaping FitRunner = { target, settings, progress, isCancelled in
            settings.kind == .tiles
                ? TileFitter(target: target, settings: settings).run(
                    progress: progress, isCancelled: isCancelled)
                : Fitter(target: target, settings: settings).run(
                    progress: progress, isCancelled: isCancelled)
        },
        loadPhoto: @escaping PhotoLoader = { try NotanCore.loadPhoto(url: $0, workingSize: $1) },
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

    /// Which of the photo's results is being viewed, and would be fitted by Start.
    public var variant: Variant { Variant(settings) }

    /// Whether the picture is built from tiles, not curves.
    public var isTiling: Bool { settings.kind == .tiles }

    /// The levels of the variant being viewed.
    public var levels: [Level] { results[variant] ?? [] }

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
        attachRefinements(to: &level.picture, mode: variant, level: shownStop)
        return level
    }

    // MARK: Refinements across levels

    /// The index in `refinements[mode]` of the refinement shown inside one of a level's own
    /// regions: the one made on that level. In Prefix mode a shape is the same on every
    /// level, so there an unlocked refinement of it is shown on all of them.
    private func ownIndex(root: Root, mode: Variant, level: Int) -> Int? {
        let all = refinements[mode] ?? []
        if let exact = all.firstIndex(where: { $0.root == root && $0.madeAtLevel == level }) {
            return exact
        }
        guard mode.mode == .prefix, !root.isGap else { return nil }
        return all.firstIndex { $0.root == root && !$0.isLocked }
    }

    /// The locked areas painted on top of a level, in painting order, each with the index
    /// of its refinement: those made on earlier levels. The earliest is painted last, so
    /// that where two overlap, the one locked first is the one that shows.
    private func lockedAreas(mode: Variant, level: Int) -> [(index: Int, area: LockedArea)] {
        let all = refinements[mode] ?? []
        let levels = results[mode] ?? []
        let above = all.indices
            .filter {
                all[$0].isLocked && all[$0].madeAtLevel < level
                    && levels.indices.contains(all[$0].madeAtLevel)
            }
            .sorted { (all[$0].madeAtLevel, $0) > (all[$1].madeAtLevel, $1) }
        return above.compactMap { index in
            var source = levels[all[index].madeAtLevel].picture
            let node = all[index].root.node
            guard source.setInner(all[index].inner, at: node) else { return nil }
            return (index, LockedArea(picture: source, node: node))
        }
    }

    /// The tile refinements shown on a level, by index, in the order they are applied:
    /// each before any made inside it.
    private func shownTileRefinements(mode: Variant, level: Int) -> [Int] {
        let all = tileRefinements[mode] ?? []
        let tops = all.indices
            .filter {
                all[$0].parent == nil
                    && (all[$0].madeAtLevel == level
                        || (mode.mode == .prefix && all[$0].isLocked && all[$0].madeAtLevel < level))
            }
            .sorted { (all[$0].path.count, all[$0].madeAtLevel, $0) < (all[$1].path.count, all[$1].madeAtLevel, $1) }
        var shown: [Int] = []
        // A refined tile takes the place of everything in it, so a refinement of a tile
        // inside one already shown is not: the larger, or the one locked first, wins.
        for index in tops where !shown.contains(where: { all[index].path.starts(with: all[$0].path) }) {
            shown.append(index)
        }
        var grew = true
        while grew {
            grew = false
            for index in all.indices where !shown.contains(index) {
                guard let parent = all[index].parent,
                    let outer = shown.first(where: { all[$0].id == parent }),
                    all[outer].inner.shownIndex == all[index].parentLevel
                else { continue }
                shown.append(index)
                grew = true
            }
        }
        return shown
    }

    private func attachTileRefinements(to picture: inout NotanCore.Picture, mode: Variant, level: Int) {
        guard let all = tileRefinements[mode], !all.isEmpty else { return }
        for index in shownTileRefinements(mode: mode, level: level) {
            picture.replaceTiles(under: all[index].path, with: all[index].inner.tiles)
        }
    }

    /// Sets the refinement of a tile of the picture shown on `level`: of a refined tile
    /// its own, of a tile inside a refined one a new one made inside that, of any other a
    /// new one of its own. With `afresh`, for a new fit of the tile, whatever was refined
    /// inside it before is dropped.
    private func writeTileInner(_ inner: Inner, at node: NodeID, mode: Variant, level: Int, afresh: Bool) {
        var all = tileRefinements[mode] ?? []
        defer { tileRefinements[mode] = all }
        func dropInside(_ id: Int) {
            for inside in all.filter({ $0.parent == id }).map(\.id) { dropInside(inside) }
            all.removeAll { $0.parent == id }
        }
        let shown = shownTileRefinements(mode: mode, level: level)
        if let own = shown.first(where: { all[$0].path == node.path }) {
            let id = all[own].id
            all[own].inner = inner
            if afresh { dropInside(id) }
            return
        }
        // The innermost refinement shown whose tiles the tile is one of, or a group of.
        let outer = shown
            .filter { index in
                node.path.starts(with: all[index].path)
                    && all[index].inner.tiles.contains { $0.path.starts(with: node.path) }
            }
            .max { all[$0].path.count < all[$1].path.count }
        if let outer {
            all.append(
                TileRefinement(
                    id: nextRefinementID, path: node.path, madeAtLevel: level, inner: inner,
                    parent: all[outer].id, parentLevel: all[outer].inner.shownIndex))
            nextRefinementID += 1
            return
        }
        // In Prefix a tile has one refinement, whatever level it was made on.
        if mode.mode == .prefix,
            let existing = all.firstIndex(where: { $0.parent == nil && $0.path == node.path })
        {
            let id = all[existing].id
            all[existing].inner = inner
            all[existing].madeAtLevel = min(all[existing].madeAtLevel, level)
            if afresh { dropInside(id) }
            return
        }
        all.append(
            TileRefinement(id: nextRefinementID, path: node.path, madeAtLevel: level, inner: inner))
        nextRefinementID += 1
    }

    private func attachRefinements(to picture: inout NotanCore.Picture, mode: Variant, level: Int) {
        if !picture.tiles.isEmpty {
            attachTileRefinements(to: &picture, mode: mode, level: level)
            return
        }
        guard let all = refinements[mode], !all.isEmpty else { return }
        // A picture whose gaps are not told apart still has gap 0: the whole uncovered area.
        for gap in 0..<max(picture.gaps.count, 1) {
            if let index = ownIndex(root: .gap(gap), mode: mode, level: level) {
                picture.setInner(all[index].inner, at: .gap(gap))
            }
        }
        for shape in picture.shapes.indices {
            if let index = ownIndex(root: .shape(shape), mode: mode, level: level) {
                picture.shapes[shape].inner = all[index].inner
            }
        }
        picture.locked = lockedAreas(mode: mode, level: level).map(\.area)
    }

    /// `inner` with the refinement of the shape at `path` below it replaced by `replacement`.
    private static func edited(_ inner: Inner, below path: [Int], with replacement: Inner) -> Inner? {
        // Edit inside the refinement by hanging it on a stand-in picture.
        let placeholder = NotanCore.Shape.circle(
            center: SIMD2(0, 0), radius: 1, color: RGB(r: 0, g: 0, b: 0))
        var scratch = NotanCore.Picture(
            width: 1, height: 1, background: RGB(r: 0, g: 0, b: 0),
            shapes: [NotanCore.Shape(points: placeholder.points, color: placeholder.color, inner: inner)])
        guard scratch.setInner(replacement, at: .shape([0] + path)) else { return nil }
        return scratch.shapes[0].inner
    }

    /// Sets the refinement of a region of the picture shown on `level`. For one of the
    /// level's own shapes or gaps this replaces (or creates) its refinement; for a locked
    /// area, or anything deeper, it edits the refinement that region lives in.
    private func writeInner(_ inner: Inner, at node: NodeID, mode: Variant, level: Int) {
        var all = refinements[mode] ?? []
        defer { refinements[mode] = all }
        let isRoot = node.inBackground ? node.path.isEmpty : node.path.count == 1
        let below = node.inBackground ? node.path : Array(node.path.dropFirst())

        if let number = node.locked {
            let areas = lockedAreas(mode: mode, level: level)
            guard areas.indices.contains(number) else { return }
            let index = areas[number].index
            if isRoot {
                all[index].inner = inner
            } else if let edited = FitModel.edited(all[index].inner, below: below, with: inner) {
                all[index].inner = edited
            }
            return
        }

        let root = Root(node)
        if isRoot {
            // In Prefix mode a shape has one refinement whatever level it was made on;
            // otherwise each level can have its own.
            let existing =
                mode.mode == .prefix && !root.isGap
                ? all.firstIndex { $0.root == root }
                : all.firstIndex { $0.root == root && $0.madeAtLevel == level }
            if let existing {
                all[existing].inner = inner
                all[existing].madeAtLevel = level
            } else {
                all.append(Refinement(id: nextRefinementID, root: root, madeAtLevel: level, inner: inner))
                nextRefinementID += 1
            }
            return
        }
        guard let index = ownIndex(root: root, mode: mode, level: level),
            let edited = FitModel.edited(all[index].inner, below: below, with: inner)
        else { return }
        all[index].inner = edited
    }

    // MARK: The tree of refined areas

    /// One row of the tree: a level, an area refined on it, or something refined inside
    /// such an area.
    public struct LockNode: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case level
            case area
            case inside
        }

        public var id: String
        public var title: String
        public var kind: Kind
        /// Whether the area is locked; nil for rows that are not areas.
        public var isLocked: Bool?
        public var children: [LockNode]?

        fileprivate var level = 0
        fileprivate var refinement: Int?
    }

    /// The refined areas of the mode being viewed, grouped by the level they were made on.
    public var lockTree: [LockNode] {
        if isTiling { return tileLockTree }
        let mode = variant
        let all = refinements[mode] ?? []
        let levels = results[mode] ?? []
        func inside(_ shapes: [NotanCore.Shape], of title: String, id: String) -> [LockNode]? {
            let rows = shapes.enumerated().compactMap { index, shape -> LockNode? in
                guard let inner = shape.inner else { return nil }
                let own = "\(title) › \(index + 1)"
                return LockNode(
                    id: "\(id)-\(index)", title: own, kind: .inside,
                    children: inside(inner.shapes, of: own, id: "\(id)-\(index)"))
            }
            return rows.isEmpty ? nil : rows
        }
        return Set(all.map(\.madeAtLevel)).sorted().map { level in
            let areas = all.filter { $0.madeAtLevel == level }.map { refinement -> LockNode in
                let title: String
                switch refinement.root {
                case .shape(let index): title = "Shape \(index + 1)"
                case .gap(let index):
                    let gapCount = levels.indices.contains(level) ? levels[level].picture.gaps.count : 0
                    title = gapCount > 1 ? "Gap \(index + 1)" : "Background"
                }
                let id = "area-\(refinement.id)"
                return LockNode(
                    id: id, title: title, kind: .area, isLocked: refinement.isLocked,
                    children: inside(refinement.inner.shapes, of: title, id: id), level: level,
                    refinement: refinement.id)
            }
            return LockNode(
                id: "level-\(level)", title: "Level \(level)", kind: .level, children: areas,
                level: level)
        }
    }

    /// The refined tiles of the variant being viewed, grouped by the level they were made
    /// on, each with the tiles refined inside it. Only in Prefix can a tile be locked.
    private var tileLockTree: [LockNode] {
        let mode = variant
        let all = tileRefinements[mode] ?? []
        func title(_ refinement: TileRefinement) -> String {
            "Tile " + refinement.path.map { "\($0 + 1)" }.joined(separator: " › ")
        }
        func inside(_ id: Int, level: Int) -> [LockNode]? {
            let rows = all.filter { $0.parent == id }.map { refinement in
                LockNode(
                    id: "tile-\(refinement.id)", title: title(refinement), kind: .inside,
                    children: inside(refinement.id, level: level), level: level,
                    refinement: refinement.id)
            }
            return rows.isEmpty ? nil : rows
        }
        let tops = all.filter { $0.parent == nil }
        return Set(tops.map(\.madeAtLevel)).sorted().map { level in
            let areas = tops.filter { $0.madeAtLevel == level }.map { refinement in
                LockNode(
                    id: "tile-\(refinement.id)", title: title(refinement), kind: .area,
                    isLocked: mode.mode == .prefix ? refinement.isLocked : nil,
                    children: inside(refinement.id, level: level), level: level,
                    refinement: refinement.id)
            }
            return LockNode(
                id: "level-\(level)", title: "Level \(level)", kind: .level, children: areas,
                level: level)
        }
    }

    /// Locks or unlocks an area of the tree. The selection is dropped: the regions it
    /// names may no longer be where they were.
    public func setLocked(_ locked: Bool, area: LockNode) {
        guard !isFitting, let id = area.refinement else { return }
        if let index = tileRefinements[variant]?.firstIndex(where: { $0.id == id }) {
            tileRefinements[variant]?[index].isLocked = locked
            selected = []
            return
        }
        guard let index = refinements[variant]?.firstIndex(where: { $0.id == id }) else { return }
        refinements[variant]?[index].isLocked = locked
        selected = []
    }

    /// Goes to the level a row of the tree belongs to and, for an area, selects it.
    public func show(area: LockNode) {
        guard !isFitting, levels.indices.contains(area.level) else { return }
        selected = []
        stop = area.level
        followsLatest = stop == levels.count - 1
        guard let id = area.refinement else { return }
        if let tile = tileRefinements[variant]?.first(where: { $0.id == id }) {
            // A tile refined inside another shows only on the level of that one it was made on.
            var levelOf: [Int: Int] = [:]
            var inside = tile
            while let parent = inside.parent,
                let outer = tileRefinements[variant]?.firstIndex(where: { $0.id == parent })
            {
                levelOf[outer] = inside.parentLevel
                inside = tileRefinements[variant]![outer]
            }
            for (outer, level) in levelOf { tileRefinements[variant]?[outer].inner.shown = level }
            selected = [.tile(tile.path)]
            return
        }
        guard let refinement = refinements[variant]?.first(where: { $0.id == id }) else { return }
        selected = [refinement.root.node]
    }

    public var shownPicture: NotanCore.Picture? {
        if isFitting, followsLatest, fittingMode == variant, let livePicture {
            return livePicture
        }
        return shownLevel?.picture
    }

    public var caption: String {
        guard let picture = shownPicture else { return "" }
        return FitModel.caption(
            shapes: picture.shapeCount(maxDepth: shownDepth),
            bytes: picture.estimatedBytes(maxDepth: shownDepth), fileBytes: photo?.fileBytes ?? 0,
            tiles: !picture.tiles.isEmpty)
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
        selected.removeAll { FitModel.depth(of: $0) > shownDepth }
    }

    /// 0 for the picture's own shapes and the background, 1 for shapes fitted inside
    /// those, and so on.
    private static func depth(of node: NodeID) -> Int {
        node.inBackground ? node.path.count : node.path.count - 1
    }

    // MARK: Selection

    /// The selected shape, for outlining; nil when nothing or the background is selected.
    public var selectedShape: NotanCore.Shape? {
        guard let selection else { return nil }
        return shownLevel?.picture.shape(at: selection)
    }

    /// White where the selected gap shows, for highlighting it; nil unless a gap is selected.
    public var selectedGapMask: CGImage? {
        guard let selection, selection.isBackground, let picture = shownLevel?.picture else {
            return nil
        }
        return maskImage(picture, node: selection, scale: 2)
    }

    /// Every selected shape, for outlining.
    public var selectedShapes: [NotanCore.Shape] {
        guard let picture = shownLevel?.picture else { return [] }
        return selected.compactMap { picture.shape(at: $0) }
    }

    /// For every selected gap, white where it shows.
    public var selectedGapMasks: [CGImage] {
        guard let picture = shownLevel?.picture else { return [] }
        return selected.filter(\.isBackground).compactMap { maskImage(picture, node: $0, scale: 2) }
    }

    /// For every selected tile, the tiles it stands for at the level shown: itself, or the
    /// pieces it has been cut into by then.
    public var selectedTiles: [[Tile]] {
        guard let picture = shownLevel?.picture else { return [] }
        return selected.filter(\.isTile).map { picture.tiles(under: $0) }
    }

    /// Whether a gap, or the background as a whole, is among the selected regions.
    public var backgroundSelected: Bool { selected.contains(where: \.isBackground) }

    public var selectionLabel: String {
        if selected.count > 1 {
            let kind =
                selected.contains(where: \.isTile)
                ? "tiles" : (selected.contains(where: \.isBackground) ? "regions" : "shapes")
            return "\(selected.count) \(kind) selected"
        }
        guard let selection else { return "Whole picture" }
        if selection.isTile {
            return "Tile " + selection.path.map { "\($0 + 1)" }.joined(separator: " › ")
        }
        // A region of a locked area is named as in the picture of the level it is from.
        var home = shownLevel?.picture
        var suffix = ""
        if let number = selection.locked {
            let areas = lockedAreas(mode: variant, level: shownStop)
            guard areas.indices.contains(number) else { return "Whole picture" }
            home = areas[number].area.picture
            let level = refinements[variant]?[areas[number].index].madeAtLevel ?? 0
            suffix = ", locked on level \(level)"
        }
        let steps = selection.path.map { "\($0 + 1)" }.joined(separator: " › ")
        if selection.inBackground {
            // With one gap there is nothing to tell apart: it is simply the background.
            let gapCount = home?.gaps.count ?? 0
            let name = gapCount > 1 ? "Gap \(selection.gap + 1)" : "Background"
            return (steps.isEmpty ? name : "\(name) › \(steps)") + suffix
        }
        return "Shape \(steps)" + suffix
    }

    /// Selects what is under a click, given in picture coordinates; nil (a click outside
    /// the picture) selects the whole picture again.
    ///
    /// With `toggling` (a Shift-click) the region under the click joins the selection, or
    /// leaves it if it was selected already, and a click outside changes nothing. A
    /// region that joins displaces any selected region it lies inside or that lies inside
    /// it: refining a shape replaces everything in it, so the two cannot be refined
    /// together.
    public func select(at point: SIMD2<Float>?, toggling: Bool = false) {
        guard !isFitting else { return }
        let hit = point.flatMap { shownLevel?.picture.hitTest($0, maxDepth: shownDepth) }
        guard toggling else {
            selection = hit
            return
        }
        guard let hit else { return }
        if let index = selected.firstIndex(of: hit) {
            selected.remove(at: index)
            return
        }
        selected.removeAll { FitModel.lies($0, inside: hit) || FitModel.lies(hit, inside: $0) }
        selected.append(hit)
    }

    /// Whether `node` was fitted somewhere inside `other`.
    private static func lies(_ node: NodeID, inside other: NodeID) -> Bool {
        node != other && other.contains(node)
    }

    /// Moves the selection to the region the selected shape was fitted inside, or to the
    /// whole picture if it has none.
    public func selectParent() {
        guard !isFitting, selected.count == 1 else { return }
        selection = selection?.parent.flatMap(FitModel.meaningful)
    }

    /// The tile at the top of the tree is the whole picture, which is what no selection
    /// means; any other region stands for itself.
    private static func meaningful(_ node: NodeID) -> NodeID? {
        node.isTile && node.path.isEmpty ? nil : node
    }

    /// Tiles are selected by their place in the tree of cuts, which is the same on every
    /// level. On a level where a selected tile has not been cut out yet, the tile that
    /// contains it is selected in its place.
    private func resolveTileSelection() {
        guard let picture = shownLevel?.picture, selected.contains(where: \.isTile) else { return }
        var kept: [NodeID] = []
        for node in selected {
            let resolved = node.isTile ? picture.resolved(node).flatMap(FitModel.meaningful) : node
            // Two tiles may fall back to one that contains both.
            if let resolved, !kept.contains(where: { $0.contains(resolved) }) { kept.append(resolved) }
        }
        selected = kept
    }

    // MARK: The Level slider

    private var selectedInner: Inner? {
        guard let selection else { return nil }
        if selection.isTile {
            // A refined tile, as long as its refinement is shown on this level.
            let all = tileRefinements[variant] ?? []
            return shownTileRefinements(mode: variant, level: shownStop)
                .first { all[$0].path == selection.path }
                .map { all[$0].inner }
        }
        return shownLevel?.picture.inner(at: selection)
    }

    /// Whether the Level slider steps through the levels of the selected region's
    /// refinement, as opposed to the picture's own levels.
    public var sliderStepsSelection: Bool {
        isTiling ? selectedInner != nil : !selected.isEmpty
    }

    /// The Level slider's position: within the selected region's refinement, or within the
    /// picture's own levels when nothing is selected.
    public var sliderStop: Int {
        sliderStepsSelection ? (selectedInner?.shownIndex ?? 0) : shownStop
    }

    /// The slider's last position. With several regions selected there is no one set of
    /// levels to step through, so it is 0.
    public var sliderLast: Int {
        sliderStepsSelection
            ? max((selectedInner?.levels.count ?? 1) - 1, 0) : max(levels.count - 1, 0)
    }

    public nonisolated static func caption(
        shapes: Int, bytes: Int, fileBytes: Int, tiles: Bool = false
    ) -> String {
        let english = Locale(identifier: "en_US")
        let noun = tiles ? "tile" : "shape"
        var parts = ["\(shapes) \(shapes == 1 ? noun : noun + "s")"]
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
        tileRefinements = [:]
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

        let mode = variant
        let runSettings = settings
        let stageCount =
            runSettings.kind == .tiles
            ? tileSchedule(totalTiles: runSettings.totalShapes, order: runSettings.tileOrder).count
            : stageSchedule(totalShapes: runSettings.totalShapes).count
        results[mode] = []
        refinements[mode] = []
        tileRefinements[mode] = []
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
        !selected.isEmpty && !isFitting && shownLevel != nil && photoURL != nil
    }

    /// Fits finer shapes inside each selected region of the level shown, using the current
    /// settings, and attaches them to it. Any refinement a region already has is replaced.
    /// The regions are refined side by side, up to `refinementsAtOnce` at a time. The view
    /// is locked until all have finished or been cancelled.
    public func refine() {
        guard canRefine, let url = photoURL, let level = shownLevel else { return }
        let nodes = selected
        settings.stepsPerStage = min(
            max(settings.stepsPerStage, FitModel.stepsRange.lowerBound), FitModel.stepsRange.upperBound)
        abandonRun()

        let mode = variant
        let rootStop = shownStop
        let runSettings = settings
        let picture = level.picture
        depthLimit = nil
        isRefining = true
        let stagesEach =
            runSettings.kind == .tiles
            ? tileSchedule(totalTiles: runSettings.totalShapes, order: runSettings.tileOrder).count
            : stageSchedule(totalShapes: runSettings.totalShapes).count
        status = .fitting(stage: 0, stageCount: stagesEach * nodes.count)

        generation += 1
        let run = generation
        let flag = CancelFlag()
        cancelFlag = flag
        let runRefine = self.runRefine
        let failure = FailureBox()

        // Each report says which of the regions it is about.
        let (stream, continuation) = AsyncStream.makeStream(of: (Int, RefineProgress).self)
        FitModel.fitQueue.async {
            // The queue is held until every refinement is over, so the next run still
            // starts only once this one has stopped.
            FitModel.runSeveral(nodes.count, atOnce: FitModel.refinementsAtOnce) { index in
                do {
                    _ = try runRefine(
                        url, picture, nodes[index], runSettings, { continuation.yield((index, $0)) },
                        { flag.isCancelled })
                } catch {
                    failure.set(error)
                }
            }
            continuation.finish()
        }
        Task { [weak self] in
            var finished = [[InnerLevel]](repeating: [], count: nodes.count)
            var stages = [Int](repeating: 0, count: nodes.count)
            for await (index, progress) in stream {
                guard let self, self.generation == run, !flag.isCancelled else { continue }
                // Progress is counted over the stages of all the refinements together.
                stages[index] = progress.stage
                self.status = .fitting(
                    stage: stages.reduce(0, +), stageCount: progress.stageCount * nodes.count)
                if let level = progress.finishedLevel {
                    finished[index].append(level)
                    let inner = Inner(levels: finished[index], shown: finished[index].count - 1)
                    if nodes[index].isTile {
                        self.writeTileInner(
                            inner, at: nodes[index], mode: mode, level: rootStop, afresh: true)
                    } else {
                        self.writeInner(inner, at: nodes[index], mode: mode, level: rootStop)
                    }
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
        guard selected.count <= 1 || isTiling else { return }
        if let selection, isTiling, sliderStepsSelection {
            guard var inner = selectedInner, !inner.levels.isEmpty else { return }
            inner.shown = max(0, min(newStop, inner.levels.count - 1))
            writeTileInner(inner, at: selection, mode: variant, level: shownStop, afresh: false)
            return
        }
        if let selection, !isTiling {
            guard var inner = selectedInner, !inner.levels.isEmpty, levels.indices.contains(shownStop)
            else { return }
            inner.shown = max(0, min(newStop, inner.levels.count - 1))
            writeInner(inner, at: selection, mode: variant, level: shownStop)
            return
        }
        stop = max(0, min(newStop, levels.count - 1))
        // Parking on the newest level means "keep following".
        followsLatest = stop == levels.count - 1
        resolveTileSelection()
    }

    /// Writes the level shown on the slider as SVG, at the original photo's pixel size.
    public func exportSVG(to url: URL) throws {
        guard let level = shownLevel, let photo else { throw ExportError.nothingToExport }
        try svg(level.picture, outputSize: photo.originalPixelSize, maxDepth: shownDepth)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Internals

    /// Calls `body` with every index below `count`, on up to `atOnce` threads at a time,
    /// and returns when all the calls have.
    private nonisolated static func runSeveral(
        _ count: Int, atOnce: Int, _ body: @escaping @Sendable (Int) -> Void
    ) {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var next = 0

            func take() -> Int {
                lock.lock()
                defer { lock.unlock() }
                next += 1
                return next - 1
            }
        }
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: max(1, min(count, atOnce))) { _ in
            while true {
                let index = counter.take()
                if index >= count { return }
                body(index)
            }
        }
    }

    /// Stops the current run, if any, and makes sure nothing it reports later is applied.
    private func abandonRun() {
        cancelFlag?.cancel()
        cancelFlag = nil
        generation += 1
        livePicture = nil
        fittingMode = nil
        isRefining = false
    }

    private func receive(_ progress: FitProgress, mode: Variant) {
        // A fit told to stop may still report what it had in hand; it no longer counts.
        guard cancelFlag?.isCancelled == false else { return }
        livePicture = progress.picture
        status = .fitting(stage: progress.stage, stageCount: progress.stageCount)
        if let level = progress.finishedLevel {
            results[mode, default: []].append(level)
            if followsLatest && variant == mode {
                stop = (results[mode]?.count ?? 1) - 1
            }
        }
    }
}
