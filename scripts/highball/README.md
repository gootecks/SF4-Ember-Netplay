# Ember on macOS through the Highball CLI

Part of #47. Ember runs on Highball's engine stack. We do not build or patch Wine.
`ember-hb.sh` is a small adapter that builds a pinned `highball` CLI and drives it. Ember itself stays MIT.

## Pins

| Item | Value |
| --- | --- |
| Highball tag | `v0.10.14` |
| Highball commit | `d3ae31779fd6dd93ae3ac15ed9c65518f60357e2` |
| Engine manifest | `x64-sikarugir10.0_6-r23`, copy in `docs/validation/macos-highball-engine-r23.json` |
| Bottle recipe | `scripts/highball/ember-bottle.json` (our own file, MIT) |

The CLI is built with `swift build -c release --product highball` (Swift 6.x, about one minute).
The adapter checks that the checkout is at the pinned commit before it builds.

## Commands

```sh
scripts/highball/ember-hb.sh build-cli      # clone the tag, build, print tag / commit / sha256
scripts/highball/ember-hb.sh setup --steam-from <dir with steam.exe> \
    [--login-from <wine prefix>] [--library <host dir> [letter]]
scripts/highball/ember-hb.sh steam-start    # Steam hidden, waits for SetLoginState: Success
scripts/highball/ember-hb.sh launch         # Ember update check, then highball run
scripts/highball/ember-hb.sh status
scripts/highball/ember-hb.sh kill
```

`setup` does these steps, each one skipped when already done:

1. `highball engine install docs/validation/macos-highball-engine-r23.json` (no D3DMetal licence is accepted).
2. `highball bottle create ember --engine x64-sikarugir10.0_6-r23`.
3. `highball recipe apply ember scripts/highball/ember-bottle.json`, then `bottle set ember dxvkasync 1`.
   The recipe sets: DXMT bottle renderer (SSFIV.exe is D3D9 and goes to DXVK), msync, and the `SSFIV.exe` section
   `d3d9.maxFrameLatency = 1` and `dxvk.enableAsync = True` in the bottle's `dxvk.conf`. It also pins Steam.
4. Steam: `--steam-from` copies a Steam folder into the bottle. `--steam-recipe <steam.json>` runs Highball's own
   Steam recipe instead (Steam's first start then takes 15 to 25 minutes).
   `--login-from <wine prefix>` copies that prefix's `local.vdf` and `MachineGuid` so the copied Steam stays signed in.
5. `--library <host dir> [letter]` maps a drive letter (default `R`) to a Steam library and makes sure
   `libraryfolders.vdf` lists it. App 45760 must be listed before launch, or the game starts as Arcade Edition.
6. Ember: the version in `docs/validation/macos-engine-manifest.json` is downloaded, checked against
   `MANIFEST.txt`, installed to `C:\sf4e-<version>` and pinned. `launch` also installs a newer stable release.

Environment: `EMBER_HB_ROOT` (default `~/Library/Application Support/Ember/highball-cli`), `EMBER_HB_HOME`
(becomes `HIGHBALL_HOME`; default `$EMBER_HB_ROOT/home`), `EMBER_HB_BIN`, `EMBER_HB_BOTTLE`, `EMBER_HB_TAG`, `EMBER_HB_COMMIT`.

All `highball` calls go through the `hb()` function in the script. It always sets `HIGHBALL_HOME`, so the user's own
`~/Library/Application Support/Highball` is never read or written. Recipes and the engine manifest are passed as
explicit paths because the CLI only finds ids in `./recipes` or `../highball-db`.

## Known CLI quirks

- Output is human text only. The adapter parses tab-separated `bottle list`, `engine list`, `pin list` lines.
- `highball run` stays in the foreground until the program exits. The adapter starts it detached.
- `bottle ps` reports `MISMATCH ... sync none` for Ember's processes. The Steam pin carries `WINEMSYNC=0`
  (the Steam UI hangs under msync), and the wineserver that Steam starts keeps that mode for the whole bottle.
- `highball config` writes the user's Highball preferences. Never call it from Ember; use `HIGHBALL_HOME`.
- ARM64 engines need Highball's signed `WineLoader.app`. The x64 engine used here does not.
- Steam may show "Steam Service Error: install service". Press Cancel. The service does not run under Wine and
  USF4 does not need it.

## Licence

Highball is GPL-3.0. Ember is MIT. `highball` is a separate executable that Ember starts as a program
(aggregation). No HighballKit code is linked into Ember.

Each Ember.app release that bundles the CLI must ship:

- Highball's `LICENSE` file (`build-cli` copies it to `$EMBER_HB_ROOT/LICENSE-highball`),
- the tag and commit above,
- a link to the source: <https://github.com/gauthierpiarrette/highball/tree/v0.10.14>.

The engine is downloaded from the URLs and sha256 values in the manifest; its components keep their own licences.
