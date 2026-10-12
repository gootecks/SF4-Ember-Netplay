import XCTest

@testable import EmberKit

final class SteamTests: XCTestCase {
    private func fixture(ssfivSHA: String? = nil, build: Int = 834219) throws -> SteamFixture {
        let f = try SteamFixture.make(ssfivSHA: ssfivSHA, build: build)
        addTeardownBlock { f.cleanup() }
        return f
    }

    func testLoginStateIgnoresOldLines() throws {
        let f = try fixture()
        let s = f.controller()
        try f.writeLoginLog("a SetLoginState: Success\nb SetLoginState: Connecting\n")
        XCTAssertFalse(s.isLoggedOn())
        XCTAssertEqual(s.loginState(), "b SetLoginState: Connecting")
        try f.writeLoginLog("a SetLoginState: Success\n")
        let offset = s.loginLogSize()
        XCTAssertTrue(s.isLoggedOn())
        XCTAssertFalse(s.isLoggedOn(since: offset))
        try f.writeLoginLog("c SetLoginState: Success\n", append: true)
        XCTAssertTrue(s.isLoggedOn(since: offset))
        XCTAssertTrue(s.isLoggedOn(since: 10_000), "an offset past the end (log rotated) rescans from the start")
    }

    func testStartHiddenIgnoresOldSuccessAndTimesOut() async throws {
        let f = try fixture()
        try f.installSteamExe()
        try f.writeLoginLog("old SetLoginState: Success\n")
        let s = f.controller(timeout: 0.3)
        do {
            try await s.startHidden()
            XCTFail("expected timeout")
        } catch let error as SteamError {
            XCTAssertEqual(error, .loginTimeout(seconds: 1, lastState: ""))
            XCTAssertTrue(error.localizedDescription.contains("SetLoginState: Success"))
        }
        let deadline = Date().addingTimeInterval(3)
        while !f.calls().contains("steam.exe -silent -no-browser"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(f.calls().contains("C:\\Program Files (x86)\\Steam\\steam.exe -silent -no-browser"))
    }

    func testStartHiddenSucceedsOnNewLogLine() async throws {
        let f = try fixture()
        try f.installSteamExe()
        try f.writeLoginLog("old SetLoginState: Success\n")
        let s = f.controller(timeout: 5)
        let writer = Task {
            try await Task.sleep(for: .milliseconds(200))
            try f.writeLoginLog("new SetLoginState: Success\n", append: true)
        }
        let outcome = try await s.startHidden()
        try await writer.value
        guard case .ready = outcome else { return XCTFail("expected ready, got \(outcome)") }
    }

    func testStartHiddenNoopWhenRunningAndLoggedOn() async throws {
        let f = try fixture()
        try f.installSteamExe()
        try f.setTasklist("steam.exe 00000010\r\n")
        try f.writeLoginLog("x SetLoginState: Success\n")
        let outcome = try await f.controller().startHidden()
        XCTAssertEqual(outcome, .alreadyReady)
        XCTAssertFalse(f.calls().contains("steam.exe -silent"))
    }

    func testStartHiddenRequiresSteamExe() async throws {
        let f = try fixture()
        do {
            try await f.controller().startHidden()
            XCTFail("expected error")
        } catch let error as SteamError {
            guard case .steamNotInstalled = error else { return XCTFail("\(error)") }
        }
    }

    func testInstallRunsSetupWithManifestArgs() async throws {
        let f = try fixture()
        let s = f.controller()
        let first = try await s.install()
        XCTAssertTrue(first)
        XCTAssertTrue(f.calls().contains("SteamSetup.exe /S"))
        XCTAssertTrue(f.calls().contains("wineserver -w"))
        let second = try await s.install()
        XCTAssertFalse(second)
    }

    func testVDFAddPreservesExistingEntriesAndListsApp() throws {
        let original = """
            "libraryfolders"
            {
            \t"0"
            \t{
            \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
            \t\t"apps"
            \t\t{
            \t\t}
            \t}
            \t"1"
            \t{
            \t\t"path"\t\t"D:\\\\Games"
            \t\t"apps"
            \t\t{
            \t\t\t"45760"\t\t"1234"
            \t\t}
            \t}
            }

            """
        XCTAssertTrue(SteamVDF.containsApp(45760, in: original))
        let result = try XCTUnwrap(SteamVDF.adding(windowsPath: "E:\\", to: original))
        XCTAssertEqual(result.index, 2)
        XCTAssertEqual(
            SteamVDF.libraryPaths(in: result.text),
            ["C:\\Program Files (x86)\\Steam", "D:\\Games", "E:\\"])
        XCTAssertTrue(SteamVDF.containsApp(45760, in: result.text))
        XCTAssertTrue(result.text.contains("\t\t\t\"45760\"\t\t\"1234\""))
        XCTAssertTrue(result.text.hasSuffix("\t}\n}\n"))
        XCTAssertNil(try SteamVDF.adding(windowsPath: "d:\\games\\", to: original))
        XCTAssertThrowsError(try SteamVDF.adding(windowsPath: "E:\\", to: "\"libraryfolders\"\n"))
    }

    func testAddLibraryCreatesAndEditsVDFAndMapsDrive() async throws {
        let f = try fixture()
        try f.installSteamExe()
        try f.makeGameLibrary()
        let s = f.controller(alive: false)
        let first = try await s.addLibrary(host: f.hostLibrary, letter: "e")
        XCTAssertEqual(first, .created(windowsPath: "E:\\"))
        let link = f.paths.prefixDir.appending(path: "dosdevices/e:").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), f.hostLibrary.path)
        let text = try String(contentsOf: f.vdf, encoding: .utf8)
        XCTAssertEqual(SteamVDF.libraryPaths(in: text), ["C:\\Program Files (x86)\\Steam", "E:\\"])
        let again = try await s.addLibrary(host: f.hostLibrary, letter: "E")
        XCTAssertEqual(again, .alreadyRegistered(windowsPath: "E:\\"))
        XCTAssertThrowsError(try SteamVDF.adding(windowsPath: "E:\\", to: "{"))
    }

    func testAddLibraryAppendsToExistingVDFWithBackup() async throws {
        let f = try fixture()
        try f.makeGameLibrary()
        let existing = SteamVDF.newLibraryFolders(adding: "D:\\Other")
        try FileManager.default.createDirectory(at: f.vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try existing.write(to: f.vdf, atomically: true, encoding: .utf8)
        let outcome = try await f.controller(alive: false).addLibrary(host: f.hostLibrary, letter: "F")
        XCTAssertEqual(outcome, .registered(windowsPath: "F:\\", index: 2))
        XCTAssertEqual(try String(contentsOf: f.vdf.appendingPathExtension("m0bak"), encoding: .utf8), existing)
        let paths = SteamVDF.libraryPaths(in: try String(contentsOf: f.vdf, encoding: .utf8))
        XCTAssertEqual(paths, ["C:\\Program Files (x86)\\Steam", "D:\\Other", "F:\\"])
    }

    func testAddLibraryRefusals() async throws {
        let f = try fixture()
        try f.makeGameLibrary()
        try f.setTasklist("steam.exe 00000010\r\n")
        do {
            try await f.controller(alive: true).addLibrary(host: f.hostLibrary)
            XCTFail("steam running should refuse")
        } catch let error as SteamError {
            XCTAssertEqual(error, .steamRunning)
        }
        try f.setTasklist("")
        do {
            try await f.controller(alive: false).addLibrary(host: f.hostLibrary, letter: "C")
            XCTFail("C should refuse")
        } catch let error as SteamError {
            XCTAssertEqual(error, .invalidDriveLetter("C"))
        }
        let bottleDos = f.dir.appending(path: "Highball/bottles/b1/dosdevices")
        try FileManager.default.createDirectory(at: bottleDos, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bottleDos.appending(path: "z:").path, withDestinationPath: f.hostLibrary.path)
        do {
            try await f.controller(alive: false, highball: true).addLibrary(host: f.hostLibrary)
            XCTFail("highball conflict should refuse")
        } catch let error as SteamError {
            guard case .highballConflict = error else { return XCTFail("\(error)") }
        }
        let ok = try await f.controller(alive: false, highball: false).addLibrary(host: f.hostLibrary)
        XCTAssertEqual(ok, .created(windowsPath: "E:\\"))
    }

    func testGameCheckMatch() async throws {
        let f = try fixture()
        try f.makeGameLibrary()
        let s = f.controller(alive: false)
        try await s.addLibrary(host: f.hostLibrary)
        let report = try s.requireGameMatch()
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.libraries.count, 1)
        XCTAssertTrue(report.libraries[0].buildMatches)
        XCTAssertEqual(report.libraries[0].hash, .match)
    }

    func testGameCheckBuildMismatch() async throws {
        let f = try fixture()
        try f.makeGameLibrary(build: 111)
        let s = f.controller(alive: false)
        try await s.addLibrary(host: f.hostLibrary)
        XCTAssertFalse(try s.gameCheck().ok)
        XCTAssertThrowsError(try s.requireGameMatch()) { error in
            guard case .gameMismatch(let detail) = error as? SteamError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("MISMATCH"))
        }
    }

    func testGameCheckShaMismatch() async throws {
        let f = try fixture(ssfivSHA: String(repeating: "a", count: 64))
        try f.makeGameLibrary()
        let s = f.controller(alive: false)
        try await s.addLibrary(host: f.hostLibrary)
        let report = try s.gameCheck()
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.libraries[0].hash, .mismatch(expected: String(repeating: "a", count: 64)))
    }

    func testGameCheckMissingAppManifest() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.controller().gameCheck()) { error in
            XCTAssertEqual(error as? SteamError, .appManifestMissing(appId: 45760))
        }
    }

    private func readyForLaunch(_ f: SteamFixture) throws {
        try f.installSteamExe()
        try f.setTasklist("steam.exe 00000010\r\nsteamwebhelper.exe 00000020\r\n")
        try f.writeLoginLog("x SetLoginState: Success\n")
        try FileManager.default.createDirectory(at: f.vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SteamVDF.newLibraryFolders(adding: "E:\\")
            .replacingOccurrences(of: "\"apps\"\n\t\t{\n\t\t}\n\t}\n}", with: "\"apps\"\n\t\t{\n\t\t\t\"45760\"\t\t\"1\"\n\t\t}\n\t}\n}")
            .write(to: f.vdf, atomically: true, encoding: .utf8)
    }

    func testLaunchPicksNewestVersion() async throws {
        let f = try fixture()
        try readyForLaunch(f)
        try f.makeEmber("sf4e-1.2.0")
        try f.makeEmber("sf4e-1.10.0")
        try f.makeEmber("sf4e-1.9.1")
        try f.makeEmber("sf4e-old", release: "1.3.0")
        XCTAssertEqual(EmberPayloadInstaller.installed(in: f.paths.prefixDir).map(\.version), ["1.2.0", "1.3.0", "1.9.1", "1.10.0"])
        let outcome = try await f.controller().launch(hud: true)
        guard case .launched(let version, let pid) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(version, "1.10.0")
        XCTAssertGreaterThan(pid, 0)
        let deadline = Date().addingTimeInterval(3)
        while !f.calls().contains("Launcher.exe"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(f.calls().contains("wine C:\\sf4e-1.10.0\\Launcher.exe"))
        XCTAssertTrue(f.calls().contains("sf4e-1.10.0 hud=fps,frametimes"))
    }

    func testLaunchRefusesWithoutLogon() async throws {
        let f = try fixture()
        try readyForLaunch(f)
        try f.makeEmber("sf4e-1.1.2")
        try f.writeLoginLog("x SetLoginState: Connecting\n")
        do {
            try await f.controller().launch()
            XCTFail("expected refusal")
        } catch let error as SteamError {
            XCTAssertEqual(error, .notLoggedOn)
        }
        try f.writeLoginLog("x SetLoginState: Success\n")
        try f.setTasklist("")
        do {
            try await f.controller().launch()
            XCTFail("expected refusal")
        } catch let error as SteamError {
            XCTAssertEqual(error, .notLoggedOn)
        }
        XCTAssertFalse(f.calls().contains("Launcher.exe"))
    }

    func testLaunchRefusesWithoutLibraryOrEmber() async throws {
        let f = try fixture()
        try f.installSteamExe()
        try f.setTasklist("steam.exe 1\r\n")
        try f.writeLoginLog("x SetLoginState: Success\n")
        do {
            try await f.controller().launch()
            XCTFail("expected refusal")
        } catch let error as SteamError {
            XCTAssertEqual(error, .libraryNotAdopted(appId: 45760))
        }
        try readyForLaunch(f)
        do {
            try await f.controller().launch()
            XCTFail("expected refusal")
        } catch let error as SteamError {
            XCTAssertEqual(error, .emberNotInstalled)
        }
        try f.setTasklist("steam.exe 1\r\nSSFIV.exe 2\r\n")
        let outcome = try await f.controller().launch()
        XCTAssertEqual(outcome, .alreadyRunning)
    }

    func testKillStopsWineserverOnlyWhenAlive() async throws {
        let f = try fixture()
        await f.controller(alive: false).kill()
        XCTAssertFalse(f.calls().contains("wineserver -k"))
        await f.controller(alive: true).kill()
        XCTAssertTrue(f.calls().contains("wineserver -k"))
        XCTAssertTrue(f.calls().contains("wineserver -w"))
    }

    private func waitForCall(_ f: SteamFixture, _ text: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !f.calls().contains(text), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testLaunchPassesJoinLink() async throws {
        let f = try fixture()
        try readyForLaunch(f)
        try f.makeEmber("sf4e-1.1.2")
        let outcome = try await f.controller().launch(joinLink: "ember://join/7K3M-0X1R-T9PZ")
        guard case .launched = outcome else { return XCTFail("\(outcome)") }
        try await waitForCall(f, "--join-link")
        XCTAssertTrue(f.calls().contains("Launcher.exe --join-link ember://join/7K3M-0X1R-T9PZ"))
    }

    func testLaunchHandsLinkToRunningGame() async throws {
        let f = try fixture()
        try readyForLaunch(f)
        try f.makeEmber("sf4e-1.1.2")
        try f.setTasklist("steam.exe 1\r\nSSFIV.exe 2\r\n")
        let outcome = try await f.controller().launch(joinLink: "ember://join/7K3M-0X1R-T9PZ")
        XCTAssertEqual(outcome, .handedOff)
        try await waitForCall(f, "--join-link")
        XCTAssertTrue(f.calls().contains("Launcher.exe --join-link ember://join/7K3M-0X1R-T9PZ"))
    }

    func testLaunchLogDoesNotContainLink() async throws {
        let f = try fixture()
        try readyForLaunch(f)
        try f.makeEmber("sf4e-1.1.2")
        try f.setTasklist("steam.exe 1\r\nSSFIV.exe 2\r\n")
        let lines = LogRecorder()
        _ = try await f.controller(log: { lines.add($0) }).launch(joinLink: "ember://join/7K3M-0X1R-T9PZ")
        XCTAssertFalse(lines.all().contains { $0.contains("7K3M") })
    }
}
