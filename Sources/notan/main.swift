import Foundation
import NotanCore

let usage = "usage: notan <image> <outdir> [--mode refit|prefix] [--shapes N] [--size N] [--steps N] [--min-width PX] [--folds avoid|allow|0…0.5] [--fill flat|gradient]\n       [--kind curves|tiles] [--order tree|worst]\n       tuning: [--softness PX] [--floor W] [--reach PX] [--xing W] [--seeds error|paper]\n               [--fold-weight W]"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("notan: \(message)\n".utf8))
    exit(1)
}

var positional: [String] = []
var settings = FitSettings()
var lossConfig = LossConfig()
var seedRule = SeedRule.error
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    guard argument.hasPrefix("--") else {
        positional.append(argument)
        continue
    }
    guard !arguments.isEmpty else { fail("\(argument) needs a value\n\(usage)") }
    let value = arguments.removeFirst()
    func positiveInt(max limit: Int) -> Int {
        guard let n = Int(value), (1...limit).contains(n) else {
            fail("\(argument) must be a whole number from 1 to \(limit), not “\(value)”")
        }
        return n
    }
    switch argument {
    case "--mode":
        guard let mode = LevelMode(rawValue: value) else {
            fail("--mode must be refit or prefix, not “\(value)”")
        }
        settings.mode = mode
    case "--seeds":
        guard let rule = SeedRule(rawValue: value) else {
            fail("--seeds must be error or paper, not “\(value)”")
        }
        seedRule = rule
    case "--min-width":
        guard let width = Float(value), width >= 0, width.isFinite else {
            fail("--min-width must be a non-negative number of pixels, not “\(value)”")
        }
        settings.minWidth = width
    case "--folds":
        // How far a shape may fold over itself: avoid (0), allow (anything), or a number.
        switch value {
        case "avoid": settings.foldTolerance = 0
        case "allow": settings.limitsFolds = false
        default:
            guard let tolerance = Float(value), (0...FitSettings.maxFoldTolerance).contains(tolerance)
            else { fail("--folds must be avoid, allow or a number from 0 to 0.5, not “\(value)”") }
            settings.foldTolerance = tolerance
        }
    case "--fill":
        guard value == "flat" || value == "gradient" else {
            fail("--fill must be flat or gradient, not “\(value)”")
        }
        settings.gradients = value == "gradient"
    case "--kind":
        guard let kind = ShapeKind(rawValue: value) else {
            fail("--kind must be curves or tiles, not “\(value)”")
        }
        settings.kind = kind
    case "--order":
        guard let order = TileOrder(rawValue: value) else {
            fail("--order must be tree or worst, not “\(value)”")
        }
        settings.tileOrder = order
    case "--shapes": settings.totalShapes = positiveInt(max: 4096)
    case "--size": settings.workingSize = positiveInt(max: 2048)
    case "--steps": settings.stepsPerStage = positiveInt(max: 100_000)
    // Tuning levers, for experiments.
    case "--softness", "--floor", "--reach", "--xing", "--fold-weight":
        guard let number = Float(value), number >= 0, number.isFinite else {
            fail("\(argument) must be a non-negative number, not “\(value)”")
        }
        switch argument {
        case "--softness":
            guard number > 0 else { fail("--softness must be greater than 0") }
            lossConfig.softness = number
        case "--floor": lossConfig.floorWeight = number
        case "--reach":
            guard number > 0 else { fail("--reach must be greater than 0") }
            lossConfig.boundaryReach = number
        case "--fold-weight": settings.foldStrength = number
        default: lossConfig.xingWeight = number
        }
    default: fail("unknown option \(argument)\n\(usage)")
    }
}
guard positional.count == 2 else { fail(usage) }

let imageURL = URL(fileURLWithPath: positional[0])
let outputURL = URL(fileURLWithPath: positional[1], isDirectory: true)

let photo: LoadedPhoto
do {
    photo = try loadPhoto(url: imageURL, workingSize: settings.workingSize)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
} catch {
    fail(error.localizedDescription)
}

func pad(_ text: String, _ width: Int) -> String {
    text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0)
}

let target = photo.target
print("\(imageURL.lastPathComponent): fitting at \(target.width)×\(target.height), "
    + "\(settings.totalShapes) \(settings.kind == .tiles ? "tiles, order \(settings.tileOrder.rawValue)" : "shapes"), "
    + "\(settings.stepsPerStage) steps per stage, mode \(settings.mode.rawValue)"
    + (settings.minWidth > 0 ? ", min width \(settings.minWidth) px" : ""))
print(pad("level", 7) + pad("shapes", 8) + pad("bytes", 8) + pad("mse", 10) + "seconds")

let started = Date()
var written = 0
let pngSize = CGSize(width: target.width * 4, height: target.height * 4)
let report: (FitProgress) -> Void = { progress in
        guard let level = progress.finishedLevel else { return }
        let name = String(format: "level-%02d", written)
        do {
            try svg(level.picture, outputSize: photo.originalPixelSize)
                .write(to: outputURL.appendingPathComponent(name + ".svg"), atomically: true, encoding: .utf8)
            try writePNG(level.picture, pixelSize: pngSize, to: outputURL.appendingPathComponent(name + ".png"))
        } catch {
            fail(error.localizedDescription)
        }
        print(
            pad("\(written)", 7) + pad("\(level.picture.shapes.count + level.picture.tiles.count)", 8)
                + pad("\(level.picture.estimatedBytes)", 8)
                + pad(String(format: "%.5f", level.mse), 10)
                + String(format: "%.1f", Date().timeIntervalSince(started)))
        fflush(stdout)
        written += 1
}
let levels =
    settings.kind == .tiles
    ? TileFitter(target: target, settings: settings, loss: lossConfig).run(
        progress: report, isCancelled: { false })
    : Fitter(target: target, settings: settings, loss: lossConfig, seedRule: seedRule).run(
        progress: report, isCancelled: { false })
var summary = String(
    format: "total %.1f s, %d levels, peak memory in use %.1f GB", Date().timeIntervalSince(started),
    levels.count, Double(peakFitMemoryBytes()) / 1e9)
if settings.kind == .curves {
    let shapes = levels.last?.picture.shapes ?? []
    let ratios = shapes.map { foldRatio(of: $0) }
    let crossings = shapes.map { selfCrossings(of: $0) }
    summary += String(
        format: "; at the last level %d shapes cross themselves (%d crossings), %d sweep back over 5%%, %d over 15%%, most %.3f",
        crossings.filter { $0 > 0 }.count, crossings.reduce(0, +),
        ratios.filter { $0 > 0.05 }.count, ratios.filter { $0 > 0.15 }.count, ratios.max() ?? 0)
}
print(summary)
