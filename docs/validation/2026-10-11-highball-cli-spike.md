# Spike: run Ember on Highball's r23 engine through the existing M0 flow (#47)

Date: 2026-10-11. Machine: Apple M4, macOS 27, Ember 1.1.2, USF4 (Steam 45760) from an external Steam library.

## Decision

An earlier attempt drove Ember through a Highball bottle with a separate adapter and the `highball` CLI. That adapter is gone.
Ember keeps the working `scripts/macos-engine` flow (`m0.sh --manifest <m> kill | steam-start | launch`,
`EMBER_M0_ROOT=/Volumes/EmberM0`, msync on, DXVK d9vk path via `WINEDLLPATH_PREPEND`, prefix and Steam unchanged).
Only the engine changes, to Highball's `x64-sikarugir10.0_6-r23`
(manifest copy: `docs/validation/macos-highball-engine-r23.json`), with one deliberate deviation (see below).

## Manifest

`docs/validation/m0-manifest-1.1.2-r23.json`, id `ember-m0-r23`. Differences from the `hbpatch` manifest
(`ember-m0-hbpatch-test`, which overlaid Highball r22 files by hand):

| Part | hbpatch | r23 manifest |
| --- | --- | --- |
| wine | Sikarugir 10.0 rev 6 | same archive and sha256 |
| `bin/wineserver`, `ntdll.so` | Highball r22 files | Highball r22 `wine10-dep-20261003` archive (sha256 `be0a6de0...`), same bytes as hbpatch (`ntdll.so` `089dc7b4...`, `wineserver` `127f4bc1...`) |
| `winemac.so` | Highball focus and retina build | r23 `winemac-focus-20261006` (same bytes, `b8be9bfc...`) |
| runtime frameworks, DXVK-Kegworks 1.10.4 d9vk | Template-1.0.11 | same |
| MoltenVK | stock 1.4.1 from the Template | 1.4.1 shadow-import rebuild (off unless `MVK_SHADOW_IMPORT=1`) |
| `reference.highball.engineId` | r22 | r23 |
| `highballOnlyPatchesNotReproduced` | five items | only `libhbaudiobuf.dylib` (r23 ships it, but Highball inserts it with `DYLD_INSERT_LIBRARIES` from the bottle environment; the M0 flow has no such step) |

**Deviation from r23.** r23's own `ntdll.so` (`wine10-msync-20261001`, sha256 `e0954d3f...`) is the msync-only build. It lacks the DEP change that
makes the title screen fast (experiment log section 15, watch10). The first run on that exact r23 manifest took about 140 s to reach the title
(window black for about 75 s, picture fading in at about 115 s, bright at about 140 s, CPU about 205 %), the same as the stock engine. The manifest therefore
takes `wineserver` and `ntdll.so` from r22's `wine10-dep-20261003` archive, which contains the same msync fix plus the DEP edit (its note in the r22 engine manifest says so;
the wineserver bytes equal r23's). `reference.deviationFromR23` records this.

`prefix`, `steam`, `ember`, `game`, `fallback` and `engine` sections are unchanged. No change to `scripts/macos-engine` was needed:
`m0.sh --manifest <r23> --cache-from <Highball downloads> engine` builds `/Volumes/EmberM0/engine/ember-m0-r23` in about 17 s from the pinned URLs.

## Result

The game runs on the r23 engine through the M0 flow. Sequence: `kill`, `steam-start` (Steam logged on after 33 s), about 20 s wait, `launch`.

| Check | Evidence |
| --- | --- |
| Engine | `SSFIV.exe` maps `/Volumes/EmberM0/engine/ember-m0-r23/renderers/d9vk/wine/i386-windows/d3d9.dll` and `.../frameworks/libMoltenVK.dylib`; the prefix's wineserver is `/Volumes/EmberM0/engine/ember-m0-r23/bin/wineserver`; installed `ntdll.so` is `089dc7b4...` |
| DXVK | `SSFIV_d3d9.log`: `DXVK-Kegworks: v1.10.4-async`, `Found config file: C:\ember\dxvk.conf`, `d3d9.maxFrameLatency = 1`, `dxvk.enableAsync = True` |
| msync | the launch log's effective environment lists `WINEMSYNC=1`. [INFERENCE] The process environment itself cannot be read from `ps` on macOS. |
| Sidecar | `launcher.log`: `CreateSF4Process resumed` 13:30:33.9, `received Sidecar sync signal` 13:30:35.8 |

## Time to title (method of experiment log section 15)

A screen watcher (`/tmp/ssfiv-watch.py`, started before `launch`) logs the mean luminance of the `SSFIVAE` window once a second.
`launch` was typed at about 13:30:31.

| Event | Wall time | After `launch` |
| --- | --- | --- |
| Window appears, black | 13:30:38 | about 7 s |
| First image (luminance above 3) | 13:30:46 | about 15 s |
| Title bright (luminance above 100) | 13:30:49 | about 18 s |
| SSFIV CPU | | 95 to 210 % while loading, 125 to 175 % afterwards |

This matches the hbpatch engine (section 15 watch5 and watch9: bright at 18 to 20 s) and is about eight times faster than the r23 manifest
with its own `ntdll.so` (about 140 s).

## Not done

- No netplay match was played in this run.
- Whether the msync fix changes the VS-screen hang (experiment log sections 9 and 14) was not tested.
- The audio buffer library is not inserted.
- No `highball` CLI is used. Nothing from Highball is linked or bundled; the engine components are downloaded from the manifest's URLs and keep their own licences.
