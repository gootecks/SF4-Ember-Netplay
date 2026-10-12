# Ember.app

Native SwiftUI macOS app (macOS 14+, arm64, Swift 6) for SF4 Ember Netplay. It is a thin shell over [`../EmberKit`](../EmberKit): everything that touches Wine, Steam or the payload goes through EmberKit.

## Layout

| Target | Purpose |
| --- | --- |
| `EmberAppCore` | testable library: `AppModel` state machine, setup steps, status polling, lifecycle, `EmberBackend` protocol (`LiveBackend` wraps EmberKit), settings, log |
| `Ember` | executable: SwiftUI `App`, views, `NSApplicationDelegate`, single-instance guard, Rosetta admin prompt |
| `Resources/Info.plist` | bundle template (`@VERSION@`, `@BUILD@` substituted by the script) |
| `scripts/build-app.sh` | release build, `.app` assembly, ad-hoc signing, DMG |

## Build and run

```sh
cd macos/EmberApp
swift test
scripts/build-app.sh           # build/Ember.app and build/Ember.dmg
open build/Ember.app
```

Environment for the script: `SCRATCH` (SwiftPM scratch path, default `.build`), `BUILD_DIR`, `EMBER_APP_VERSION`, `EMBER_APP_BUILD`, `SIGN_IDENTITY` (default `-`, ad-hoc). `build/` is git-ignored.

## Behavior

- **Setup wizard**: Rosetta 2, engine, prefix, Steam, Steam login, USF4, Ember payload. Each step is idempotent, shows EmberKit's log lines as progress, and has Retry on error. Skipped when everything is already set up.
- **Steam login** opens visible Steam, waits for a logged-on state, then stops it.
- **USF4**: pick the folder that contains `SteamLibrary` (mapped to a Wine drive with `addLibrary`), or install it with Steam (`installGame`) while the app polls `gameCheck`.
- **Main window**: status rows (engine, prefix, Steam, Ember installed/latest, game, helper), Play, Update Ember, Diagnostics, Open Logs Folder. Status polls every 5 s while the window is visible and only spawns Wine when the wineserver is alive.
- **Quit**: confirms when the game is running. If the app started Steam it kills the whole prefix; otherwise it ends only the Ember processes.
- **Single instance**: a second launch activates the first, forwards any URL, and exits.
- The app log is `<data folder>/Logs/ember-app.log`. Join links are never logged, only their kind.

## Data folder override

Default `~/Library/Application Support/Ember`; change it in Settings (stored in UserDefaults). For testing, override per launch:

```sh
open -n --env EMBER_ROOT=/tmp/ember-test build/Ember.app
build/Ember.app/Contents/MacOS/Ember -EmberRoot /tmp/ember-test
```

## ember:// links

The bundle registers the `ember` URL scheme. A link is pre-filtered with `EmberLink.isAccepted` (the launcher stays the authority), kept pending while setup is incomplete, and otherwise passed to `launch(joinLink:)`. If the game is already running the launcher hands the link to it.

```sh
open 'ember://join/7K3M-0X1R-T9PZ'
```

With a data root that has no prefix this only reaches the "setup required" path and starts no Wine.

## Not yet (M5)

Developer ID signing, hardened runtime, notarization and stapling of the app and DMG, and an app icon. `build-app.sh` has separate `sign` and `package_dmg` functions for that.
