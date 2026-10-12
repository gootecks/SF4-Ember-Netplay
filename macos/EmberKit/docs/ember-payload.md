# Ember payload install and update

Ports `scripts/macos-engine/ember.sh` (`ember_install`, `ember_update`). The payload is always the unmodified official release zip from `Confetti3/SF4-Ember-Netplay` (`sf4-ember-netplay-<version>.zip`); the room build gate is the SHA of `Sidecar.dll`, so only official binaries interoperate with Windows players.

## API

- `EmberReleaseSource` (protocol): `latest()` and `release(version:)`, each returning an `EmberRelease` (`version`, `assetName`, `url`, `sha256`).
- `GitHubReleaseSource(repo:session:pinned:)`: `/releases/latest` (stable only) or `/releases/tags/v<version>`. The sha256 comes from the asset `digest`; a release without one is refused. When `pinned` (the manifest `ember` section) matches the requested version, the manifest url and sha256 are used with no network call.
- `EmberPayloadInstaller(paths:source:downloader:log:)`
  - `install(version:)`: latest when `nil`, else the pinned version. `install(_ release:)` installs a resolved release.
  - `update()`: installs only if the latest release is newer than every installed `sf4e-*`. Returns `.upToDate`, `.installed`, or `.checkFailed` (lookup failed: offline or rate limited; the installed build still launches). A failed install of a found update throws.
  - `installed()` / `newestInstalled()`: installs with `Launcher.exe`; the version comes from `BUILD_INFO.txt` (`Release:`), falling back to the folder name, because Ember's own updater replaces an install in place.
- `EmberVersion.compare/isNewer`: numeric per dotted token, like `sort -V`.
- Errors: `EmberPayloadError` (own enum), plus `EmberError.sha256Mismatch` from `Downloader` and `.prefixIncomplete` when `drive_c` is missing.

## Install flow

1. `drive_c/sf4e-<version>` with `Launcher.exe` already present: no-op. Present without it: `installDirIncomplete`.
2. `Downloader.fetch` downloads to the cache and checks the zip sha256.
3. `ditto -x -k` into `sf4e-<version>.tmp.x`, `__MACOSX` dropped, a single top-level folder flattened into `sf4e-<version>.tmp`. Staging lives inside `drive_c` so the final rename is atomic on the same volume.
4. Every `MANIFEST.txt` line (`<64 hex>  <path>`, optional `*`, CRLF, `./`, backslashes, top-folder prefix) is hashed. Missing or mismatching files fail; unparsable lines are skipped; zero lines fail; paths escaping the package fail.
5. `Launcher.exe` must exist, then staging is renamed to `sf4e-<version>`.

Any failure removes both staging directories and leaves existing installs untouched (rollback). Older `sf4e-*` folders are never deleted by an update.

## Tests

`Tests/EmberKitTests/PayloadTests.swift` builds fixture zips with `ditto` in a temp dir and uses a fake `EmberReleaseSource`; no network, no real Steam or Ember directories.
