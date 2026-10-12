import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    private init(tool: String, arguments: [String], environment: [String: String]?, directory: URL?) {
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
    }

    public static func run(
        _ tool: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let runner = ProcessRunner(tool: tool, arguments: arguments, environment: environment, directory: currentDirectory)
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appending(path: "ember-\(UUID().uuidString).out")
        let errURL = tmp.appending(path: "ember-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        runner.process.standardOutput = outHandle
        runner.process.standardError = errHandle
        runner.process.standardInput = FileHandle.nullDevice
        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await runner.launchAndWait(tool: tool)
            } onCancel: {
                runner.terminate()
            }
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            throw error
        }
        try? outHandle.close()
        try? errHandle.close()
        try Task.checkCancellation()
        return ProcessResult(
            status: status,
            stdout: String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self),
            stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        )
    }

    public static func runChecked(
        _ tool: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let result = try await run(tool, arguments, environment: environment, currentDirectory: currentDirectory)
        guard result.succeeded else {
            throw EmberError.toolFailed(
                tool: URL(filePath: tool).lastPathComponent,
                status: result.status,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    @discardableResult
    public static func spawnDetached(
        _ tool: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        logFile: URL
    ) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logFile)
        defer { try? log.close() }
        try log.seekToEnd()
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            throw EmberError.launchFailed(tool: tool, reason: error.localizedDescription)
        }
        return process.processIdentifier
    }

    private func launchAndWait(tool: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: EmberError.launchFailed(tool: tool, reason: error.localizedDescription))
            }
        }
    }

    private func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}
