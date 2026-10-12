import XCTest

@testable import EmberKit

final class GameInstallTests: XCTestCase {
    private func fixture() throws -> SteamFixture {
        let f = try SteamFixture.make()
        addTeardownBlock { f.cleanup() }
        return f
    }

    private func waitForCall(_ f: SteamFixture, _ text: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !f.calls().contains(text), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testInstallGameSpawnsSteamWithInstallURL() async throws {
        let f = try fixture()
        try f.installSteamExe()
        try await f.controller().installGame()
        try await waitForCall(f, "steam://install/45760")
        XCTAssertTrue(f.calls().contains("steam.exe steam://install/45760"))
    }

    func testInstallGameNeedsSteam() async throws {
        let f = try fixture()
        do {
            try await f.controller().installGame()
            XCTFail("expected refusal")
        } catch let error as SteamError {
            guard case .steamNotInstalled = error else { return XCTFail("\(error)") }
        }
    }

    func testStopEmberKillsOnlyEmberProcesses() async throws {
        let f = try fixture()
        try await f.controller().stopEmber()
        let calls = f.calls()
        for name in SteamController.emberProcessNames {
            XCTAssertTrue(calls.contains("wine taskkill /F /IM \(name)"), name)
        }
        XCTAssertFalse(calls.contains("steam.exe"))
        XCTAssertFalse(calls.contains("wineserver -k"))
    }

    func testStopEmberDoesNothingWithoutWineserver() async throws {
        let f = try fixture()
        try await f.controller(alive: false).stopEmber()
        XCTAssertFalse(f.calls().contains("taskkill"))
    }
}
