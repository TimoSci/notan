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

    public init(target: TargetImage, settings: FitSettings, loss: LossConfig = .init()) {
        self.target = target
        self.settings = settings
        self.loss = loss
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

        var mesh = TileMesh(width: width, height: height, color: target.meanColor)
        var levels: [Level] = []

        func picture() -> Picture {
            var picture = Picture(width: width, height: height, background: target.meanColor, shapes: [])
            picture.tiles = mesh.tiles()
            return picture
        }
        func finish(stage: Int) {
            let picture = picture()
            let level = Level(picture: picture, mse: measuredMSE(picture, against: target))
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
            for (leaf, _) in candidates.prefix(cutCount) {
                // Sharing an earlier cut's end may have given this tile a new corner.
                guard let choice = search(leaf) else { continue }
                let made = mesh.cut(
                    leaf, from: choice.from, to: choice.to, stage: stage, shareCorners: sharesCorners)
                mesh.setColor(made.first, choice.firstColor)
                mesh.setColor(made.second, choice.secondColor)
                children += [made.first, made.second]
                placed += mesh.points.suffix(2)
                placedColours += [choice.firstColor, choice.secondColor]
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
                for (index, node) in movable.enumerated() {
                    mesh.setColor(
                        node,
                        RGB(r: colours[index * 3], g: colours[index * 3 + 1], b: colours[index * 3 + 2]))
                }
            }

            // Every tile is painted, the ones that are not being fitted with the colours
            // they have: `colourSource` lists the mesh's colours, then the parameters'.
            let fixedColours = coloursArray(allLeaves)
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
                    let under = rasterizer.render(
                        edges: underEdges, colors: take(colours, reversedColours, axis: 0),
                        background: background, crops: underCrops)
                    let (image, boundary) = rasterizer.render(
                        edges: allLayout.edges(outline: outline), colors: colours, background: background,
                        crops: allCrops, over: (under.image, farAway))
                    // Keeps a tile from shrinking away to nothing.
                    let shrunk =
                        maximum(minTileArea - allLayout.areas(outline: outline), 0).sum() / minTileArea
                    return [
                        tileLoss(
                            image: image, target: targetArray, boundaryDistance: boundary,
                            config: lossConfig) + areaWeight * shrunk
                    ]
                }, argumentNumbers: [0, 1])

            var adam = Adam(learningRates: [pointRate, colorRate])
            let steps = max(settings.stepsPerStage, 1)
            for step in 1...steps {
                if isCancelled() { return levels }
                place()
                let outline = allLayout.outline(points: points(parameters[0]))
                let (_, gradients) = onOneStream { lossAndGradient([outline, parameters[1]]) }
                let byPoint = allLayout.pointGradient(
                    outlineGradient: gradients[0].asArray(Float.self), pointCount: mesh.points.count)
                let first: MLXArray
                if let mask {
                    first = MLXArray(byPoint, [mesh.points.count, 2]) * mask
                } else {
                    // A cut end moves only along its edge.
                    first = MLXArray(
                        slideAlong.indices.map { index in
                            let point = (firstNewPoint + index) * 2
                            return byPoint[point] * slideAlong[index].x + byPoint[point + 1] * slideAlong[index].y
                        })
                }
                parameters = adam.step(parameters: parameters, gradients: [first, gradients[1]])
                parameters[1] = clip(parameters[1], min: 0, max: 1)
                if !sharesCorners { parameters[0] = clip(parameters[0], min: slideLow, max: slideHigh) }
                eval(parameters)
                let before = mesh.points
                store()
                if sharesCorners {
                    // A step may push a corner across a neighbouring tile. Those corners go
                    // back, and the tiling stays one.
                    let stepped = mesh.points
                    revertInvalid(&mesh, previous: before, minArea: 1)
                    if mesh.points != stepped { parameters[0] = pointsArray(mesh.points[...]) }
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
                    }
                }
            }
            finish(stage: stage)
        }
        return levels
    }
}

/// Puts back the corners of tiles that a step has left unsound: crossing themselves,
/// turned inside out or smaller than `minArea`. `previous` holds every point's position
/// before the step, when the tiling was sound.
///
/// Only the corners of the unsound tiles go back, so the rest of the step stands. A tile
/// that was sound only thanks to a neighbour's move may be unsound after that; then every
/// point goes back.
func revertInvalid(_ mesh: inout TileMesh, previous: [SIMD2<Float>], minArea: Float) {
    let broken = mesh.invalidLeaves(minArea: minArea)
    guard !broken.isEmpty else { return }
    for leaf in broken {
        for corner in mesh.nodes[leaf].corners { mesh.setPoint(corner, previous[corner]) }
    }
    guard !mesh.invalidLeaves(minArea: minArea).isEmpty else { return }
    for index in previous.indices { mesh.setPoint(index, previous[index]) }
}
