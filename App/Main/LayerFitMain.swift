import LayerFitUI
import SwiftUI

@main
struct LayerFitMain: App {
    @State private var model = FitModel()

    /// A photo path given on the command line is opened at launch.
    private var initialPhoto: URL? {
        CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
    }

    var body: some Scene {
        Window("LayerFit", id: "main") {
            ContentView(model: model, initialPhoto: initialPhoto)
                #if DEBUG
                    .task { await SmokeDriver.runIfRequested(model) }
                #endif
        }
    }
}
