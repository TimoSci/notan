import Foundation

/// Where a new shape starts: a small circle of the target's colour.
public struct Seed: Equatable, Sendable {
    public var center: SIMD2<Float>
    public var radius: Float
    public var color: RGB
}

public enum SeedRule: String, Sendable, CaseIterable {
    /// Seed the region holding the most squared error, with the largest circle that fits
    /// inside it. LayerFit's default.
    case error
    /// LIVE as published: seed the largest region by area, with a small circle
    /// (5 px on a 256 px picture).
    case paper
}

/// LIVE's component-wise initialisation. Finds the connected regions holding most error where the
/// current picture is badly wrong and the target is roughly one colour, and seeds one
/// shape per region at the point deepest inside it.
/// `current` has the same layout as `target.pixels`.
public func findSeeds(
    target: TargetImage, current: [Float], count: Int, errorThreshold: Float = 0.1,
    colorLevels: Int = 4, rule: SeedRule = .error
) -> [Seed] {
    precondition(current.count == target.pixels.count)
    guard count > 0 else { return [] }
    let width = target.width
    let height = target.height
    let pixelCount = width * height

    var error = [Float](repeating: 0, count: pixelCount)
    // -1 where the error is below the threshold, else the quantised target colour.
    var label = [Int32](repeating: -1, count: pixelCount)
    for i in 0..<pixelCount {
        var sum: Float = 0
        var quantised: Int32 = 0
        for channel in 0..<3 {
            let t = target.pixels[i * 3 + channel]
            let d = t - current[i * 3 + channel]
            sum += d * d
            let level = min(Int32(t * Float(colorLevels)), Int32(colorLevels - 1))
            quantised = quantised * Int32(colorLevels) + max(level, 0)
        }
        error[i] = sum.squareRoot()
        if error[i] > errorThreshold { label[i] = quantised }
    }

    // 4-connected components of equal label.
    var components: [[Int]] = []
    var visited = [Bool](repeating: false, count: pixelCount)
    var stack: [Int] = []
    for start in 0..<pixelCount where label[start] >= 0 && !visited[start] {
        var members: [Int] = []
        visited[start] = true
        stack.append(start)
        while let i = stack.popLast() {
            members.append(i)
            let x = i % width
            let y = i / width
            if x > 0 { visit(i - 1) }
            if x < width - 1 { visit(i + 1) }
            if y > 0 { visit(i - width) }
            if y < height - 1 { visit(i + width) }
        }
        components.append(members)

        func visit(_ j: Int) {
            if !visited[j] && label[j] == label[start] {
                visited[j] = true
                stack.append(j)
            }
        }
    }
    // Rank regions by the squared error they hold, not by area alone (LIVE uses area):
    // a small region that is badly wrong matters more than a large one that is nearly right.
    func errorMass(_ members: [Int]) -> Float {
        members.reduce(0) { $0 + error[$1] * error[$1] }
    }
    switch rule {
    case .error:
        let ranked = components.map { (members: $0, mass: errorMass($0)) }
            .sorted { $0.mass > $1.mass }
        components = ranked.map { $0.members }
    case .paper:
        components.sort { $0.count > $1.count }
    }
    let paperRadius = max(5 * Float(max(width, height)) / 256, 2)

    var seeds: [Seed] = []
    for members in components.prefix(count) {
        let (index, depth) = deepestPixel(of: members, width: width, height: height)
        seeds.append(
            Seed(
                center: SIMD2(Float(index % width) + 0.5, Float(index / width) + 0.5),
                radius: rule == .paper ? paperRadius : max(depth, 2),
                color: target.color(x: index % width, y: index / width)))
    }

    // Not enough regions: fall back to the worst remaining pixels, kept apart.
    if seeds.count < count {
        let order = (0..<pixelCount).sorted { error[$0] > error[$1] }
        for spacing in [Float(4), 0] {
            for i in order where seeds.count < count {
                let p = SIMD2(Float(i % width) + 0.5, Float(i / width) + 0.5)
                let clear = seeds.allSatisfy { seed in
                    let d = seed.center - p
                    return (d * d).sum().squareRoot() > spacing
                }
                if clear || spacing == 0 {
                    seeds.append(
                        Seed(center: p, radius: 2, color: target.color(x: i % width, y: i / width)))
                }
            }
        }
        // A picture with fewer pixels than seeds asked for: reuse pixels.
        var next = 0
        while seeds.count < count {
            let i = order[next % order.count]
            seeds.append(
                Seed(
                    center: SIMD2(Float(i % width) + 0.5, Float(i / width) + 0.5), radius: 2,
                    color: target.color(x: i % width, y: i / width)))
            next += 1
        }
    }
    return seeds
}

/// The member pixel farthest from any non-member pixel (or the image border), and that
/// distance in pixels, by a two-pass 3-4 chamfer distance transform.
private func deepestPixel(of members: [Int], width: Int, height: Int) -> (index: Int, depth: Float) {
    let far = Int32.max / 2
    var distance = [Int32](repeating: 0, count: width * height)
    for i in members { distance[i] = far }

    func at(_ x: Int, _ y: Int) -> Int32 {
        (x < 0 || y < 0 || x >= width || y >= height) ? 0 : distance[y * width + x]
    }
    for y in 0..<height {
        for x in 0..<width where distance[y * width + x] != 0 {
            let best = min(
                min(at(x - 1, y) + 3, at(x, y - 1) + 3),
                min(at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4))
            distance[y * width + x] = min(distance[y * width + x], best)
        }
    }
    for y in stride(from: height - 1, through: 0, by: -1) {
        for x in stride(from: width - 1, through: 0, by: -1) where distance[y * width + x] != 0 {
            let best = min(
                min(at(x + 1, y) + 3, at(x, y + 1) + 3),
                min(at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4))
            distance[y * width + x] = min(distance[y * width + x], best)
        }
    }
    var bestIndex = members[0]
    for i in members where distance[i] > distance[bestIndex] { bestIndex = i }
    // A pixel adjacent to the outside has chamfer distance 3: its centre is half a pixel in.
    return (bestIndex, Float(distance[bestIndex]) / 3 - 0.5)
}
