import AppKit
import EmberAppCore
import EmberKit

@MainActor
enum Shared {
    static let model = AppModel(
        settings: AppSettings.load(),
        rosettaInstaller: { try await AdminCommand.installRosetta() },
        makeBackend: { settings in
            do {
                return LiveBackend(paths: EmberPaths(root: settings.dataRoot), manifest: try EngineManifest.bundled())
            } catch {
                fatalError("bundled engine manifest unreadable: \(error.localizedDescription)")
            }
        }
    )
}
