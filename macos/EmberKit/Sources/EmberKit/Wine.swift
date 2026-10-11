import Foundation

public enum Renderer: String, Sendable, CaseIterable {
    case dxvk
    case wined3d
}

public struct Wine: Sendable {
    public let manifest: EngineManifest
    public let paths: EmberPaths
    public let renderer: Renderer
    public let debug: Bool
    public let baseEnvironment: [String: String]

    public init(
        manifest: EngineManifest,
        paths: EmberPaths,
        renderer: Renderer = .dxvk,
        debug: Bool = false,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.manifest = manifest
        self.paths = paths
        self.renderer = renderer
        self.debug = debug
        self.baseEnvironment = baseEnvironment
    }

    public var engineDir: URL { paths.engineDir(manifest.id) }
    public var wineURL: URL { engineDir.appending(path: manifest.engine.wine) }
    public var wineserverURL: URL { engineDir.appending(path: manifest.engine.wineserver) }
    public var winebootURL: URL? { manifest.engine.wineboot.map { engineDir.appending(path: $0) } }

    public func environment(extra: [String: String] = [:]) throws -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: wineURL.path) else {
            throw EmberError.engineNotInstalled(path: engineDir.path)
        }
        let fw = engineDir.appending(path: "frameworks").path
        let gst = engineDir.appending(path: "frameworks/GStreamer.framework/Versions/1.0/lib").path
        var env = baseEnvironment
        env["WINEPREFIX"] = paths.prefixDir.path
        env["WINEDEBUG"] = "-all"
        env["PATH"] = wineURL.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = fw
        var lib = "\(fw):\(gst)"
        var isDir: ObjCBool = false
        let libDir = engineDir.appending(path: "lib").path
        if FileManager.default.fileExists(atPath: libDir, isDirectory: &isDir), isDir.boolValue {
            lib += ":\(libDir)"
        }
        env["DYLD_FALLBACK_LIBRARY_PATH"] = lib
        env["GST_PLUGIN_PATH"] = "\(gst)/gstreamer-1.0"
        switch renderer {
        case .wined3d:
            env.merge(manifest.fallback?.env ?? [:]) { _, new in new }
        case .dxvk:
            env.merge(manifest.prefix.env ?? [:]) { _, new in new }
            let dxvk = engineDir.appending(path: manifest.engine.dxvkDllPathPrepend)
            guard FileManager.default.fileExists(atPath: dxvk.appending(path: "i386-windows/d3d9.dll").path) else {
                throw EmberError.dxvkMissing(path: dxvk.path)
            }
            env["WINEDLLPATH_PREPEND"] = dxvk.path
        }
        if debug { env["WINEDEBUG"] = nil }
        env.merge(extra) { _, new in new }
        return env
    }

    @discardableResult
    public func run(
        _ arguments: [String],
        executable: URL? = nil,
        extraEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil,
        check: Bool = true
    ) async throws -> ProcessResult {
        let env = try environment(extra: extraEnvironment)
        let tool = (executable ?? wineURL).path
        if check {
            return try await ProcessRunner.runChecked(
                tool, arguments, environment: env, currentDirectory: currentDirectory)
        }
        return try await ProcessRunner.run(tool, arguments, environment: env, currentDirectory: currentDirectory)
    }

    public func waitWineserver() async throws {
        let env = try environment()
        guard FileManager.default.isExecutableFile(atPath: wineserverURL.path) else {
            throw EmberError.engineBinaryMissing(wineserverURL.path)
        }
        try await ProcessRunner.runChecked(wineserverURL.path, ["-w"], environment: env)
    }

    public func killServer() async {
        guard let env = try? environment(),
            FileManager.default.isExecutableFile(atPath: wineserverURL.path)
        else { return }
        _ = try? await ProcessRunner.run(wineserverURL.path, ["-k"], environment: env)
    }

    @discardableResult
    public func spawn(
        _ arguments: [String],
        logFile: URL,
        currentDirectory: URL? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> Int32 {
        try ProcessRunner.spawnDetached(
            wineURL.path, arguments,
            environment: try environment(extra: extraEnvironment),
            currentDirectory: currentDirectory,
            logFile: logFile
        )
    }
}
