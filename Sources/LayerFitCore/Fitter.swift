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

/// Layer-wise fitting after LIVE: shapes are added in stages, each seeded where the
/// picture is most wrong, then refined by gradient descent through the soft rasteriser.
public struct Fitter {
    public let target: TargetImage
    public let settings: FitSettings
    public let loss: LossConfig

    /// How often, in optimisation steps, an unfinished stage reports its current picture.
    public static let progressInterval = 10
    /// Edge softness, in pixels, used when measuring a level's error and placing seeds.
    public static let measuringSoftness: Float = 0.25

    public init(target: TargetImage, settings: FitSettings, loss: LossConfig = .init()) {
        self.target = target
        self.settings = settings
        self.loss = loss
    }

    /// Blocking. Returns the levels finished so far, level 0 first, when done or cancelled.
    public func run(progress: (FitProgress) -> Void, isCancelled: () -> Bool) -> [Level] {
        let width = target.width
        let height = target.height
        // LIVE's rates and reach are for ~256 px pictures; scale them with ours.
        let scale = Float(max(width, height)) / 256
        var lossConfig = loss
        lossConfig.boundaryReach = loss.boundaryReach * scale
        let pointRate = 1.0 * scale
        let colorRate: Float = 0.01

        let rasterizer = Rasterizer(width: width, height: height, softness: loss.softness)
        // A level's reported error is measured with near-hard edges, like the vectors the
        // user sees, so it does not include the blur of the soft raster used for fitting.
        let sharp = Rasterizer(width: width, height: height, softness: Fitter.measuringSoftness)
        let targetArray = MLXArray(target.pixels, [height, width, 3])
        let schedule = stageSchedule(totalShapes: settings.totalShapes)

        var picture = Picture(width: width, height: height, background: target.meanColor, shapes: [])
        var levels: [Level] = []

        func render(_ picture: Picture, with rasterizer: Rasterizer) -> MLXArray {
            rasterizer.render(
                points: pointsArray(picture.shapes), colors: colorsArray(picture.shapes),
                background: colorArray(picture.background)
            ).image
        }
        func finish(stage: Int) {
            let mse = plainMSE(image: render(picture, with: sharp), target: targetArray).item(Float.self)
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
            let seeds = findSeeds(target: target, current: current, count: addCount)
            let frozenCount = settings.mode == .prefix ? picture.shapes.count : 0
            picture.shapes += seeds.map {
                Shape.circle(center: $0.center, radius: $0.radius, color: $0.color)
            }

            // Frozen shapes are rendered but never updated, so in prefix mode each level
            // stays an exact prefix of the next.
            let frozen = Array(picture.shapes.prefix(frozenCount))
            let movable = Array(picture.shapes.dropFirst(frozenCount))
            let frozenPoints = pointsArray(frozen)
            let frozenColors = colorsArray(frozen)
            let fixedBackground = colorArray(picture.background)
            let fitsBackground = settings.mode == .refit

            var parameters = [pointsArray(movable), colorsArray(movable)]
            var rates = [pointRate, colorRate]
            if fitsBackground {
                parameters.append(fixedBackground)
                rates.append(colorRate)
            }
            var adam = Adam(learningRates: rates)

            let lossAndGradient = valueAndGrad(
                { (arrays: [MLXArray]) -> [MLXArray] in
                    let points =
                        frozenCount > 0 ? concatenated([frozenPoints, arrays[0]], axis: 0) : arrays[0]
                    let colors =
                        frozenCount > 0 ? concatenated([frozenColors, arrays[1]], axis: 0) : arrays[1]
                    let background = fitsBackground ? arrays[2] : fixedBackground
                    let (image, boundary) = rasterizer.render(
                        points: points, colors: colors, background: background)
                    return [
                        fitLoss(
                            image: image, target: targetArray, boundaryDistance: boundary,
                            points: arrays[0], config: lossConfig)
                    ]
                }, argumentNumbers: Array(parameters.indices))

            func snapshot() -> Picture {
                var result = picture
                let points = parameters[0].asArray(Float.self)
                let colors = parameters[1].asArray(Float.self)
                for index in 0..<movable.count {
                    let base = index * Shape.pointCount * 2
                    result.shapes[frozenCount + index] = Shape(
                        points: (0..<Shape.pointCount).map {
                            SIMD2(points[base + $0 * 2], points[base + $0 * 2 + 1])
                        },
                        color: RGB(
                            r: colors[index * 3], g: colors[index * 3 + 1], b: colors[index * 3 + 2]))
                }
                if fitsBackground {
                    let b = parameters[2].asArray(Float.self)
                    result.background = RGB(r: b[0], g: b[1], b: b[2])
                }
                return result
            }

            for step in 1...max(settings.stepsPerStage, 1) {
                if isCancelled() { return levels }
                let (_, gradients) = lossAndGradient(parameters)
                parameters = adam.step(parameters: parameters, gradients: gradients)
                for index in 1..<parameters.count {
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
