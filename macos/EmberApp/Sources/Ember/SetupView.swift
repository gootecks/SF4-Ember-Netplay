import AppKit
import EmberAppCore
import SwiftUI

struct SetupView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Ember").font(.title.bold())
            Text("Ember runs Ultra Street Fighter IV in its own Windows environment. Each step is safe to repeat.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SetupStep.allCases) { step in
                    StepRow(model: model, step: step)
                }
            }
            if !model.progress.isEmpty {
                Text(model.progress)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                if model.setupRunning {
                    Button("Cancel") { model.cancelSetup() }
                } else {
                    Button("Start Setup") { model.runSetup() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct StepRow: View {
    let model: AppModel
    let step: SetupStep

    private var state: StepState { model.steps[step] ?? .pending }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.headline)
                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                actions
            }
            Spacer()
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsInput: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var actions: some View {
        switch (step, state) {
        case (.game, .needsInput), (.game, .failed):
            HStack {
                Button("I already have it") { chooseLibrary() }
                Button("Install with Steam") { model.chooseGame(.install) }
            }
        case (.rosetta, .failed):
            HStack {
                Button("Install Rosetta") { model.installRosetta() }
                Button("Retry") { model.runSetup() }
            }
        case (_, .failed):
            Button("Retry") { model.runSetup() }
        default:
            EmptyView()
        }
    }

    @MainActor
    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that contains SteamLibrary"
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseGame(.existing(url))
    }
}
