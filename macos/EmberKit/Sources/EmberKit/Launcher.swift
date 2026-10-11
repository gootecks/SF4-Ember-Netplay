import Foundation

public enum LaunchOutcome: Sendable, Equatable {
    case launched(version: String, pid: Int32)
    case alreadyRunning
}

extension SteamController {
    public static let emberProcessNames = ["Launcher.exe", "SSFIV.exe", "sf4-net.exe", "ember-discord.exe"]

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
        guard let install = EmberPayloadInstaller.newest(in: prefixDir) else { throw SteamError.emberNotInstalled }
        let extra = hud ? ["DXVK_HUD": "fps,frametimes", "MTL_HUD_ENABLED": "1"] : [:]
        let logFile = logFile("launcher-wine")
        log("launching Ember \(install.version): \(install.launcherWindowsPath) (detached; output: \(logFile.path))")
        let pid = try wine.spawn(
            [install.launcherWindowsPath], logFile: logFile, currentDirectory: install.directory,
            extraEnvironment: extra)
        return .launched(version: install.version, pid: pid)
    }
}
