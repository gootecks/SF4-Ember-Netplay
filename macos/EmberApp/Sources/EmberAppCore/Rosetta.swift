import EmberKit
import Foundation

public enum Rosetta {
    public static let installCommand = "softwareupdate --install-rosetta --agree-to-license"

    public static func isInstalled() async -> Bool {
        guard let result = try? await ProcessRunner.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) else {
            return false
        }
        return result.succeeded
    }
}
