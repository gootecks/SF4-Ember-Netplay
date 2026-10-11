import Foundation

public struct InstalledEmber: Sendable, Equatable {
    public let version: String
    public let directory: URL

    public var directoryName: String { directory.lastPathComponent }
    public var windowsDirectory: String { "C:\\\(directoryName)" }
    public var launcherWindowsPath: String { "\(windowsDirectory)\\Launcher.exe" }
}

public enum EmberUpdateResult: Sendable, Equatable {
    case upToDate(installed: String, latest: String)
    case installed(version: String, directory: URL)
    case checkFailed(reason: String, installed: String?)
}

public struct EmberPayloadInstaller: Sendable {
    public let paths: EmberPaths
    public let source: any EmberReleaseSource
    public let downloader: Downloader
    public let log: @Sendable (String) -> Void

    public init(
        paths: EmberPaths,
        source: any EmberReleaseSource,
        downloader: Downloader? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.paths = paths
        self.source = source
        self.downloader = downloader ?? Downloader(cacheDir: paths.cacheDir, log: log)
        self.log = log
    }

    public var driveC: URL { paths.prefixDir.appending(path: "drive_c", directoryHint: .isDirectory) }

    public func installDir(version: String) -> URL {
        driveC.appending(path: "sf4e-\(version)", directoryHint: .isDirectory)
    }

    public func installed() -> [InstalledEmber] {
        Self.installed(in: paths.prefixDir)
    }

    public func newestInstalled() -> InstalledEmber? {
        Self.newest(in: paths.prefixDir)
    }

    public static func installed(in prefix: URL) -> [InstalledEmber] {
        let fm = FileManager.default
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let names = (try? fm.contentsOfDirectory(atPath: driveC.path)) ?? []
        var result: [InstalledEmber] = []
        for name in names where name.hasPrefix("sf4e-") && !name.hasSuffix(".tmp") {
            let dir = driveC.appending(path: name, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: dir.appending(path: "Launcher.exe").path) else { continue }
            let fallback = String(name.dropFirst("sf4e-".count))
            result.append(InstalledEmber(version: buildVersion(in: dir) ?? fallback, directory: dir))
        }
        return result.sorted {
            let order = EmberVersion.compare($0.version, $1.version)
            return order == 0 ? $0.directoryName < $1.directoryName : order < 0
        }
    }

    public static func newest(in prefix: URL) -> InstalledEmber? {
        installed(in: prefix).last
    }

    @discardableResult
    public func install(version: String? = nil) async throws -> InstalledEmber {
        let release: EmberRelease
        if let version {
            release = try await source.release(version: version)
        } else {
            release = try await source.latest()
        }
        return try await install(release)
    }

    public func update() async throws -> EmberUpdateResult {
        let current = newestInstalled()?.version
        let release: EmberRelease
        do {
            release = try await source.latest()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("Ember update check failed; using installed \(current ?? "none")")
            return .checkFailed(reason: error.localizedDescription, installed: current)
        }
        if let current, !EmberVersion.isNewer(release.version, than: current) {
            log("Ember \(current) is up to date (latest release: \(release.version))")
            return .upToDate(installed: current, latest: release.version)
        }
        log("Ember \(release.version) available (installed: \(current ?? "none")); installing")
        let result = try await install(release)
        return .installed(version: result.version, directory: result.directory)
    }

    @discardableResult
    public func install(_ release: EmberRelease) async throws -> InstalledEmber {
        let fm = FileManager.default
        guard fm.fileExists(atPath: driveC.path) else {
            throw EmberError.prefixIncomplete(path: paths.prefixDir.path)
        }
        let version = release.version
        guard !version.isEmpty, !version.contains("/"), !version.contains("..") else {
            throw EmberPayloadError.invalidVersion(version)
        }
        let dest = installDir(version: version)
        if fm.fileExists(atPath: dest.appending(path: "Launcher.exe").path) {
            log("Ember \(version) already installed: \(dest.path) (nothing to do)")
            return InstalledEmber(version: version, directory: dest)
        }
        if (try? fm.attributesOfItem(atPath: dest.path)) != nil {
            throw EmberPayloadError.installDirIncomplete(dest.path)
        }
        let archive = try await downloader.fetch(url: release.url, sha256: release.sha256, fileName: release.assetName)

        let staging = driveC.appending(path: "sf4e-\(version).tmp", directoryHint: .isDirectory)
        let unpack = driveC.appending(path: "sf4e-\(version).tmp.x", directoryHint: .isDirectory)
        for dir in [staging, unpack] { try? fm.removeItem(at: dir) }
        defer { for dir in [staging, unpack] { try? fm.removeItem(at: dir) } }

        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        _ = try await ProcessRunner.runChecked("/usr/bin/ditto", ["-x", "-k", archive.path, unpack.path])
        try? fm.removeItem(at: unpack.appending(path: "__MACOSX"))

        var top = ""
        let entries = try fm.contentsOfDirectory(atPath: unpack.path)
        var isDir: ObjCBool = false
        if entries.count == 1, fm.fileExists(atPath: unpack.appending(path: entries[0]).path, isDirectory: &isDir),
            isDir.boolValue
        {
            top = entries[0]
            try fm.moveItem(at: unpack.appending(path: top), to: staging)
            log("flattened top-level folder '\(top)'")
        } else {
            try fm.moveItem(at: unpack, to: staging)
        }

        let count = try verifyManifest(in: staging, top: top)
        guard fm.fileExists(atPath: staging.appending(path: "Launcher.exe").path) else {
            throw EmberPayloadError.launcherMissing
        }
        try fm.moveItem(at: staging, to: dest)
        log("Ember \(version) installed: \(dest.path) (\(count) files verified)")
        return InstalledEmber(version: version, directory: dest)
    }

    private func verifyManifest(in staging: URL, top: String) throws -> Int {
        let manifest = staging.appending(path: "MANIFEST.txt")
        guard let data = try? Data(contentsOf: manifest) else { throw EmberPayloadError.manifestMissing }
        let entries = Self.parseManifest(String(decoding: data, as: UTF8.self), top: top)
        guard !entries.isEmpty else { throw EmberPayloadError.manifestEmpty }
        log("verifying \(entries.count) files against MANIFEST.txt")
        var bad: [String] = []
        for entry in entries {
            if entry.path.hasPrefix("/") || "/\(entry.path)/".contains("/../") {
                throw EmberPayloadError.unsafeManifestPath(entry.path)
            }
            let file = staging.appending(path: entry.path)
            guard let actual = try? Downloader.sha256(of: file), actual == entry.sha256 else {
                bad.append(entry.path)
                continue
            }
        }
        guard bad.isEmpty else { throw EmberPayloadError.manifestMismatch(bad) }
        return entries.count
    }

    static func parseManifest(_ text: String, top: String) -> [(sha256: String, path: String)] {
        var result: [(String, String)] = []
        for rawLine in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            let line = String(rawLine)
            let hash = line.prefix(while: { $0.isHexDigit })
            guard hash.count == 64 else { continue }
            var path = String(line.dropFirst(hash.count))
            guard let first = path.first, first == " " || first == "\t" else { continue }
            path = String(path.drop(while: { $0 == " " || $0 == "\t" }))
            if path.hasPrefix("*") { path.removeFirst() }
            path = path.replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("./") { path.removeFirst(2) }
            if !top.isEmpty, path.hasPrefix(top + "/") { path.removeFirst(top.count + 1) }
            result.append((hash.lowercased(), path))
        }
        return result
    }

    private static func buildVersion(in dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appending(path: "BUILD_INFO.txt")) else { return nil }
        for line in String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            guard line.hasPrefix("Release:") else { continue }
            let value = line.dropFirst("Release:".count).drop(while: { $0 == " " })
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }
}
