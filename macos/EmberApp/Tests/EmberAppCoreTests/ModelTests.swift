import XCTest

@testable import EmberAppCore

@MainActor
final class ModelTests: XCTestCase {
    private func make(
        _ backend: FakeBackend, poll: Duration = .milliseconds(20),
        rosetta: @escaping @Sendable () async throws -> Void = {}
    ) -> AppModel {
        AppModel(
            settings: AppSettings(), defaults: nil, pollInterval: poll, rosettaInstaller: rosetta,
            makeBackend: { _ in backend })
    }

    private func wait(_ what: String = "condition", _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    func testSetupSkippedWhenEverythingDone() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        let model = make(backend)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.setupComplete)
        XCTAssertEqual(model.latestEmber, "9.9.9")
        XCTAssertTrue(backend.performed.isEmpty)
    }

    func testPartialSetupResumesAtFirstMissingStep() async {
        let backend = FakeBackend(done: [.rosetta, .engine, .prefix, .game])
        let model = make(backend)
        await model.start()
        XCTAssertEqual(model.phase, .setup)
        XCTAssertEqual(model.steps[.engine], .done)
        XCTAssertEqual(model.steps[.steam], .pending)
        model.runSetup()
        await wait { model.phase == .ready }
        XCTAssertEqual(backend.performed, [.steam, .login, .ember])
        XCTAssertEqual(model.steps.values.filter { $0 == .done }.count, SetupStep.allCases.count)
    }

    func testFailureStopsAndRetryContinues() async {
        let backend = FakeBackend(done: [.rosetta])
        backend.fail(.prefix, with: FakeFailure())
        let model = make(backend)
        await model.start()
        model.runSetup()
        await wait { !model.setupRunning }
        XCTAssertEqual(model.steps[.engine], .done)
        XCTAssertEqual(model.steps[.prefix], .failed("boom"))
        XCTAssertEqual(model.steps[.steam], .pending)
        XCTAssertEqual(backend.performed, [.engine, .prefix])
        backend.fail(.prefix, with: nil)
        model.runSetup()
        await wait { model.phase == .ready || model.steps[.game] == .needsInput }
        XCTAssertEqual(model.steps[.prefix], .done)
        XCTAssertEqual(model.steps[.steam], .done)
        XCTAssertEqual(model.steps[.login], .done)
    }

    func testGameStepWaitsForChoiceAndFailureAsksAgain() async {
        let backend = FakeBackend(done: [.rosetta, .engine, .prefix, .steam, .login])
        backend.fail(.game, with: FakeFailure())
        let model = make(backend)
        await model.start()
        model.runSetup()
        await wait { model.steps[.game] == .needsInput }
        XCTAssertFalse(backend.performed.contains(.game))
        let folder = URL(filePath: "/tmp/lib")
        model.chooseGame(.existing(folder))
        await wait { !model.setupRunning }
        XCTAssertEqual(model.steps[.game], .failed("boom"))
        XCTAssertEqual(backend.games.last ?? nil, .existing(folder))
        backend.fail(.game, with: nil)
        model.chooseGame(.install)
        await wait { model.phase == .ready }
        XCTAssertEqual(backend.games.last ?? nil, .install)
        XCTAssertEqual(backend.performed.last, .ember)
    }

    func testRosettaInstallRunsThenResumesSetup() async {
        let backend = FakeBackend()
        backend.fail(.rosetta, with: FakeFailure())
        let installed = Flag()
        let model = make(backend, rosetta: { installed.set() })
        await model.start()
        model.runSetup()
        await wait { model.steps[.rosetta] == .failed("boom") }
        backend.fail(.rosetta, with: nil)
        model.installRosetta()
        await wait { model.steps[.engine] != .pending }
        XCTAssertTrue(installed.value)
    }

    func testPlayTracksSteamStartedByApp() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        let model = make(backend)
        await model.start()
        await model.play()
        XCTAssertTrue(model.startedSteam)
        XCTAssertEqual(model.notice, Notice("launched hud=false"))
        XCTAssertEqual(backend.launches, 1)
        await model.shutdown()
        XCTAssertEqual(backend.shutdowns, [true])
        XCTAssertFalse(model.startedSteam)
    }

    func testQuitOnlyStopsEmberWhenSteamWasNotStartedByApp() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        backend.setSteamStarts(false)
        let model = make(backend)
        await model.start()
        await model.play()
        XCTAssertFalse(model.startedSteam)
        await model.shutdown()
        XCTAssertEqual(backend.shutdowns, [false])
    }

    func testPlayFailureIsReported() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        backend.setLaunchError(FakeFailure())
        let model = make(backend)
        await model.start()
        await model.play()
        XCTAssertEqual(model.notice, Notice("boom", isError: true))
        XCTAssertNil(model.busy)
    }

    func testPlayIsIgnoredBeforeSetupCompletes() async {
        let backend = FakeBackend()
        let model = make(backend)
        await model.start()
        await model.play()
        XCTAssertEqual(backend.launches, 0)
    }

    func testPollingRunsOnlyWhenReadyAndStops() async {
        let backend = FakeBackend()
        let model = make(backend)
        model.startPolling()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(backend.statusCalls, 0)
        model.stopPolling()

        let ready = FakeBackend(done: Set(SetupStep.allCases))
        let readyModel = make(ready)
        await readyModel.start()
        let before = ready.statusCalls
        readyModel.startPolling()
        await wait { ready.statusCalls >= before + 3 }
        readyModel.stopPolling()
        try? await Task.sleep(for: .milliseconds(60))
        let after = ready.statusCalls
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(ready.statusCalls, after)
    }

    func testUpdateAndDiagnosticsNotices() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        let model = make(backend)
        await model.start()
        await model.updateEmber()
        XCTAssertEqual(model.notice, Notice("updated latest"))
        let dir = URL(filePath: "/tmp/diag")
        let url = await model.createDiagnostics(into: dir)
        XCTAssertEqual(url?.deletingLastPathComponent().path, "/tmp/diag")
        XCTAssertTrue(url?.lastPathComponent.hasPrefix("ember-diagnostics-") ?? false)
    }

    func testChangingDataFolderRebuildsBackend() async {
        let first = FakeBackend(done: Set(SetupStep.allCases))
        let second = FakeBackend()
        let used = Counter()
        let model = AppModel(
            settings: AppSettings(), defaults: nil, pollInterval: .seconds(60),
            makeBackend: { _ in used.next() == 0 ? first : second })
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        model.settings.customRoot = URL(filePath: "/tmp/other-root")
        await wait { model.phase == .setup }
        XCTAssertEqual(model.steps[.engine], .pending)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; defer { count += 1 }; return count }
}
