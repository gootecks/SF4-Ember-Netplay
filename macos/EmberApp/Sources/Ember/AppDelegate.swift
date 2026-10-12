import AppKit
import EmberAppCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var existingInstance: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        existingInstance = SingleInstance.other()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let existingInstance else { return }
        existingInstance.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let existingInstance, let target = existingInstance.bundleURL {
            NSWorkspace.shared.open(urls, withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        Task { @MainActor in
            NSApp.activate()
            for url in urls where await Shared.model.handle(link: url) == .refused {
                Self.showRefusedLink()
            }
        }
    }

    @MainActor
    private static func showRefusedLink() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Ember cannot open this link"
        alert.informativeText = "Only Ember join, tournament, room and Discord connect links are supported."
        alert.runModal()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard existingInstance == nil else { return .terminateNow }
        Task { @MainActor in
            let model = Shared.model
            if await model.gameRunningNow(), !Self.confirmQuitWithGameRunning() {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    private static func confirmQuitWithGameRunning() -> Bool {
        let alert = NSAlert()
        alert.messageText = "The game is still running"
        alert.informativeText = "Quitting Ember ends the game and its netplay helper."
        alert.addButton(withTitle: "Quit and End Game")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
