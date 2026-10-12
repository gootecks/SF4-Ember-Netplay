import EmberKit
import XCTest

@testable import EmberAppCore

final class SettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "ember-app-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testDefaults() {
        let settings = AppSettings.load(defaults: defaults(), environment: [:])
        XCTAssertEqual(settings.dataRoot, EmberPaths.defaultRoot)
        XCTAssertEqual(settings.policy, .latest)
        XCTAssertFalse(settings.hud)
        XCTAssertFalse(settings.rootFromEnvironment)
    }

    func testStoredRootPolicyAndHUD() {
        let d = defaults()
        d.set("/tmp/ember-root", forKey: AppSettings.rootKey)
        d.set("pinned", forKey: AppSettings.policyKey)
        d.set(true, forKey: AppSettings.hudKey)
        let settings = AppSettings.load(defaults: d, environment: [:])
        XCTAssertEqual(settings.dataRoot.path, "/tmp/ember-root")
        XCTAssertEqual(settings.policy, .pinned)
        XCTAssertTrue(settings.hud)
    }

    func testEnvironmentOverridesStoredRootAndIsNotSaved() {
        let d = defaults()
        d.set("/tmp/stored", forKey: AppSettings.rootKey)
        var settings = AppSettings.load(defaults: d, environment: ["EMBER_ROOT": "/tmp/from-env"])
        XCTAssertEqual(settings.dataRoot.path, "/tmp/from-env")
        XCTAssertTrue(settings.rootFromEnvironment)
        settings.hud = true
        settings.save(to: d)
        XCTAssertEqual(d.string(forKey: AppSettings.rootKey), "/tmp/stored")
        XCTAssertTrue(d.bool(forKey: AppSettings.hudKey))
    }

    func testSaveAndClearRoot() {
        let d = defaults()
        var settings = AppSettings(customRoot: URL(filePath: "/tmp/x", directoryHint: .isDirectory), policy: .pinned, hud: true)
        settings.save(to: d)
        XCTAssertEqual(AppSettings.load(defaults: d, environment: [:]), settings)
        settings.customRoot = nil
        settings.save(to: d)
        XCTAssertNil(d.string(forKey: AppSettings.rootKey))
    }

    func testTildeIsExpanded() {
        let settings = AppSettings.load(defaults: defaults(), environment: ["EMBER_ROOT": "~/ember-x"])
        XCTAssertEqual(settings.dataRoot.path, NSHomeDirectory() + "/ember-x")
    }
}
