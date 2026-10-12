import XCTest

@testable import EmberAppCore

@MainActor
final class LinkTests: XCTestCase {
    private let join = URL(string: "ember://join/7K3M-0X1R-T9PZ")!

    private func make(_ backend: FakeBackend) -> AppModel {
        AppModel(
            settings: AppSettings(), defaults: nil, pollInterval: .milliseconds(20),
            makeBackend: { _ in backend })
    }

    private func wait(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testRefusesInvalidLinkWithoutLaunching() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        let model = make(backend)
        await model.start()
        let result = await model.handle(link: URL(string: "ember://join/nope")!)
        XCTAssertEqual(result, .refused)
        XCTAssertEqual(backend.launches, 0)
    }

    func testReadyModelLaunchesWithLink() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        let model = make(backend)
        await model.start()
        let result = await model.handle(link: join)
        XCTAssertEqual(result, .launched)
        XCTAssertEqual(backend.links, [join.absoluteString])
        XCTAssertTrue(model.startedSteam)
    }

    func testLinkBeforeStartChecksSetupItself() async {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        let model = make(backend)
        let result = await model.handle(link: join)
        XCTAssertEqual(result, .launched)
        XCTAssertEqual(backend.launches, 1)
    }

    func testLinkIsKeptUntilSetupCompletes() async {
        let backend = FakeBackend(done: [.rosetta, .engine, .prefix])
        let model = make(backend)
        await model.start()
        let result = await model.handle(link: join)
        XCTAssertEqual(result, .deferred)
        XCTAssertEqual(model.pendingLinkKind, .join)
        XCTAssertEqual(backend.launches, 0)
        model.chooseGame(.install)
        await wait { model.phase == .ready && backend.launches == 1 }
        XCTAssertEqual(backend.links, [join.absoluteString])
        XCTAssertNil(model.pendingLinkKind)
    }

    func testFailedLaunchReportsAndLogDoesNotContainLink() async throws {
        let backend = FakeBackend(done: Set(SetupStep.allCases))
        backend.setLaunchError(FakeFailure())
        let model = make(backend)
        await model.start()
        let result = await model.handle(link: join)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(model.notice, Notice("boom", isError: true))
        let log = try String(contentsOf: model.appLog.file, encoding: .utf8)
        XCTAssertTrue(log.contains("join link"))
        XCTAssertFalse(log.contains("7K3M"))
    }
}
