import AppKit

enum SingleInstance {
    static let bundleIdentifier = "io.github.gootecks.ember"

    static func other() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }
}
