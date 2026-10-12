import Foundation

public enum InstallOutcome: Sendable, Equatable {
    case alreadyInstalled
    case installed
}

public struct EngineInstaller: Sendable {
    public let manifest: EngineManifest
    public let paths: EmberPaths
    public let downloader: Downloader
    public let log: @Sendable (String) -> Void

    public init(
        manifest: EngineManifest,
        paths: EmberPaths,
        downloader: Downloader? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.manifest = manifest
        self.paths = paths
        self.downloader = downloader ?? Downloader(cacheDir: paths.cacheDir, log: log)
        self.log = log
    }

    public var engineDir: URL { paths.engineDir(manifest.id) }

    @discardableResult
    public func install() async throws -> InstallOutcome {
        let fm = FileManager.default
        let wineRel = manifest.engine.wine
        if fm.isExecutableFile(atPath: engineDir.appending(path: wineRel).path) {
            log("engine \(manifest.id) already installed: \(engineDir.path) (nothing to do)")
            return .alreadyInstalled
        }
        if (try? fm.attributesOfItem(atPath: engineDir.path)) != nil {
            throw EmberError.engineDirIncomplete(path: engineDir.path, missing: wineRel)
        }
        try fm.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.enginesDir, withIntermediateDirectories: true)
        let staging = paths.enginesDir.appending(path: manifest.id + ".tmp", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var components = ComponentInstaller(downloader: downloader, log: log)
        defer { components.cleanup() }
        do {
            for component in manifest.components {
                try await components.install(component, scope: "engine", base: staging)
            }
            guard fm.isExecutableFile(atPath: staging.appending(path: wineRel).path) else {
                throw EmberError.engineBinaryMissing("\(wineRel) in the installed engine")
            }
            _ = try? await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
            try fm.moveItem(at: staging, to: engineDir)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        log("engine installed: \(engineDir.path)")
        return .installed
    }
}
