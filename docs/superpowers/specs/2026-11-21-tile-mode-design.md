# Tile mode for Notan — design

Date: 2026-11-21

## Intent

A second way of fitting a photo, next to the existing curved shapes: straight-edged
polygons that fit together like tiles, with no overlaps and no gaps, built as a hierarchy
of ever smaller tiles that can be navigated. The question is the same as before: how
good can the picture look at each level of compression?

## What the owner decided

- Polygons instead of Bézier curves, connected like tiles, not overlapping.
- The same concept as the rest of the app: a navigable hierarchy of ever smaller shapes.
- Built as a second mode in Notan, not a separate app.
- Two cut orders, both available: a strict tree, where every tile is cut once more at
  each level, and worst first, where the tiles that gain most are cut first.

Everything below is the designer's call.

## Goals

- A "Tiles" choice next to "Curves", with a cut order of "Strict tree" or "Worst first".
- Both level modes work with tiles. In Prefix, a tile's outline is frozen once its stage
  ends, so each level's tiles are exactly unions of the next level's. In Re-fit, all
  corners keep moving at every stage, so each level is the best tiling found with that
  many tiles.
- The level slider, selection by click, the Parent button, SVG export and the
  command-line tool work with tiles.
- A tiling is always valid: every pixel belongs to exactly one tile.

## Non-goals (this plan)

- The depth slider in tile mode.
- Gradient fills and the "Folds" setting in tile mode.
- Bent cuts. A cut is one straight segment.
- A compact byte format for tiles. The byte figure is an estimate.

## Anti-goals

- Hairline seams of another colour between neighbouring tiles, on screen or in the SVG.
- Tiles that flip inside out, cross themselves or shrink to slivers.

## Approaches considered

1. **Cuts only, found by search, no gradient descent.** With frozen outlines each cut is
   an independent problem with two unknowns, so a search finds it. Simple and fast, but
   it cannot do Re-fit, where corners shared by several tiles move together.
2. **Shared-corner mesh, cut by search, then gradient descent (chosen).** A search
   places each new cut; the existing differentiable rasteriser then moves corners and
   colours. Prefix is the special case where only the new cut ends move, each along its
   frozen edge. One fitter serves both level modes.
3. **Voronoi cells from movable seed points.** Always a valid tiling, but there is no
   natural tree of tiles, so no hierarchy to navigate.

## How it works

### The tiling

- A tree of tiles. The root is the whole picture. A cut splits one leaf into two with a
  straight segment between points on two of its edges. Each tile's address is the list
  of first-or-second choices from the root.
- Tiles refer to corners by index, so neighbours share corners.
- In Re-fit, a cut end placed on an edge shared with a neighbour becomes a corner of the
  neighbour too. Picture corners never move; corners on the picture's border move only
  along it; all others move freely.
- In Prefix, existing corners never move. A new cut end slides along the frozen edge it
  was placed on and is not added to the neighbour. The neighbour's edge stays straight,
  so no gap opens.

### Stages and the two cut orders

- Level 0 is one tile in the photo's mean colour.
- At each stage a search finds, for every leaf, the straight cut that lowers the squared
  error most, with each side in its mean colour. That lowering is the tile's gain.
- The stage cuts the leaves with the largest gain. How many is the only difference
  between the orders:
  - **Strict tree:** all of them, so tile counts go 1, 2, 4, 8, …
  - **Worst first:** the same counts per stage as the curve mode's schedule
    (1, 1, 1, 1, 2, 2, 4, 4, …).
  The last stage is cut short so the total is the number of shapes chosen.
- A tile is not cut if every cut would leave a piece thinner than the Min width setting
  (at least 1 px) or smaller than 4 px in area.
- Then corners and colours are optimised for the chosen number of steps, and the tiling
  is saved as a level.

"Worst" is measured by gain, not by error alone (designer's call): a tile with high
error that no straight cut improves would waste cuts.

### Fitting

- The existing rasteriser already works on straight edges, so tiles go to it directly.
  It needs the same number of edges for every shape, so a tile with fewer corners has
  one of its edges divided into equal parts.
- Painting soft-edged tiles one over another does not blend two neighbours evenly: the
  one painted later counts for more, which would pull every shared edge about a quarter
  pixel off the edge in the photo. So the tiles are first painted grown by a few pixels,
  in reverse order, as an underlay; the tiles themselves are painted over that. Near a
  shared edge the underlay holds the colour of the tile painted first, so the second
  blends with it by its own soft edge alone, which is even.
- A corner shared by several tiles collects a part of its gradient from each. That sum
  is done on the CPU in a fixed order, so that fits are reproducible.
- The loss is the existing boundary-weighted error plus the plain error floor.
- In Re-fit, a penalty keeps tiles from shrinking, and after every step each tile is
  checked: not crossing itself, area above the minimum. Corners of failing tiles go back
  to where they were.
- A level's error is measured on the hard-edged picture drawn from the tiles, at four
  times the working size and averaged down.

### Display and export

- Each tile is drawn filled and outlined in its own colour, so neighbours overlap by a
  fraction of a pixel and nothing shows through between them. The SVG does the same.
- Clicking selects the tile under the pointer. Parent selects the tile it was cut from.
  A selected tile that has been cut further at the level shown is highlighted as the
  group of its pieces; on an earlier level the selection falls back to the tile that
  contains it. The rest of the picture is dimmed.
- Size estimate: 3 bytes, plus 3 per tile, plus 4 per distinct corner.

### Refining a tile (added 2026-11-21, after the first build)

The owner asked for refinement in tile mode, on these rules, proposed by the designer:

- Refine selection cuts each selected tile further, with the current tile count, steps
  and cut order, zoomed into that part of the photo as curve refinement is. A selected
  group of pieces is refined as one area, inside the outline round the group.
- The fit is the ordinary tile fit, kept to the tile's outline: only the pixels inside
  it count, the outline's corners do not move, and a cut end on the outline slides
  along it.
- The finer tiles take the tile's place. With a refined tile selected, the Level slider
  steps through its levels.
- With Prefix levels a tile has the same outline on every later level, so a refined
  tile is shown there too, locked by default, and can be unlocked in the refined-areas
  panel. With Re-fit levels its outline differs on every other level, so it shows only
  on the level it was refined on.
- A tile inside a refined tile can be refined in turn. It belongs to the level of the
  outer refinement it was made on. Refining the outer tile again drops it.

## Left to the builder

- Number of cut candidates per tile, the shrink penalty's weight, how far tiles are
  grown for the underlay, the outline width.
- Layout of files and tests.

## How we know it works

- Unit tests for the tiling (cuts, shared corners, validity), the cut search on synthetic
  images, the edge layout, both orders' tile counts, the prefix property, and a seam test:
  tiles of one colour over a contrasting background must show no other colour.
- The command-line tool, on a real photo, gives levels whose error falls as tiles are
  added, in all four combinations of order and level mode.
- The app is launched, a photo is fitted in tile mode, and the slider, selection and
  export are checked.
