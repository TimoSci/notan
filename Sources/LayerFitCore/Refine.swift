import CoreGraphics
import Foundation

// Refining inside one region: fit finer shapes only where a chosen shape (or the
// background) is visible, zoomed into that region of the original photo. The rest of the
// picture is left exactly as it is.

/// Where a refinement looks and at what size it is fitted.
public struct RefinePlan: Equatable, Sendable {
    /// The rectangle of the picture, in picture coordinates, that the fit zooms into.
    public var viewport: CGRect
    /// The size in pixels the viewport is fitted at.
    public var width: Int
    public var height: Int
}

/// The zoom for refining `node`: its bounding box plus a small margin, clamped to the
/// picture (the whole picture for the background), fitted with its long side at
/// `workingSize` but never beyond the photo's own pixels. Nil if the node does not exist.
public func refinePlan(
    picture: Picture, node: NodeID, originalPixelSize: CGSize, workingSize: Int
) -> RefinePlan? {
    let whole = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
    var viewport = whole
    if node.isBackground {
        // One gap: zoom to its extent. Gaps not told apart: the whole picture, as gap 0.
        let map = picture.gaps.isEmpty ? nil : gapMap(of: picture)
        if let map, picture.gapsMatch(map) {
            guard let box = map.box(of: node.gap) else { return nil }
            viewport = box.insetBy(dx: -0.04 * box.width, dy: -0.04 * box.height).intersection(whole)
        } else if node.gap != 0 {
            return nil
        }
    } else {
        guard let shape = picture.shape(at: node) else { return nil }
        let polygon = samplePolygon(shape.points, samplesPerSegment: 8)
            .filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = polygon.first else { return nil }
        var low = first
        var high = first
        for point in polygon {
            low = pointwiseMin(low, point)
            high = pointwiseMax(high, point)
        }
        let box = CGRect(
            x: CGFloat(low.x), y: CGFloat(low.y), width: CGFloat(high.x - low.x),
            height: CGFloat(high.y - low.y))
        viewport = box.insetBy(dx: -0.04 * box.width, dy: -0.04 * box.height).intersection(whole)
        guard !viewport.isNull, viewport.width >= 1, viewport.height >= 1 else { return nil }
    }
    // How many of the photo's own pixels the viewport covers.
    let availableWidth = viewport.width * originalPixelSize.width / CGFloat(picture.width)
    let availableHeight = viewport.height * originalPixelSize.height / CGFloat(picture.height)
    let factor = min(1, CGFloat(workingSize) / max(availableWidth, availableHeight))
    return RefinePlan(
        viewport: viewport, width: max(1, Int((availableWidth * factor).rounded())),
        height: max(1, Int((availableHeight * factor).rounded())))
}

public struct RefineProgress: Sendable {
    /// 1-based stage being fitted; 0 for the report of level 0.
    public var stage: Int
    public var stageCount: Int
    /// Non-nil when a level has just finished, in picture coordinates.
    public var finishedLevel: InnerLevel?

    public init(stage: Int, stageCount: Int, finishedLevel: InnerLevel?) {
        self.stage = stage
        self.stageCount = stageCount
        self.finishedLevel = finishedLevel
    }
}

public enum RefineError: Error, LocalizedError, Equatable {
    case regionNotFound
    case regionNotVisible

    public var errorDescription: String? {
        switch self {
        case .regionNotFound: return "That shape is no longer in the picture."
        case .regionNotVisible:
            return "That shape is hidden behind other shapes or too small, so there is nothing to refine inside it."
        }
    }
}

public struct Refiner {
    public let photoURL: URL
    public let picture: Picture
    public let node: NodeID
    public let settings: FitSettings
    public let loss: LossConfig

    /// `picture` is the picture as shown; `node` the region of it to refine.
    /// `settings.workingSize` is the size the zoomed region is fitted at.
    public init(
        photoURL: URL, picture: Picture, node: NodeID, settings: FitSettings,
        loss: LossConfig = .init()
    ) {
        self.photoURL = photoURL
        self.picture = picture
        self.node = node
        self.settings = settings
        self.loss = loss
    }

    /// Blocking. Returns the levels finished so far, level 0 (no new shapes) first, with
    /// shapes in picture coordinates. Any refinement the node already has is ignored: the
    /// new levels are meant to replace it.
    public func run(progress: (RefineProgress) -> Void, isCancelled: () -> Bool) throws -> [InnerLevel] {
        let original = try photoPixelSize(url: photoURL)
        guard
            let plan = refinePlan(
                picture: picture, node: node, originalPixelSize: original,
                workingSize: settings.workingSize)
        else { throw RefineError.regionNotFound }

        let viewport = plan.viewport
        let maskPixels = renderRegion(
            picture, region: viewport, width: plan.width, height: plan.height,
            style: .mask(of: node))
        let mask = stride(from: 0, to: maskPixels.count, by: 3).map { maskPixels[$0] }
        guard mask.reduce(0, +) >= 4 else { throw RefineError.regionNotVisible }
        // Shapes fitted in a gap are drawn under the picture's shapes but not clipped to
        // the gap, so they are scored over every gap in view: straying into a neighbouring
        // gap then counts against them.
        var scored = mask
        if node.isBackground {
            let all = renderRegion(
                picture, region: viewport, width: plan.width, height: plan.height,
                style: .backgroundMask)
            scored = stride(from: 0, to: all.count, by: 3).map { all[$0] }
        }

        let target = try loadPhotoRegion(
            url: photoURL, region: viewport, pictureWidth: picture.width,
            pictureHeight: picture.height, width: plan.width, height: plan.height)
        let base = renderRegion(
            picture, region: viewport, width: plan.width, height: plan.height,
            omittingInnerOf: node)

        // Fitted in viewport pixels; stored in picture coordinates.
        let scale = SIMD2(
            Float(viewport.width) / Float(plan.width), Float(viewport.height) / Float(plan.height))
        let origin = SIMD2(Float(viewport.minX), Float(viewport.minY))
        func inPicture(_ level: Level) -> InnerLevel {
            InnerLevel(
                shapes: level.picture.shapes.map { shape in
                    Shape(
                        points: shape.points.map { $0 * scale + origin }, color: shape.color,
                        gradient: shape.gradient.map {
                            Gradient(
                                from: $0.from * scale + origin, to: $0.to * scale + origin,
                                endColor: $0.endColor)
                        })
                }, mse: level.mse)
        }

        let fitter = Fitter(
            target: target, settings: settings, loss: loss,
            region: FitRegion(base: base, mask: scored, seedMask: mask))
        let levels = fitter.run(
            progress: {
                progress(
                    RefineProgress(
                        stage: $0.stage, stageCount: $0.stageCount,
                        finishedLevel: $0.finishedLevel.map(inPicture)))
            }, isCancelled: isCancelled)
        return levels.map(inPicture)
    }
}
