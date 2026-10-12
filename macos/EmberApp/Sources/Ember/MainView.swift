import AppKit
import EmberAppCore
import EmberKit
import SwiftUI

struct MainView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Text("Ember").font(.largeTitle.bold())
            statusGrid
            Button(action: { Task { await model.play() } }) {
                Text(model.busy == .playing ? "Starting…" : "Play")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy != nil)
            .keyboardShortcut(.defaultAction)
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.progress.isEmpty ? busy.label : model.progress)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let notice = model.notice {
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(notice.isError ? .red : .secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("Update Ember") { Task { await model.updateEmber() } }
                Button("Diagnostics") { Task { await collectDiagnostics() } }
                Button("Open Logs Folder") { openLogs() }
                SettingsLink { Text("Settings…") }
            }
            .disabled(model.busy != nil)
        }
        .padding(24)
        .frame(width: 520)
    }

    private var statusGrid: some View {
        let status = model.status
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Engine", status.engineInstalled ? "Installed" : "Missing", ok: status.engineInstalled)
            row("Prefix", status.prefixBuilt ? "Built" : "Missing", ok: status.prefixBuilt)
            row("Steam", status.steam.label, ok: status.steam == .loggedOn)
            row("Ember", emberText(status), ok: status.emberInstalled != nil)
            row("Game", status.gameRunning ? "Running" : "Not running", ok: status.gameRunning)
            row("Helper (sf4-net.exe)", status.helperRunning ? "Running" : "Not running", ok: status.helperRunning)
        }
    }

    private func emberText(_ status: StatusSnapshot) -> String {
        let installed = status.emberInstalled.map { "Installed \($0)" } ?? "Not installed"
        guard let latest = model.latestEmber else { return installed }
        if let current = status.emberInstalled, EmberVersion.isNewer(latest, than: current) {
            return "\(installed), latest \(latest) (update available)"
        }
        return "\(installed), latest \(latest)"
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
                Circle().fill(ok ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                Text(value)
            }
        }
    }

    @MainActor
    private func collectDiagnostics() async {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let directory = desktop ?? model.backend.logsDirectory
        guard let url = await model.createDiagnostics(into: directory) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    private func openLogs() {
        let logs = model.backend.logsDirectory
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }
}
