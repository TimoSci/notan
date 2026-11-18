import Foundation
import LayerFitCore

let usage = "usage: layerfit <image> <outdir> [--mode refit|prefix] [--shapes N] [--size N] [--steps N]\n       tuning: [--softness PX] [--floor W] [--reach PX] [--xing W]"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("layerfit: \(message)\n".utf8))
    exit(1)
}

var positional: [String] = []
var settings = FitSettings()
var lossConfig = LossConfig()
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
    case "--shapes": settings.totalShapes = positiveInt(max: 4096)
    case "--size": settings.workingSize = positiveInt(max: 2048)
    case "--steps": settings.stepsPerStage = positiveInt(max: 100_000)
    // Tuning levers, for experiments.
    case "--softness", "--floor", "--reach", "--xing":
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
    + "\(settings.totalShapes) shapes, \(settings.stepsPerStage) steps per stage, mode \(settings.mode.rawValue)")
print(pad("level", 7) + pad("shapes", 8) + pad("bytes", 8) + pad("mse", 10) + "seconds")

let started = Date()
var written = 0
let pngSize = CGSize(width: target.width * 4, height: target.height * 4)
let levels = Fitter(target: target, settings: settings, loss: lossConfig).run(
    progress: { progress in
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
            pad("\(written)", 7) + pad("\(level.picture.shapes.count)", 8)
                + pad("\(level.picture.estimatedBytes)", 8)
                + pad(String(format: "%.5f", level.mse), 10)
                + String(format: "%.1f", Date().timeIntervalSince(started)))
        fflush(stdout)
        written += 1
    },
    isCancelled: { false })
print(String(format: "total %.1f s, %d levels", Date().timeIntervalSince(started), levels.count))
