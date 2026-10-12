import EmberKit
import Foundation

extension AppModel {
    public func dismissNotice() {
        notice = nil
    }

    public func play() async {
        guard phase == .ready, busy == nil else { return }
        busy = .playing
        notice = nil
        defer {
            busy = nil
            progress = ""
        }
        let log = sink()
        do {
            if try await backend.ensureSteam(log: log) { startedSteam = true }
            let summary = try await backend.launchGame(hud: settings.hud, log: log)
            record("play: \(summary)")
            notice = Notice(summary)
        } catch {
            record("play failed: \(error.localizedDescription)")
            notice = Notice(error.localizedDescription, isError: true)
        }
        await refreshStatus()
    }

    public func updateEmber() async {
        guard phase == .ready, busy == nil else { return }
        busy = .updating
        notice = nil
        defer {
            busy = nil
            progress = ""
        }
        do {
            let summary = try await backend.updateEmber(policy: settings.policy, log: sink())
            record("update: \(summary)")
            notice = Notice(summary)
        } catch {
            record("update failed: \(error.localizedDescription)")
            notice = Notice(error.localizedDescription, isError: true)
        }
        await refreshStatus()
        await refreshLatest()
    }

    public func createDiagnostics(into directory: URL) async -> URL? {
        guard busy == nil else { return nil }
        busy = .diagnostics
        notice = nil
        defer { busy = nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let destination = directory.appending(path: "ember-diagnostics-\(stamp).zip")
        do {
            let url = try await backend.createDiagnostics(at: destination)
            record("diagnostics written: \(url.lastPathComponent)")
            notice = Notice("Diagnostics saved to \(url.path)")
            return url
        } catch {
            record("diagnostics failed: \(error.localizedDescription)")
            notice = Notice(error.localizedDescription, isError: true)
            return nil
        }
    }

    public func gameRunningNow() async -> Bool {
        await backend.isGameRunning()
    }

    public func shutdown() async {
        stopPolling()
        setupTask?.cancel()
        await setupTask?.value
        let killPrefix = startedSteam
        record(killPrefix ? "quit: stopping the prefix (app started Steam)" : "quit: stopping Ember processes only")
        await backend.shutdown(killPrefix: killPrefix, log: sink())
        startedSteam = false
    }
}
