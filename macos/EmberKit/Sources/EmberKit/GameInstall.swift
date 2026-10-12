import Foundation

extension SteamController {
    public var gameInstallURL: String { "steam://install/\(appId)" }

    @discardableResult
    public func installGame() async throws -> Bool {
        try requirePrefix()
        try requireSteamExe()
        log("asking Steam to install app \(appId) into the prefix's default library")
        try spawnSteam([gameInstallURL])
        return true
    }
}
