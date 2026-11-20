# LIVE-style layered photo vectoriser for macOS — design

Date: 2026-11-18

## Intent

The owner wants to test an idea: a photograph compressed as a short list of
flat-coloured closed curves, built coarse-to-fine, should still look
beautiful however few shapes are kept. It should degrade into a poster or
illustration, not into blocks and blur.

This app is the experiment. Load a photo, let it fit shapes, then drag a
slider through the levels of compression and judge by eye.

## Goals

- A native macOS app: open or drop a photo, press Start, watch it fit, then
  drag a slider through every level.
- The fitting follows the method of LIVE (Layer-wise Image Vectorization,
  Ma et al., CVPR 2022): shapes are added in stages, each new shape starts
  where the picture is currently most wrong, and shapes are refined by
  gradient descent through a differentiable rasteriser.
- Runs on the GPU through MLX Swift, using MLX's automatic differentiation
  for everything but the rasteriser. The rasteriser's gradient was at first
  automatic too; it is now written by hand, for speed (see "Differentiable
  rasteriser"). Adam is a small struct of our own on MLX
  arrays, because MLX's optimiser is built around neural-network modules
  and we need per-parameter learning rates and a frozen subset.
- Each level shows its shape count and an approximate size in bytes, so
  "how compressed" is visible.
- Export the level currently shown as an SVG file.

## Non-goals

- A real file format, entropy coding, or a decoder. The byte figure is an
  estimate.
- A web or wasm version, or any platform other than macOS on Apple Silicon.
- Gradients, strokes, transparency, or textures inside shapes.
- Full-resolution fitting. Fitting happens on a downscaled copy.
- Batch processing, saving sessions, or settings beyond those listed below.

## Anti-goals

- Levels that look like noise, smears or soft-edged blobs. The picture at
  every level is hard-edged flat shapes.
- Showing the soft raster used for fitting as the result. The display is
  always drawn from the vector shapes at window resolution.
- A UI that freezes while fitting.

## Constraints

- Machine: Mac Studio, M3 Ultra, 512 GB RAM, macOS 27.2, Xcode 27.1,
  Swift 6.4. `xcodegen` is installed.
- MLX Swift 0.33.0 (`https://github.com/ml-explore/mlx-swift`). MLX needs
  its Metal shaders compiled, so builds go through `xcodebuild`, not plain
  `swift build`.
- The repository is empty; there is nothing existing to fit in with.

## Approaches considered

1. **Greedy LIVE-style fit in Rust/wasm.** Trace the outline of the largest
   error region and fill it; no optimisation. Fast and runs in a browser,
   but the shapes are not optimised, so it needs more shapes for the same
   quality and is not really LIVE.
2. **Faithful LIVE in Rust/wasm.** Differentiable rasteriser and Adam in
   Rust. Correct method, but single-threaded wasm would take minutes per
   photo and the gradients must be written by hand.
3. **Faithful LIVE as a Mac app with Swift + MLX (chosen).** MLX gives GPU
   execution, automatic differentiation and Adam, so the rasteriser is
   written as array operations and the gradients come for free. Gives up
   the browser.
4. **Swift + raw Metal, or Rust + wgpu.** Same speed, but gradients are
   hand-derived in shaders. Rejected as the most bug-prone path.

The owner chose approach 3, trading the web app for faithful optimisation
at usable speed.

## What the owner decided

- The method is LIVE's, reimplemented (the original is Python + PyTorch +
  DiffVG and cannot be reused).
- macOS app, Swift, MLX, GPU.
- Upload a photo; a slider shows all the levels of compression.

Everything below is the designer's call, not something the owner agreed to
line by line.

## The fitting method

### Representation

- A picture is a background colour plus an ordered list of shapes, painted
  back to front.
- Each shape is one closed path of 4 cubic Bézier segments (12 control
  points) with one opaque RGB fill colour. Opaque, flat fill is deliberate:
  it matches the owner's original "each enclosed area gets a solid colour".
- Coordinates are in working-image pixels. Colours are sRGB in 0…1, and the
  loss is computed in sRGB, as LIVE does.

### Working resolution

The photo is downscaled so its long side is 256 px (setting: 128, 256, 384,
512). Fitting uses only this copy. Display and SVG export scale the shapes
up, which is free because they are vectors.

### Stages

Shapes are added in stages. Default schedule of shapes added per stage:

`1, 1, 1, 1, 2, 2, 4, 4, 8, 8, 16, 16, 32, 32` (128 shapes, 14 stages)

A setting picks the total: 32, 64, 128 or 256, by truncating or extending
the same doubling pattern.

In each stage:

1. Render the current picture and compare with the target.
2. Place each new shape (see Initialisation).
3. Optimise for a fixed number of Adam steps (default 150; setting). Which
   shapes may move depends on the level mode (see The slider and levels):
   - **Re-fit:** all shapes so far, old and new, plus the background
     colour.
   - **Prefix:** only the shapes added in this stage. Earlier shapes and
     the background are frozen: they are still rendered, but receive no
     updates. The background colour is optimised only before the first
     shape is added (it starts at the target's mean colour, which is
     already the optimum for a flat picture, so this may be a no-op).
4. Save a snapshot of every shape and the background. This is one level.

### Initialisation

As in LIVE's component-wise initialisation, on the CPU:

1. Per-pixel error between current render and target; quantise the target
   colours coarsely among pixels whose error is above a threshold, so that
   a region is "badly wrong and roughly one colour".
2. Find connected components; take the largest.
3. Centre the new shape at the pixel of that component farthest from the
   component's edge, so the centre is always inside it.
4. Start as a small circle; fill colour is the target colour at the centre.
5. When a stage adds several shapes, mark the chosen component as used and
   repeat, so they land in different regions.

If no pixel is above the threshold, fall back to the largest remaining
error pixel.

### Differentiable rasteriser

What it computes:

1. Sample each Bézier segment at a fixed number of parameter values to get
   a closed polygon per shape. This is linear in the control points.
2. For every pixel centre and every shape: the distance to the nearest
   polygon edge, and an inside/outside sign from an even-odd crossing
   count. The sign is treated as a constant; gradient flows through the
   distance.
3. Coverage = sigmoid(signed distance / softness), softness about one
   pixel.
4. Composite back to front over the background:
   `C = C·(1 − a) + colour·a`.

This was first written entirely as MLX array operations, so that MLX could
differentiate it, and hand-written gradients were ruled out as bug-prone.
It turned out to take nearly all of the fitting time, so steps 2 to 4 are
now a few small Metal programs run through MLX, with their gradient written
by hand; only step 1 is still array operations. To keep the hand-written
gradient honest, the tests hold the first version's arithmetic as a plain
reference, differentiated automatically, and compare picture and gradient
against it shape by shape.

The builder must keep memory in check at 256 shapes and 512 px, for example
by processing shapes in chunks. 512 GB of unified memory is available, but
speed matters more than using it.

### Loss

- Mean squared error between render and target, each pixel weighted by its
  closeness to a shape boundary (LIVE's UDF-weighted loss). The distances
  are already computed by the rasteriser. "Boundary" means the nearest
  edge of any shape, hidden or not. The weight is held constant: no
  gradient flows through it.
- Plus a small unweighted mean squared error term over all pixels, so the
  background colour and large flat interiors still receive gradient when
  few shapes exist. This is a deliberate departure from LIVE (designer's
  call); its weight is the builder's to tune.
- The background colour starts as the mean colour of the target.
- LIVE's Xing loss on every Bézier segment, to discourage self-crossing
  shapes. Use the formulation and weight from the paper.

### Optimiser

Adam. Learning rate 1.0 for control points (in pixels at 256 px, scaled
with working resolution) and 0.01 for colours, as in LIVE. Colours are
clamped to 0…1 after each step.

### Running

Fitting runs off the main thread. After each stage, and a few times within
a stage, the current shapes are sent to the UI. Cancel stops at the next
step and keeps the levels finished so far.

Expected time for 128 shapes at 256 px is a few minutes. This is an
expectation, not a requirement; measure and report it.

## The slider and levels

- One slider stop per finished stage, plus stop 0, which is the background
  colour alone.
- Each stop shows that stage's snapshot.
- The owner chose to have two level modes, picked with a toggle before
  fitting starts:
  - **Re-fit** (faithful to LIVE). Every stage re-optimises all shapes, so
    a level is not a prefix of the next: each level is the best picture
    found with that many shapes. The result is a set of independent
    compressed versions.
  - **Prefix.** Shapes are frozen once their stage ends, so every level is
    exactly the first N shapes of one final list: a single stream that can
    be cut anywhere. This is the strict hierarchy of the owner's original
    idea. Higher levels are expected to be somewhat worse per shape.
- The point of having both is to compare them: how much does the strict
  hierarchy cost in looks? The app keeps the most recent result of each
  mode for the loaded photo, and switching the toggle after fitting
  switches which result the slider shows, at the same stop. Fitting one
  mode does not discard the other's result; loading a new photo discards
  both.
- In Prefix mode the snapshots must satisfy the prefix property exactly:
  level k's shapes are bit-identical to the first shapes of level k+1.
- The slider can be dragged while fitting is still running; new stops
  appear as stages finish.

### Size estimate

Per level: `3 + shapes × (24 × 2 + 3)` bytes — a background colour, and per
shape 24 coordinates at 2 bytes each plus 3 colour bytes. Shown next to the
original file's size and the ratio between them.

## The window

```
+--------------------------------------------------------------+
| [Open…]  Shapes [128 v]  Size [256 v]  Steps [150]           |
| Levels (Re-fit | Prefix)                             [Start] |
+--------------------------------------------------------------+
|                                                              |
|                   picture at current level                   |
|            (drop a photo here when nothing loaded)           |
|                                                              |
|                                                              |
+--------------------------------------------------------------+
| Level  o-----------O---------------------   8 of 14          |
| 16 shapes · 819 B · 1/4,000 of original      [Hold: original]|
| Fitting stage 11 of 14 ..........  [Cancel]     [Export SVG] |
+--------------------------------------------------------------+
```

- The picture is drawn from the vector shapes at window resolution, with
  hard anti-aliased edges, keeping the photo's aspect ratio.
- "Hold: original" shows the source photo while pressed, for comparison.
- While fitting, the picture follows the newest state unless the user has
  moved the slider.
- Export SVG writes the level shown, at the original photo's pixel size.
- Left and right arrow keys move the slider.

## Project shape

- `project.yml` for `xcodegen`; the generated Xcode project is not checked
  in.
- A core library with no UI: shapes, Bézier sampling, rasteriser, loss,
  initialisation, the stage loop, SVG writing.
- A SwiftUI app target on top of it.
- A small command-line target that runs the same core on an image file and
  writes one SVG and one PNG per level to a folder. It exists so the method
  can be checked and timed without the UI.
- Unit tests for the core.

## How we know it works

- Unit tests: Bézier sampling of a circle is round; rasterised coverage of
  a circle is close to πr²; connected-component initialisation picks the
  expected region on a synthetic image; one shape converges onto a
  synthetic flat disc; SVG output parses and has the right shape count;
  in Prefix mode each level's shapes are identical to the start of the
  next level's.
- The command-line tool takes the level mode as an option, and the builder
  reports per-level error for both modes on each test photo.
- The command-line tool, run on a real photo, produces levels whose error
  against the target falls as shapes are added.
- The app is launched, a photo is fitted, and the slider is checked at the
  first, middle and last levels.

### What counts as done

- Test photos: three of the desktop pictures shipped with macOS in
  `/System/Library/Desktop Pictures`, chosen to differ (a landscape, one
  with fine texture, one with large flat areas).
- The builder does one bounded tuning pass on those three, checking every
  level against the anti-goals: hard-edged flat shapes, no smears, no
  noise.
- The builder reports timings and the per-level error for each photo.
- Whether the levels are *beautiful* is the owner's judgement, made in the
  app on their own photos. The build is done when the above holds, not
  when that judgement is in.

## Left to the builder

- App name and bundle identifier.
- Module and file layout inside the targets.
- Polygon samples per segment, softness, error threshold and colour
  quantisation, tuned by looking at results.
- Chunking and any other memory or speed measures in the rasteriser.
- How often the UI is updated within a stage.
- Sandbox and entitlement settings.
