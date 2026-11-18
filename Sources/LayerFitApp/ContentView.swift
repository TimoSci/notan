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
                Spacer()
                Button("Start") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.photoURL == nil)
            }
        }
        .padding(12)
    }

    // MARK: Middle

    private var pictureArea: some View {
        ZStack {
            PictureView(
                picture: model.shownPicture, original: original,
                showsOriginal: holdingOriginal || (model.shownPicture == nil && original != nil))
            if model.photoURL == nil {
                Text("Drop a photo here")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom

    private var lastStop: Int { max(model.levels.count - 1, 0) }

    private var stopLabel: String {
        guard !model.levels.isEmpty else { return "" }
        if case .fitting(_, let stageCount) = model.status { return "\(model.shownStop) of \(stageCount)" }
        return "\(model.shownStop) of \(lastStop)"
    }

    private var levelBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Level")
                Slider(
                    value: Binding(
                        get: { Double(model.shownStop) },
                        set: { model.userMovedSlider(to: Int($0.rounded())) }),
                    in: 0...Double(max(lastStop, 1)), step: 1
                )
                .disabled(model.levels.count < 2)
                Text(stopLabel)
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
                Button("") { model.userMovedSlider(to: model.shownStop - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.userMovedSlider(to: model.shownStop + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .disabled(model.levels.count < 2)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle:
            Text(model.photoURL == nil ? " " : "Ready").foregroundStyle(.secondary)
        case .fitting(let stage, let stageCount):
            Text("Fitting stage \(max(stage, 1)) of \(stageCount)")
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
