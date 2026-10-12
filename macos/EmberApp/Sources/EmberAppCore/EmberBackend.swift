import Foundation

public typealias LogSink = @Sendable (String) -> Void

public protocol EmberBackend: Sendable {
    var logsDirectory: URL { get }

    func isDone(_ step: SetupStep) async -> Bool
    func perform(_ step: SetupStep, game: GameChoice?, policy: VersionPolicy, log: @escaping LogSink) async throws
    func status() async -> StatusSnapshot
    func latestEmber() async -> String?
    func ensureSteam(log: @escaping LogSink) async throws -> Bool
    func launchGame(hud: Bool, joinLink: String?, log: @escaping LogSink) async throws -> String
    func updateEmber(policy: VersionPolicy, log: @escaping LogSink) async throws -> String
    func createDiagnostics(at destination: URL) async throws -> URL
    func isGameRunning() async -> Bool
    func shutdown(killPrefix: Bool, log: @escaping LogSink) async
}
