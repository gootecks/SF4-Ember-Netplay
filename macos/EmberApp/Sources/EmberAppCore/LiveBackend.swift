import EmberKit
import Foundation

public struct LiveBackend: EmberBackend {
    public let paths: EmberPaths
    public let manifest: EngineManifest
    public let loginPollInterval: Duration
    public let gamePollInterval: Duration
    public let settleDelay: Duration

    public init(
        paths: EmberPaths, manifest: EngineManifest,
        loginPollInterval: Duration = .seconds(2), gamePollInterval: Duration = .seconds(5),
        settleDelay: Duration = .seconds(5)
    ) {
        self.paths = paths
        self.manifest = manifest
        self.loginPollInterval = loginPollInterval
        self.gamePollInterval = gamePollInterval
        self.settleDelay = settleDelay
    }

    public var logsDirectory: URL { paths.logsDir }

    func wine() -> Wine { Wine(manifest: manifest, paths: paths) }

    func steam(alive: Bool? = nil, log: @escaping LogSink = { _ in }) -> SteamController {
        let serverAlive: (@Sendable () async -> Bool)? = alive.map { value in { @Sendable in value } }
        return SteamController(wine: wine(), serverAlive: serverAlive, log: log)
    }

    func source() -> GitHubReleaseSource { GitHubReleaseSource(pinned: manifest.ember) }

    func payload(log: @escaping LogSink = { _ in }) -> EmberPayloadInstaller {
        EmberPayloadInstaller(paths: paths, source: source(), log: log)
    }

    var loginUsers: URL { steam().steamDir.appending(path: "config/loginusers.vdf") }

    func hasRememberedLogin() -> Bool {
        guard let text = try? String(contentsOf: loginUsers, encoding: .utf8) else { return false }
        return text.range(of: #""RememberPassword"\s+"1""#, options: .regularExpression) != nil
    }

    public func isDone(_ step: SetupStep) async -> Bool {
        let fm = FileManager.default
        switch step {
        case .rosetta:
            return await Rosetta.isInstalled()
        case .engine:
            return fm.isExecutableFile(atPath: wine().wineURL.path)
        case .prefix:
            return fm.fileExists(atPath: paths.prefixMarker.path)
        case .steam:
            return fm.fileExists(atPath: steam().steamExe.path)
        case .login:
            return hasRememberedLogin()
        case .game:
            return (try? steam().gameCheck().ok) ?? false
        case .ember:
            return payload().newestInstalled() != nil
        }
    }

    public func perform(
        _ step: SetupStep, game: GameChoice?, policy: VersionPolicy, log: @escaping LogSink
    ) async throws {
        switch step {
        case .rosetta:
            throw SetupError.rosettaMissing
        case .engine:
            try await EngineInstaller(manifest: manifest, paths: paths, log: log).install()
        case .prefix:
            try await PrefixBuilder(manifest: manifest, paths: paths, log: log).create()
        case .steam:
            try await steam(log: log).install()
        case .login:
            try await login(log: log)
        case .game:
            try await setUpGame(game, log: log)
        case .ember:
            _ = try await installEmber(policy: policy, log: log)
        }
    }

    func login(log: @escaping LogSink) async throws {
        let controller = steam(log: log)
        let offset = controller.loginLogSize()
        try await controller.login()
        log("waiting for you to sign in to Steam")
        do {
            while !controller.isLoggedOn(since: offset) {
                try await Task.sleep(for: loginPollInterval)
            }
            log("Steam login detected; letting Steam save it")
            try await Task.sleep(for: settleDelay)
        } catch {
            await controller.kill()
            throw error
        }
        await controller.kill()
    }

    func setUpGame(_ choice: GameChoice?, log: @escaping LogSink) async throws {
        let controller = steam(log: log)
        switch choice {
        case .existing(let folder):
            await controller.kill()
            try await controller.addLibrary(host: folder)
            try controller.requireGameMatch()
        case .install:
            try await controller.installGame()
            log("waiting for Steam to finish installing the game")
            do {
                while true {
                    if let report = try? controller.gameCheck(), report.ok { break }
                    try await Task.sleep(for: gamePollInterval)
                }
                try await Task.sleep(for: settleDelay)
            } catch {
                await controller.kill()
                throw error
            }
            await controller.kill()
        case nil:
            throw SetupError.noGameChoice
        }
    }

    func installEmber(policy: VersionPolicy, log: @escaping LogSink) async throws -> String {
        let installer = payload(log: log)
        switch policy {
        case .pinned:
            guard let pinned = manifest.ember else { throw SteamError.manifestSectionMissing("ember") }
            let installed = try await installer.install(version: pinned.version)
            return "Ember \(installed.version) installed"
        case .latest:
            switch try await installer.update() {
            case .upToDate(let installed, _):
                return "Ember \(installed) is up to date"
            case .installed(let version, _):
                return "Ember \(version) installed"
            case .checkFailed(let reason, let installed):
                guard installed != nil else { throw EmberPayloadError.releaseLookupFailed(reason) }
                return "Could not check for updates (\(reason)); keeping \(installed ?? "the installed version")"
            }
        }
    }

    public func updateEmber(policy: VersionPolicy, log: @escaping LogSink) async throws -> String {
        try await installEmber(policy: policy, log: log)
    }

    public func status() async -> StatusSnapshot {
        let fm = FileManager.default
        var snapshot = StatusSnapshot()
        snapshot.engineInstalled = fm.isExecutableFile(atPath: wine().wineURL.path)
        snapshot.prefixBuilt = fm.fileExists(atPath: paths.prefixMarker.path)
        snapshot.emberInstalled = payload().newestInstalled()?.version
        guard snapshot.prefixBuilt else { return snapshot }
        let installed = fm.fileExists(atPath: steam().steamExe.path)
        let alive = await SteamController.wineserverAlive(prefix: paths.prefixDir)
        snapshot.wineserverAlive = alive
        let controller = steam(alive: alive)
        let tasks = alive ? ((try? await controller.tasklist()) ?? []) : []
        func has(_ name: String) -> Bool { tasks.contains { $0.range(of: name, options: .caseInsensitive) != nil } }
        if !installed {
            snapshot.steam = .notInstalled
        } else if has("steam.exe") {
            snapshot.steam = controller.isLoggedOn() ? .loggedOn : .starting
        } else {
            snapshot.steam = .stopped
        }
        snapshot.gameRunning = has("SSFIV.exe")
        snapshot.helperRunning = has("sf4-net.exe")
        return snapshot
    }

    public func latestEmber() async -> String? {
        try? await source().latest().version
    }

    public func ensureSteam(log: @escaping LogSink) async throws -> Bool {
        try await steam(log: log).startHidden() != .alreadyReady
    }

    public func launchGame(hud: Bool, log: @escaping LogSink) async throws -> String {
        switch try await steam(log: log).launch(hud: hud) {
        case .launched(let version, _): "Ember \(version) is starting"
        case .alreadyRunning: "The game is already running"
        }
    }

    public func createDiagnostics(at destination: URL) async throws -> URL {
        try await DiagnosticsBundle.create(paths: paths, manifest: manifest, to: destination)
    }

    public func isGameRunning() async -> Bool {
        (try? await steam().hasProcess("SSFIV.exe")) ?? false
    }

    public func shutdown(killPrefix: Bool, log: @escaping LogSink) async {
        let controller = steam(log: log)
        if killPrefix {
            await controller.kill()
        } else {
            try? await controller.stopEmber()
        }
    }
}
