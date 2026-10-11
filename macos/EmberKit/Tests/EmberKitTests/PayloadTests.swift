import CryptoKit
import XCTest

@testable import EmberKit

struct FixtureReleaseSource: EmberReleaseSource {
    var releases: [EmberRelease]
    var failLookup = false

    func latest() async throws -> EmberRelease {
        if failLookup { throw EmberPayloadError.releaseLookupFailed("offline") }
        return releases.max { EmberVersion.compare($0.version, $1.version) < 0 }!
    }

    func release(version: String) async throws -> EmberRelease {
        guard let found = releases.first(where: { $0.version == version }) else {
            throw EmberPayloadError.releaseLookupFailed("no release \(version)")
        }
        return found
    }
}

struct PayloadFixture {
    let dir: URL
    let paths: EmberPaths

    static func make() throws -> PayloadFixture {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "emberpayload-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = EmberPaths(root: dir.appending(path: "root"))
        try FileManager.default.createDirectory(
            at: paths.prefixDir.appending(path: "drive_c"), withIntermediateDirectories: true)
        return PayloadFixture(dir: dir, paths: paths)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func installer(_ releases: [EmberRelease], failLookup: Bool = false) -> EmberPayloadInstaller {
        EmberPayloadInstaller(
            paths: paths, source: FixtureReleaseSource(releases: releases, failLookup: failLookup))
    }

    func release(
        _ version: String, wrapInFolder: Bool = false, corruptManifest: Bool = false,
        shaOverride: String? = nil, includeBuildInfo: Bool = true
    ) throws -> EmberRelease {
        let fm = FileManager.default
        let work = dir.appending(path: "build-\(version)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pkg = work.appending(path: "sf4-ember-netplay-\(version)", directoryHint: .isDirectory)
        try fm.createDirectory(at: pkg.appending(path: "bin"), withIntermediateDirectories: true)
        var files: [String: String] = [
            "Launcher.exe": "launcher \(version)",
            "Sidecar.dll": "sidecar \(version)",
            "ember-discord.exe": "discord \(version)",
            "bin/extra.dat": "extra",
        ]
        if includeBuildInfo { files["BUILD_INFO.txt"] = "Release: \(version)\r\nCommit: abc\r\n" }
        var manifest = ""
        for (path, body) in files.sorted(by: { $0.key < $1.key }) {
            try body.write(to: pkg.appending(path: path), atomically: true, encoding: .utf8)
            let hash = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            manifest += "\(hash)  \(wrapInFolder ? "sf4-ember-netplay-\(version)/" : "")\(path)\r\n"
        }
        if corruptManifest {
            try "tampered".write(to: pkg.appending(path: "Sidecar.dll"), atomically: true, encoding: .utf8)
        }
        try manifest.write(to: pkg.appending(path: "MANIFEST.txt"), atomically: true, encoding: .utf8)

        let archive = dir.appending(path: "sf4-ember-netplay-\(version).zip")
        let args = wrapInFolder ? ["-c", "-k", "--keepParent"] : ["-c", "-k"]
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = args + [pkg.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        try? fm.removeItem(at: work)
        let sha = try Downloader.sha256(of: archive)
        return EmberRelease(
            version: version, assetName: "sf4-ember-netplay-\(version).zip", url: archive,
            sha256: shaOverride ?? sha)
    }

    func sf4eDirs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.prefixDir.appending(path: "drive_c").path)
            .filter { $0.hasPrefix("sf4e-") }.sorted()
    }
}

final class PayloadTests: XCTestCase {
    func testInstallSucceedsAndVerifies() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let release = try fx.release("1.1.1", wrapInFolder: true)
        let result = try await fx.installer([release]).install()
        XCTAssertEqual(result.version, "1.1.1")
        XCTAssertEqual(try fx.sf4eDirs(), ["sf4e-1.1.1"])
        for name in ["Launcher.exe", "Sidecar.dll", "ember-discord.exe", "bin/extra.dat", "MANIFEST.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.directory.appending(path: name).path), name)
        }
        let again = try await fx.installer([release]).install(version: "1.1.1")
        XCTAssertEqual(again, result)
    }

    func testInstallFlatArchive() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let release = try fx.release("1.1.1")
        let result = try await fx.installer([release]).install(version: "1.1.1")
        XCTAssertEqual(result.directory.lastPathComponent, "sf4e-1.1.1")
        XCTAssertEqual(try fx.sf4eDirs(), ["sf4e-1.1.1"])
    }

    func testShaMismatchRollsBackAndKeepsOldVersion() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let old = try fx.release("1.1.1")
        _ = try await fx.installer([old]).install()
        let bad = try fx.release("1.1.2", shaOverride: String(repeating: "0", count: 64))
        do {
            _ = try await fx.installer([old, bad]).install(version: "1.1.2")
            XCTFail("expected sha mismatch")
        } catch let error as EmberError {
            guard case .sha256Mismatch = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try fx.sf4eDirs(), ["sf4e-1.1.1"])
        let installer = fx.installer([old])
        XCTAssertEqual(installer.newestInstalled()?.version, "1.1.1")
    }

    func testManifestMismatchRollsBackAndKeepsOldVersion() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let old = try fx.release("1.1.1")
        _ = try await fx.installer([old]).install()
        let bad = try fx.release("1.1.2", corruptManifest: true)
        do {
            _ = try await fx.installer([old, bad]).install(version: "1.1.2")
            XCTFail("expected manifest mismatch")
        } catch let error as EmberPayloadError {
            XCTAssertEqual(error, .manifestMismatch(["Sidecar.dll"]))
        }
        XCTAssertEqual(try fx.sf4eDirs(), ["sf4e-1.1.1"])
    }

    func testMissingManifestRollsBack() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let release = try fx.release("1.1.1")
        let dirOnly = fx.dir.appending(path: "empty.zip")
        let tmp = fx.dir.appending(path: "nomanifest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "x".write(to: tmp.appending(path: "Launcher.exe"), atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.runChecked("/usr/bin/ditto", ["-c", "-k", tmp.path, dirOnly.path])
        let broken = EmberRelease(
            version: "1.1.3", assetName: "empty.zip", url: dirOnly, sha256: try Downloader.sha256(of: dirOnly))
        do {
            _ = try await fx.installer([release, broken]).install(version: "1.1.3")
            XCTFail("expected missing manifest")
        } catch let error as EmberPayloadError {
            XCTAssertEqual(error, .manifestMissing)
        }
        XCTAssertEqual(try fx.sf4eDirs(), [])
    }

    func testUpdateSkipsWhenInstalledIsNewest() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let r111 = try fx.release("1.1.1")
        let r112 = try fx.release("1.1.2")
        _ = try await fx.installer([r112]).install()
        let result = try await fx.installer([r111, r112]).update()
        XCTAssertEqual(result, .upToDate(installed: "1.1.2", latest: "1.1.2"))
        let older = try await fx.installer([r111]).update()
        XCTAssertEqual(older, .upToDate(installed: "1.1.2", latest: "1.1.1"))
        XCTAssertEqual(try fx.sf4eDirs(), ["sf4e-1.1.2"])
    }

    func testUpgradeFrom111To112() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let r111 = try fx.release("1.1.1")
        let r112 = try fx.release("1.1.2", wrapInFolder: true)
        _ = try await fx.installer([r111]).install()
        let installer = fx.installer([r111, r112])
        let result = try await installer.update()
        guard case .installed(let version, let directory) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(version, "1.1.2")
        XCTAssertEqual(directory.lastPathComponent, "sf4e-1.1.2")
        XCTAssertEqual(try fx.sf4eDirs(), ["sf4e-1.1.1", "sf4e-1.1.2"])
        XCTAssertEqual(installer.newestInstalled()?.version, "1.1.2")
    }

    func testUpdateCheckFailureKeepsInstall() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let r111 = try fx.release("1.1.1")
        _ = try await fx.installer([r111]).install()
        let result = try await fx.installer([r111], failLookup: true).update()
        guard case .checkFailed(_, let installed) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(installed, "1.1.1")
    }

    func testFailedUpdateInstallThrowsAndKeepsOld() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let r111 = try fx.release("1.1.1")
        _ = try await fx.installer([r111]).install()
        let bad = try fx.release("1.1.2", corruptManifest: true)
        do {
            _ = try await fx.installer([r111, bad]).update()
            XCTFail("expected failure")
        } catch is EmberPayloadError {}
        XCTAssertEqual(try fx.sf4eDirs(), ["sf4e-1.1.1"])
    }

    func testRefusesIncompleteExistingDir() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let dest = fx.paths.prefixDir.appending(path: "drive_c/sf4e-1.1.1")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let release = try fx.release("1.1.1")
        do {
            _ = try await fx.installer([release]).install()
            XCTFail("expected failure")
        } catch let error as EmberPayloadError {
            XCTAssertEqual(error, .installDirIncomplete(dest.path))
        }
    }

    func testMissingPrefixFails() async throws {
        let fx = try PayloadFixture.make()
        defer { fx.cleanup() }
        let release = try fx.release("1.1.1")
        try FileManager.default.removeItem(at: fx.paths.prefixDir)
        do {
            _ = try await fx.installer([release]).install()
            XCTFail("expected failure")
        } catch let error as EmberError {
            XCTAssertEqual(error, .prefixIncomplete(path: fx.paths.prefixDir.path))
        }
    }

    func testVersionCompare() {
        XCTAssertTrue(EmberVersion.isNewer("1.1.2", than: "1.1.1"))
        XCTAssertTrue(EmberVersion.isNewer("1.1.10", than: "1.1.9"))
        XCTAssertTrue(EmberVersion.isNewer("1.2", than: "1.1.9"))
        XCTAssertFalse(EmberVersion.isNewer("1.1.1", than: "1.1.1"))
        XCTAssertFalse(EmberVersion.isNewer("1.1.1", than: "1.1.2"))
        XCTAssertEqual(EmberVersion.normalized("v1.1.2"), "1.1.2")
    }

    func testManifestParsing() {
        let h = String(repeating: "a", count: 64)
        let text = "\(h)  top/a.txt\r\n\(h) *./b.txt\n\(h)  dir\\c.txt\nnot a line\nshort  x\n"
        let parsed = EmberPayloadInstaller.parseManifest(text, top: "top").map(\.path)
        XCTAssertEqual(parsed, ["a.txt", "b.txt", "dir/c.txt"])
    }

    func testGitHubReleaseParsing() throws {
        let h = String(repeating: "b", count: 64)
        let json = """
            {"tag_name": "v1.1.3", "assets": [
              {"name": "other.zip", "browser_download_url": "https://x/other.zip", "digest": "sha256:\(h)"},
              {"name": "sf4-ember-netplay-1.1.3.zip", "browser_download_url": "https://x/e.zip", "digest": "sha256:\(h.uppercased())"}
            ]}
            """
        let release = try GitHubReleaseSource.parse(Data(json.utf8))
        XCTAssertEqual(release.version, "1.1.3")
        XCTAssertEqual(release.sha256, h)
        XCTAssertEqual(release.url.absoluteString, "https://x/e.zip")

        let noDigest = """
            {"tag_name": "v1.1.3", "assets": [{"name": "sf4-ember-netplay-1.1.3.zip", "browser_download_url": "https://x/e.zip"}]}
            """
        XCTAssertThrowsError(try GitHubReleaseSource.parse(Data(noDigest.utf8))) {
            XCTAssertEqual($0 as? EmberPayloadError, .digestMissing(tag: "v1.1.3", asset: "sf4-ember-netplay-1.1.3.zip"))
        }
        let noAsset = #"{"tag_name": "v1.1.3", "assets": []}"#
        XCTAssertThrowsError(try GitHubReleaseSource.parse(Data(noAsset.utf8))) {
            XCTAssertEqual($0 as? EmberPayloadError, .assetMissing(tag: "v1.1.3", asset: "sf4-ember-netplay-1.1.3.zip"))
        }
    }

    func testPinnedVersionUsesBundledManifest() async throws {
        let manifest = try EngineManifest.bundled()
        let ember = try XCTUnwrap(manifest.ember)
        let source = GitHubReleaseSource(pinned: ember)
        let release = try await source.release(version: "v\(ember.version)")
        XCTAssertEqual(release.version, ember.version)
        XCTAssertEqual(release.sha256, ember.sha256)
        XCTAssertEqual(release.url.absoluteString, ember.url)
    }
}
