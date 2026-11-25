import SwiftUI

/// The user guide shown from the Help menu. The text uses Markdown for emphasis; the
/// names of controls are in bold, as they read in the window.
public enum UserGuide {
    public struct Section: Identifiable, Hashable {
        public let title: String
        public let blocks: [Block]
        public var id: String { title }

        public static func == (a: Section, b: Section) -> Bool { a.title == b.title }
        public func hash(into hasher: inout Hasher) { hasher.combine(title) }
    }

    public enum Block {
        case text(String)
        case heading(String)
        /// Numbered steps.
        case steps([String])
        /// Names with an explanation each.
        case terms([(name: String, text: String)])
    }

    public static let sections: [Section] = [
        Section(
            title: "What Notan does",
            blocks: [
                .text(
                    "Notan turns a photo into a short list of coloured shapes. It builds the picture from coarse to fine, and keeps every step on the way as a *level*, so you can see how few shapes still make a good picture."
                ),
                .text(
                    "The picture can be built from **Curves**, which are curved shapes laid over one another, or from **Tiles**, which are straight-edged pieces that fit together with no overlaps and no gaps."
                ),
                .text(
                    "What you see is always drawn from the shapes themselves, with hard edges, and it is what **Export SVG…** writes. The fitting is done on a smaller copy of the photo, on the graphics processor."
                ),
                .heading("The window"),
                .terms([
                    ("Top", "The settings for a fit, the selection, and the buttons that start work."),
                    ("Middle", "The picture. Click in it to select shapes or tiles."),
                    ("Right", "The **Refined areas** panel, which lists the parts you have refined."),
                    (
                        "Bottom",
                        "The **Level** slider, the **Depth** slider for curves, the size of the level shown, the progress of a fit, and export."
                    ),
                ]),
                .text("Hold the pointer over any control for a short explanation."),
            ]),
        Section(
            title: "Quick start",
            blocks: [
                .steps([
                    "Press **Open…** and choose a photo, or drop one on the window.",
                    "Press **Start**, or the Return key. The picture updates as each level is finished.",
                    "Drag the **Level** slider, or press the left and right arrow keys, to step through the levels.",
                    "Press and hold **Hold: original** to compare with the photo.",
                    "Press **Export SVG…** to save the level on screen.",
                ]),
                .text(
                    "The settings as they come give a fair result on most photos. The rest of this guide explains what each one changes."
                ),
            ]),
        Section(
            title: "Fitting a photo",
            blocks: [
                .text(
                    "A fit runs in stages. Each stage adds shapes, or cuts tiles, and then adjusts them to match the photo. Each stage ends as one level."
                ),
                .terms([
                    ("**Start**", "Fits the photo with the current settings. A result of an earlier fit with the same **Kind**, **Cuts** and **Levels** is replaced."),
                    ("**Restart**", "What **Start** reads while a fit is running. It drops that fit and begins again with the settings as they are now."),
                    ("**Cancel**", "Stops the fit. It appears next to the progress bar at the bottom. The levels finished so far are kept."),
                ]),
                .heading("Settings for every fit"),
                .terms([
                    (
                        "**Shapes**",
                        "The number of shapes on the last level, from \(FitModel.shapeChoices.first!) to \(FitModel.shapeChoices.last!). In tile mode it reads **Tiles**. More shapes give a closer picture, more levels and a longer fit."
                    ),
                    (
                        "**Size**",
                        "The long side of the copy of the photo that is fitted, from \(FitModel.sizeChoices.first!) to \(FitModel.sizeChoices.last!) pixels. A larger size shows the fit finer detail and takes longer. It does not change the size of the exported picture, which is always the photo's."
                    ),
                    (
                        "**Min width**",
                        "Keeps shapes from becoming slivers and spikes. For curves, the value is the narrowest a shape may be on the last level; earlier, larger shapes must be wider. For tiles, no cut may leave a piece thinner than this. **Off** sets no limit."
                    ),
                    (
                        "**Gradients**",
                        "Fills each shape or tile with a gradient between two colours instead of one flat colour. Smooth areas such as sky come closer to the photo. The fit takes longer, and each gradient adds 11 bytes to the size."
                    ),
                    (
                        "**Steps**",
                        "How many times the shapes are adjusted in each stage, from \(FitModel.stepsRange.lowerBound) to \(FitModel.stepsRange.upperBound). More steps give a somewhat closer fit and take proportionally longer."
                    ),
                ]),
                .heading("Results are kept side by side"),
                .text(
                    "Each combination of **Kind**, **Cuts** and **Levels** keeps its own result. Switching one of them shows the result fitted with that combination, or the photo if there is none yet, so you can fit several and compare them. The other settings apply to the next fit only."
                ),
            ]),
        Section(
            title: "Curves and tiles",
            blocks: [
                .text("**Kind** chooses what the picture is built from."),
                .terms([
                    (
                        "**Curves**",
                        "Closed curved shapes, painted one over another on a background colour. A new shape is placed where the picture is most wrong. Shapes may overlap, and the background may show between them."
                    ),
                    (
                        "**Tiles**",
                        "Straight-edged pieces that share their edges, so every point of the picture belongs to exactly one tile. The picture starts as one tile and is cut with straight lines again and again. Then the corners are moved to fit the photo."
                    ),
                ]),
                .heading("Cuts, for tiles"),
                .text("**Cuts** chooses which tiles are cut at each stage. The ⓘ button next to it shows this in short."),
                .terms([
                    (
                        "**Strict tree**",
                        "Every tile is cut in two at every stage, so the number of tiles doubles from level to level: 1, 2, 4, 8 and so on. Every part of the picture is divided equally often."
                    ),
                    (
                        "**Worst first**",
                        "Only the tiles that a cut improves most are cut. Detailed parts of the picture get many small tiles and plain parts keep a few large ones. This usually gives a better picture for the same number of tiles."
                    ),
                ]),
            ]),
        Section(
            title: "Levels",
            blocks: [
                .text(
                    "Level 0 is the background colour alone. Each later level has more shapes, up to the number you chose. **Levels** chooses how the levels relate to one another."
                ),
                .terms([
                    (
                        "**Re-fit**",
                        "At every stage all shapes are adjusted again, the earlier ones too. Each level is the best picture found with that many shapes, but a shape differs from level to level. For tiles, all corners keep moving, so a tile has a different outline on every level."
                    ),
                    (
                        "**Prefix**",
                        "A shape is fixed once its stage ends, so each level is exactly the first shapes of the next, and one list of shapes holds every level. For tiles, a tile's outline is fixed once it has been cut, so each level's tiles are made up exactly of the next level's. The fit is somewhat worse at the same number of shapes."
                    ),
                ]),
                .heading("Moving through the levels"),
                .terms([
                    (
                        "**Level**",
                        "The slider steps through the levels; the left and right arrow keys do the same from anywhere in the window. The number next to it is the level shown and the last level."
                    ),
                    (
                        "The line below the sliders",
                        "The number of shapes on the level shown, an estimate of its size in bytes, and how that compares with the photo's file."
                    ),
                    ("**Hold: original**", "Shows the photo for as long as you hold the mouse button down on it."),
                ]),
                .text(
                    "With a refined shape or tile selected, the slider reads *Level in selection* and steps through the levels of that refinement instead."
                ),
            ]),
        Section(
            title: "Folds, for curves",
            blocks: [
                .text(
                    "A curved shape that follows the photo closely can end up crossing over itself: a loop, or a thin tail whose two sides have swapped. These three settings control that. They do not apply to tiles, which never cross themselves."
                ),
                .terms([
                    (
                        "**Limit folds**",
                        "On, shapes are held to what **Folds** and **Strength** say. Off, nothing is checked: the fit is a little closer and takes about a third less time, and most shapes end up crossing themselves somewhere."
                    ),
                    (
                        "**Folds**",
                        "How far a shape may fold over itself. At *None*, no outline crosses itself at all. At *Any*, nothing is checked. In between, a shape may fold up to that share of a full bow-tie. A thin tail that crosses itself counts as a very small fold, so every setting above *None* lets such tails through."
                    ),
                    (
                        "**Strength**",
                        "How firmly shapes are held to the **Folds** setting. With **Folds** at *None* no outline can cross itself whatever this is; it only sets how much shapes that curl round something are discouraged. With **Folds** higher, it is what keeps shapes from folding further than allowed. Higher values follow the photo less closely."
                    ),
                ]),
                .text("If you want clean outlines, leave **Limit folds** on and **Folds** at *None*. If you only care how the picture looks, switch **Limit folds** off."),
            ]),
        Section(
            title: "Selecting",
            blocks: [
                .text("A selection says which part of the picture **Refine selection** and the **Level** slider act on. The rest of the picture is dimmed. The top row shows what is selected; *Whole picture* means nothing is."),
                .terms([
                    ("Click", "Selects the shape or tile under the pointer. For curves, a click where the background shows between shapes selects that gap."),
                    ("Shift-click", "Adds one to the selection, or takes it out."),
                    ("Esc, or a click outside the picture", "Selects the whole picture again."),
                    (
                        "**Parent**",
                        "With one tile selected, selects the tile it was cut from. With one shape selected that was fitted inside another by refining, selects that outer shape."
                    ),
                ]),
                .text(
                    "In tile mode a selection stays as you move through the levels. On a later level it is shown as the group of pieces the tile has been cut into; on an earlier level it falls back to the tile that contains it."
                ),
            ]),
        Section(
            title: "Refining",
            blocks: [
                .text(
                    "Refining adds detail to one part of the picture without fitting everything again. The fit is zoomed into that part of the photo, so it sees finer detail there than the first fit did."
                ),
                .steps([
                    "Select one or more shapes, gaps or tiles.",
                    "Set **Shapes**, **Steps** and the other settings for the refinement. They are used as for a whole fit, but inside each selected area.",
                    "Press **Refine selection**. Several selected areas are refined side by side.",
                ]),
                .heading("Curves"),
                .text(
                    "Finer shapes are fitted inside each selected shape or gap and painted over it. A refined area is *locked*: it stays as refined, on top, on every later level. A shape inside a refined area can be refined in turn."
                ),
                .terms([
                    (
                        "**Depth**",
                        "How many layers of refinement are drawn, across the whole picture. At 0 only the first fit is shown; each step up adds the shapes fitted inside the layer before."
                    )
                ]),
                .heading("Tiles"),
                .text(
                    "Each selected tile is cut further and the finer tiles take its place. A selected group of pieces is refined as one area. With **Prefix** levels a refined tile has the same outline on later levels, so it stays there too, locked. With **Re-fit** levels a tile has another outline on every level, so the refined tile shows only on the level it was refined on."
                ),
                .heading("The Refined areas panel"),
                .text(
                    "**Refined areas** lists what you have refined, by level. Click a name to go to that area. Click the lock next to one to unlock it, so that it is no longer kept on later levels, or to lock it again."
                ),
            ]),
        Section(
            title: "Exporting",
            blocks: [
                .text(
                    "**Export SVG…** writes the level on screen as an SVG file, at the photo's size in pixels, with refined areas as they are shown. An SVG is a vector picture: it stays sharp at any size and opens in browsers and drawing programs."
                ),
                .text(
                    "Tiles are written with a thin outline in their own colour, so that no hairline of another colour shows between neighbours."
                ),
                .text(
                    "The size shown in the window is an estimate of how small the level could be stored in a compact form. The SVG file itself is larger, because SVG is written as text."
                ),
            ]),
        Section(
            title: "Keys",
            blocks: [
                .terms([
                    ("Return", "**Start** a fit. It does nothing while one is running."),
                    ("Left and right arrows", "One level back or forward."),
                    ("Esc", "Select the whole picture again."),
                    ("Shift-click", "Add to the selection, or take out of it."),
                    ("⌘?", "Open this guide."),
                ])
            ]),
        Section(
            title: "Getting a better picture",
            blocks: [
                .terms([
                    ("The picture is too coarse everywhere", "Raise **Shapes**. Raising **Size** as well lets the fit see finer detail."),
                    ("One part needs more detail", "Select it and use **Refine selection**, rather than fitting everything with more shapes."),
                    ("Sky and other smooth areas look banded", "Switch **Gradients** on."),
                    ("Shapes have thin spikes or slivers", "Raise **Min width**."),
                    ("Shapes loop or cross themselves", "Switch **Limit folds** on and set **Folds** to *None*."),
                    ("Fitting takes too long", "Lower **Size** or **Steps**, switch **Gradients** off, or, for curves, switch **Limit folds** off."),
                    ("You want the smallest result that still looks right", "Fit once, then step down with the **Level** slider until the picture stops being good enough, and export the level before that."),
                ])
            ]),
    ]
}

public struct UserGuideView: View {
    @State private var shown: UserGuide.Section? = UserGuide.sections.first

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(UserGuide.sections, selection: $shown) { section in
                Text(section.title).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            ScrollView {
                if let shown {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(shown.title).font(.title).bold()
                        ForEach(Array(shown.blocks.enumerated()), id: \.offset) { _, block in
                            view(for: block)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(shown.id)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private func marked(_ text: String) -> Text { Text(.init(text)) }

    @ViewBuilder private func view(for block: UserGuide.Block) -> some View {
        switch block {
        case .text(let text):
            marked(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            Text(text).font(.title3).bold().padding(.top, 8)
        case .steps(let steps):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        marked(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .terms(let terms):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                    VStack(alignment: .leading, spacing: 2) {
                        marked(term.name).fontWeight(.semibold)
                        marked(term.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
