import EmberAppCore
import Foundation

struct AdminCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AdminCommand {
    @MainActor
    static func installRosetta() async throws {
        let source = "do shell script \"\(Rosetta.installCommand)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw AdminCommandError(message: "Could not prepare the Rosetta installer.")
        }
        var failure: NSDictionary?
        script.executeAndReturnError(&failure)
        if let failure {
            let text = failure[NSAppleScript.errorMessage] as? String
            throw AdminCommandError(message: text ?? "Rosetta 2 installation did not finish.")
        }
    }
}
