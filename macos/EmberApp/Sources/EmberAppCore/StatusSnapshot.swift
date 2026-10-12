import Foundation

public enum SteamState: Equatable, Sendable {
    case notInstalled
    case stopped
    case starting
    case loggedOn

    public var label: String {
        switch self {
        case .notInstalled: "Not installed"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .loggedOn: "Logged on"
        }
    }
}

public struct StatusSnapshot: Equatable, Sendable {
    public var engineInstalled = false
    public var prefixBuilt = false
    public var steam = SteamState.notInstalled
    public var emberInstalled: String?
    public var gameRunning = false
    public var helperRunning = false
    public var wineserverAlive = false

    public init() {}
}
