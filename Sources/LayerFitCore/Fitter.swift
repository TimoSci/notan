import Foundation
import MLX

public struct FitProgress: Sendable {
    /// 1-based stage being fitted; 0 for the report of level 0.
    public var stage: Int
    public var stageCount: Int
    public var step: Int
    public var stepCount: Int
    public var picture: Picture
    /// Non-nil exactly once per stage, when it finishes, and once for level 0.
    public var finishedLevel: Level?

    public init(
        stage: Int, stageCount: Int, step: Int, stepCount: Int, picture: Picture,
        finishedLevel: Level?
    ) {
        self.stage = stage
        self.stageCount = stageCount
        self.step = step
        self.stepCount = stepCount
        self.picture = picture
        self.finishedLevel = finishedLevel
    }
}

/// The most memory MLX has held for arrays in use at once in this process, in bytes.
public func peakFitMemoryBytes() -> Int { Memory.peakMemory }

/// Restricts a fit to one region of an existing picture, for refining inside a shape.
public struct FitRegion: Sendable {
    /// The picture as it stands, at the target's size: row-major RGB 0…1. New shapes are
    /// painted on top of it, and it is not changed.
    public var base: [Float]
    /// One value per pixel, 0…1: where the region is visible. Shapes are seeded, scored
    /// and painted only there.
    public var mask: [Float]
    /// Where new shapes may start, if narrower than `mask`. Used to refine one gap: shapes
    /// start in that gap, but are scored over every gap, so spilling into another one costs.
    public var seedMask: [Float]?

    public init(base: [Float], mask: [Float], seedMask: [Float]? = nil) {
        self.base = base
        self.mask = mask
        self.seedMask = seedMask
    }
}

/// Layer-wise fitting after LIVE: shapes are added in stages, each seeded where the
/// picture is most wrong, then refined by gradient descent through the soft rasteriser.
public struct Fitter {
    public let target: TargetImage
    public let settings: FitSettings
    public let loss: LossConfig
    public let seedRule: SeedRule
    public let region: FitRegion?

    /// How often, in optimisation steps, an unfinished stage reports its current picture.
    public static let progressInterval = 10
    /// Edge softness, in pixels, used when measuring a level's error and placing seeds.
    public static let measuringSoftness: Float = 0.25
    /// How many bytes of freed buffers MLX may keep for reuse while fitting.
    public static let bufferCacheLimit = 16 << 30

    public init(
        target: TargetImage, settings: FitSettings, loss: LossConfig = .init(),
        seedRule: SeedRule = .error, region: FitRegion? = nil
    ) {
        precondition(region == nil || region!.base.count == target.pixels.count)
        precondition(region == nil || region!.mask.count == target.width * target.height)
        self.target = target
        self.settings = settings
        self.loss = loss
        self.seedRule = seedRule
        self.region = region
    }

    /// Blocking. Returns the levels finished so far, level 0 first, when done or cancelled.
    public func run(progress: (FitProgress) -> Void, isCancelled: () -> Bool) -> [Level] {
        let width = target.width
        let height = target.height
        // The shapes' windows change size as the shapes are fitted, so the buffers a step
        // frees often do not fit the next step's requests. Without a limit MLX keeps them
        // all and the process footprint grows without bound.
        Memory.cacheLimit = Fitter.bufferCacheLimit
        // LIVE's rates and reach are for ~256 px pictures; scale them with ours.
        let scale = Float(max(width, height)) / 256
        var lossConfig = loss
        lossConfig.boundaryReach = loss.boundaryReach * scale
        if !settings.avoidFolds { lossConfig.foldWeight = 0 }
        let pointRate = 1.0 * scale
        let colorRate: Float = 0.01

        let rasterizer = Rasterizer(width: width, height: height, softness: loss.softness)
        // Beyond this distance a shape's soft edge and its boundary weight are both nil.
        let cropMargin = max(16 * loss.softness, lossConfig.boundaryReach) + 1
        // A level's reported error is measured with near-hard edges, like the vectors the
        // user sees, so it does not include the blur of the soft raster used for fitting.
        let sharp = Rasterizer(width: width, height: height, softness: Fitter.measuringSoftness)
        let targetArray = MLXArray(target.pixels, [height, width, 3])
        let schedule = stageSchedule(totalShapes: settings.totalShapes)

        // Each shape keeps the minimum width of the stage it was added in.
        let stageMinWidths = minWidthSchedule(
            minWidth: settings.minWidth * scale, schedule: schedule,
            longSide: Float(max(width, height)))
        var shapeMinWidths: [Float] = []

        var picture = Picture(width: width, height: height, background: target.meanColor, shapes: [])
        var levels: [Level] = []

        // Inside a region: start from the existing picture and stay within the mask.
        let maskArray = region.map { MLXArray($0.mask, [height, width]) }
        let regionBase: (image: MLXArray, boundaryDistance: MLXArray)? = region.map {
            (
                MLXArray($0.base, [height, width, 3]),
                MLXArray.zeros([height, width]) + Rasterizer.noBoundary
            )
        }

        // What lies under the shapes when fitting a whole picture: each gap in its own
        // colour. Recomputed whenever a stage ends, and held fixed while one runs.
        var gapBase: (image: MLXArray, boundaryDistance: MLXArray)?
        func refreshGaps() {
            guard region == nil else { return }
            picture.assignGaps(from: target)
            gapBase = picture.gapLayer(gapMap(of: picture)).map {
                (
                    MLXArray($0, [height, width, 3]),
                    MLXArray.zeros([height, width]) + Rasterizer.noBoundary
                )
            }
        }

        func render(_ picture: Picture, with rasterizer: Rasterizer) -> MLXArray {
            rasterizer.render(
                points: pointsArray(picture.shapes), colors: colorsArray(picture.shapes),
                background: colorArray(picture.background), over: regionBase ?? gapBase,
                mask: maskArray,
                gradients: settings.gradients ? gradientArrays(picture.shapes) : nil
            ).image
        }
        func finish(stage: Int) {
            refreshGaps()
            let image = render(picture, with: sharp)
            let mse =
                (maskArray.map { maskedMSE(image: image, target: targetArray, mask: $0) }
                ?? plainMSE(image: image, target: targetArray)).item(Float.self)
            let level = Level(picture: picture, mse: mse)
            levels.append(level)
            progress(
                FitProgress(
                    stage: stage, stageCount: schedule.count, step: settings.stepsPerStage,
                    stepCount: settings.stepsPerStage, picture: picture, finishedLevel: level))
        }

        finish(stage: 0)

        for (stageIndex, addCount) in schedule.enumerated() {
            if isCancelled() { return levels }
            let stage = stageIndex + 1

            let current = render(picture, with: sharp).asArray(Float.self)
            let stageMinWidth = stageMinWidths[stageIndex]
            // A seed starts at least as wide as it must stay.
            let seeds = findSeeds(
                target: target, current: current, count: addCount, rule: seedRule,
                minRadius: max(2, stageMinWidth), mask: region?.seedMask ?? region?.mask)
            shapeMinWidths += Array(repeating: stageMinWidth, count: addCount)
            let frozenCount = settings.mode == .prefix ? picture.shapes.count : 0
            picture.shapes += seeds.map {
                var shape = Shape.circle(center: $0.center, radius: $0.radius, color: $0.color)
                if settings.gradients {
                    // Starts flat, with the axis across the seed; the two colours part as
                    // the fit finds a slope.
                    let reach = SIMD2<Float>($0.radius, 0)
                    shape.gradient = Gradient(
                        from: $0.center - reach, to: $0.center + reach, endColor: $0.color)
                }
                return shape
            }

            // Frozen shapes are rendered but never updated, so in prefix mode each level
            // stays an exact prefix of the next.
            let frozen = Array(picture.shapes.prefix(frozenCount))
            let movable = Array(picture.shapes.dropFirst(frozenCount))
            let frozenPoints = pointsArray(frozen)
            let frozenColors = colorsArray(frozen)
            let fixedBackground = colorArray(picture.background)
            // The background colour is not fitted: what shows between shapes is the gaps'
            // own colours (or, inside a region, the existing picture).
            let ground = regionBase ?? gapBase
            let minWidths: MLXArray? =
                settings.minWidth > 0 ? MLXArray(Array(shapeMinWidths.dropFirst(frozenCount))) : nil

            // Points, colours and, with gradients, end colours and axes.
            var parameters = [pointsArray(movable), colorsArray(movable)]
            var rates = [pointRate, colorRate]
            if settings.gradients {
                let arrays = gradientArrays(movable)
                parameters += [arrays.endColors, arrays.axes]
                rates += [colorRate, pointRate]
            }
            let colorParameters = settings.gradients ? [1, 2] : [1]
            var adam = Adam(learningRates: rates)

            // Frozen shapes never change during the stage: paint them once, outside the
            // gradient, and fit the new shapes on top.
            var base = ground
            if frozenCount > 0 {
                let rendered = rasterizer.render(
                    points: frozenPoints, colors: frozenColors, background: fixedBackground,
                    crops: frozen.map {
                        cropRect(points: $0.points, margin: cropMargin, width: width, height: height)
                    }, over: ground, mask: maskArray,
                    gradients: settings.gradients ? gradientArrays(frozen) : nil)
                eval(rendered.image, rendered.boundaryDistance)
                base = rendered
            }
            // Each movable shape is only evaluated near where it currently is.
            var crops: [PixelRect] = []
            func updateCrops() {
                let flat = parameters[0].asArray(Float.self)
                crops = (0..<movable.count).map { index in
                    let start = index * Shape.pointCount * 2
                    let points = (0..<Shape.pointCount).map {
                        SIMD2(flat[start + $0 * 2], flat[start + $0 * 2 + 1])
                    }
                    return cropRect(points: points, margin: cropMargin, width: width, height: height)
                }
            }

            let lossAndGradient = valueAndGrad(
                { (arrays: [MLXArray]) -> [MLXArray] in
                    let (image, boundary) = rasterizer.render(
                        points: arrays[0], colors: arrays[1], background: fixedBackground,
                        crops: crops, over: base, mask: maskArray,
                        gradients: settings.gradients ? (arrays[3], arrays[2]) : nil)
                    return [
                        fitLoss(
                            image: image, target: targetArray, boundaryDistance: boundary,
                            points: arrays[0], config: lossConfig, minWidths: minWidths,
                            mask: maskArray)
                    ]
                }, argumentNumbers: Array(parameters.indices))

            func snapshot() -> Picture {
                var result = picture
                let points = parameters[0].asArray(Float.self)
                let colors = parameters[1].asArray(Float.self)
                let ends = settings.gradients ? parameters[2].asArray(Float.self) : []
                let axes = settings.gradients ? parameters[3].asArray(Float.self) : []
                for index in 0..<movable.count {
                    let base = index * Shape.pointCount * 2
                    result.shapes[frozenCount + index] = Shape(
                        points: (0..<Shape.pointCount).map {
                            SIMD2(points[base + $0 * 2], points[base + $0 * 2 + 1])
                        },
                        color: RGB(
                            r: colors[index * 3], g: colors[index * 3 + 1], b: colors[index * 3 + 2]),
                        gradient: settings.gradients
                            ? Gradient(
                                from: SIMD2(axes[index * 4], axes[index * 4 + 1]),
                                to: SIMD2(axes[index * 4 + 2], axes[index * 4 + 3]),
                                endColor: RGB(
                                    r: ends[index * 3], g: ends[index * 3 + 1],
                                    b: ends[index * 3 + 2]))
                            : nil)
                }
                return result
            }

            for step in 1...max(settings.stepsPerStage, 1) {
                if isCancelled() { return levels }
                updateCrops()
                let (_, gradients) = onOneStream { lossAndGradient(parameters) }
                parameters = adam.step(parameters: parameters, gradients: gradients)
                for index in colorParameters {
                    parameters[index] = clip(parameters[index], min: 0, max: 1)
                }
                eval(parameters)
                if step % Fitter.progressInterval == 0 && step < settings.stepsPerStage {
                    progress(
                        FitProgress(
                            stage: stage, stageCount: schedule.count, step: step,
                            stepCount: settings.stepsPerStage, picture: snapshot(),
                            finishedLevel: nil))
                }
            }
            picture = snapshot()
            finish(stage: stage)
        }
        return levels
    }
}
