import MLX

/// Everything between the edges of the shapes' outlines and the finished picture, as five
/// small programs that the GPU runs directly, with the derivative written by hand.
///
/// Going forward:
/// 1. `distanceKernel`, once per window pixel: the signed distance to the shape's outline
///    and which edge is nearest.
/// 2. `paintKernel`, once per picture pixel: the shapes painted over one another.
///
/// Going back, from how the loss changes with the picture to how it changes with the
/// edges, the colours and the picture beneath:
/// 3. `backKernel`, once per picture pixel: how the loss changes with each shape's
///    distance at that pixel, and how much of each shape shows there.
/// 4. `rowKernel`, once per window row: that row's share of its shape's derivative.
/// 5. `sumKernel`, once per shape and number: the rows added up.
///
/// Every sum is made by one GPU thread adding in a fixed order, so the same input gives
/// exactly the same result every time. Sums that GPU threads race to add into come out
/// rounded differently from run to run, and a fit magnifies that into different shapes.
enum RasterKernels {
    /// For every window pixel, in strip order: `distance` to the shape's outline, positive
    /// inside and negative outside, and `nearest`, the index of the edge it is measured
    /// to. `edges` [P', E, 4] holds the start x, start y, end x and end y of every edge of
    /// each drawn shape. Where edges are equally near, as two are all around the corner
    /// they share, the first one counts. Neither result carries a derivative.
    static func distances(
        edges: MLXArray, layout: WindowLayout
    ) -> (distance: MLXArray, nearest: MLXArray) {
        let found = distances(
            edges: edges, windows: windowsArray(layout), stripLength: layout.stripLength)
        return (found[0], found[1])
    }

    /// The drawn shapes painted in order over `base`, each within its window: the picture
    /// [H, W, 3] and the distance [H, W] from each pixel to the nearest edge of any shape.
    ///
    /// `edges` [P', E, 4], `colors` [P', 3] and `fills` (endColors [P', 3], axes
    /// [P', 2, 2]) describe the drawn shapes only. The picture has a derivative by all of
    /// them and by `base.image`; the edge distance has none, and nor does anything by
    /// `mask`.
    static func paint(
        edges: MLXArray, colors: MLXArray, fills: (endColors: MLXArray, axes: MLXArray)?,
        base: (image: MLXArray, boundaryDistance: MLXArray), mask: MLXArray?,
        layout: WindowLayout, softness: Float
    ) -> (image: MLXArray, boundaryDistance: MLXArray) {
        let shapes = layout.drawn.count
        let strip = layout.stripLength
        let rowCount = layout.rowCount
        let height = base.image.dim(0)
        let width = base.image.dim(1)
        let edgeCount = edges.dim(1)
        precondition(edges.dim(0) == shapes && edges.dim(2) == 4 && colors.dim(0) == shapes)

        let windows = windowsArray(layout)
        let soft = MLXArray(softness)
        // Stands in for an input that this variant of a kernel never reads.
        let unused = MLXArray.zeros([1])
        let cover = mask ?? unused
        let filled = fills != nil
        let variant: [(String, any KernelTemplateArg)] = [("FILLS", filled), ("MASKED", mask != nil)]
        let pictureShape = [height, width, 3]
        // Per shape: four numbers for each edge, then the colour, then with gradient
        // fills the end colour and the axis.
        let numbers = 4 * edgeCount + (filled ? 10 : 3)

        var inputs = [edges, colors, base.image]
        if let fills { inputs += [fills.endColors, fills.axes.reshaped(shapes, 4)] }

        // MLX's core wraps the results of a function like this one in operations of its
        // own, which must share the stream of everything else (see `onOneStream`).
        let painted = onOneStream {
            CustomFunction {
                Forward { inputs in
                    let found = distances(edges: inputs[0], windows: windows, stripLength: strip)
                    let picture = paintKernel(
                        [
                            found[0], windows, inputs[1], filled ? inputs[3] : unused,
                            filled ? inputs[4] : unused, inputs[2], base.boundaryDistance, cover, soft,
                        ],
                        template: variant, grid: (width, height, 1), threadGroup: (16, 16, 1),
                        outputShapes: [pictureShape, [height, width]],
                        outputDTypes: [.float32, .float32])
                    // The distances and nearest edges are handed on to the way back.
                    return [picture[0], picture[1], found[0], found[1]]
                }
                VJP { inputs, cotangents, outputs in
                    let byPicture = cotangents[0]
                    let ends = filled ? inputs[3] : unused
                    let axes = filled ? inputs[4] : unused
                    let walked = backKernel(
                        [outputs[2], windows, inputs[1], ends, axes, inputs[2], cover, soft, byPicture],
                        template: variant, grid: (width, height, 1), threadGroup: (16, 16, 1),
                        outputShapes: [[strip], [strip], pictureShape],
                        outputDTypes: [.float32, .float32, .float32])
                    let rows = rowKernel(
                        [walked[0], walked[1], outputs[3], inputs[0], windows, inputs[1], ends, axes, byPicture],
                        template: [("EDGES", edgeCount), ("FILLS", filled)],
                        grid: (rowCount, 1, 1), threadGroup: (64, 1, 1),
                        outputShapes: [[rowCount, numbers]], outputDTypes: [.float32])
                    let sums = sumKernel(
                        [rows[0], windows], grid: (numbers, shapes, 1), threadGroup: (32, 8, 1),
                        outputShapes: [[shapes, numbers]], outputDTypes: [.float32])[0]
                    let colorsAt = 4 * edgeCount
                    var derivatives = [
                        sums[0..., 0..<colorsAt].reshaped(shapes, edgeCount, 4),
                        sums[0..., colorsAt..<(colorsAt + 3)],
                        walked[2],
                    ]
                    if filled {
                        derivatives += [
                            sums[0..., (colorsAt + 3)..<(colorsAt + 6)],
                            sums[0..., (colorsAt + 6)..<(colorsAt + 10)],
                        ]
                    }
                    return derivatives
                }
            }(inputs)
        }
        return (painted[0], painted[1])
    }

    private static func windowsArray(_ layout: WindowLayout) -> MLXArray {
        MLXArray(layout.table, [layout.drawn.count, WindowLayout.fields])
    }

    private static func distances(
        edges: MLXArray, windows: MLXArray, stripLength: Int
    ) -> [MLXArray] {
        distanceKernel(
            [stopGradient(edges), windows], grid: (stripLength, 1, 1), threadGroup: (256, 1, 1),
            outputShapes: [[stripLength], [stripLength]], outputDTypes: [.float32, .int32])
    }

    // In all the programs below, `windows` is the table of `WindowLayout`: for each drawn
    // shape its window's left column, top row, width and height, the strip element of its
    // first pixel, and the number of window rows before it.

    private static let header = #"""
        // The last row of a windows table whose entry `field` is not past `at`: the shape
        // that a strip element, or a window row, belongs to.
        #define LAYERFIT_FIND(found, table, count, field, at)       \
            int found = 0;                                          \
            {                                                       \
                int last = (count) - 1;                             \
                while (found < last) {                              \
                    int middle = (found + last + 1) >> 1;           \
                    if (table[6 * middle + (field)] <= int(at)) {   \
                        found = middle;                             \
                    } else {                                        \
                        last = middle - 1;                          \
                    }                                               \
                }                                                   \
            }

        // How much of a pixel a shape covers, from the pixel's signed distance to the
        // shape's outline. Written so that neither far end overflows.
        inline float layerfit_coverage(float d, float softness) {
            float z = exp(-fabs(d) / softness);
            return d >= 0.0f ? 1.0f / (1.0f + z) : z / (1.0f + z);
        }

        // How fast that coverage changes with the distance.
        inline float layerfit_coverage_slope(float d, float softness) {
            float z = exp(-fabs(d) / softness);
            return z / ((1.0f + z) * (1.0f + z) * softness);
        }

        // How far along a gradient fill's axis a pixel lies: 0 at the axis's start and 1
        // at its end, and not yet held within those.
        inline float layerfit_along(float px, float py, float fx, float fy, float tx, float ty) {
            float ax = tx - fx;
            float ay = ty - fy;
            return ((px - fx) * ax + (py - fy) * ay) / (ax * ax + ay * ay + 1e-6f);
        }
        """#

    /// One thread per window pixel.
    private static let distanceKernel = MLXFast.metalKernel(
        name: "layerfit_edge_distance",
        inputNames: ["edges", "windows"],
        outputNames: ["edge_distance", "edge_index"],
        source: #"""
            uint element = thread_position_in_grid.x;
            LAYERFIT_FIND(shape, windows, windows_shape[0], 4, element)
            int entry = 6 * shape;
            int across = windows[entry + 2];
            int local = int(element) - windows[entry + 4];
            float px = float(windows[entry] + local % across) + 0.5f;
            float py = float(windows[entry + 1] + local / across) + 0.5f;

            int count = edges_shape[1];
            int first = shape * count * 4;
            float least = 3.0e38f;
            int nearest = 0;
            int winding = 0;
            for (int e = 0; e < count; e++) {
                int at = first + 4 * e;
                float ax = edges[at];
                float ay = edges[at + 1];
                float bx = edges[at + 2];
                float by = edges[at + 3];
                float dx = bx - ax;
                float dy = by - ay;
                float relX = px - ax;
                float relY = py - ay;

                // Squared distance from the pixel centre to the edge.
                float t = clamp((relX * dx + relY * dy) / (dx * dx + dy * dy + 1e-8f), 0.0f, 1.0f);
                float offX = relX - t * dx;
                float offY = relY - t * dy;
                float squared = offX * offX + offY * offY;
                if (squared < least) {
                    least = squared;
                    nearest = e;
                }

                // Non-zero inside test: a ray toward +x counts each edge it crosses as +1
                // or -1 by the edge's direction; the pixel is inside if these do not
                // cancel. A shape that overlaps itself is therefore solid there, not cut
                // out.
                if ((ay > py) != (by > py)) {
                    float crossX = ax + (py - ay) / dy * dx;
                    if (px < crossX) {
                        winding += by > ay ? 1 : -1;
                    }
                }
            }
            edge_distance[element] = (winding != 0 ? 1.0f : -1.0f) * sqrt(least + 1e-8f);
            edge_index[element] = nearest;
            """#,
        header: header)

    /// One thread per picture pixel: paints the shapes whose windows hold the pixel, in
    /// order, each over what is there already.
    private static let paintKernel = MLXFast.metalKernel(
        name: "layerfit_paint",
        inputNames: [
            "edge_distance", "windows", "colors", "end_colors", "axes", "base", "base_boundary",
            "mask", "softness",
        ],
        outputNames: ["image", "boundary"],
        source: #"""
            uint column = thread_position_in_grid.x;
            uint row = thread_position_in_grid.y;
            uint pixel = row * threads_per_grid.x + column;
            float px = float(column) + 0.5f;
            float py = float(row) + 0.5f;
            float cover = MASKED ? mask[pixel] : 1.0f;
            float red = base[3 * pixel];
            float green = base[3 * pixel + 1];
            float blue = base[3 * pixel + 2];
            float nearest = base_boundary[pixel];

            int shapes = windows_shape[0];
            for (int shape = 0; shape < shapes; shape++) {
                int entry = 6 * shape;
                int cx = int(column) - windows[entry];
                int cy = int(row) - windows[entry + 1];
                int across = windows[entry + 2];
                if (cx < 0 || cy < 0 || cx >= across || cy >= windows[entry + 3]) {
                    continue;
                }
                float d = edge_distance[windows[entry + 4] + cy * across + cx];
                nearest = min(nearest, fabs(d));
                float alpha = cover * layerfit_coverage(d, softness);

                float fillRed = colors[3 * shape];
                float fillGreen = colors[3 * shape + 1];
                float fillBlue = colors[3 * shape + 2];
                if (FILLS) {
                    float t = clamp(
                        layerfit_along(
                            px, py, axes[4 * shape], axes[4 * shape + 1], axes[4 * shape + 2],
                            axes[4 * shape + 3]),
                        0.0f, 1.0f);
                    fillRed += t * (end_colors[3 * shape] - fillRed);
                    fillGreen += t * (end_colors[3 * shape + 1] - fillGreen);
                    fillBlue += t * (end_colors[3 * shape + 2] - fillBlue);
                }
                red += alpha * (fillRed - red);
                green += alpha * (fillGreen - green);
                blue += alpha * (fillBlue - blue);
            }
            image[3 * pixel] = red;
            image[3 * pixel + 1] = green;
            image[3 * pixel + 2] = blue;
            boundary[pixel] = nearest;
            """#,
        header: header)

    /// One thread per picture pixel, given `cotangent`: how the loss changes with each
    /// channel of the picture. For every shape whose window holds the pixel it writes, at
    /// that pixel's place in the strip:
    /// - `d_distance`: how the loss changes with the unsigned distance from the pixel to
    ///   the shape's outline;
    /// - `shows`: how much of the shape's fill ends up in the picture at that pixel.
    /// It also writes `d_base`: how the loss changes with the picture beneath.
    private static let backKernel = MLXFast.metalKernel(
        name: "layerfit_paint_back",
        inputNames: [
            "edge_distance", "windows", "colors", "end_colors", "axes", "base", "mask", "softness",
            "cotangent",
        ],
        outputNames: ["d_distance", "shows", "d_base"],
        source: #"""
            uint column = thread_position_in_grid.x;
            uint row = thread_position_in_grid.y;
            uint pixel = row * threads_per_grid.x + column;
            float px = float(column) + 0.5f;
            float py = float(row) + 0.5f;
            float cover = MASKED ? mask[pixel] : 1.0f;
            float byRed = cotangent[3 * pixel];
            float byGreen = cotangent[3 * pixel + 1];
            float byBlue = cotangent[3 * pixel + 2];
            float red = base[3 * pixel];
            float green = base[3 * pixel + 1];
            float blue = base[3 * pixel + 2];
            int shapes = windows_shape[0];

            // Going up through the shapes, painting as before. More of a shape's coverage
            // here moves the picture from what lies beneath it toward its fill; noted for
            // each shape is how the loss would change with that, were nothing above it.
            for (int shape = 0; shape < shapes; shape++) {
                int entry = 6 * shape;
                int cx = int(column) - windows[entry];
                int cy = int(row) - windows[entry + 1];
                int across = windows[entry + 2];
                if (cx < 0 || cy < 0 || cx >= across || cy >= windows[entry + 3]) {
                    continue;
                }
                int slot = windows[entry + 4] + cy * across + cx;

                float fillRed = colors[3 * shape];
                float fillGreen = colors[3 * shape + 1];
                float fillBlue = colors[3 * shape + 2];
                if (FILLS) {
                    float t = clamp(
                        layerfit_along(
                            px, py, axes[4 * shape], axes[4 * shape + 1], axes[4 * shape + 2],
                            axes[4 * shape + 3]),
                        0.0f, 1.0f);
                    fillRed += t * (end_colors[3 * shape] - fillRed);
                    fillGreen += t * (end_colors[3 * shape + 1] - fillGreen);
                    fillBlue += t * (end_colors[3 * shape + 2] - fillBlue);
                }
                d_distance[slot] =
                    byRed * (fillRed - red) + byGreen * (fillGreen - green)
                    + byBlue * (fillBlue - blue);

                float alpha = cover * layerfit_coverage(edge_distance[slot], softness);
                red += alpha * (fillRed - red);
                green += alpha * (fillGreen - green);
                blue += alpha * (fillBlue - blue);
            }

            // Coming back down. `through` is how much of what is painted at this level
            // the shapes above it let through to the finished picture.
            float through = 1.0f;
            for (int shape = shapes - 1; shape >= 0; shape--) {
                int entry = 6 * shape;
                int cx = int(column) - windows[entry];
                int cy = int(row) - windows[entry + 1];
                int across = windows[entry + 2];
                if (cx < 0 || cy < 0 || cx >= across || cy >= windows[entry + 3]) {
                    continue;
                }
                int slot = windows[entry + 4] + cy * across + cx;
                float d = edge_distance[slot];
                float alpha = cover * layerfit_coverage(d, softness);
                // By coverage, then by signed distance, then by distance itself: inside
                // the shape a greater distance means more coverage, outside it less.
                d_distance[slot] =
                    (d < 0.0f ? -1.0f : 1.0f) * through * d_distance[slot] * cover
                    * layerfit_coverage_slope(d, softness);
                shows[slot] = alpha * through;
                through *= 1.0f - alpha;
            }
            d_base[3 * pixel] = through * byRed;
            d_base[3 * pixel + 1] = through * byGreen;
            d_base[3 * pixel + 2] = through * byBlue;
            """#,
        header: header)

    /// One thread per window row. Adds up, over the pixels of that row, how the loss
    /// changes with each number that describes the row's shape: four for each edge (start
    /// x, start y, end x, end y), three for the colour and, with gradient fills, three
    /// for the end colour and four for the axis.
    private static let rowKernel = MLXFast.metalKernel(
        name: "layerfit_row_sums",
        inputNames: [
            "d_distance", "shows", "edge_index", "edges", "windows", "colors", "end_colors", "axes",
            "cotangent",
        ],
        outputNames: ["row_sums"],
        source: #"""
            uint line = thread_position_in_grid.x;
            LAYERFIT_FIND(shape, windows, windows_shape[0], 5, line)
            int entry = 6 * shape;
            int across = windows[entry + 2];
            int row = int(line) - windows[entry + 5];
            int slot = windows[entry + 4] + row * across;
            int pixel = (windows[entry + 1] + row) * cotangent_shape[1] + windows[entry];
            float py = float(windows[entry + 1] + row) + 0.5f;

            const int numbers = 4 * EDGES + (FILLS ? 10 : 3);
            float sums[4 * EDGES + (FILLS ? 10 : 3)];
            for (int k = 0; k < numbers; k++) {
                sums[k] = 0.0f;
            }

            for (int cx = 0; cx < across; cx++) {
                float px = float(windows[entry] + cx) + 0.5f;

                // The pixel's distance is measured to one edge, at the point of it nearest
                // the pixel: a share `s` of the way from its start to its end. Moving the
                // edge toward the pixel shortens the distance, by 1 - s of a move of the
                // start and s of a move of the end.
                int e = edge_index[slot + cx];
                int at = (shape * EDGES + e) * 4;
                float ax = edges[at];
                float ay = edges[at + 1];
                float edgeX = edges[at + 2] - ax;
                float edgeY = edges[at + 3] - ay;
                float fromX = px - ax;
                float fromY = py - ay;
                float s = clamp(
                    (fromX * edgeX + fromY * edgeY) / (edgeX * edgeX + edgeY * edgeY + 1e-8f),
                    0.0f, 1.0f);
                float gapX = fromX - s * edgeX;
                float gapY = fromY - s * edgeY;
                float pull = -d_distance[slot + cx] / sqrt(gapX * gapX + gapY * gapY + 1e-8f);
                sums[4 * e] += pull * (1.0f - s) * gapX;
                sums[4 * e + 1] += pull * (1.0f - s) * gapY;
                sums[4 * e + 2] += pull * s * gapX;
                sums[4 * e + 3] += pull * s * gapY;

                // The picture holds `shows` of the shape's fill at this pixel.
                float seen = shows[slot + cx];
                float byRed = seen * cotangent[3 * (pixel + cx)];
                float byGreen = seen * cotangent[3 * (pixel + cx) + 1];
                float byBlue = seen * cotangent[3 * (pixel + cx) + 2];
                int fill = 4 * EDGES;
                if (FILLS) {
                    // The fill is the colour at the axis's start, the end colour at its
                    // end, and between them in proportion to how far along the pixel lies.
                    float startX = axes[4 * shape];
                    float startY = axes[4 * shape + 1];
                    float alongX = axes[4 * shape + 2] - startX;
                    float alongY = axes[4 * shape + 3] - startY;
                    float relX = px - startX;
                    float relY = py - startY;
                    float span = alongX * alongX + alongY * alongY + 1e-6f;
                    float u = (relX * alongX + relY * alongY) / span;
                    float t = clamp(u, 0.0f, 1.0f);
                    sums[fill] += (1.0f - t) * byRed;
                    sums[fill + 1] += (1.0f - t) * byGreen;
                    sums[fill + 2] += (1.0f - t) * byBlue;
                    sums[fill + 3] += t * byRed;
                    sums[fill + 4] += t * byGreen;
                    sums[fill + 5] += t * byBlue;
                    // Beyond either end of the axis the fill no longer changes with it.
                    if (u > 0.0f && u < 1.0f) {
                        float slope =
                            (byRed * (end_colors[3 * shape] - colors[3 * shape])
                                + byGreen * (end_colors[3 * shape + 1] - colors[3 * shape + 1])
                                + byBlue * (end_colors[3 * shape + 2] - colors[3 * shape + 2]))
                            / span;
                        sums[fill + 6] += slope * ((2.0f * u - 1.0f) * alongX - relX);
                        sums[fill + 7] += slope * ((2.0f * u - 1.0f) * alongY - relY);
                        sums[fill + 8] += slope * (relX - 2.0f * u * alongX);
                        sums[fill + 9] += slope * (relY - 2.0f * u * alongY);
                    }
                } else {
                    sums[fill] += byRed;
                    sums[fill + 1] += byGreen;
                    sums[fill + 2] += byBlue;
                }
            }
            for (int k = 0; k < numbers; k++) {
                row_sums[line * uint(numbers) + uint(k)] = sums[k];
            }
            """#,
        header: header)

    /// One thread per shape and number: adds that number up over the rows of the shape's
    /// window.
    private static let sumKernel = MLXFast.metalKernel(
        name: "layerfit_shape_sums",
        inputNames: ["row_sums", "windows"],
        outputNames: ["shape_sums"],
        source: #"""
            uint number = thread_position_in_grid.x;
            uint shape = thread_position_in_grid.y;
            uint numbers = uint(row_sums_shape[1]);
            uint first = uint(windows[6 * shape + 5]);
            uint rows = uint(windows[6 * shape + 3]);
            float total = 0.0f;
            for (uint r = first; r < first + rows; r++) {
                total += row_sums[r * numbers + number];
            }
            shape_sums[shape * numbers + number] = total;
            """#)
}
