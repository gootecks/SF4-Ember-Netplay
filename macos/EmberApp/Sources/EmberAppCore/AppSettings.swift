import EmberKit
import Foundation

public enum VersionPolicy: String, Sendable, CaseIterable, Identifiable {
    case latest
    case pinned

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .latest: "Latest release"
        case .pinned: "Pinned to the tested version"
        }
    }
}

public struct AppSettings: Equatable, Sendable {
    public static let rootKey = "EmberRoot"
    public static let policyKey = "EmberVersionPolicy"
    public static let hudKey = "EmberHUD"
    public static let environmentKey = "EMBER_ROOT"

    public var customRoot: URL?
    public var policy: VersionPolicy
    public var hud: Bool
    public private(set) var rootFromEnvironment: Bool

    public init(
        customRoot: URL? = nil, policy: VersionPolicy = .latest, hud: Bool = false, rootFromEnvironment: Bool = false
    ) {
        self.customRoot = customRoot
        self.policy = policy
        self.hud = hud
        self.rootFromEnvironment = rootFromEnvironment
    }

    public var dataRoot: URL { customRoot ?? EmberPaths.defaultRoot }

    public static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppSettings {
        var settings = AppSettings(
            policy: defaults.string(forKey: policyKey).flatMap(VersionPolicy.init(rawValue:)) ?? .latest,
            hud: defaults.bool(forKey: hudKey)
        )
        if let env = environment[environmentKey], !env.isEmpty {
            settings.customRoot = directory(env)
            settings.rootFromEnvironment = true
        } else if let stored = defaults.string(forKey: rootKey), !stored.isEmpty {
            settings.customRoot = directory(stored)
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(policy.rawValue, forKey: Self.policyKey)
        defaults.set(hud, forKey: Self.hudKey)
        guard !rootFromEnvironment else { return }
        if let customRoot {
            defaults.set(customRoot.path, forKey: Self.rootKey)
        } else {
            defaults.removeObject(forKey: Self.rootKey)
        }
    }

    private static func directory(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
}
