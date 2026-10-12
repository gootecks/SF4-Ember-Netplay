import Foundation

struct ComponentInstaller {
    let downloader: Downloader
    let log: @Sendable (String) -> Void
    private var extracted: [String: URL] = [:]
    private var extractionDirs: [URL] = []

    init(downloader: Downloader, log: @escaping @Sendable (String) -> Void) {
        self.downloader = downloader
        self.log = log
    }

    mutating func install(_ component: EngineManifest.Component, scope: String, base: URL) async throws {
        let prefix = scope + ":"
        var steps: [(from: String, rel: String)] = []
        for step in component.install ?? [] {
            guard step.to.hasPrefix("engine:") || step.to.hasPrefix("prefix:") else {
                throw EmberError.invalidInstallTarget(step.to)
            }
            guard step.to.hasPrefix(prefix) else { continue }
            let rel = String(step.to.dropFirst(prefix.count))
            if "/\(step.from)/\(rel)/".contains("/../") {
                throw EmberError.pathTraversal(from: step.from, to: step.to)
            }
            steps.append((step.from, rel))
        }
        guard !steps.isEmpty else { return }
        guard let url = URL(string: component.url) else {
            throw EmberError.downloadFailed(url: component.url, reason: "invalid URL")
        }
        log("component \(component.name) (\(scope))")
        let archive = try await downloader.fetch(url: url, sha256: component.sha256)
        let root = try await extractedRoot(sha: component.sha256.lowercased(), format: component.format, archive: archive)
        for step in steps {
            let src = (step.from.isEmpty || step.from == ".") ? root : root.appending(path: step.from)
            try await copyItem(from: src, to: base.appending(path: step.rel), root: root)
        }
    }

    func cleanup() {
        for dir in extractionDirs { try? FileManager.default.removeItem(at: dir) }
    }

    private mutating func extractedRoot(sha: String, format: String, archive: URL) async throws -> URL {
        if let dir = extracted[sha] { return dir }
        let dir = downloader.cacheDir.appending(path: "extract.\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        extractionDirs.append(dir)
        switch format {
        case "tar.xz":
            try await ProcessRunner.runChecked("/usr/bin/tar", ["-xJf", archive.path, "-C", dir.path])
        case "tar.gz", "tgz":
            try await ProcessRunner.runChecked("/usr/bin/tar", ["-xzf", archive.path, "-C", dir.path])
        case "zip":
            try await ProcessRunner.runChecked("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path])
        default:
            throw EmberError.unsupportedArchiveFormat(format)
        }
        extracted[sha] = dir
        return dir
    }

    private func copyItem(from src: URL, to dst: URL, root: URL) async throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: src.path) else {
            throw EmberError.installSourceMissing(String(src.path.dropFirst(root.path.count)))
        }
        if attrs[.type] as? FileAttributeType == .typeDirectory {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try await ProcessRunner.runChecked("/bin/cp", ["-Rpf", src.path + "/.", dst.path + "/"])
        } else {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: dst.path)) != nil { try fm.removeItem(at: dst) }
            try await ProcessRunner.runChecked("/bin/cp", ["-Rpf", src.path, dst.path])
        }
    }
}
