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
        .commands {
            CommandGroup(replacing: .help) { GuideMenuItem() }
        }

        Window("Notan User Guide", id: GuideMenuItem.windowID) {
            UserGuideView()
        }
        .defaultSize(width: 820, height: 620)
        // Not reopened at the next launch, and not opened in place of the main window.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The Help menu's entry, which opens the user guide in its own window.
private struct GuideMenuItem: View {
    static let windowID = "guide"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Notan User Guide") { openWindow(id: Self.windowID) }
            .keyboardShortcut("?", modifiers: .command)
    }
}
