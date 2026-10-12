import EmberAppCore
import SwiftUI

@main
struct EmberMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Ember", id: "main") {
            ContentView(model: Shared.model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: Shared.model)
        }
    }
}
