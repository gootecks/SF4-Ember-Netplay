# Steam, game check and launch

Swift port of `m0.sh` `steam-install`, `steam-login`, `steam-start`, `library`, `game-check`, `launch` and `kill`. Everything hangs off `SteamController`, built from a `Wine` (manifest + paths + environment).

```swift
let wine = Wine(manifest: manifest, paths: paths)
let steam = SteamController(wine: wine, log: { print($0) })

try await steam.install()                 // SteamSetup.exe (manifest steam.sha256, installArgs) in the prefix
try await steam.login()                   // visible steam.exe, user logs in once
try await steam.addLibrary(host: dir, letter: "E")   // only while Steam is stopped
try await steam.startHidden()             // steam.exe + hiddenArgs, waits for SetLoginState: Success
try steam.requireGameMatch()              // build + SSFIV.exe SHA-256
try await steam.launch()                  // newest C:\sf4e-*\Launcher.exe, detached
await steam.kill()                        // wineserver -k, then -w
```

## Mapping to m0.sh

| m0.sh | EmberKit |
| --- | --- |
| `step_steam_install` | `SteamController.install()` |
| `step_steam_login` | `login()` |
| `step_steam_start` | `startHidden()` -> `SteamStartOutcome` |
| `steam_running`, `steam_logged_on`, `conn_state` | `isRunning()`, `isLoggedOn(since:)`, `loginState(since:)` |
| `step_library`, `highball_conflict`, `vdf_block` | `addLibrary(host:letter:)`, `SteamVDF` |
| `step_game_check` | `gameCheck()` / `requireGameMatch()` |
| `step_launch` | `launch(hud:)` |
| `step_kill` | `kill()` |
| `ember_installs`, `ember_newest` | `EmberInstall.installed(in:)`, `.newest(in:)` |

## Readiness

`startHidden()` spawns `C:\Program Files (x86)\Steam\steam.exe <hiddenArgs>` detached (log `Logs/<stamp>-steam.log`), then polls `steamui_login.txt` every `pollInterval` seconds (default 1). Only bytes after the log size recorded before the spawn are scanned, so a `SetLoginState: Success` from an earlier session never counts; the offset resets to 0 when the log shrinks. Timeout is `steam.readyTimeoutSeconds` (override with `readyTimeout:`); on expiry `SteamError.loginTimeout` carries the last `SetLoginState:` line. If Steam is already running and logged on, nothing happens; if running but not logged on, it only waits.

## Process checks

"Running" means the prefix's wineserver is alive and `wine tasklist` lists `steam.exe` (case-insensitive substring, as in the shell). Wineserver liveness is `lsof -t` on `/tmp/.wine-<uid>/server-<dev>-<inode>/lock`, with dev/inode of the prefix directory in hex. Tests replace it with `serverAlive:`.

## Library

`addLibrary` refuses when:

- Highball's wineserver runs (`pgrep -f 'Highball/engines/.*/wineserver'`) and any `Highball/bottles/*/dosdevices/*` symlink resolves to the same host directory (`SteamError.highballConflict`);
- our Steam is running (`steamRunning`);
- the letter is not A-Y or is C; or the letter already maps elsewhere.

It symlinks `dosdevices/<letter>:` to the host directory, picks the library (`.` when the directory has `steamapps`, otherwise the first child that has it, preferring one holding `appmanifest_45760.acf`), and creates or edits `steamapps/libraryfolders.vdf`. A new entry is inserted before the last closing brace with the next free index; existing entries are untouched; the first edit keeps `libraryfolders.vdf.m0bak`. Paths already registered (case-insensitive, trailing backslash ignored) are skipped. Without a library listing app 45760, USF4 boots as Arcade Edition; `launch()` refuses with `libraryNotAdopted` in that case.

## Game check

For the Steam folder and every library in the VDF (mapped through `dosdevices`), `gameCheck()` reads `appmanifest_<appid>.acf` and compares `buildid` with `game.build`, then hashes `steamapps/common/<installdir>/SSFIV.exe` against `game.ssfivSha256` (empty means not pinned). `GameCheckReport.ok` needs every found library to pass; `requireGameMatch()` throws `SteamError.gameMismatch` with per-library detail. No `appmanifest` anywhere is `appManifestMissing`.

## Launch

`launch()` requires a built prefix, Steam running and logged on (`notLoggedOn`), a VDF mentioning the app id, and an Ember install. If `SSFIV.exe` already runs it returns `.alreadyRunning`. Otherwise it spawns `C:\sf4e-<version>\Launcher.exe` detached with that directory as cwd (log `Logs/<stamp>-launcher-wine.log`); `hud: true` sets `DXVK_HUD=fps,frametimes` and `MTL_HUD_ENABLED=1`. Installs are `drive_c/sf4e-*` folders with a `Launcher.exe`; the version is `Release:` from `BUILD_INFO.txt` or the folder suffix, ordered numerically (`1.10.0` > `1.9.1`). Downloading and updating Ember is the payload installer's job, not this file's.

## Tests

`SteamTests` uses a fake `wine` (logs its arguments to `calls.log`, prints `tasklist.txt` for `tasklist`, creates `steam.exe` for `SteamSetup.exe`), a prefilled cache for `SteamSetup.exe`, and fixture Steam files in a temp directory.
