import Foundation

final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
