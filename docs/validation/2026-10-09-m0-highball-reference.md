# M0 reference: Highball known-good USF4 + Ember stack (2026-10-09)

Purpose: record what the working Highball `Games` bottle actually runs, and pin
public, downloadable equivalents for the fresh-prefix script. The machine-readable
result is [`macos-engine-manifest.json`](macos-engine-manifest.json).

Everything in section 1 was read, never modified. Statements not observed on this
machine are marked **[INFERENCE]**.

Evidence root `HB` = `~/Library/Application Support/Highball`.

## 1. Highball reference inventory

### 1.1 Versions

| Item | Value | Evidence |
| --- | --- | --- |
| Highball.app | 0.10.13 (`CFBundleShortVersionString` and `CFBundleVersion`), id `app.highball.Highball` | `/Applications/Highball.app/Contents/Info.plist` |
| `highball` CLI | no `--version`/`version`; binary built 2026-10-02, sha256 `816796004a63481f1e30e6ca0793d7eff379d8fdc27dc086b863b423781ba2b4`, differs from the app binary. Release train 0.10.13 **[INFERENCE]** | `~/.local/bin/highball` |
| Engine id | `x64-sikarugir10.0_6-r22` ("Wine 10.0 (Sikarugir) r22", x86_64, requires Rosetta 2, min macOS 14.0) | `HB/engines/x64-sikarugir10.0_6-r22/manifest.json` |
| Wine | `wine sikarugir 10.0 (revision 6)` (Gcenx/Sikarugir build of upstream Wine 10.0) | `HB/engines/*/engine/version` |
| WoW64 mode | new/experimental WoW64: 32-bit SSFIV.exe and Launcher.exe both start with `in experimental wow64 mode`; no `wine64` loader needed, `bin/` holds only `wine` + `wineserver` (no `wineboot`) | `HB/logs/2026-10-09T093805Z-Games-Launcher.exe.log` lines 13-14; `ls engine/bin` |
| D3D9 renderer actually used | **DXVK-Kegworks v1.10.4-async** (log line `DXVK-Kegworks: v1.10.4-async`), from the Sikarugir Template's `renderer/d9vk`, version file `1.10.4-async` | log line 22; `HB/engines/*/frameworks/renderer/d9vk/version` |
| MoltenVK | 1.4.1 (Vulkan 1.4.334), Highball shadow-import rebuild `1.4.1+shadow-import-1`; the shadow-import path is off unless `MVK_SHADOW_IMPORT=1` | log line 38; engine manifest `components.moltenvk` |
| GPU as seen by Vulkan | Apple integrated, vendorID `0x106b`, 12124 MB | log lines 195-199 |
| Sync mode | msync (Mach-port based; engine's wine/wineserver have msync built in, 37 `msync` string hits in `wineserver`) | log header line 3 `sync=msync`; Steam log `msync: bootstrapped mach port on wine-6da04cb-msync.` |

### 1.2 Bottle `Games` settings

| Setting | Value | Evidence |
| --- | --- | --- |
| Windows version | win10 (Windows 10 Pro, build 19043, 6.3/10.0 in both hives) | `bottle.json` `windowsVersion`; `system.reg` `CurrentBuild="19043"`, `ProductName="Windows 10 Pro"` |
| DLL overrides (registry) | none: `[Software\\Wine\\DllOverrides]` is empty | `HB/bottles/Games/user.reg` line 966 |
| DLL overrides (env) | `WINEDLLOVERRIDES=winemenubuilder.exe=d` only | log header line 6 |
| How DXVK is selected | no `d3d9` override. `WINEDLLPATH_PREPEND=<engine>/renderers/dxmt/wine:<engine>/frameworks/renderer/d9vk/wine` puts a Wine-builtin-stamped DXVK d3d9.dll ahead of Wine's own; `drive_c/windows/{system32,syswow64}/d3d9.dll` are still Wine's stock wined3d builtins (sha256 identical to `engine/lib/wine/*-windows/d3d9.dll`) | log header line 5; sha256 comparison |
| Logged launch env | `WINEDLLPATH_PREPEND`, `WINEDLLOVERRIDES`, `CX_FWD_COMPAT_GL_CTX=1`, `DXVK_CONFIG_FILE=C:\highball\dxvk.conf`, `DXVK_LOG_PATH=C:\highball\logs`; engine `baseEnv`: `WINEDEBUG=fixme-all`, `DYLD_FALLBACK_FRAMEWORK_PATH=${frameworks}`, `DYLD_FALLBACK_LIBRARY_PATH=${frameworks}:${frameworks}/GStreamer.framework/Versions/1.0/lib`, `GST_PLUGIN_PATH=${frameworks}/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0`. Process env of the running Steam was not readable (`ps eww` empty), so `WINEMSYNC=1` for msync is **[INFERENCE]** from `sync=msync` plus the pin that sets `WINEMSYNC=0` to opt Steam out | log headers; `HB/engines/*/manifest.json` |
| dxvk.conf | `dxvk.enableAsync = True`; `[SSFIV.exe] d3d9.maxFrameLatency = 1` (a `[csgo.exe]` block is irrelevant) | `HB/bottles/Games/drive_c/highball/dxvk.conf`; `bottle.json` `dxvkAsync`, `dxvkAppConfig` |
| bottle.json options | `renderer: "dxmt"` (+`rendererExplicit`), `sync: "msync"`, `dxvkAsync: true`, `dpiScale: 96`, `retinaAt100: false`, `advertiseAVX: false`, `commandIsControl: true`, `fpsCap: 0`, `metalHUD: false`, `frameGen: 1` but logs say `frameGen=off`, `recipes: ["steam","usf4-low-latency"]`, empty `environment`/`gameEnvironment`/`dllOverrides` | `HB/bottles/Games/bottle.json` |
| Renderer caveat | the bottle's `dxmt` renderer (D3D10/11) is irrelevant to SSFIV.exe (D3D9); the log shows DXVK-Kegworks serving it | log lines 21-22 |
| Pins | `Steam` pin env `WINEESYNC=0`, `WINEMSYNC=0`; `Ember` pin `sf4e-1.1.1/Launcher.exe` with empty env | `bottle.json` `pins` |
| Registry (wine) | `Mac Driver`: `LeftCommandIsCtrl`, `RightCommandIsCtrl`, `LeftOptionIsAlt`, `RightOptionIsAlt` = `"y"`; `LogPixels` = 0x60 (96 dpi); `Direct3D` `VideoPciVendorID=0x1002`, `VideoPciDeviceID=0x73bf` (looks like the csgo recipe's GPU spoof; not carried into the manifest **[INFERENCE]**) | `user.reg` lines 961-964, 988, 1865-1870 |
| Audio | CoreAudio at 48000 Hz for Launcher (44100 for the Steam log) | log header line 4 |

### 1.3 Highball cached components (`HB/downloads/`) and whether Games uses them

SHA-256 computed locally; "Upstream" is the manifest `url` in the engine manifest.

| File | sha256 | Role | Used by Games / USF4? |
| --- | --- | --- | --- |
| `WS12WineSikarugir10.0_6.tar.xz` | `9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2` | Wine engine (`wswine.bundle`) | yes. Byte-identical to the public Sikarugir-App/Engines v1.0 asset (same name, size 166304096, sha256) |
| `Template-1.0.11.tar.xz` | `9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a` | Sikarugir Wrapper Template; source of `frameworks/` (GStreamer, gnutls, freetype, SDL2, ICU, MoltenVK) and of `renderer/d9vk` (DXVK-Kegworks 1.10.4-async) | yes. Byte-identical to public Sikarugir-App/Wrapper v1.0 asset |
| `moltenvk-1.4.1-shadow-import-1-x86_64.tar.gz` | `fbed7b80d6dc2aeaba6fa7047c1fe64827d5004c28029fb43c2bc34f80c35228` | Highball MoltenVK 1.4.1 + shadow-import patch; replaces the Template's `libMoltenVK.dylib` (installed sha256 `72f1d2e0f4783285f2d0914bcffd931e17d0389076bf04b50d43c41532780a9a`; stock Template copy is `3e365bfdfb4e9292d9cd1d896330c6d639721015d0443c6391ef86c104c17568`) | yes, but the added feature is off by default, so behaviour is stock 1.4.1 for USF4 **[INFERENCE]** |
| `wine10-msync-20261001.tar.xz` | `c5f47326fab52d92bd072225c385365da12e615ac2b732dd51c6d085570fcac9` | wineserver one-byte fix: wait registration that meets a signaled object at index i>0 unregisters objects 0..i-1 (msync registration leak, highball#224) | superseded by `wine10-dep`, same bytes |
| `wine10-dep-20261003.tar.xz` | `be0a6de062b21b111c38aaaded76160c75ba3c167f7f6740b31cff3b8902a298` | the msync fix plus `ntdll.so` edit: `ProcessExecuteFlags` always `STATUS_ACCESS_DENIED` so DEP stays on; avoids RWX-everywhere pages that cost a Mach round trip under Rosetta for 32-bit games without `NX_COMPAT` (highball#165) | yes (r21+). Likely relevant to SSFIV.exe, a 2010-era 32-bit D3D9 game **[INFERENCE]** |
| `winemac-focus-20260930.tar.xz` | `0192214d7d5c7cc8acd13dcacb0c27e8313ef0c64c51b91a93deff0a851a8974` | `winemac.so` four-byte focus fixes (r15) | superseded by 20261006 |
| `winemac-focus-20261006.tar.xz` | `5bf89e7c5c1309d2e4d53c40d70ef98bba33b7d9dbff4e0976524ac537949f08` | focus fixes + retina `GetDeviceCaps` fix (r22) | yes |
| `audiobuf-20261001.tar.xz` | `037da88d5da0226b3e06778a2038a40d13bb278b8ff859b07eb0261b63a6f268` | `libhbaudiobuf.dylib`, Highball's audio buffer (MIT) | installed in `frameworks/`; whether it is injected for this bottle is unknown **[INFERENCE: via bottle.environment, which is empty, so probably not]** |
| `d9vk-dxvk-macos-3.1-20260916.tar.xz` | `0fabdffde07ef1ef041e95181ca1507db96919cf70acfa91a15c159718ad7611` | metalsharp/DXVK-MacOS v3.1-macos1.0 d3d9 re-stamped as Wine builtin, component `d9vk-modern` | **no**. Opt-in per game recipe only (manifest note: not on any launch's search path); its path is absent from `WINEDLLPATH_PREPEND`. Installed `renderers/d9vk-modern/wine/{i386,x86_64}-windows/d3d9.dll` sha256 `f43a6441...`/`dac63524...` |
| `dxmt-highball-20260930T161516Z-a444716.tar.gz` | `96feaf5d98d3c6cdc3edea9503e2891d435df8d5bfdf7d3f6998a56ec62bbd58` | Highball fork of DXMT (D3D10/11 over Metal); the bottle's selected renderer | on the DLL path, but SSFIV.exe is D3D9 so unused for USF4 |
| `d3dmetal-tsshim-20260915.tar.xz` | `453f33ef1442ec8d24e9a44d901d35d4d07431c05ae8318c30567facc78d9ef3` | d3d12 timestamp shim in front of Apple D3DMetal | no (D3D12 only; D3DMetal is license-gated) |
| `SteamSetup.exe` | `7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb` | Steam installer | yes; hash equals the current official CDN file |
| `winetricks` | `f35c29737ca08a583569e6a3752d52fbe23333c5acfad5f16c4177d25eaf3f4b` | pinned to upstream commit 5a59ea07 | tooling only |

Engine components with no download in `downloads/`: frameworks `libMacportsLegacy*`,
`renderers/d9vk` (Template). No `lsfg` (removed in r11). No separate `manifests/`
directory exists in this Highball data dir; the engine manifest at
`HB/engines/x64-sikarugir10.0_6-r22/manifest.json` is the manifest of record.

Wine-archive file hashes (sha256 as shipped by Sikarugir; Highball patches three of them):

| File | Upstream sha256 (from the archive) | In use by Highball |
| --- | --- | --- |
| `lib/wine/x86_64-unix/ntdll.so` | `8eae29d1f367cdb32932a03b62d8503c7035dc2e783c638fb7bc69be85ab04e2` | patched (msync + DEP) |
| `bin/wineserver` | `6dfe1f9d2d8a67cc6a09a57966f5ef88fd461abe7321d6fb0d4a1672e8ff0350` | patched (msync fix) |
| `lib/wine/x86_64-unix/winemac.so` | `4cbf65e363d6d8b5a70dba719b50b811fb4b2705985e93f777c6cb7a12878eb0` | patched (focus, retina) |

### 1.4 DXVK DLLs actually serving d3d9

| DLL | sha256 | Size | Source |
| --- | --- | --- | --- |
| `frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll` | `d42207530b7b94695f0a11e0ffc354e7d0ca1499d9ab7e789b0af165d6c760d5` | 4068231 | Template-1.0.11, identical bytes to the archive member |
| `frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll` | `e1883ca30101ac0ec0c985d591433898eb2b30260bb248bd279ff0e0cb8afddb` | 3861636 | Template-1.0.11, identical bytes to the archive member |

Both are DXVK 1.10.4 with the async patch (zlib license, `renderer/d9vk/LICENSE` is
the DXVK zlib text). They are PE DLLs with Wine's builtin signature.

### 1.5 Ember on the reference

- Ember v1.1.1 extracted to `HB/bottles/Games/drive_c/sf4e-1.1.1` (same layout as the
  release zip's `sf4-ember-netplay-1.1.1/` directory).
- USF4 launches from `E:\SteamLibrary\steamapps\common\Super Street Fighter IV - Arcade Edition\SSFIV.exe`
  (`E:` = `/Volumes/Result`, exFAT). Ember logs: `drive_c/users/prime/AppData/Roaming/sf4e/logs/`.
- Local `SSFIV.exe` sha256 `5d724595...b0b9eb` equals the value pinned in the repo docs.

## 2. Chosen components (manifest `ember-m0-sikarugir10.0_6-kegworks-dxvk1.10.4-moltenvk1.4.1-r2`)

Design rule: reproduce what Highball runs for USF4 with unmodified public bytes only.
No Highball binary or source is used.

| Component | Version | URL | sha256 | License | Verified |
| --- | --- | --- | --- | --- | --- |
| wine | 10.0 Sikarugir r6 | `https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz` | `9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2` | LGPL-2.1+ | streamed 2026-10-09; equals GitHub asset digest and Highball's cache |
| runtime-frameworks | Template 1.0.11 | `https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz` | `9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a` | mixed (LGPL libs, Apache-2.0 MoltenVK) | streamed; equals GitHub digest |
| moltenvk | 1.4.1 stock (in Template) | same Template URL | same | Apache-2.0 | member sha256 `3e365bfd...c17568` |
| dxvk (d3d9) | DXVK-Kegworks 1.10.4-async | same Template URL | same | zlib | member hashes (`d4220753...`, `e1883ca3...`) equal the DLLs Highball runs |
| Steam | SteamSetup.exe | `https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe` | `7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb` | Valve EULA | streamed; `last-modified` 2024-05-20, 2380800 bytes. Rolling URL: a Valve replacement breaks the pin and must be a deliberate bump |
| Ember | 1.1.1 | `https://github.com/Confetti3/SF4-Ember-Netplay/releases/download/v1.1.1/sf4-ember-netplay-1.1.1.zip` | `f8831747ba896c8413cd5ad68ffd6b00f71dea74579eee5482cbd5b05b6231f9` | repo license | streamed; equals the release `.sha256` asset and API digest. Zip root dir `sf4-ember-netplay-1.1.1/`, contains `MANIFEST.txt` |
| SSFIV.exe | build 834219 | local Steam install | `5d724595a8ab3c6c6d6f4959187f756f5be35bb497e51e5233c4e73b18b0b9eb` | game, not redistributed | this value is pinned in `docs/design/SAVESTATE_FREE.md`, `docs/design/NATIVE_MATCH_RESULT.md`, `docs/design/training-native-scope.md`; nothing in `src/` pins a SHA, the code only comments "USF4 Steam build 834219". Recomputed on the live install: match |

### 2.1 Rationale and install semantics

- **Why Template for DXVK and MoltenVK.** Highball's real USF4 D3D9 path is the
  Template's DXVK-Kegworks 1.10.4-async, not the newer 3.1 build. Taking the same
  archive gives byte-identical DLLs and the same MoltenVK 1.4.1 base without a second
  download. The Wine engine's `frameworks/` (gnutls, freetype, SDL2, GStreamer, ICU)
  are also required at runtime (`DYLD_FALLBACK_*`), so the Template is needed anyway.
- **Install path rule.** `from` is a path inside the archive. When `from` is a file,
  `to` is the full destination file path (name included); when it is a directory, its
  contents are copied to `to`. `engine:.` means the engine root. Copy symlinks as symlinks
  (`cp -a` / `ditto`); 55 of the `runtime-frameworks` entries are relative dylib symlinks.
- **D3DMetal excluded on purpose.** The Template also ships Apple's
  `renderer/d3dmetal/external/D3DMetal.framework` (Apple GPTK license, non-commercial
  and non-modifiable). The manifest therefore lists `frameworks/` entries one by one
  (GStreamer.framework + 94 dylib files/symlinks, `libMoltenVK.dylib` as its own
  component) instead of copying the whole directory. `SikarugirSdk.framework`,
  `moltenvkcx/` (older MoltenVK for CrossOver) and `renderer/` are not installed.
- **Runtime env the script must derive** (they depend on the extracted engine root, so
  they are not in the manifest `env`): `DYLD_FALLBACK_FRAMEWORK_PATH=<engine>/frameworks`,
  `DYLD_FALLBACK_LIBRARY_PATH=<engine>/frameworks:<engine>/frameworks/GStreamer.framework/Versions/1.0/lib`,
  `GST_PLUGIN_PATH=<engine>/frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0`,
  matching Highball's `baseEnv`. The engine is x86_64, so run through Rosetta 2.
- **`wineboot`** is `null`: the archive has no `bin/wineboot`; create the prefix with
  `wine wineboot -u` (new-WoW64 prefix with `drive_c/windows/{system32,syswow64}`).
- **DXVK config file.** `prefix.env.DXVK_CONFIG_FILE=C:\ember\dxvk.conf`, `DXVK_LOG_PATH=C:\ember\logs`.
  The script must create `drive_c/ember/dxvk.conf` containing

  ```
  dxvk.enableAsync = True

  [SSFIV.exe]
  d3d9.maxFrameLatency = 1
  ```

  (identical effect to Highball's generated file; verify it in the DXVK log's
  `Effective configuration` block).
- **d3d9 selection.** Mirrors Highball: the DLLs go into the engine at
  `renderers/d9vk/wine/{i386,x86_64}-windows/`, every wine call exports
  `WINEDLLPATH_PREPEND=<engine>/renderers/d9vk/wine`, and there is no `d3d9` override.
  The first manifest (`...-moltenvk1.4.1`, no `-r2`) copied them into
  `system32`/`syswow64` with `d3d9=native,builtin`. That failed silently: because the
  DLLs are builtin-stamped, Wine loaded its own builtin `d3d9.dll` and the game ran on
  `wined3d.dll` + `opengl32` + `AppleMetalOpenGLRenderer` (seen via `lsof` on the live
  SSFIV process, no DXVK banner in the wine log). Online it measured persistently
  slow: sf4e.log `spedUpMs` ~25 ms/s and rift -2..-6, against Highball's ~1 ms/s and
  -0.3 (#35).
- **Fallback.** `wined3d` on macOS OpenGL: `d3d9=builtin`, no `WINEDLLPATH_PREPEND`.
  Only for isolating engine faults from DXVK/MoltenVK faults.

### 2.2 Alternatives considered

| Candidate | Result |
| --- | --- |
| `metalsharp/DXVK-MacOS` v3.1-macos1.0 (zlib, source available; basis of Highball's `d9vk-modern`) | released as `dxvk-macos-v3.1-metalsharp.tar.zst` (41653188 B, sha256 `8b37482116da0136b2b4feaa0118f9441bcf148b9532de474edc5a89c3e55687`); `.zst` is not a manifest format and Highball itself keeps it opt-in because of game-specific regressions (grayscale render, a freeze). Not chosen for M0; a good later experiment |
| `Sikarugir-App/DXVK` v3.0.2 `d9vk-3.0.2.tar.gz` (6107209 B, sha256 `d1d5254c38b3821627393a020bd42e97ef35a227fbc169b8d6d9fb91dbc61c50`) | newer DXVK 3.0 d3d9; unverified on USF4; candidate for a later A/B |
| `Gcenx/DXVK-macOS` v1.10.3-20230507-repack (builtin) | older and smaller (2.8 MB) public fallback for the same DXVK 1.10 family; a source-available upstream for the Kegworks 1.10.4 line was not found (no public Kegworks DXVK repo located via GitHub search) |
| `KhronosGroup/MoltenVK` v1.4.1 `MoltenVK-macos.tar` (56034304 B, sha256 `5ea0c259df7ded9a275444820f09cced54d6e5a7c7a31d262de62a5cdb7e15cf`) | same version as the Template's dylib; unnecessary; usable if a universal or rebuilt dylib is wanted |
| `Sikarugir-App/Engines` newer builds (`10.0_7`, `10.0_8`) | exist (`..._7` sha256 `7a51686a...3985`, `..._8` `2a6bcf2a...8c68`); not chosen so M0 matches the reference r6 |
| Highball's DXMT, tsshim, audiobuf, patched MoltenVK/wineserver/ntdll/winemac | not used (GPL-3 app / Highball-only builds). Patch sources in the LGPL-2.1 repo `gauthierpiarrette/highball-engine` (`patches/0013-...`, `patches/0014-...`, plus the winemac patches under the app repo's `spike/patches`) could be applied to a self-built Wine later; not part of M0 |

## 3. Gaps vs Highball and risks

| Gap | Expected impact | Mitigation |
| --- | --- | --- |
| No wineserver msync registration-leak fix (wine10-msync/dep) | msync waits can leave stale registrations; Highball saw it as a leak/hang over long sessions. Short matches probably unaffected **[INFERENCE]** | start with `WINEMSYNC=1`; if hangs appear, retry `WINEMSYNC=0` (esync/server sync), compare |
| No DEP always-on edit in ntdll.so | 32-bit game modules lacking `NX_COMPAT` disable DEP for the whole process; every mapping becomes RWX and each first touch costs a Mach round trip under Rosetta; Highball measured slow D3D9 vertex streaming. Could cost frame time in USF4 **[INFERENCE]** | measure frame-time first; check the `.exe` NX flag; self-build option via highball-engine patch 0013 |
| Stock `winemac.so` (no focus or retina fix) | window focus/click-through quirks, wrong `HORZRES`/`VERTRES` in retina mode; relevant to the Launcher and game window handoff | keep `retinaAt100` off / avoid retina mode; test focus manually |
| No `libhbaudiobuf.dylib` | audio buffer underruns at 48 kHz on macOS per Highball r19 note | test audio; Ember is audio-incidental for M0 |
| Stock MoltenVK 1.4.1, no shadow-import | none for D3D9 (feature is 32-bit native Vulkan only) | none |
| Direct3D PCI ID registry and csgo-specific dxvk blocks | none for USF4 | not carried over |
| Frameworks installed as individual entries | one manifest line per dylib; a Template bump needs the list regenerated | script should treat a missing `from` as a hard error |
| `DXVK_CONFIG_FILE` file creation not expressed by the manifest schema | script has to write it (see 2.1) | documented above |
| Rosetta 2 + Apple Silicon only | engine is x86_64 | document in M0 prerequisites |
| Wine archive is 166 MB, Template 85 MB | download size | cache by sha256 |
| Steam installer URL is rolling | pin breaks if Valve replaces the file | deliberate manifest bump |
| Apple GPTK D3DMetal | excluded to avoid redistributing it | n/a for D3D9 |
| Source-available upstream for DXVK-Kegworks 1.10.4-async not located | GPL/zlib compliance still satisfied (zlib; no copyleft), but reproducibility of the binary is by hash only | accept; see alternatives |

## 4. Verification performed (2026-10-09)

- `jq . docs/validation/macos-engine-manifest.json` parses; all `install.from` paths
  exist in `Template-1.0.11.tar.xz`; `wswine.bundle` exists in the Wine archive.
- Streamed `curl | shasum -a 256` for Wine, Template, Ember zip and SteamSetup.exe: each
  equals the manifest value (no archives kept; the Ember zip was temporarily saved to
  `/tmp` to list contents, then deleted).
- Nothing under `HB` was modified; no Highball process was touched.
- Not done: no Wine run, no prefix creation, no network test, no render test.
