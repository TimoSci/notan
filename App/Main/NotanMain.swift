import NotanUI
import SwiftUI

@main
struct NotanMain: App {
    @State private var model = FitModel()

    /// A photo path given on the command line is opened at launch.
    private var initialPhoto: URL? { initialPhotoURL(arguments: CommandLine.arguments) }

    var body: some Scene {
        Window("Notan", id: "main") {
            ContentView(model: model, initialPhoto: initialPhoto)
                #if DEBUG
                    .task { await SmokeDriver.runIfRequested(model) }
                #endif
        }
    }
}
