import EmberAppCore
import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .checking:
                ProgressView("Checking setup")
                    .frame(width: 520, height: 200)
            case .setup:
                SetupView(model: model)
            case .ready:
                MainView(model: model)
            }
        }
        .task { await model.start() }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }
}
