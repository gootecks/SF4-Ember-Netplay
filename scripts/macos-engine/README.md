# macOS engine spike (M0): fresh Wine prefix without Highball

`m0.sh` builds an isolated WoW64 Wine prefix for Ember / Ultra Street Fighter IV on Apple Silicon,
driven only by [`docs/validation/macos-engine-manifest.json`](../../docs/validation/macos-engine-manifest.json).
It never touches Highball's data or processes. `lib.sh` holds the helpers.

## Prerequisites

- Apple Silicon Mac with Rosetta 2 (`softwareupdate --install-rosetta --agree-to-license`); the engine is x86_64.
- About 4 GB free on the internal disk (engine ~1.2 GB + prefix ~0.6 GB + Steam ~1.8 GB; the script aborts below 4 GB, `--force` overrides).
- `jq`, `curl`, `shasum`, `ditto` (stock macOS except `jq`).
- A Steam account that owns Ultra Street Fighter IV (app 45760). No Steam emulators or DRM workarounds.

Root directory: `${EMBER_M0_ROOT:-$HOME/Library/Application Support/Ember-M0}` with `cache/` (downloads),
`engine/<id>/`, `prefix/`, `logs/`. Every step writes `logs/<stamp>-<step>.log` and is idempotent
(a finished step prints "nothing to do").

## Options

`--manifest <file>`, `--cache-from <dir>` (reuse a matching download, e.g. Highball's `downloads/`, copied only if the SHA-256 matches),
`--renderer dxvk|wined3d`, `--hud`, `--debug` (unset WINEDEBUG; see below), `--force`.

## Step order

```sh
scripts/macos-engine/m0.sh --cache-from "$HOME/Library/Application Support/Highball/downloads" all
scripts/macos-engine/m0.sh steam-login            # visible Steam window: log in once, then quit Steam
scripts/macos-engine/m0.sh library /Volumes/Result E   # reuse E:\SteamLibrary (or install: steam://install/45760)
scripts/macos-engine/m0.sh ember-install
scripts/macos-engine/m0.sh game-check
scripts/macos-engine/m0.sh steam-start
scripts/macos-engine/m0.sh launch --hud
```

| Step | What it does |
| --- | --- |
| `engine` | Downloads each component to `cache/`, verifies SHA-256, extracts, applies `engine:` install steps into `engine/<id>.tmp`, clears quarantine xattrs, renames to `engine/<id>`. Any failure deletes the tmp dir. |
| `prefix` | `wineboot -i`, `wineserver -w`, `winecfg /v <windowsVersion>`, applies `prefix:` install steps (DXVK DLLs), `prefix.dllOverrides` under `HKCU\Software\Wine\DllOverrides`, `prefix.registry`; logs the effective env. `--renderer wined3d` skips DXVK and applies the manifest `fallback` block instead. The chosen renderer is stored in `prefix/.ember-m0-prefix` and reused by later steps. A failed build removes the half-made prefix. |
| `steam-install` | Downloads `SteamSetup.exe`, checks the manifest SHA-256 (on mismatch prints expected vs actual: Valve rotates the installer; update the manifest deliberately), runs it with `steam.installArgs`. |
| `library <dir> [letter]` | Symlinks `prefix/dosdevices/<letter>:` to the host dir and adds the library (`<dir>` itself or its child holding `steamapps`) to `libraryfolders.vdf` (backup `.m0bak`, existing entries kept). Refused while our Steam runs, or while Highball's wineserver runs and a Highball bottle maps the same host dir (two Steam clients must not share a library). |
| `steam-login` | Starts Steam with no hidden args, detached, for the one-time interactive login. |
| `steam-start` | Starts Steam with `steam.hiddenArgs`, detached (`nohup` + `disown`, output `logs/<stamp>-steam.log`), then polls `connection_log.txt` for a `[Logged On` state newer than the start offset up to `steam.readyTimeoutSeconds`. |
| `ember-install` | Downloads the Ember zip, verifies SHA-256, `ditto -x -k` to `drive_c/sf4e-<v>.tmp`, flattens a single top-level folder, verifies every file against the zip's `MANIFEST.txt` (`sha256  path` lines, CRLF tolerated), renames to `sf4e-<v>`. Rolls back on failure. |
| `game-check` | Finds `appmanifest_45760.acf` in every library from `libraryfolders.vdf` (Windows paths mapped through `dosdevices`), prints appmanifest `buildid` vs manifest `game.build`, and compares `SSFIV.exe` SHA-256 with `game.ssfivSha256` (prints the computed value when the manifest has `null`). Exits non-zero on mismatch. |
| `launch [--hud]` | Requires Steam logged on; starts `C:\sf4e-<v>\Launcher.exe` detached so `sf4-net.exe` and `ember-discord.exe` outlive the shell. `--hud` sets `DXVK_HUD=fps,frametimes` and `MTL_HUD_ENABLED=1`. |
| `status` | Engine/prefix/Steam state, wine processes of this prefix only (found via `WINEPREFIX` in the process environment), tail of `launcher.log` and `sf4e.log`. |
| `kill` | `WINEPREFIX=<ours> wineserver -k` only. |

## Measuring fps / frame time

Use the same scene in both environments (for example Training mode, same stage, 2 minutes idle plus 2 minutes of inputs), windowed 1280x720.

**This prefix.** `m0.sh launch --hud`. DXVK's HUD shows fps and a frametime graph; the Metal HUD (`MTL_HUD_ENABLED=1`) shows GPU frame
timing and memory. Record by screen capture (`Cmd+Shift+5`, 120 s) and read min/avg fps and frametime spikes from the video. To compare renderers,
build a second root: `EMBER_M0_ROOT=$HOME/Library/Application\ Support/Ember-M0-wd3d m0.sh --renderer wined3d all` and repeat.

**Highball bottle.** Quit Steam in the Highball bottle's UI, start a session so Highball's log header shows its env and sync mode
(`~/Library/Application Support/Highball/logs/<stamp>-Games-<exe>.log`), and launch Ember there with the same HUD variables set in the bottle's
environment (`DXVK_HUD=fps,frametimes`, `MTL_HUD_ENABLED=1`; set in Highball's per-app config, never by editing the bottle by hand). Capture the same scene the same way.

Never run both environments at once with the same Steam library (see `library`) and note sync mode (`WINEMSYNC`) and renderer in the results.

## Manifest assumptions

- `engine.wine/wineserver/wineboot` are paths relative to `engine/<id>/`. `wineboot` is null (the Wine archive has no `bin/wineboot`), so the prefix is initialised with `wine wineboot -i`.
- `install[].from` is a path inside the archive (Wine's content is under `wswine.bundle/`). A file `from` has a `to` that is the full destination file path; a directory `from` has its contents copied into `to`. `engine:.` is the engine root, `prefix:` paths are relative to `WINEPREFIX`. Symlinks are copied as symlinks. A missing `from` is a hard error.
- Components sharing a URL (runtime-frameworks, moltenvk, dxvk all come from `Template-1.0.11.tar.xz`) are downloaded once (cache) and extracted once per run.
- `components[].url` file names are the cache names; `ember.asset` names the Ember zip.

## Environment for every wine call

Derived from the engine root (not in the manifest): `DYLD_FALLBACK_FRAMEWORK_PATH=<engine>/frameworks`,
`DYLD_FALLBACK_LIBRARY_PATH=<engine>/frameworks:<engine>/frameworks/GStreamer.framework/Versions/1.0/lib` (plus `<engine>/lib` if present),
`GST_PLUGIN_PATH=<engine>/frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0`. The script sets `WINEDEBUG=-all` first, then the manifest
`prefix.env` (which sets `WINEDEBUG=fixme-all`) overrides it, so `fixme-all` is the effective default. `--debug` unsets `WINEDEBUG` (Wine's default
debug channels). With `--renderer wined3d` the manifest `fallback.env` is used instead of `prefix.env`, and `fallback.dllOverrides` (`d3d9=builtin`) instead
of `prefix.dllOverrides`; the `dxvk` component's prefix files are not installed and `dxvk.conf` is not written.

`prefix` also creates `drive_c/ember/logs/` and (DXVK only) `drive_c/ember/dxvk.conf` (`DXVK_CONFIG_FILE=C:\ember\dxvk.conf`, `DXVK_LOG_PATH=C:\ember\logs`):

```
dxvk.enableAsync = True
[SSFIV.exe]
d3d9.maxFrameLatency = 1
```
