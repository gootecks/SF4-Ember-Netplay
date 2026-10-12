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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
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
