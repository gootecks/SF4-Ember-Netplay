import XCTest

@testable import EmberKit

final class EmberKitTests: XCTestCase {
    func testBundledManifestDecodes() throws {
        let m = try EngineManifest.bundled()
        XCTAssertEqual(m.id, "ember-m0-r23")
        XCTAssertEqual(m.engine.wine, "bin/wine")
        XCTAssertNil(m.engine.wineboot)
        XCTAssertEqual(m.engine.dxvkDllPathPrepend, "renderers/d9vk/wine")
        XCTAssertEqual(m.components.count, 6)
        XCTAssertEqual(m.components[0].install?.first?.to, "engine:.")
        XCTAssertEqual(m.prefix.windowsVersion, "win10")
        XCTAssertEqual(m.prefix.env?["WINEMSYNC"], "1")
        XCTAssertEqual(m.prefix.registry?.count, 4)
        XCTAssertEqual(m.fallback?.renderer, "wined3d")
        XCTAssertEqual(m.steam?.readyTimeoutSeconds, 120)
        XCTAssertEqual(m.ember?.version, "1.1.2")
        XCTAssertEqual(m.game?.steamAppId, 45760)
        XCTAssertNotNil(m.reference)
    }

    func testBundledManifestMatchesDocsCopy() throws {
        let docs = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/validation/m0-manifest-1.1.2-r23.json")
        guard FileManager.default.fileExists(atPath: docs.path) else {
            throw XCTSkip("docs manifest not found at \(docs.path)")
        }
        let bundled = try XCTUnwrap(
            Bundle.module.url(forResource: "m0-manifest-1.1.2-r23", withExtension: "json"))
        XCTAssertEqual(try Data(contentsOf: bundled), try Data(contentsOf: docs))
    }

    func testPathsLayout() {
        let p = EmberPaths(root: URL(filePath: "/tmp/x"))
        XCTAssertEqual(p.engineDir("id").path, "/tmp/x/Engine/id")
        XCTAssertEqual(p.prefixDir.path, "/tmp/x/Prefix")
        XCTAssertEqual(p.cacheDir.path, "/tmp/x/Cache")
        XCTAssertEqual(p.logsDir.path, "/tmp/x/Logs")
    }

    func testShaMismatchLeavesNoEngineAndRemovesStaging() async throws {
        let f = try Fixture.make(sha256Override: String(repeating: "0", count: 64))
        defer { f.cleanup() }
        let installer = EngineInstaller(manifest: f.manifest, paths: f.paths)
        do {
            try await installer.install()
            XCTFail("expected sha mismatch")
        } catch let EmberError.sha256Mismatch(_, expected, actual) {
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual, f.archiveSHA)
        }
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: f.paths.engineDir("fake-engine").path))
        XCTAssertFalse(fm.fileExists(atPath: f.paths.enginesDir.appending(path: "fake-engine.tmp").path))
        let cached = (try? fm.contentsOfDirectory(atPath: f.paths.cacheDir.path)) ?? []
        XCTAssertTrue(cached.isEmpty, "cache should hold no partial or extracted files: \(cached)")
    }

    func testInstallThenSecondInstallIsNoOp() async throws {
        let f = try Fixture.make()
        defer { f.cleanup() }
        let installer = EngineInstaller(manifest: f.manifest, paths: f.paths)
        let first = try await installer.install()
        XCTAssertEqual(first, .installed)
        let engine = f.paths.engineDir("fake-engine")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: engine.appending(path: "bin/wine").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.enginesDir.appending(path: "fake-engine.tmp").path))
        try FileManager.default.removeItem(at: f.archive)
        let second = try await installer.install()
        XCTAssertEqual(second, .alreadyInstalled)
    }

    func testCacheFromReusesArchive() async throws {
        let f = try Fixture.make()
        defer { f.cleanup() }
        let donor = f.dir.appending(path: "donor")
        try FileManager.default.createDirectory(at: donor, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.archive, to: donor.appending(path: f.archive.lastPathComponent))
        try FileManager.default.removeItem(at: f.archive)
        let downloader = Downloader(cacheDir: f.paths.cacheDir, cacheFrom: donor)
        let file = try await downloader.fetch(url: f.archive, sha256: f.archiveSHA)
        XCTAssertEqual(try Downloader.sha256(of: file), f.archiveSHA)
    }

    func testPrefixBuilderIssuesExpectedWineCommands() async throws {
        let f = try Fixture.make()
        defer { f.cleanup() }
        try await EngineInstaller(manifest: f.manifest, paths: f.paths).install()
        let builder = PrefixBuilder(manifest: f.manifest, paths: f.paths, baseEnvironment: ["PATH": "/usr/bin:/bin"])
        let outcome = try await builder.create()
        XCTAssertEqual(outcome, .created)

        let engine = f.paths.engineDir("fake-engine")
        let prefix = f.paths.prefixDir.path
        let dll = engine.appending(path: "renderers/d9vk/wine").path
        let lines = try String(contentsOf: f.callsLog, encoding: .utf8).split(separator: "\n").map(String.init)
        let common = "prefix=\(prefix) msync=1 dllpath=\(dll)"
        XCTAssertEqual(
            lines,
            [
                "wine wineboot -i | \(common) overrides=mscoree,mshtml=",
                "wineserver -w",
                "wine winecfg /v win10 | \(common) overrides=",
                "wineserver -w",
                "wine reg add HKCU\\Software\\Wine\\DllOverrides /v winemenubuilder.exe /d d /f | \(common) overrides=",
                "wine reg add HKCU\\Software\\Wine\\Mac Driver /v LeftCommandIsCtrl /t REG_SZ /d y /f | \(common) overrides=",
                "wine reg add HKCU\\Software\\Wine\\X /ve /t REG_SZ /d z /f | \(common) overrides=",
                "wineserver -w",
            ])

        let marker = try XCTUnwrap(PrefixMarker.read(from: f.paths.prefixMarker))
        XCTAssertEqual(marker.renderer, "dxvk")
        XCTAssertEqual(marker.engine, "fake-engine")
        XCTAssertTrue(marker.created.hasSuffix("Z"))
        let conf = try String(contentsOf: f.paths.prefixDir.appending(path: "drive_c/ember/dxvk.conf"), encoding: .utf8)
        XCTAssertEqual(conf, "dxvk.enableAsync = True\n[SSFIV.exe]\nd3d9.maxFrameLatency = 1\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.prefixDir.appending(path: "drive_c/ember/logs").path))

        let again = try await builder.create()
        XCTAssertEqual(again, .alreadyBuilt(renderer: "dxvk"))
        do {
            try await builder.create(renderer: .wined3d)
            XCTFail("expected renderer mismatch")
        } catch EmberError.prefixRendererMismatch(let existing, _, _) {
            XCTAssertEqual(existing, "dxvk")
        }
    }

    func testPrefixBuilderRemovesPrefixOnFailure() async throws {
        let f = try Fixture.make()
        defer { f.cleanup() }
        try await EngineInstaller(manifest: f.manifest, paths: f.paths).install()
        let wine = f.paths.engineDir("fake-engine").appending(path: "bin/wine")
        try "#!/bin/sh\nmkdir -p \"$WINEPREFIX/drive_c\"\nexit 3\n".write(to: wine, atomically: true, encoding: .utf8)
        let builder = PrefixBuilder(manifest: f.manifest, paths: f.paths, baseEnvironment: ["PATH": "/usr/bin:/bin"])
        do {
            try await builder.create()
            XCTFail("expected failure")
        } catch EmberError.toolFailed(_, let status, _) {
            XCTAssertEqual(status, 3)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.prefixDir.path))
    }

    func testWineEnvironmentMatchesRunWine() throws {
        let f = try Fixture.make()
        defer { f.cleanup() }
        let engine = f.paths.engineDir("fake-engine")
        try FileManager.default.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.dir.appending(path: "src/bundle"), to: engine)
        let env = try Wine(manifest: f.manifest, paths: f.paths, baseEnvironment: ["PATH": "/usr/bin"]).environment()
        XCTAssertEqual(env["WINEPREFIX"], f.paths.prefixDir.path)
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEDLLPATH_PREPEND"], engine.appending(path: "renderers/d9vk/wine").path)
        XCTAssertEqual(env["DYLD_FALLBACK_FRAMEWORK_PATH"], engine.appending(path: "frameworks").path)
        XCTAssertTrue(env["PATH"]!.hasPrefix(engine.appending(path: "bin").path + ":"))
        XCTAssertNil(env["DXVK_CONFIG_FILE"])
    }
}
