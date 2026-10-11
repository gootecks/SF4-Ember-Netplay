# Spike: run Ember on Highball's r23 engine through the existing M0 flow (#47)

Date: 2026-10-11. Machine: Apple M4, macOS 27, Ember 1.1.2, USF4 (Steam 45760) from an external Steam library.

## Decision

An earlier attempt drove Ember through a Highball bottle with a new adapter (`scripts/highball/ember-hb.sh`). That adapter
was removed. Ember keeps the working `scripts/macos-engine` flow (`m0.sh --manifest <m> kill | steam-start | launch`,
`EMBER_M0_ROOT=/Volumes/EmberM0`, msync on, DXVK d9vk path via `WINEDLLPATH_PREPEND`, prefix and Steam unchanged).
Only the engine changes, to Highball's `x64-sikarugir10.0_6-r23`
(manifest copy: `docs/validation/macos-highball-engine-r23.json`).

## Manifest

`docs/validation/m0-manifest-1.1.2-r23.json`, id `ember-m0-r23`. Differences from the `hbpatch` manifest
(`ember-m0-hbpatch-test`, which overlaid Highball r22 files by hand):

| Part | hbpatch | r23 |
| --- | --- | --- |
| wine | Sikarugir 10.0 rev 6 | same archive and sha256 |
| `bin/wineserver`, `ntdll.so` | Highball r22 files (`ntdll.so` is the `wine10-dep` build, sha256 `089dc7b4...`) | `wine10-msync-20261001` (url and sha256 from the r23 manifest). `ntdll.so` is msync-only, sha256 `e0954d3f...` |
| `winemac.so` | Highball focus and retina build | `winemac-focus-20261006` (same bytes, `b8be9bfc...`) |
| runtime frameworks, DXVK-Kegworks 1.10.4 d9vk | Template-1.0.11 | same |
| MoltenVK | stock 1.4.1 from the Template | 1.4.1 shadow-import rebuild (off unless `MVK_SHADOW_IMPORT=1`) |
| `reference.highball.engineId` | r22 | r23 |
| `highballOnlyPatchesNotReproduced` | five items | only `libhbaudiobuf.dylib` (r23 ships it, but Highball inserts it with `DYLD_INSERT_LIBRARIES` from the bottle environment; the M0 flow has no such step) |

`prefix`, `steam`, `ember`, `game`, `fallback` and `engine` sections are unchanged. No change to `scripts/macos-engine` was needed:
`m0.sh --manifest <r23> --cache-from /Volumes/EmberM0/hb-home/downloads engine` built `/Volumes/EmberM0/engine/ember-m0-r23` in 17 s
from the pinned URLs (patch archives were copied from the earlier spike's download cache after the sha256 matched).
`wineserver` and `winemac.so` hashes equal Highball's installed r23 engine; so does `ntdll.so`.

## Result

The game runs on r23 through the M0 flow. Sequence: `kill`, `steam-start`, 45 s wait, `launch`.

| Check | Evidence |
| --- | --- |
| Engine | `SSFIV.exe` maps `/Volumes/EmberM0/engine/ember-m0-r23/renderers/d9vk/wine/i386-windows/d3d9.dll` and `.../frameworks/libMoltenVK.dylib`; the prefix's wineserver is `/Volumes/EmberM0/engine/ember-m0-r23/bin/wineserver` |
| DXVK | `SSFIV_d3d9.log`: `DXVK-Kegworks: v1.10.4-async`, `Found config file: C:\ember\dxvk.conf`, `d3d9.maxFrameLatency = 1`, `dxvk.enableAsync = True` |
| msync | the launch log's effective environment lists `WINEMSYNC=1`, `WINEDLLPATH_PREPEND=.../ember-m0-r23/renderers/d9vk/wine`, `WINEPREFIX=/Volumes/EmberM0/prefix`. [INFERENCE] The process environment itself cannot be read from `ps` on macOS. |
| Sidecar | `launcher.log`: `CreateSF4Process received Sidecar sync signal` 1.6 s after `resumed`; `sf4e.log`: `GGPO: battle ticks run on thread`, `Room: network relay=usw1 connected=true udp=true nat=open` |
| Note | `steam-start` printed `did not reach 'SetLoginState: Success' within 120s`; `launch` then passed its own login check and Ember and the game started |

## Time to title (method of experiment log section 15)

A screen watcher (`/tmp/ssfiv-watch.py`) logs the mean luminance of the `SSFIVAE` window once a second.
The watcher was started about 28 s after the `launch` command (the first attempt to start it failed because `python3` lacked Quartz; it was
started with `uv run --with pyobjc-framework-Quartz --with pillow`), so times below are the watcher time plus 28 s.
The window appeared at the launch (Sidecar sync at 13:19:01.9, launch at 13:18:57).

| Event | After `launch` |
| --- | --- |
| Window black (luminance about 2) | 0 to about 75 s |
| First image (luminance 3.5 to 4) | about 75 s |
| Picture fading in (luminance 51) | about 115 s |
| Title bright (luminance above 100) | about 140 s |
| SSFIV CPU | about 205 % while black and loading, 150 to 290 % while the picture fades in |

This is the same as the stock engine in section 15 (watch6: first image 17 s, title bright 140 s, CPU about 205 %), and about seven times slower
than the hbpatch engine (watch5/watch9: bright at 18 to 20 s). The r23 `ntdll.so` is the msync-only build, which section 15 measured as
slow (watch10). It lacks the DEP change that the r22 `ntdll.so` has. The earlier adapter spike's "title in a few seconds" claim is not supported by this
measurement; its bottle was never timed with the watcher.

[INFERENCE] r23 will not give a fast title on its own. To get both r23's other components and the fast start, the manifest would need Highball's r22 `wine10-dep`
`ntdll.so` (or section 15 option 3, `SetProcessDEPPolicy` from Sidecar). Neither was done here, because the decision was to change only the engine.

## Not done

- No netplay match was played.
- Whether the msync fix changes the VS-screen hang (experiment log sections 9 and 14) was not tested.
- No `highball` CLI is used any more. Nothing from Highball is linked or bundled, so the GPL-3.0 notice in the earlier README no longer applies. The engine
  components are downloaded from the manifest's URLs and keep their own licences.
