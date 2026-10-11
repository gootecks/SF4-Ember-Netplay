# EmberKit

Swift package (tools 6.0, macOS 14+, no third-party dependencies) that installs the pinned Wine engine and builds the Wine prefix for Ember on macOS. It is the Swift port of the `engine` and `prefix` steps of `scripts/macos-engine/m0.sh`, driven by the same manifest. MIT licensed.

The engine and prefix steps never touch the Windows payload; it is always the unmodified official Confetti3 release, installed separately by `EmberPayloadInstaller`.

## Layout on disk

`EmberPaths(root:)` defaults to `~/Library/Application Support/Ember`:

| Path | Purpose |
| --- | --- |
| `Engine/<manifest id>` | installed engine (`bin/wine`, `frameworks`, `lib`, `renderers`) |
| `Prefix` | Wine prefix (`WINEPREFIX`), marker file `.ember-m0-prefix` |
| `Cache` | verified downloads (`extract.*` scratch dirs are removed after use) |
| `Logs` | log files |

## API

```swift
EmberPaths(root: URL = EmberPaths.defaultRoot)   // engineDir(_:), prefixDir, cacheDir, logsDir, enginesDir, prefixMarker

EngineManifest.bundled() throws -> EngineManifest      // shipped r23 manifest
EngineManifest.load(from: URL) / .decode(Data)         // Codable; reference is raw JSONValue

Downloader(cacheDir:, cacheFrom: URL? = nil, session:, log:)
    .fetch(url: URL, sha256: String, fileName: String? = nil) async throws -> URL
    Downloader.sha256(of: URL) throws -> String

EngineInstaller(manifest:, paths:, downloader: = nil, log:)
    .install() async throws -> InstallOutcome         // .installed | .alreadyInstalled

PrefixBuilder(manifest:, paths:, downloader: = nil, baseEnvironment:, log:)
    .create(renderer: Renderer? = nil, debugWine: Bool = false) async throws -> PrefixOutcome
    // .created | .alreadyBuilt(renderer:)

Wine(manifest:, paths:, renderer: = .dxvk, debug: = false, baseEnvironment:)
    .environment(extra:) throws -> [String: String]
    .run(_ args: [String], executable:, extraEnvironment:, currentDirectory:, check:) async throws -> ProcessResult
    .waitWineserver() async throws
    .killServer() async
    .spawn(_ args: [String], logFile: URL, ...) throws -> Int32   // detached

ProcessRunner.run / runChecked / spawnDetached                      // async, env, cwd, stdout/stderr capture

EmberError                                                          // typed LocalizedError enum
```

`Renderer` is `.dxvk` (default) or `.wined3d` (the manifest `fallback` block).

### Steam, launch and game check (`docs/steam-launch.md`)

```swift
SteamController(wine:, downloader: = nil, highballDir:, ...)
    .install() / .login() / .startHidden() async throws       // Steam in the prefix, hidden start, login state
    .gameCheck() throws -> GameCheckReport / .requireGameMatch()
    .launch(hud: Bool = false) async throws -> LaunchOutcome  // newest installed Ember
    .tasklist() / .emberProcesses() / .kill() async

SteamError                                                      // typed LocalizedError enum
```

See [docs/steam-launch.md](docs/steam-launch.md).

### Ember payload (`docs/ember-payload.md`)

```swift
EmberPayloadInstaller(paths:, source: any EmberReleaseSource, downloader: = nil, log:)
    .install(version: String? = nil) async throws -> InstalledEmber
    .update() async throws -> EmberUpdateResult                // .upToDate | .installed | .checkFailed
    .installed() / .newestInstalled()                          // instance, for the configured prefix
    EmberPayloadInstaller.installed(in: URL) / .newest(in: URL) // shared listing, also used by SteamController.launch

GitHubReleaseSource(repo:, session:, pinned:)                  // latest() / release(version:)
EmberVersion.compare / isNewer                                  // numeric per dotted token, 1.10.0 > 1.9.1
EmberPayloadError
```

Versions come from `BUILD_INFO.txt` (`Release:`) with the `sf4e-<version>` folder name as fallback. See [docs/ember-payload.md](docs/ember-payload.md).

### Diagnostics (`docs/diagnostics.md`)

```swift
DiagnosticsBundle.create(paths:, manifest:, to: URL, ...)       // support bundle; secrets and Steam login files are denied
DiagnosticsBundle.isDenied(_ name: String) -> Bool
```

See [docs/diagnostics.md](docs/diagnostics.md).

## Behavior

- **Engine install**: each component with `engine:` install steps is downloaded, sha256-checked, extracted (`/usr/bin/tar` for `tar.xz`/`tar.gz`, `/usr/bin/ditto` for `zip`; an archive is extracted once per sha256), and its `from` paths are copied with `cp -Rpf` into a `Engine/<id>.tmp` staging dir. After a `bin/wine` check and `xattr -dr com.apple.quarantine`, the staging dir is moved atomically to `Engine/<id>`. Any failure removes the staging dir; a second call with a working engine is a no-op.
- **Download**: a cached file with the right hash is reused; otherwise `cacheFrom/<file>` is copied if its hash matches; otherwise the URL is fetched (3 attempts) into `<file>.part` and renamed only after the hash matches.
- **Prefix**: `wineboot -i` (with `WINEDLLOVERRIDES=mscoree,mshtml=`), `winecfg /v <windowsVersion>`, `C:\ember\logs` and `C:\ember\dxvk.conf` (dxvk only), prefix components, DLL overrides and registry through `reg add`, `wineserver -w`, then the marker. On failure the wineserver is killed and the prefix directory removed. A marker means a no-op; a different requested renderer is an error.
- **Wine environment** (same as `wine_env` in `lib.sh`): `WINEPREFIX`, `WINEDEBUG=-all` (overridden by manifest env, dropped when `debug`), engine `bin` first on `PATH`, `DYLD_FALLBACK_FRAMEWORK_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, `GST_PLUGIN_PATH`, then `prefix.env` (dxvk) or `fallback.env` (wined3d). For dxvk, `WINEDLLPATH_PREPEND` is `<engine>/<engine.dxvkDllPathPrepend>` and `i386-windows/d3d9.dll` must exist.

## Mapping to m0.sh

| m0.sh / lib.sh | EmberKit |
| --- | --- |
| `step_engine` | `EngineInstaller.install()` |
| `fetch_verified`, `--cache-from` | `Downloader.fetch`, `cacheFrom` |
| `install_component`, `extract_archive`, `copy_item` | internal `ComponentInstaller` |
| `step_prefix` | `PrefixBuilder.create()` |
| marker `.ember-m0-prefix` (`renderer=`, `engine=`, `created=`) | `PrefixMarker` |
| `wine_env`, `run_wine`, `wait_wineserver` | `Wine.environment`, `run`, `waitWineserver` |
| `spawn_detached` | `ProcessRunner.spawnDetached`, `Wine.spawn` |
| `MANIFEST` | `EngineManifest.bundled()` |

The Windows payload is installed by `EmberPayloadInstaller`; Steam, game check, launch and diagnostics are covered above.

## Manifest copy

`Sources/EmberKit/Resources/m0-manifest-1.1.2-r23.json` is a byte copy of `docs/validation/m0-manifest-1.1.2-r23.json`. Keep them in sync; `testBundledManifestMatchesDocsCopy` fails when they differ.

## Tests

```sh
cd macos/EmberKit && swift test
```

Tests use a local fake engine archive (fake `wine` and `wineserver` shell scripts) in a temp dir and never touch the real Ember or Highball directories.
