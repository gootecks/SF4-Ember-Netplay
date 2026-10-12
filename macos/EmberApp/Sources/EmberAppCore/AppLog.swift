import Foundation

public final class AppLog: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(directory: URL, name: String = "ember-app.log") {
        file = directory.appending(path: name)
    }

    public func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
