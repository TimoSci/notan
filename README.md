# Notan

Notan turns a photograph into a short list of flat-coloured shapes, built from coarse to
fine, and lets you slide through the levels to see how few shapes still make a good
picture. The shapes are either curves laid over one another or straight-edged tiles that
fit together. It is a native macOS app that does its fitting on the GPU.

The name is the Japanese design term for reducing a picture to flat shapes of light and
dark.

## What it does

- **Fits shapes to a photo.** Each shape is a closed curve with one fill colour (or,
  optionally, a linear gradient). Shapes are added in stages; each new shape starts where
  the picture is currently most wrong, and all of them are then adjusted by gradient
  descent. The method follows LIVE (Layer-wise Image Vectorization, Ma et al., CVPR 2022).
- **Or fits tiles.** Instead of curves, the picture can be cut into straight-edged tiles
  that share edges and never overlap. Each stage cuts tiles in two with a straight line
  and then moves the corners to fit. *Strict tree* cuts every tile at every stage, so
  the tile count doubles; *Worst first* cuts only the tiles that gain most.
- **Keeps every level.** Each stage is one level on a slider, from the background colour
  alone up to the full set of shapes. Each level shows its shape count and an estimate of
  its size in bytes next to the original file's.
- **Two ways of building levels.** In *Re-fit*, every level is re-optimised as a whole, so
  each is the best picture found with that many shapes. In *Prefix*, shapes are frozen
  once their stage ends, so each level is exactly the first shapes of the next. For
  tiles, *Prefix* means a tile's outline is fixed once it is cut, so each level's tiles
  are made up exactly of the next level's.
- **Refines parts of the picture.** Select one or more shapes, or the gaps between them,
  and fit finer shapes inside just those areas. A refined area is locked: it stays on top
  on later levels until you unlock it.
  A selected tile is cut further in the same way, and the finer tiles take its place.
  With *Prefix* levels a refined tile stays on later levels too, until you unlock it;
  with *Re-fit* levels it shows on the level it was refined on, because a tile has
  another outline on every other level.
- **Exports SVG.** The level on screen is written as an SVG at the photo's pixel size.

The picture on screen and in the SVG is always drawn from the vector shapes, with hard
edges. Fitting happens on a downscaled copy of the photo.

## Requirements

- A Mac with Apple Silicon, macOS 15 or later
- Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

Builds go through `xcodebuild`, not plain `swift build`, because MLX needs its Metal
shaders compiled.

## Building and running the app

```sh
cd App
xcodegen generate
xcodebuild build -project Notan.xcodeproj -scheme Notan -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath ../.build/app
open ../.build/app/Build/Products/Release/Notan.app
```

## Using the app

1. **Open a photo** with *Open…*, or drop one on the window.
2. **Choose settings** if you like: *Kind* (*Curves* or *Tiles*) and, for tiles, *Cuts*
   (*Strict tree* or *Worst first*); the number of shapes, the working size, the steps
   per stage, the level mode (*Re-fit* or *Prefix*), and the options *Min width*, *Avoid
   folds* and *Gradients* (the last two are for curves). Each combination of kind, cuts
   and level mode keeps its own result, so you can switch between them to compare. Hover
   over a control for an explanation.
3. **Press Start.** The picture updates as it fits; *Cancel* keeps the levels finished so
   far.
4. **Drag the Level slider**, or use the left and right arrow keys, to step through the
   levels. Press and hold *Hold: original* to compare with the photo.
5. **Select tiles, in tile mode.** Click a tile to select it; the rest of the picture is
   dimmed. *Parent* selects the tile it was cut from. The selection stays as you move
   through the levels: on a later level it is the pieces the tile was cut into.
6. **Refine, if you want more detail somewhere.** Click a shape, a gap or a tile to select it;
   Shift-click adds one to the selection or takes it out; Esc selects the whole picture
   again. *Refine selection* then fits finer shapes inside each selected area. The
   *Refined areas* panel on the right lists them by level, and the lock next to each one
   switches its lock on or off.
7. **Export SVG…** writes the level shown.

## Command-line tool

The same fitting is available without the window, for checking and timing:

```sh
xcodebuild build -scheme notan -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/dd
.build/dd/Build/Products/Release/notan photo.jpg out --shapes 128 --size 256
```

It writes one SVG and one PNG per level to the output folder. Options:

| Option | Meaning | Values |
| --- | --- | --- |
| `--kind` | what the picture is built from | `curves`, `tiles` |
| `--order` | for tiles, which are cut at each stage | `tree`, `worst` |
| `--mode` | how levels are built | `refit`, `prefix` |
| `--shapes` | total number of shapes | whole number |
| `--size` | long side of the working copy, in pixels | whole number |
| `--steps` | optimisation steps per stage | whole number |
| `--min-width` | narrowest shape allowed, in pixels | number, 0 for no limit |
| `--folds` | whether shapes may cross over themselves | `avoid`, `allow` |
| `--fill` | flat colour or linear gradient | `flat`, `gradient` |

Run `notan` with no arguments to see the tuning options as well.

## Tests

```sh
xcodebuild test -scheme Notan-Package -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/dd
```

## Layout

- `Sources/NotanCore`: shapes, rasteriser, loss, fitting, SVG writing; no UI
- `Sources/NotanApp`: the SwiftUI window and its model
- `Sources/notan`: the command-line tool
- `App`: the app target and its XcodeGen project file
- `docs/superpowers/specs`: the design documents
