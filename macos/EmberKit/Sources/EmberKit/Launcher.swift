import Foundation

public struct EmberInstall: Sendable, Equatable {
    public let version: String
    public let directoryName: String
    public let directory: URL

    public var windowsDirectory: String { "C:\\\(directoryName)" }
    public var launcherWindowsPath: String { "\(windowsDirectory)\\Launcher.exe" }

    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    public static func installed(in prefix: URL) -> [EmberInstall] {
        let fm = FileManager.default
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let names = (try? fm.contentsOfDirectory(atPath: driveC.path)) ?? []
        var found: [EmberInstall] = []
        for name in names where name.hasPrefix("sf4e-") {
            let dir = driveC.appending(path: name, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: dir.appending(path: "Launcher.exe").path) else { continue }
            found.append(
                EmberInstall(
                    version: releaseVersion(in: dir) ?? String(name.dropFirst("sf4e-".count)),
                    directoryName: name, directory: dir))
        }
        return found.sorted {
            let order = compareVersions($0.version, $1.version)
            return order == .orderedSame ? $0.directoryName < $1.directoryName : order == .orderedAscending
        }
    }

    public static func newest(in prefix: URL) -> EmberInstall? {
        installed(in: prefix).last
    }

    static func releaseVersion(in dir: URL) -> String? {
        guard let text = try? String(contentsOf: dir.appending(path: "BUILD_INFO.txt"), encoding: .utf8) else {
            return nil
        }
        for line in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            guard line.hasPrefix("Release:") else { continue }
            let value = line.dropFirst("Release:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

public enum LaunchOutcome: Sendable, Equatable {
    case launched(version: String, pid: Int32)
    case alreadyRunning
}

extension SteamController {
    public static let emberProcessNames = ["Launcher.exe", "SSFIV.exe", "sf4-net.exe", "ember-discord.exe"]

    public func emberInstalls() -> [EmberInstall] {
        EmberInstall.installed(in: prefixDir)
    }

    public func emberProcesses() async throws -> [String] {
        try await tasklist().filter { line in
            Self.emberProcessNames.contains { line.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    @discardableResult
    public func launch(hud: Bool = false) async throws -> LaunchOutcome {
        try requirePrefix()
        try await requireLoggedOn()
        let vdf = (try? String(contentsOf: libraryFoldersFile, encoding: .utf8)) ?? ""
        guard SteamVDF.containsApp(appId, in: vdf) else { throw SteamError.libraryNotAdopted(appId: appId) }
        if try await hasProcess("SSFIV.exe") {
            log("SSFIV.exe already running in this prefix (nothing to do)")
            return .alreadyRunning
        }
        guard let install = EmberInstall.newest(in: prefixDir) else { throw SteamError.emberNotInstalled }
        let extra = hud ? ["DXVK_HUD": "fps,frametimes", "MTL_HUD_ENABLED": "1"] : [:]
        let logFile = logFile("launcher-wine")
        log("launching Ember \(install.version): \(install.launcherWindowsPath) (detached; output: \(logFile.path))")
        let pid = try wine.spawn(
            [install.launcherWindowsPath], logFile: logFile, currentDirectory: install.directory,
            extraEnvironment: extra)
        return .launched(version: install.version, pid: pid)
    }
}
