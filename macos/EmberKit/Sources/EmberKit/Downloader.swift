import CryptoKit
import Foundation

public struct Downloader: Sendable {
    public let cacheDir: URL
    public let cacheFrom: URL?
    public let session: URLSession
    public let log: @Sendable (String) -> Void

    public init(
        cacheDir: URL,
        cacheFrom: URL? = nil,
        session: URLSession = .shared,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.cacheDir = cacheDir
        self.cacheFrom = cacheFrom
        self.session = session
        self.log = log
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func fetch(url: URL, sha256: String, fileName: String? = nil) async throws -> URL {
        let want = sha256.lowercased()
        let name = fileName ?? url.lastPathComponent
        guard want.count == 64, want.allSatisfy(\.isHexDigit) else {
            throw EmberError.invalidChecksum(name: name)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dest = cacheDir.appending(path: name)
        let part = cacheDir.appending(path: name + ".part")

        if fm.fileExists(atPath: dest.path) {
            if try Self.sha256(of: dest) == want {
                log("cache hit: \(name)")
                return dest
            }
            log("cached \(name) has wrong SHA-256; refetching")
            try fm.removeItem(at: dest)
        }

        if let cacheFrom {
            let candidate = cacheFrom.appending(path: name)
            if fm.fileExists(atPath: candidate.path) {
                let got = try Self.sha256(of: candidate)
                if got == want {
                    log("copying \(name) from \(cacheFrom.path) (SHA matches)")
                    try? fm.removeItem(at: part)
                    try fm.copyItem(at: candidate, to: part)
                    try fm.moveItem(at: part, to: dest)
                    return dest
                }
                log("\(candidate.path) has a different SHA-256 (\(got)); downloading instead")
            }
        }

        log("downloading \(url.absoluteString)")
        try await download(url: url, to: part)
        let got = try Self.sha256(of: part)
        guard got == want else {
            try? fm.removeItem(at: part)
            throw EmberError.sha256Mismatch(url: url.absoluteString, expected: want, actual: got)
        }
        try fm.moveItem(at: part, to: dest)
        return dest
    }

    private func download(url: URL, to part: URL) async throws {
        let fm = FileManager.default
        var lastReason = ""
        for attempt in 1...3 {
            do {
                let (tmp, response) = try await session.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? fm.removeItem(at: tmp)
                    throw EmberError.downloadFailed(url: url.absoluteString, reason: "HTTP \(http.statusCode)")
                }
                try? fm.removeItem(at: part)
                try fm.moveItem(at: tmp, to: part)
                return
            } catch let error as EmberError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastReason = error.localizedDescription
                log("download attempt \(attempt) failed: \(lastReason)")
            }
        }
        throw EmberError.downloadFailed(url: url.absoluteString, reason: lastReason)
    }
}
