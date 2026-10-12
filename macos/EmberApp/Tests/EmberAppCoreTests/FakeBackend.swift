import Foundation

@testable import EmberAppCore

struct FakeFailure: LocalizedError {
    var errorDescription: String? { "boom" }
}

final class FakeBackend: EmberBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _done: Set<SetupStep>
    private var _performed: [SetupStep] = []
    private var _games: [GameChoice?] = []
    private var _failures: [SetupStep: Error] = [:]
    private var _statusCalls = 0
    private var _shutdowns: [Bool] = []
    private var _gameRunning = false
    private var _steamStarts = true
    private var _launchError: Error?
    private var _launches = 0
    private var _links: [String?] = []
    let logsDirectory: URL

    init(done: Set<SetupStep> = [], logs: URL = FileManager.default.temporaryDirectory.appending(path: "ember-app-tests-\(UUID().uuidString)")) {
        _done = done
        logsDirectory = logs
    }

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var performed: [SetupStep] { sync { _performed } }
    var games: [GameChoice?] { sync { _games } }
    var statusCalls: Int { sync { _statusCalls } }
    var shutdowns: [Bool] { sync { _shutdowns } }
    var launches: Int { sync { _launches } }
    var links: [String?] { sync { _links } }
    func fail(_ step: SetupStep, with error: Error?) { sync { _failures[step] = error } }
    func setGameRunning(_ value: Bool) { sync { _gameRunning = value } }
    func setSteamStarts(_ value: Bool) { sync { _steamStarts = value } }
    func setLaunchError(_ error: Error?) { sync { _launchError = error } }

    func isDone(_ step: SetupStep) async -> Bool { sync { _done.contains(step) } }

    func perform(_ step: SetupStep, game: GameChoice?, policy: VersionPolicy, log: @escaping LogSink) async throws {
        log("working on \(step.rawValue)")
        let failure: Error? = sync {
            _performed.append(step)
            _games.append(game)
            return _failures[step]
        }
        if let failure { throw failure }
        _ = sync { _done.insert(step) }
    }

    func status() async -> StatusSnapshot {
        sync {
            _statusCalls += 1
            var snapshot = StatusSnapshot()
            snapshot.gameRunning = _gameRunning
            return snapshot
        }
    }

    func latestEmber() async -> String? { "9.9.9" }

    func ensureSteam(log: @escaping LogSink) async throws -> Bool { sync { _steamStarts } }

    func launchGame(hud: Bool, joinLink: String?, log: @escaping LogSink) async throws -> String {
        let error: Error? = sync {
            _launches += 1
            _links.append(joinLink)
            return _launchError
        }
        if let error { throw error }
        return "launched hud=\(hud)"
    }

    func updateEmber(policy: VersionPolicy, log: @escaping LogSink) async throws -> String { "updated \(policy.rawValue)" }

    func createDiagnostics(at destination: URL) async throws -> URL { destination }

    func isGameRunning() async -> Bool { sync { _gameRunning } }

    func shutdown(killPrefix: Bool, log: @escaping LogSink) async { sync { _shutdowns.append(killPrefix) } }
}
