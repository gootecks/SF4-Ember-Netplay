import AppKit
import EmberAppCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Data folder") {
                Text(model.settings.dataRoot.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if model.settings.rootFromEnvironment {
                    Text("Set by the EMBER_ROOT environment variable.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Change…") { chooseFolder() }
                        Button("Use Default") { model.settings.customRoot = nil }
                            .disabled(model.settings.customRoot == nil)
                    }
                }
            }
            Section("Ember version") {
                Picker("Install", selection: $model.settings.policy) {
                    ForEach(VersionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section("Game") {
                Toggle("Show the DXVK performance HUD", isOn: $model.settings.hud)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }

    @MainActor
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where Ember keeps its engine, Wine prefix and logs"
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.customRoot = url
    }
}
