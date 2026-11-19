import AppKit
import LayerFitCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @State private var model: FitModel
    @State private var original: CGImage?
    @State private var holdingOriginal = false
    @State private var importing = false

    private let initialPhoto: URL?

    /// `initialPhoto` is opened as soon as the window appears.
    @MainActor
    public init(model: FitModel? = nil, initialPhoto: URL? = nil) {
        _model = State(initialValue: model ?? FitModel())
        self.initialPhoto = initialPhoto
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            pictureArea
            Divider()
            levelBar
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(.windowBackground)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.open(url) }
        }
        .alert(
            "LayerFit", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onOpenURL { model.open($0) }
        .onAppear { if let initialPhoto { model.open(initialPhoto) } }
        .onChange(of: model.photoURL, initial: true) { _, url in
            original = url.flatMap { loadPreview(url: $0, maxPixelSize: 2048) }
        }
    }

    // MARK: Top

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button("Open…") { importing = true }
                Picker("Shapes", selection: $model.settings.totalShapes) {
                    ForEach(FitModel.shapeChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Picker("Size", selection: $model.settings.workingSize) {
                    ForEach(FitModel.sizeChoices, id: \.self) { Text("\($0) px").tag($0) }
                }
                .fixedSize()
                Picker("Min width", selection: $model.settings.minWidth) {
                    ForEach(FitModel.minWidthChoices, id: \.self) { width in
                        Text(width == 0 ? "Off" : "\(Int(width)) px").tag(width)
                    }
                }
                .fixedSize()
                .help(
                    "Keeps shapes from thinning into slivers and spikes. The value is the narrowest allowed at the last level; earlier shapes must be wider."
                )
                LabeledContent("Steps") {
                    TextField("Steps", value: $model.settings.stepsPerStage, format: .number)
                        .labelsHidden()
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                }
                .fixedSize()
                .help("Optimisation steps per stage, \(FitModel.stepsRange.lowerBound) to \(FitModel.stepsRange.upperBound)")
                Spacer()
            }
            .disabled(model.isFitting)
            HStack(spacing: 16) {
                Picker("Levels", selection: $model.settings.mode) {
                    Text("Re-fit").tag(LevelMode.refit)
                    Text("Prefix").tag(LevelMode.prefix)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(
                    "Re-fit: every level is re-optimised as a whole. Prefix: each level is exactly the first shapes of the next."
                )
                .disabled(model.isRefining)
                Toggle(
                    "Carry refinements",
                    isOn: Binding(
                        get: { model.settings.mode == .prefix || model.carryRefinements },
                        set: { model.carryRefinements = $0 })
                )
                .toggleStyle(.checkbox)
                .disabled(model.settings.mode == .prefix || model.isRefining)
                .help(
                    "Show a refinement on every level, not only the one it was made on. Prefix always does this, exactly, because a shape is the same on every level. In Re-fit the shapes move between levels, so a carried refinement goes on the shape with the same number and may not line up."
                )
                Divider().frame(height: 16)
                Text(model.selectionLabel)
                    .foregroundStyle(model.selection == nil ? .secondary : .primary)
                    .help("Click a shape in the picture to select it; click outside the picture or press Esc to select the whole picture again.")
                Button("Parent") { model.selectParent() }
                    .disabled(model.selection == nil || model.isFitting)
                    .help("Select the shape this one was fitted inside")
                Spacer()
                Button("Refine selection") { model.refine() }
                    .disabled(!model.canRefine)
                    .help(
                        "Fit finer shapes only inside the selected shape, zoomed into that part of the photo, using the settings above"
                    )
                // Return starts a fit, but must not restart one that is already running.
                Button(model.isFitting ? "Restart" : "Start") { model.start() }
                    .keyboardShortcut(model.isFitting ? nil : .defaultAction)
                    .disabled(model.photoURL == nil || model.isRefining)
            }
        }
        .padding(12)
    }

    // MARK: Middle

    private var pictureArea: some View {
        ZStack {
            PictureView(
                picture: model.shownPicture, original: original,
                showsOriginal: holdingOriginal || (model.shownPicture == nil && original != nil),
                maxDepth: model.shownDepth, selectedShape: model.selectedShape,
                backgroundSelected: model.selection?.isBackground ?? false,
                onClick: { model.select(at: $0) })
            if model.photoURL == nil {
                Text("Drop a photo here")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom

    private var stopLabel: String {
        guard !model.levels.isEmpty else { return "" }
        // While the whole picture is being fitted, count against the stages still to come.
        if model.selection == nil, !model.isRefining, case .fitting(_, let stageCount) = model.status {
            return "\(model.sliderStop) of \(stageCount)"
        }
        return "\(model.sliderStop) of \(model.sliderLast)"
    }

    private var levelBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(model.selection == nil ? "Level" : "Level in selection")
                    .frame(minWidth: 116, alignment: .leading)
                    .help("Steps through the levels of the selected shape, or of the whole picture when nothing is selected")
                Slider(
                    value: Binding(
                        get: { Double(model.sliderStop) },
                        set: { model.userMovedSlider(to: Int($0.rounded())) }),
                    in: 0...Double(max(model.sliderLast, 1)), step: 1
                )
                .disabled(model.sliderLast < 1 || model.isRefining)
                Text(stopLabel)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text("Depth")
                    .frame(minWidth: 116, alignment: .leading)
                    .help("How many layers of refinement inside shapes are shown, across the whole picture")
                Slider(
                    value: Binding(
                        get: { Double(model.shownDepth) },
                        set: { model.setDepth(Int($0.rounded())) }),
                    in: 0...Double(max(model.maxDepth, 1)), step: 1
                )
                .disabled(model.maxDepth < 1 || model.isRefining)
                Text(model.levels.isEmpty ? "" : "\(model.shownDepth) of \(model.maxDepth)")
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text(model.caption.isEmpty ? " " : model.caption)
                    .monospacedDigit()
                Spacer()
                Text("Hold: original")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        holdingOriginal ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .opacity(original == nil ? 0.4 : 1)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in holdingOriginal = original != nil }
                            .onEnded { _ in holdingOriginal = false })
                    .help("Press and hold to compare with the original photo")
            }
            HStack(spacing: 12) {
                statusView
                Spacer()
                Button("Export SVG…") { exportSVG() }
                    .disabled(model.levels.isEmpty)
            }
        }
        .padding(12)
        .background {
            // Left and right arrows step through the levels from anywhere in the window.
            Group {
                Button("") { model.userMovedSlider(to: model.sliderStop - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(model.sliderLast < 1)
                Button("") { model.userMovedSlider(to: model.sliderStop + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(model.sliderLast < 1)
                // Esc goes back to the whole picture.
                Button("") { model.select(at: nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.selection == nil)
            }
            .opacity(0)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle:
            Text(model.photoURL == nil ? " " : "Ready").foregroundStyle(.secondary)
        case .fitting(let stage, let stageCount):
            Text("\(model.isRefining ? "Refining" : "Fitting") stage \(max(stage, 1)) of \(stageCount)")
            ProgressView(value: Double(stage), total: Double(max(stageCount, 1)))
                .frame(width: 160)
            Button("Cancel") { model.cancel() }
        case .done:
            Text("Done").foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled").foregroundStyle(.secondary)
        }
    }

    private func exportSVG() {
        guard let level = model.shownLevel else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        let base = model.photoURL?.deletingPathExtension().lastPathComponent ?? "picture"
        panel.nameFieldStringValue = "\(base)-\(level.picture.shapes.count)-shapes.svg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportSVG(to: url)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
