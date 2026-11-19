#if DEBUG
    import AppKit
    import LayerFitCore
    import LayerFitUI

    /// Debug builds only. When LAYERFIT_SMOKE_DIR and LAYERFIT_SMOKE_PHOTO are set, drives
    /// the real window through a fit and writes snapshots of it and a log to that folder,
    /// then quits. For checking the app where the screen cannot be captured from outside.
    @MainActor
    enum SmokeDriver {
        static func runIfRequested(_ model: FitModel) async {
            let environment = ProcessInfo.processInfo.environment
            guard let directory = environment["LAYERFIT_SMOKE_DIR"],
                let photo = environment["LAYERFIT_SMOKE_PHOTO"]
            else { return }
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var log: [String] = []
            func note(_ text: String) {
                log.append(text)
                try? log.joined(separator: "\n").write(
                    to: folder.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
            }
            func snapshot(_ name: String) {
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { return note("\(name): no window") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent(name + ".png"))
                note(
                    "\(name): status=\(model.status) stop=\(model.shownStop)/\(model.levels.count - 1) "
                        + "mode=\(model.settings.mode.rawValue) caption=[\(model.caption)]")
            }
            func pause(_ seconds: Double) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            }
            /// Waits for the condition; also records the longest the main thread went
            /// without getting a turn, as a measure of how responsive the window stayed.
            func wait(_ what: String, timeout: Double = 600, until done: () -> Bool) async {
                let start = Date()
                var last = Date()
                var longestStall = 0.0
                while !done() {
                    if Date().timeIntervalSince(start) > timeout { return note("TIMEOUT \(what)") }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    longestStall = max(longestStall, Date().timeIntervalSince(last) - 0.010)
                    last = Date()
                }
                note(String(
                    format: "%@ after %.1f s, longest main-thread stall %.0f ms", what,
                    Date().timeIntervalSince(start), longestStall * 1000))
            }

            await pause(1)
            snapshot("1-empty")

            model.open(URL(fileURLWithPath: photo))
            await pause(0.5)
            snapshot("2-opened")

            model.settings.totalShapes = 32
            model.start()
            await wait("refit: 4 levels") { model.levels.count >= 4 }
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                var frame = window.frame
                frame.size.width += 160
                frame.size.height += 60
                window.setFrame(frame, display: true, animate: false)
            }
            await pause(0.3)
            snapshot("3-fitting-resized")
            await wait("refit: done") { model.status == .done }
            snapshot("4-refit-last")
            model.userMovedSlider(to: 0)
            await pause(0.2)
            snapshot("5-refit-first")
            model.userMovedSlider(to: model.levels.count / 2)
            await pause(0.2)
            snapshot("6-refit-middle")

            model.settings.mode = .prefix
            model.start()
            await wait("prefix: stage 4 running") {
                if case .fitting(let stage, _) = model.status { return stage >= 4 }
                return false
            }
            model.cancel()
            await wait("prefix: cancelled") { model.status == .cancelled }
            snapshot("7-prefix-cancelled")

            model.start()
            await wait("prefix: done") { model.status == .done }
            model.userMovedSlider(to: model.levels.count / 2)
            await pause(0.2)
            snapshot("8-prefix-middle")
            model.settings.mode = .refit
            await pause(0.2)
            snapshot("9-toggled-to-refit")

            // Select a gap between shapes and refine inside it.
            model.userMovedSlider(to: 6)
            await pause(0.2)
            if let picture = model.shownPicture {
                note("level 6 has \(picture.gaps.count) gaps, \(picture.shapes.count) shapes")
                search: for y in stride(from: 4, to: picture.height, by: 8) {
                    for x in stride(from: 4, to: picture.width, by: 8) {
                        let point = SIMD2(Float(x), Float(y))
                        if picture.hitTest(point)?.isBackground == true {
                            model.select(at: point)
                            break search
                        }
                    }
                }
            }
            await pause(0.2)
            snapshot("8a-gap-selected")
            note("selected: \(model.selectionLabel), canRefine=\(model.canRefine)")
            model.settings.totalShapes = 32
            model.refine()
            await wait("gap refine: done") { !model.isFitting }
            snapshot("8b-gap-refined")
            note("after gap refine: status=\(model.status) slider=\(model.sliderStop)/\(model.sliderLast) depth=\(model.shownDepth)/\(model.maxDepth) error=\(model.errorMessage ?? "nil")")
            model.select(at: nil)

            // Refine inside one shape of the Re-fit result, then scrub and hide it.
            model.userMovedSlider(to: 4)
            await pause(0.2)
            if let picture = model.shownPicture {
                model.select(at: SIMD2(Float(picture.width) * 0.5, Float(picture.height) * 0.8))
            }
            await pause(0.2)
            snapshot("9a-selected")
            note("selected: \(model.selectionLabel), canRefine=\(model.canRefine)")
            model.settings.totalShapes = 32
            model.refine()
            await wait("refine: done") { !model.isRefining && model.status != .fitting(stage: 0, stageCount: 10) && !model.isFitting }
            snapshot("9b-refined")
            note("after refine: status=\(model.status) slider=\(model.sliderStop)/\(model.sliderLast) depth=\(model.shownDepth)/\(model.maxDepth) error=\(model.errorMessage ?? "nil")")
            model.userMovedSlider(to: max(model.sliderLast / 2, 1))
            await pause(0.2)
            snapshot("9c-refined-middle")
            model.setDepth(0)
            await pause(0.2)
            snapshot("9d-depth-0")
            model.setDepth(1)
            model.select(at: nil)
            await pause(0.2)
            snapshot("9e-whole-picture")

            do {
                try model.exportSVG(to: folder.appendingPathComponent("export.svg"))
                note("exported level \(model.shownStop) of refit")
            } catch {
                note("export failed: \(error.localizedDescription)")
            }

            model.open(URL(fileURLWithPath: "/nonexistent/photo.jpg"))
            await pause(0.5)
            snapshot("10-error")
            note("errorMessage=\(model.errorMessage ?? "nil")")
            note("finished")
            NSApp.terminate(nil)
        }
    }
#endif
