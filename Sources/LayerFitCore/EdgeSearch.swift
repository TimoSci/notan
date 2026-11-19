import MLX

/// The costly part of rasterising: every pixel of a window against every edge of its
/// shape, to find which edge is nearest and whether the pixel is inside the outline.
///
/// Written as array operations this takes some twenty passes over an array with one entry
/// per pixel per edge. Here it is one small program that the GPU runs once per pixel, with
/// a loop over the edges inside it. Neither answer has a derivative, so nothing of this
/// has to be differentiated; MLX could not differentiate a program of this kind by itself.
enum EdgeSearch {
    /// `edges` [n, E, 4] holds, for each of the n shapes of the batch, the start x, start
    /// y, end x and end y of every edge of its outline. Returns, for every pixel centre of
    /// each shape's window:
    /// - `isNearest` [n, h, w, E]: 1 for the edge nearest to the pixel and 0 for the
    ///   others. Where edges are equally near, as two are all around the corner they
    ///   share, the first one counts.
    /// - `sign` [n, h, w]: 1 inside the outline and -1 outside.
    ///
    /// Neither result carries a derivative.
    static func nearest(
        edges: MLXArray, batch: WindowLayout.Batch
    ) -> (isNearest: MLXArray, sign: MLXArray) {
        let count = batch.shapes.count
        precondition(edges.ndim == 3 && edges.dim(0) == count && edges.dim(2) == 4)
        let origins = MLXArray(
            zip(batch.originsX, batch.originsY).flatMap { [Float($0), Float($1)] }, [count, 2])
        let found = kernel(
            [stopGradient(edges).asType(.float32), origins],
            grid: (batch.width, batch.height, count),
            threadGroup: (16, 16, 1),
            outputShapes: [
                [count, batch.height, batch.width, edges.dim(1)],
                [count, batch.height, batch.width],
            ],
            outputDTypes: [.float32, .float32])
        return (found[0], found[1])
    }

    /// One GPU thread per pixel: x and y across the window, z over the shapes.
    private static let kernel = MLXFast.metalKernel(
        name: "layerfit_edge_search",
        inputNames: ["edges", "origins"],
        outputNames: ["is_nearest", "side"],
        source: """
            uint column = thread_position_in_grid.x;
            uint row = thread_position_in_grid.y;
            uint shape = thread_position_in_grid.z;
            uint width = threads_per_grid.x;
            uint height = threads_per_grid.y;
            int count = edges_shape[1];
            float px = origins[2 * shape] + float(column) + 0.5f;
            float py = origins[2 * shape + 1] + float(row) + 0.5f;

            float least = 3.0e38f;
            int nearest = 0;
            int winding = 0;
            uint first = shape * uint(count) * 4;
            for (int e = 0; e < count; e++) {
                uint at = first + 4 * uint(e);
                float ax = edges[at];
                float ay = edges[at + 1];
                float bx = edges[at + 2];
                float by = edges[at + 3];
                float dx = bx - ax;
                float dy = by - ay;
                float relX = px - ax;
                float relY = py - ay;

                // Distance from the pixel centre to the edge.
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

            uint pixel = (shape * height + row) * width + column;
            uint entry = pixel * uint(count);
            for (int e = 0; e < count; e++) {
                is_nearest[entry + uint(e)] = e == nearest ? 1.0f : 0.0f;
            }
            side[pixel] = winding != 0 ? 1.0f : -1.0f;
            """)
}
