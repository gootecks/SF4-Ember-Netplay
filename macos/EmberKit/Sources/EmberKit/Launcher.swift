import Foundation

public enum LaunchOutcome: Sendable, Equatable {
    case launched(version: String, pid: Int32)
    case alreadyRunning
    case handedOff
}

extension SteamController {
    public static let emberProcessNames = ["Launcher.exe", "SSFIV.exe", "sf4-net.exe", "ember-discord.exe"]

    public func emberProcesses() async throws -> [String] {
        try await tasklist().filter { line in
            Self.emberProcessNames.contains { line.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    public func stopEmber() async throws {
        guard await serverAlive() else {
            log("no wineserver for this prefix (nothing to do)")
            return
        }
        for name in Self.emberProcessNames {
            log("taskkill /F /IM \(name)")
            _ = try await wine.run(["taskkill", "/F", "/IM", name], check: false)
        }
    }

    @discardableResult
    public func launch(hud: Bool = false, joinLink: String? = nil) async throws -> LaunchOutcome {
        try requirePrefix()
        try await requireLoggedOn()
        let vdf = (try? String(contentsOf: libraryFoldersFile, encoding: .utf8)) ?? ""
        guard SteamVDF.containsApp(appId, in: vdf) else { throw SteamError.libraryNotAdopted(appId: appId) }
        let running = try await hasProcess("SSFIV.exe")
        if running && joinLink == nil {
            log("SSFIV.exe already running in this prefix (nothing to do)")
            return .alreadyRunning
        }
        guard let install = EmberPayloadInstaller.newest(in: prefixDir) else { throw SteamError.emberNotInstalled }
        let extra = hud ? ["DXVK_HUD": "fps,frametimes", "MTL_HUD_ENABLED": "1"] : [:]
        let logFile = logFile("launcher-wine")
        var arguments = [install.launcherWindowsPath]
        if let joinLink { arguments += ["--join-link", joinLink] }
        if running {
            log("SSFIV.exe already running; handing the link to the running game")
        } else {
            log("launching Ember \(install.version): \(install.launcherWindowsPath) (detached; output: \(logFile.path))")
        }
        let pid = try wine.spawn(
            arguments, logFile: logFile, currentDirectory: install.directory, extraEnvironment: extra)
        return running ? .handedOff : .launched(version: install.version, pid: pid)
    }
}
