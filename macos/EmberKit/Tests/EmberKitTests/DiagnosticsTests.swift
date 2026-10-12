import XCTest

@testable import EmberKit

final class DiagnosticsTests: XCTestCase {
    private var fixture: Fixture!

    override func setUpWithError() throws {
        fixture = try Fixture.make()
    }

    override func tearDown() {
        fixture.cleanup()
    }

    private func put(_ rel: String, _ text: String, under base: URL? = nil) throws {
        let url = (base ?? fixture.paths.root).appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func entries(_ zip: URL) async throws -> [String] {
        let result = try await ProcessRunner.runChecked("/usr/bin/unzip", ["-Z1", zip.path])
        return result.stdout.split(separator: "\n").map { String($0.split(separator: "/", maxSplits: 1).last ?? "") }
    }

    private func read(_ zip: URL, _ entry: String) async throws -> String {
        let list = try await ProcessRunner.runChecked("/usr/bin/unzip", ["-Z1", zip.path])
        let full = try XCTUnwrap(list.stdout.split(separator: "\n").map(String.init).first { $0.hasSuffix("/" + entry) })
        return try await ProcessRunner.runChecked("/usr/bin/unzip", ["-p", zip.path, full]).stdout
    }

    private func populate() throws {
        let p = fixture.paths
        try put("Logs/20260101-prefix.log", "emberkit", under: p.root)
        try put("Prefix/\(PrefixMarker.fileName)", "renderer=dxvk\nengine=fake\ncreated=now\n")
        try put("Prefix/drive_c/ember/wine.log", "wine")
        try put("Prefix/drive_c/ember/logs/SSFIV.exe_d3d9.log", "dxvk")
        let roaming = "Prefix/drive_c/users/steamuser/AppData/Roaming/sf4e/logs"
        try put("\(roaming)/sf4e.log", "sf4e")
        try put("\(roaming)/sf4e-1.log", "sf4e1")
        try put("\(roaming)/session-42.log", "session")
        try put("\(roaming)/launcher.log", "launcher")
        try put("\(roaming)/other.log", "other")
        let steam = "Prefix/drive_c/Program Files (x86)/Steam"
        try put("\(steam)/logs/connection_log.txt", "conn")
        try put("\(steam)/logs/steamui_login.txt", "login")
        try put("\(steam)/config/config.vdf", "SECRET-CONFIG")
        try put("\(steam)/config/loginusers.vdf", "SECRET-LOGIN")
        try put("\(steam)/ssfn1234567890", "SECRET-SSFN")
        try put("\(steam)/local.vdf", "SECRET-LOCAL")
        try put("\(steam)/logs/identity_token.txt", "SECRET-TOKEN")
    }

    func testBundleContainsExpectedEntries() async throws {
        try populate()
        let out = fixture.dir.appending(path: "out/bundle.zip")
        let result = try await DiagnosticsBundle.create(paths: fixture.paths, manifest: fixture.manifest, to: out)
        XCTAssertEqual(result, out)
        let names = try await entries(out)
        for expected in [
            "emberkit-logs/20260101-prefix.log", "wine/wine.log", "wine/SSFIV.exe_d3d9.log",
            "ember/steamuser/sf4e.log", "ember/steamuser/sf4e-1.log", "ember/steamuser/session-42.log",
            "ember/steamuser/launcher.log", "steam/connection_log.txt", "steam/steamui_login.txt",
            "manifest.json", "prefix-marker.txt", "system-info.txt", "summary.txt",
        ] {
            XCTAssertTrue(names.contains(expected), "missing \(expected) in \(names)")
        }
        XCTAssertFalse(names.contains("ember/steamuser/other.log"))
        let manifest = try await read(out, "manifest.json")
        XCTAssertTrue(manifest.contains("fake-engine"))
        let info = try await read(out, "system-info.txt")
        XCTAssertTrue(info.contains("hw.memsize"))
        XCTAssertTrue(info.contains("uname -m"))
    }

    func testDeniedFilesExcluded() async throws {
        try populate()
        try put("Logs/ssfn999", "SECRET-SSFN")
        try put("Logs/sub/local.vdf", "SECRET-LOCAL")
        try put("Logs/refresh_token.log", "SECRET-TOKEN")
        let out = fixture.dir.appending(path: "bundle.zip")
        _ = try await DiagnosticsBundle.create(paths: fixture.paths, manifest: fixture.manifest, to: out)
        let names = try await entries(out)
        for denied in ["ssfn", "local.vdf", "config.vdf", "loginusers.vdf", "token", "identity"] {
            XCTAssertFalse(names.contains { $0.lowercased().contains(denied) }, "\(denied) leaked: \(names)")
        }
        let all = try await ProcessRunner.runChecked("/usr/bin/unzip", ["-p", out.path])
        XCTAssertFalse(all.stdout.contains("SECRET"))
        let summary = try await read(out, "summary.txt")
        XCTAssertTrue(summary.contains("Skipped (deny list) (3)"), summary)
    }

    func testLargeLogTruncatedToTail() async throws {
        try populate()
        let big = String(repeating: "a", count: 3000) + String(repeating: "b", count: 1000)
        try put("Prefix/drive_c/ember/logs/big_d3d9.log", big)
        let out = fixture.dir.appending(path: "bundle.zip")
        _ = try await DiagnosticsBundle.create(
            paths: fixture.paths, manifest: fixture.manifest, to: out, maxLogBytes: 1000)
        let body = try await read(out, "big_d3d9.log")
        XCTAssertEqual(body, String(repeating: "b", count: 1000))
        let summary = try await read(out, "summary.txt")
        XCTAssertTrue(summary.contains("wine/big_d3d9.log"))
        XCTAssertTrue(summary.contains("Truncated to last 1000 bytes (1)"), summary)
    }

    func testDefaultCapIsFiveMegabytes() {
        XCTAssertEqual(DiagnosticsBundle.defaultMaxLogBytes, 5 * 1024 * 1024)
    }

    func testMissingItemsListedAndBundleStillBuilt() async throws {
        try put("Logs/only.log", "x")
        let out = fixture.dir.appending(path: "bundle.zip")
        _ = try await DiagnosticsBundle.create(paths: fixture.paths, manifest: fixture.manifest, to: out)
        let names = try await entries(out)
        XCTAssertTrue(names.contains("only.log") || names.contains("emberkit-logs/only.log"))
        let summary = try await read(out, "summary.txt")
        XCTAssertTrue(summary.contains("Wine/DXVK logs"), summary)
        XCTAssertTrue(summary.contains("Ember logs"), summary)
        XCTAssertTrue(summary.contains("connection_log.txt"), summary)
        XCTAssertTrue(summary.contains("steamui_login.txt"), summary)
        XCTAssertTrue(summary.contains("prefix marker"), summary)
        XCTAssertFalse(names.contains("prefix-marker.txt"))
    }

    func testMissingEmberKitLogsDirListed() async throws {
        let out = fixture.dir.appending(path: "bundle.zip")
        _ = try await DiagnosticsBundle.create(paths: fixture.paths, manifest: fixture.manifest, to: out)
        let summary = try await read(out, "summary.txt")
        XCTAssertTrue(summary.contains("EmberKit logs"), summary)
    }
}
