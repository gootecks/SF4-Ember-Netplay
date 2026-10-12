import EmberKit
import Foundation
import Observation

public enum AppPhase: Equatable, Sendable {
    case checking
    case setup
    case ready
}

public enum BusyAction: Equatable, Sendable {
    case playing
    case updating
    case diagnostics

    public var label: String {
        switch self {
        case .playing: "Starting"
        case .updating: "Updating Ember"
        case .diagnostics: "Collecting diagnostics"
        }
    }
}

public struct Notice: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

@MainActor
@Observable
public final class AppModel {
    public internal(set) var phase = AppPhase.checking
    public internal(set) var steps: [SetupStep: StepState] = Dictionary(
        uniqueKeysWithValues: SetupStep.allCases.map { ($0, StepState.pending) })
    public internal(set) var progress = ""
    public internal(set) var status = StatusSnapshot()
    public internal(set) var latestEmber: String?
    public internal(set) var busy: BusyAction?
    public internal(set) var notice: Notice?
    public internal(set) var startedSteam = false
    public internal(set) var backend: any EmberBackend
    public internal(set) var appLog: AppLog
    public internal(set) var setupRunning = false
    public internal(set) var pendingLinkKind: EmberLink.Kind?
    var pendingLink: String?

    public var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    let makeBackend: @Sendable (AppSettings) -> any EmberBackend
    let rosettaInstaller: @Sendable () async throws -> Void
    let defaults: UserDefaults?
    let pollInterval: Duration
    var gameChoice: GameChoice?
    var setupTask: Task<Void, Never>?
    var pollTask: Task<Void, Never>?

    public init(
        settings: AppSettings,
        defaults: UserDefaults? = .standard,
        pollInterval: Duration = .seconds(5),
        rosettaInstaller: @escaping @Sendable () async throws -> Void = {},
        makeBackend: @escaping @Sendable (AppSettings) -> any EmberBackend
    ) {
        self.settings = settings
        self.defaults = defaults
        self.pollInterval = pollInterval
        self.rosettaInstaller = rosettaInstaller
        self.makeBackend = makeBackend
        let backend = makeBackend(settings)
        self.backend = backend
        self.appLog = AppLog(directory: backend.logsDirectory)
    }

    public var setupComplete: Bool { steps.values.allSatisfy { $0 == .done } }

    func sink() -> LogSink {
        let log = appLog
        return { [weak self] line in
            log.write(line)
            Task { @MainActor in self?.progress = line }
        }
    }

    func record(_ message: String) {
        appLog.write(message)
    }

    func settingsDidChange(from old: AppSettings) {
        if let defaults { settings.save(to: defaults) }
        guard old.dataRoot != settings.dataRoot else { return }
        setupTask?.cancel()
        backend = makeBackend(settings)
        appLog = AppLog(directory: backend.logsDirectory)
        record("data folder changed")
        gameChoice = nil
        startedSteam = false
        status = StatusSnapshot()
        latestEmber = nil
        phase = .checking
        Task { await start() }
    }

    public func start() async {
        await refreshSetup()
        if phase == .ready { await refreshLatest() }
    }

    public func refreshStatus() async {
        status = await backend.status()
    }

    public func refreshLatest() async {
        latestEmber = await backend.latestEmber()
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.phase == .ready { await self.refreshStatus() }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
