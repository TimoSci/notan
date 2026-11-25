import Foundation
import MLX

/// Fits a tiling to a photo: straight-edged tiles that share edges and never overlap,
/// made by cutting the picture again and again.
///
/// Each stage a search finds every tile's best straight cut (`bestCut`), the tiles with
/// the most to gain are cut, and corners and colours are then optimised by gradient
/// descent through the soft rasteriser. In Prefix mode only the new cuts' ends move, each
/// along the frozen edge it lies on, so every level's tiles are exact unions of the next
/// level's. In Re-fit mode all corners move, shared between the tiles that meet at them.
public struct TileFitter {
    public let target: TargetImage
    public let settings: FitSettings
    public let loss: LossConfig
    /// With an outline, a polygon in the target's pixel coordinates, only that polygon is
    /// tiled and only the pixels inside it are fitted: for cutting one tile further. Its
    /// own corners stay where they are.
    public let outline: [SIMD2<Float>]?

    /// How far, in units of the raster's softness, each tile is grown for the underlay.
    ///
    /// Painting soft-edged tiles one over another does not blend two neighbours evenly:
    /// the one painted later counts for more, and a little of what lies beneath shows
    /// through, which would pull every shared edge about a quarter pixel off the edge in
    /// the photo. So the tiles are first painted grown, in reverse order, as an underlay:
    /// near a shared edge it holds the colour of the tile painted first. Painted over
    /// that, the first tile changes nothing there, and the second blends with it by its
    /// own soft edge alone, which is even.
    public static let underlayGrowth: Float = 6

    public init(
        target: TargetImage, settings: FitSettings, loss: LossConfig = .init(),
        outline: [SIMD2<Float>]? = nil
    ) {
        self.target = target
        self.settings = settings
        self.loss = loss
        self.outline = outline
    }

    /// Blocking. Returns the levels finished so far, level 0 first, when done or cancelled.
    public func run(progress: (FitProgress) -> Void, isCancelled: () -> Bool) -> [Level] {
        let width = target.width
        let height = target.height
        Memory.cacheLimit = Fitter.bufferCacheLimit
        // Rates and reach are for ~256 px pictures, as in `Fitter`; scale them with ours.
        let scale = Float(max(width, height)) / 256
        var lossConfig = loss
        lossConfig.boundaryReach = loss.boundaryReach * scale
        let pointRate = 1.0 * scale
        let colorRate: Float = 0.01
        let minThickness = max(1, settings.minWidth * scale)
        let sharesCorners = settings.mode == .refit

        let rasterizer = Rasterizer(width: width, height: height, softness: loss.softness)
        let cropMargin = max(16 * loss.softness, lossConfig.boundaryReach) + 1
        let targetArray = MLXArray(target.pixels, [height, width, 3])
        let background = colorArray(target.meanColor)
        let schedule = tileSchedule(totalTiles: settings.totalShapes, order: settings.tileOrder)

        // With an outline: which pixels lie inside it, and their mean colour.
        var counted: [Bool]?
        var startColor = target.meanColor
        if let outline {
            var inside = [Bool](repeating: false, count: width * height)
            var sum = SIMD3<Double>(0, 0, 0)
            var number = 0
            for y in 0..<height {
                for x in 0..<width where polygonContains(outline, SIMD2(Float(x) + 0.5, Float(y) + 0.5)) {
                    inside[y * width + x] = true
                    let colour = target.color(x: x, y: y)
                    sum += SIMD3(Double(colour.r), Double(colour.g), Double(colour.b))
                    number += 1
                }
            }
            counted = inside
            if number > 0 {
                let mean = sum / Double(number)
                startColor = RGB(r: Float(mean.x), g: Float(mean.y), b: Float(mean.z))
            }
        }
        let lossMask = counted.map { MLXArray($0.map { $0 ? Float(1) : 0 }, [height, width]) }
        var mesh =
            outline.map { TileMesh(width: width, height: height, color: startColor, outline: $0) }
            ?? TileMesh(width: width, height: height, color: startColor)
        var levels: [Level] = []

        func picture() -> Picture {
            var picture = Picture(width: width, height: height, background: target.meanColor, shapes: [])
            picture.tiles = mesh.tiles()
            return picture
        }
        func finish(stage: Int) {
            let picture = picture()
            let level = Level(
                picture: picture, mse: measuredMSE(picture, against: target, counting: counted))
            levels.append(level)
            progress(
                FitProgress(
                    stage: stage, stageCount: schedule.count, step: settings.stepsPerStage,
                    stepCount: settings.stepsPerStage, picture: picture, finishedLevel: level))
        }
        func pointsArray(_ points: ArraySlice<SIMD2<Float>>) -> MLXArray {
            MLXArray(points.flatMap { [$0.x, $0.y] }, [points.count, 2])
        }
        func coloursArray(_ nodes: [Int]) -> MLXArray {
            MLXArray(
                nodes.flatMap { [mesh.nodes[$0].color.r, mesh.nodes[$0].color.g, mesh.nodes[$0].color.b] },
                [nodes.count, 3])
        }
        // With gradients: each tile's second colour, and the two ends of its axis.
        let ramps = settings.gradients
        func endColoursArray(_ nodes: [Int]) -> MLXArray {
            MLXArray(
                nodes.flatMap { node -> [Float] in
                    let end = mesh.nodes[node].gradient?.endColor ?? mesh.nodes[node].color
                    return [end.r, end.g, end.b]
                }, [nodes.count, 3])
        }
        func axesArray(_ nodes: [Int]) -> MLXArray {
            MLXArray(
                nodes.flatMap { node -> [Float] in
                    let from = mesh.nodes[node].gradient?.from ?? SIMD2(0, 0)
                    let to = mesh.nodes[node].gradient?.to ?? SIMD2(1, 0)
                    return [from.x, from.y, to.x, to.y]
                }, [nodes.count, 2, 2])
        }
        /// The fill a new tile starts with: flat, its axis across its middle from side to
        /// side. The two colours part as the fit finds a slope.
        func flatRamp(_ node: Int) -> Gradient {
            let polygon = mesh.polygon(node)
            let middle = polygon.reduce(SIMD2<Float>(0, 0), +) / Float(polygon.count)
            let low = polygon.map(\.x).min() ?? middle.x
            let high = polygon.map(\.x).max() ?? middle.x
            return Gradient(
                from: SIMD2(low, middle.y), to: SIMD2(max(high, low + 1), middle.y),
                endColor: mesh.nodes[node].color)
        }
        func crops(_ nodes: [Int]) -> [PixelRect] {
            nodes.map {
                cropRect(points: mesh.polygon($0), margin: cropMargin, width: width, height: height)
            }
        }

        finish(stage: 0)

        // The best cut of a tile does not change while the tile does not.
        var searched: [Int: (polygon: [SIMD2<Float>], choice: CutChoice?)] = [:]
        func search(_ leaf: Int) -> CutChoice? {
            let polygon = mesh.polygon(leaf)
            if let known = searched[leaf], known.polygon == polygon { return known.choice }
            let choice = bestCut(of: polygon, in: target, minThickness: minThickness)
            searched[leaf] = (polygon, choice)
            return choice
        }

        for (stageIndex, cutCount) in schedule.enumerated() {
            if isCancelled() { return levels }
            let stage = stageIndex + 1

            // Cut the tiles with the most to gain.
            var candidates: [(leaf: Int, gain: Float)] = []
            for leaf in mesh.leaves {
                if let choice = search(leaf) { candidates.append((leaf, choice.gain)) }
            }
            candidates.sort { $0.gain != $1.gain ? $0.gain > $1.gain : $0.leaf < $1.leaf }
            let firstNewPoint = mesh.points.count
            var children: [Int] = []
            // The search's own placing of each cut, to fall back on.
            var placed: [SIMD2<Float>] = []
            var placedColours: [RGB] = []
            var placedRamps: [Gradient?] = []
            for (leaf, _) in candidates.prefix(cutCount) {
                // Sharing an earlier cut's end may have given this tile a new corner.
                guard let choice = search(leaf) else { continue }
                let made = mesh.cut(
                    leaf, from: choice.from, to: choice.to, stage: stage, shareCorners: sharesCorners)
                mesh.setColor(made.first, choice.firstColor)
                mesh.setColor(made.second, choice.secondColor)
                if ramps {
                    mesh.setGradient(made.first, flatRamp(made.first))
                    mesh.setGradient(made.second, flatRamp(made.second))
                }
                children += [made.first, made.second]
                placed += mesh.points.suffix(2)
                placedColours += [mesh.nodes[made.first].color, mesh.nodes[made.second].color]
                placedRamps += [mesh.nodes[made.first].gradient, mesh.nodes[made.second].gradient]
            }
            // Nothing left that may be cut: the tiling is as fine as it gets.
            if children.isEmpty { break }

            let allLeaves = mesh.leaves
            let allLayout = TileEdgeLayout(tiles: allLeaves.map { mesh.nodes[$0].corners })
            let movable = sharesCorners ? allLeaves : children

            // What is optimised. Re-fit: every point, and every tile's colour. Prefix: how
            // far along its frozen edge each new cut end lies, and the new tiles' colours.
            var parameters: [MLXArray]
            let frozenPoints = pointsArray(mesh.points[..<firstNewPoint])
            var slideFrom: [SIMD2<Float>] = []
            var slideAlong: [SIMD2<Float>] = []
            var slideLength: [Float] = []
            var mask: MLXArray?
            // For a point that slides along the outline: the direction it may move in.
            var rails: MLXArray?
            if sharesCorners {
                parameters = [pointsArray(mesh.points[...]), coloursArray(movable)]
                mask = MLXArray(
                    mesh.freedom.flatMap { freedom -> [Float] in
                        switch freedom {
                        case .free: return [1, 1]
                        case .alongX: return [1, 0]
                        case .alongY: return [0, 1]
                        case .fixed, .slide: return [0, 0]
                        }
                    }, [mesh.points.count, 2])
                rails = MLXArray(
                    mesh.freedom.flatMap { freedom -> [Float] in
                        guard case .slide(let from, let to) = freedom else { return [0, 0] }
                        let edge = mesh.points[to] - mesh.points[from]
                        let length = (edge * edge).sum().squareRoot()
                        return length > 0 ? [edge.x / length, edge.y / length] : [0, 0]
                    }, [mesh.points.count, 2])
            } else {
                var distances: [Float] = []
                for index in firstNewPoint..<mesh.points.count {
                    guard case .slide(let from, let to) = mesh.freedom[index] else {
                        preconditionFailure("an unshared cut end slides")
                    }
                    let edge = mesh.points[to] - mesh.points[from]
                    let length = (edge * edge).sum().squareRoot()
                    let offset = mesh.points[index] - mesh.points[from]
                    slideFrom.append(mesh.points[from])
                    slideAlong.append(edge / length)
                    slideLength.append(length)
                    distances.append((offset * offset).sum().squareRoot())
                }
                parameters = [MLXArray(distances), coloursArray(movable)]
            }
            if ramps { parameters += [endColoursArray(movable), axesArray(movable)] }
            let slideFromArray = pointsArray(slideFrom[...])
            let slideAlongArray = pointsArray(slideAlong[...])
            let slideLow = MLXArray(slideLength.map { $0 * 0.05 })
            let slideHigh = MLXArray(slideLength.map { $0 * 0.95 })

            /// Every point of the mesh [V, 2], as the parameters have it.
            func points(_ first: MLXArray) -> MLXArray {
                if sharesCorners { return first }
                return concatenated(
                    [frozenPoints, slideFromArray + slideAlongArray * first.expandedDimensions(axis: 1)],
                    axis: 0)
            }
            /// Writes the parameters back to the mesh.
            func store() {
                let flat = points(parameters[0]).asArray(Float.self)
                let first = sharesCorners ? 0 : firstNewPoint
                for index in first..<mesh.points.count {
                    mesh.setPoint(index, SIMD2(flat[index * 2], flat[index * 2 + 1]))
                }
                let colours = parameters[1].asArray(Float.self)
                let ends = ramps ? parameters[2].asArray(Float.self) : []
                let axes = ramps ? parameters[3].asArray(Float.self) : []
                for (index, node) in movable.enumerated() {
                    mesh.setColor(
                        node,
                        RGB(r: colours[index * 3], g: colours[index * 3 + 1], b: colours[index * 3 + 2]))
                    guard ramps else { continue }
                    mesh.setGradient(
                        node,
                        Gradient(
                            from: SIMD2(axes[index * 4], axes[index * 4 + 1]),
                            to: SIMD2(axes[index * 4 + 2], axes[index * 4 + 3]),
                            endColor: RGB(
                                r: ends[index * 3], g: ends[index * 3 + 1], b: ends[index * 3 + 2])))
                }
            }

            // Every tile is painted, the ones that are not being fitted with the colours
            // they have: `colourSource` lists the mesh's colours, then the parameters'.
            let fixedColours = coloursArray(allLeaves)
            let fixedEnds = endColoursArray(allLeaves)
            let fixedAxes = axesArray(allLeaves)
            let colourSource = MLXArray(
                allLeaves.enumerated().map { index, leaf in
                    Int32(movable.firstIndex(of: leaf).map { allLeaves.count + $0 } ?? index)
                })
            // The underlay (see `underlayGrowth`): the tiles in reverse, each with corners
            // of its own, since grown tiles no longer share them.
            let reversed = Array(allLeaves.reversed())
            let reversedColours = MLXArray((0..<allLeaves.count).reversed().map { Int32($0) })
            var next = 0
            let underLayout = TileEdgeLayout(
                tiles: reversed.map { leaf in
                    let corners = Array(next..<(next + mesh.nodes[leaf].corners.count))
                    next += corners.count
                    return corners
                })
            let growth = TileFitter.underlayGrowth * loss.softness
            let farAway = MLXArray.zeros([height, width]) + Rasterizer.noBoundary
            var allCrops: [PixelRect] = []
            var underCrops: [PixelRect] = []
            var underEdges = MLXArray.zeros([0])
            /// Brings what depends on where the tiles are up to date with the mesh.
            func place() {
                allCrops = crops(allLeaves)
                underCrops = allCrops.reversed()
                let grown = reversed.flatMap { grownPolygon(mesh.polygon($0), by: growth) }
                underEdges = underLayout.edges(points: pointsArray(grown[...]))
            }

            let areaWeight = lossConfig.tileAreaWeight
            let lossAndGradient = valueAndGrad(
                { (arrays: [MLXArray]) -> [MLXArray] in
                    // By the tiles' outlines, not the points they are built from: see
                    // `TileEdgeLayout.pointGradient`.
                    let outline = arrays[0]
                    let colours = take(concatenated([fixedColours, arrays[1]], axis: 0), colourSource, axis: 0)
                    // The tiles' gradients, drawn from the same two sources as the colours.
                    var fills: (axes: MLXArray, endColors: MLXArray)?
                    var underFills: (axes: MLXArray, endColors: MLXArray)?
                    if ramps {
                        let ends = take(concatenated([fixedEnds, arrays[2]], axis: 0), colourSource, axis: 0)
                        let axes = take(concatenated([fixedAxes, arrays[3]], axis: 0), colourSource, axis: 0)
                        fills = (axes, ends)
                        underFills = (
                            take(axes, reversedColours, axis: 0), take(ends, reversedColours, axis: 0)
                        )
                    }
                    let under = rasterizer.render(
                        edges: underEdges, colors: take(colours, reversedColours, axis: 0),
                        background: background, crops: underCrops, gradients: underFills)
                    let (image, boundary) = rasterizer.render(
                        edges: allLayout.edges(outline: outline), colors: colours, background: background,
                        crops: allCrops, over: (under.image, farAway), gradients: fills)
                    // Keeps a tile from shrinking away to nothing.
                    let shrunk =
                        maximum(minTileArea - allLayout.areas(outline: outline), 0).sum() / minTileArea
                    return [
                        tileLoss(
                            image: image, target: targetArray, boundaryDistance: boundary,
                            config: lossConfig, mask: lossMask) + areaWeight * shrunk
                    ]
                }, argumentNumbers: Array(parameters.indices))

            var adam = Adam(
                learningRates: ramps ? [pointRate, colorRate, colorRate, pointRate] : [pointRate, colorRate])
            let steps = max(settings.stepsPerStage, 1)
            for step in 1...steps {
                if isCancelled() { return levels }
                place()
                let outline = allLayout.outline(points: points(parameters[0]))
                let (_, gradients) = onOneStream { lossAndGradient([outline] + parameters.dropFirst()) }
                let byPoint = allLayout.pointGradient(
                    outlineGradient: gradients[0].asArray(Float.self), pointCount: mesh.points.count)
                let first: MLXArray
                if let mask, let rails {
                    let whole = MLXArray(byPoint, [mesh.points.count, 2])
                    first = whole * mask + rails * (whole * rails).sum(axis: 1, keepDims: true)
                } else {
                    // A cut end moves only along its edge.
                    first = MLXArray(
                        slideAlong.indices.map { index in
                            let point = (firstNewPoint + index) * 2
                            return byPoint[point] * slideAlong[index].x + byPoint[point + 1] * slideAlong[index].y
                        })
                }
                let stepped = adam.step(parameters: parameters, gradients: [first] + gradients.dropFirst())
                if let mask, let rails {
                    // Adam scales each coordinate by itself, which turns a move along a
                    // slanted outline edge off that edge: keep only the part along it.
                    let move = stepped[0] - parameters[0]
                    parameters =
                        [parameters[0] + move * mask + rails * (move * rails).sum(axis: 1, keepDims: true)]
                        + stepped.dropFirst()
                } else {
                    parameters = stepped
                }
                parameters[1] = clip(parameters[1], min: 0, max: 1)
                if ramps { parameters[2] = clip(parameters[2], min: 0, max: 1) }
                if !sharesCorners { parameters[0] = clip(parameters[0], min: slideLow, max: slideHigh) }
                eval(parameters)
                let before = mesh.points
                store()
                if sharesCorners {
                    // A step may push a corner across a neighbouring tile. Those corners go
                    // back, and the tiling stays one.
                    let reverted = revertInvalid(
                        &mesh, previous: before, minArea: 1, minThickness: minThickness)
                    if !reverted.isEmpty {
                        parameters[0] = pointsArray(mesh.points[...])
                        // Or the next step would only make the same move again.
                        var keeping = [Float](repeating: 1, count: mesh.points.count * 2)
                        for point in reverted {
                            keeping[point * 2] = 0
                            keeping[point * 2 + 1] = 0
                        }
                        adam.forget(parameter: 0, keeping: MLXArray(keeping, [mesh.points.count, 2]))
                    }
                }
                if step % Fitter.progressInterval == 0 && step < settings.stepsPerStage {
                    progress(
                        FitProgress(
                            stage: stage, stageCount: schedule.count, step: step,
                            stepCount: settings.stepsPerStage, picture: picture(), finishedLevel: nil))
                }
            }

            if !sharesCorners {
                // A cut whose ends slid until a piece fell below the limits goes back to
                // where the search put it.
                for (pair, first) in stride(from: 0, to: children.count, by: 2).enumerated() {
                    let sound = [children[first], children[first + 1]].allSatisfy {
                        let polygon = mesh.polygon($0)
                        return polygonArea(polygon) >= minTileArea && thickness(of: polygon) >= minThickness
                    }
                    if sound { continue }
                    for offset in 0..<2 {
                        mesh.setPoint(firstNewPoint + pair * 2 + offset, placed[pair * 2 + offset])
                        mesh.setColor(children[first + offset], placedColours[pair * 2 + offset])
                        mesh.setGradient(children[first + offset], placedRamps[pair * 2 + offset])
                    }
                }
            }
            finish(stage: stage)
        }
        return levels
    }
}

/// Puts back the corners of tiles that a step has left unsound: crossing themselves,
/// turned inside out, smaller than `minArea` or thinner than `minThickness`. `previous`
/// holds every point's position before the step, when the tiling was sound. Returns the
/// points that were put back.
///
/// Only the corners of unsound tiles go back, so the rest of the step stands. A tile that
/// was sound only thanks to a neighbour's move may be unsound after that, so this is
/// repeated until every tile is sound. At worst every point ends up back where it was.
@discardableResult
func revertInvalid(
    _ mesh: inout TileMesh, previous: [SIMD2<Float>], minArea: Float, minThickness: Float = 0
) -> [Int] {
    var reverted: Set<Int> = []
    while true {
        let corners = Set(
            mesh.invalidLeaves(minArea: minArea, minThickness: minThickness)
                .flatMap { mesh.nodes[$0].corners })
        let fresh = corners.subtracting(reverted)
        // Nothing unsound, or nothing left to put back.
        if fresh.isEmpty { break }
        for corner in fresh { mesh.setPoint(corner, previous[corner]) }
        reverted.formUnion(fresh)
    }
    return reverted.sorted()
}
