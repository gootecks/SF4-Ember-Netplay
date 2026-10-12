import Foundation

public struct PrefixMarker: Sendable, Equatable {
    public static let fileName = ".ember-m0-prefix"

    public var renderer: String
    public var engine: String
    public var created: String

    public static func read(from url: URL) -> PrefixMarker? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return PrefixMarker(
            renderer: fields["renderer"] ?? "", engine: fields["engine"] ?? "", created: fields["created"] ?? "")
    }

    public var fileContents: String {
        "renderer=\(renderer)\nengine=\(engine)\ncreated=\(created)\n"
    }
}

public enum PrefixOutcome: Sendable, Equatable {
    case alreadyBuilt(renderer: String)
    case created
}

public struct PrefixBuilder: Sendable {
    public let manifest: EngineManifest
    public let paths: EmberPaths
    public let downloader: Downloader
    public let baseEnvironment: [String: String]
    public let log: @Sendable (String) -> Void

    public init(
        manifest: EngineManifest,
        paths: EmberPaths,
        downloader: Downloader? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.manifest = manifest
        self.paths = paths
        self.downloader = downloader ?? Downloader(cacheDir: paths.cacheDir, log: log)
        self.baseEnvironment = baseEnvironment
        self.log = log
    }

    @discardableResult
    public func create(renderer requested: Renderer? = nil, debugWine: Bool = false) async throws -> PrefixOutcome {
        let fm = FileManager.default
        let prefix = paths.prefixDir
        if let marker = PrefixMarker.read(from: paths.prefixMarker) {
            if let requested, requested.rawValue != marker.renderer {
                throw EmberError.prefixRendererMismatch(
                    existing: marker.renderer, requested: requested.rawValue, path: prefix.path)
            }
            log("prefix already built (renderer=\(marker.renderer)): \(prefix.path) (nothing to do)")
            return .alreadyBuilt(renderer: marker.renderer)
        }
        if (try? fm.attributesOfItem(atPath: prefix.path)) != nil {
            throw EmberError.prefixIncomplete(path: prefix.path)
        }
        let renderer = requested ?? .dxvk
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        let wine = Wine(
            manifest: manifest, paths: paths, renderer: renderer, debug: debugWine, baseEnvironment: baseEnvironment)
        _ = try wine.environment()
        var components = ComponentInstaller(downloader: downloader, log: log)
        defer { components.cleanup() }
        do {
            try await build(wine: wine, renderer: renderer, components: &components)
        } catch {
            await wine.killServer()
            try? fm.removeItem(at: prefix)
            throw error
        }
        log("prefix ready: \(prefix.path)")
        return .created
    }

    private func build(wine: Wine, renderer: Renderer, components: inout ComponentInstaller) async throws {
        let fm = FileManager.default
        let prefix = paths.prefixDir
        let noGecko = ["WINEDLLOVERRIDES": "mscoree,mshtml="]

        log("wineboot -i")
        if let boot = wine.winebootURL {
            try await wine.run(["-i"], executable: boot, extraEnvironment: noGecko)
        } else {
            try await wine.run(["wineboot", "-i"], extraEnvironment: noGecko)
        }
        try await wine.waitWineserver()

        let winver = manifest.prefix.windowsVersion ?? "win10"
        log("Windows version: \(winver)")
        try await wine.run(["winecfg", "/v", winver])
        try await wine.waitWineserver()

        let emberDir = prefix.appending(path: "drive_c/ember", directoryHint: .isDirectory)
        try fm.createDirectory(at: emberDir.appending(path: "logs"), withIntermediateDirectories: true)
        if renderer == .dxvk {
            try "dxvk.enableAsync = True\n[SSFIV.exe]\nd3d9.maxFrameLatency = 1\n"
                .write(to: emberDir.appending(path: "dxvk.conf"), atomically: true, encoding: .utf8)
            log("wrote C:\\ember\\dxvk.conf")
        }

        for component in manifest.components {
            try await components.install(component, scope: "prefix", base: prefix)
        }

        let overrides: [String: String]
        if renderer == .wined3d {
            log("renderer wined3d: applying fallback DLL overrides (\(manifest.fallback?.notes ?? ""))")
            overrides = manifest.fallback?.dllOverrides ?? [:]
        } else {
            overrides = manifest.prefix.dllOverrides ?? [:]
        }
        for key in overrides.keys.sorted() {
            let value = overrides[key] ?? ""
            log("DllOverride \(key)=\(value)")
            try await wine.run(["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", key, "/d", value, "/f"])
        }

        for entry in manifest.prefix.registry ?? [] {
            let name = entry.name ?? ""
            log("registry \(entry.key) [\(name.isEmpty ? "(Default)" : name)] (\(entry.type))")
            let nameArgs = name.isEmpty ? ["/ve"] : ["/v", name]
            try await wine.run(["reg", "add", entry.key] + nameArgs + ["/t", entry.type, "/d", entry.data, "/f"])
        }
        try await wine.waitWineserver()

        let marker = PrefixMarker(
            renderer: renderer.rawValue,
            engine: manifest.id,
            created: ISO8601DateFormatter().string(from: Date())
        )
        try marker.fileContents.write(to: paths.prefixMarker, atomically: true, encoding: .utf8)
    }
}
