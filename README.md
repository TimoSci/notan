# Notan

Notan turns a photograph into a short list of flat-coloured shapes, built from coarse to
fine, and lets you slide through the levels to see how few shapes still make a good
picture. It is a native macOS app that does its fitting on the GPU.

The name is the Japanese design term for reducing a picture to flat shapes of light and
dark.

## What it does

- **Fits shapes to a photo.** Each shape is a closed curve with one fill colour (or,
  optionally, a linear gradient). Shapes are added in stages; each new shape starts where
  the picture is currently most wrong, and all of them are then adjusted by gradient
  descent. The method follows LIVE (Layer-wise Image Vectorization, Ma et al., CVPR 2022).
- **Keeps every level.** Each stage is one level on a slider, from the background colour
  alone up to the full set of shapes. Each level shows its shape count and an estimate of
  its size in bytes next to the original file's.
- **Two ways of building levels.** In *Re-fit*, every level is re-optimised as a whole, so
  each is the best picture found with that many shapes. In *Prefix*, shapes are frozen
  once their stage ends, so each level is exactly the first shapes of the next.
- **Refines parts of the picture.** Select one or more shapes, or the gaps between them,
  and fit finer shapes inside just those areas. A refined area is locked: it stays on top
  on later levels until you unlock it.
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
2. **Choose settings** if you like: the number of shapes, the working size, the steps per
   stage, the level mode (*Re-fit* or *Prefix*), and the options *Min width*, *Avoid
   folds* and *Gradients*. Hover over a control for an explanation.
3. **Press Start.** The picture updates as it fits; *Cancel* keeps the levels finished so
   far.
4. **Drag the Level slider**, or use the left and right arrow keys, to step through the
   levels. Press and hold *Hold: original* to compare with the photo.
5. **Refine, if you want more detail somewhere.** Click a shape or a gap to select it;
   Shift-click adds one to the selection or takes it out; Esc selects the whole picture
   again. *Refine selection* then fits finer shapes inside each selected area. The
   *Refined areas* panel on the right lists them by level, and the lock next to each one
   switches its lock on or off.
6. **Export SVG…** writes the level shown.

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
- `docs/superpowers/specs`: the design document
