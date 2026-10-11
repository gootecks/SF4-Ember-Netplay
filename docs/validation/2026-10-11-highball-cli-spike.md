# Spike: run Ember through the bundled Highball CLI (#47)

Date: 2026-10-11. Machine: Apple M4, macOS 27, Ember 1.1.2, USF4 (Steam 45760) from an external Steam library.

## Result

Ember and USF4 run in a Highball bottle driven only by the `highball` CLI and `scripts/highball/ember-hb.sh`.
After `launch`, `SSFIV.exe` is up in about 2 s and the Sidecar is initialised about 5 s after the launch command.
The title screen ("ULTRA STREET FIGHTER IV, PRESS START") was seen on screen on the first launch.
The earlier stock-Sikarugir engine needed about 140 s to reach the title (DEP, experiment log section 15).

[INFERENCE] "Time to title" is not measured to the second. Screen capture of the Wine window returned black
(Metal layer) and region capture was covered by other windows, so the numbers above come from process start
and Sidecar log timestamps, plus a person looking at the screen.

## Pins

| Item | Value |
| --- | --- |
| Highball | tag `v0.10.14`, commit `d3ae31779fd6dd93ae3ac15ed9c65518f60357e2` |
| CLI binary | built with `swift build -c release --product highball` in 51 s; sha256 `30baa72f4e0eff7745f9743f6acdf8f63c8686c06d094a633ca55ac0adcd748b` |
| Engine | `x64-sikarugir10.0_6-r23`, manifest `docs/validation/macos-highball-engine-r23.json`, install 25 s |
| `engine list` | `x64-sikarugir10.0_6-r23 wine-10.0 (Sikarugir) renderers: wined3d,dxmt,d3dmetal (licence not accepted),dxvk` |

## Bottle `ember` (HIGHBALL_HOME = `/Volumes/EmberM0/hb-home`, not the user's Highball data)

- Created from `scripts/highball/ember-bottle.json` (own recipe). No USF4 recipe exists in highball-db,
  and `steam.json` installs Steam first, which takes 15 to 25 minutes.
- Renderer `dxmt`. SSFIV.exe is D3D9, so it runs on DXVK. Windows 10, dxvkAsync on.
- DXVK log (`C:\highball\logs\SSFIV_d3d9.log`): `DXVK-Kegworks: v1.10.4-async`, config
  `d3d9.maxFrameLatency = 1`, `dxvk.enableAsync = True`, device `Apple M4`, Vulkan 1.1.334.
- Sync: the bottle asks for msync, but `bottle ps` shows `sync=none` with `MISMATCH` for Steam, Launcher.exe and
  SSFIV.exe. The Steam pin sets `WINEMSYNC=0` and the wineserver Steam starts decides for the whole bottle.
  Not fixed in this spike.
- Steam: APFS clone of the M0 Steam folder. Library `R:\SteamLibrary` is a `dosdevices/r:` symlink to the
  external volume, already listed in `libraryfolders.vdf`.
- Ember 1.1.2 installed by the adapter (4755 files verified against `MANIFEST.txt`) at `C:\sf4e-1.1.2` and pinned.

## Timings (second launch, after Steam was already signed in)

| Event | Time after `launch` |
| --- | --- |
| Steam start to `SetLoginState: Success` (separate command) | 36 to 42 s |
| `SSFIV.exe` process seen | about 2.3 s (first launch) |
| Sidecar "Welcome to sf4e" | about 5 s (13:06:35 after launch at 13:06:30) |
| Overlay: game draws at 1280x720 | 13:06:35.4 |
| Room relay `usw1` connected, UDP, NAT open | 13:06:39.6 |
| CPU of the game process | 200 to 360 % while loading, about 200 % in the title |

Logs: `sf4e.log` in `C:\users\prime\AppData\Roaming\sf4e\logs`, Wine logs in `$HIGHBALL_HOME/logs`.

## Findings

1. Works with the CLI alone. Needed: explicit recipe and manifest paths (the CLI looks in `./recipes` or
   `../highball-db`), `HIGHBALL_HOME` for isolation, and a background start (`highball run` is foreground).
2. Steam login does not carry over with a copied Steam folder alone. It needed the old prefix's
   `AppData/Local/Steam/local.vdf` and the same `HKLM\Software\Microsoft\Cryptography\MachineGuid`
   (value `728774df-...` from the M0 prefix). The user also signed in once by hand, so it is not proven
   which of the two sufficed. `setup --login-from <prefix>` does both copies. A real Ember.app needs its own
   first-run Steam sign-in anyway.
3. Steam shows "Steam Service Error / Install service". Press Cancel. Harmless under Wine (Highball's Steam
   recipe lists it as a known issue). Ember.app should not hide the Steam window on the first run.
4. msync mismatch (see above) means all processes run without msync. Game speed was fine in this test.
5. First sign-in cost 84 s in `steam-start` because of the human step; later starts 36 to 42 s.

## Not done

- `build-cli` (clone from GitHub into `$EMBER_HB_ROOT/src`) was not run end to end. The binary used was
  built by hand from the same tag and commit in `/tmp/hb-v0.10.14`.
- No netplay match was played.
- Clean first-run (`setup` from nothing, with `--steam-recipe`) was not timed.

## Licence

Highball is GPL-3.0 and Ember is MIT. The `highball` CLI stays a separate executable that Ember.app starts.
Each release ships Highball's `LICENSE`, the tag and commit, and a link to
<https://github.com/gauthierpiarrette/highball/tree/v0.10.14>. See `scripts/highball/README.md`.
