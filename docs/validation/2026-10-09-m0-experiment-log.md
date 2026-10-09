# M0 experiment log, 2026-10-09 (issue #3)

This log records everything tried on the M0 rig while playing the #3 game set: each hypothesis, the action taken, the evidence, and the verdict. Wrong turns stay in, marked as wrong, so nobody repeats them. Times are local (PDT).

Rig: `EMBER_M0_ROOT=/Volumes/EmberM0` (APFS sparse bundle), Steam library `R:` on the exFAT drive `/Volumes/Result`. Engine `ember-m0-sikarugir10.0_6-kegworks-dxvk1.10.4-moltenvk1.4.1`. Reference: Highball's `Games` bottle on the same Mac and the same library drive.

## Where the evidence lives

| What | Path |
| --- | --- |
| Ember game log (current, plus rotated `sf4e.1.log`…`sf4e.7.log`) | `<prefix>/drive_c/users/<user>/AppData/Roaming/sf4e/logs/sf4e.log` |
| Ember room/session logs | same folder, `session-<pid>.log` |
| Wine and DXVK stdout for one launch | `$EMBER_M0_ROOT/logs/<stamp>-launcher-wine.log` |
| SSFIV DXVK state cache | `R:\SteamLibrary\steamapps\shadercache\45760\DXVK_state_cache\SSFIV.dxvk-cache` (path chosen by Steam; Highball uses the same file) |
| Highball comparison logs | `~/Library/Application Support/Highball/bottles/Games/drive_c/users/<user>/AppData/Roaming/sf4e/logs/` |

## Summary

| # | Problem or hypothesis | Verdict |
| --- | --- | --- |
| 1 | Join/create failed after a while: macOS firewall blocking Wine | **Wrong.** A network blip; Ember's UDP check stayed "blocked" until restart |
| 2 | Choppy online play | **Found a real M0 bug:** the game ran on wined3d, not DXVK. Fixed in #35 / PR #36 |
| 3 | M0 runs slower than its peer (negative rift) | Real on 1.1.1 + msync. **Matched Highball** on 1.1.2 + msync off (see 11); which change fixed it is unknown |
| 4 | Rollbacks up close with auto delay 1 | Real. Manual delay 2 used as a stopgap; Ember 1.1.2 changes auto delay |
| 5 | DXVK shader cache not saved | **Wrong.** It is saved; the wrong file was checked first |
| 6 | Slow startup is slow disk (exFAT/FSKit) | **Ruled out** |
| 7 | VS-screen hang at 13:18 | Real, unexplained. Game waiting on a signal, not loading |
| 8 | "Startup takes a fixed ~2 min" | **Wrong metric.** The log line used fires at first match start, not at the menu |
| 9 | msync lost-wakeup bug causes the hang/slow start | Built on #8, so unproven. 3 matches with msync off, no hang (see 11) |
| 10 | Ember 1.1.2 on the rig | **Works.** Installed and launched |
| 11 | Online play on 1.1.2 + msync off | **Much better:** rift −0.58, speed-up 1.1 ms/s, near Highball's −0.26 / 1.3 ms/s |

## 1. Join/create failures (about 11:06–11:13)

- **Symptom:** after a spectate dropped, joining and creating rooms failed; a created room ended with `reason=never_joined`.
- **Evidence:** at 11:06:22 Steam's connection lost its heartbeat and reconnected in the same second that Ember logged `Room control is recovering`. From 11:10, Ember's network check reported UDP blocked and NAT closed until the game was restarted.
- **First hypothesis, wrong:** the macOS application firewall was blocking the M0 `wine` binaries. After a restart UDP was open again with no firewall change, and the M0 binaries were still not on the allow list.
- **Verdict:** a network blip. Ember did not recover its UDP state afterwards. Open question: does Ember on Windows also stay stuck after a blip?
- `Runtime: network link unknown (wine)` in `sf4e.log` is harmless.

## 2. Choppy online play: the game was not using DXVK

- **Symptom:** play felt choppy online.
- **Evidence:** M0 runs before 11:40 rendered through wined3d (Wine's OpenGL path). The DXVK `d3d9.dll` copied into `syswow64` carried Wine's builtin stamp and was ignored, so Wine loaded its own `d3d9`. The launcher Wine logs for 10:23, 10:33 and 11:18 contain no DXVK lines.
- **Fix:** select DXVK by prepending its directory with `WINEDLLPATH_PREPEND`, not by copying it into `system32`/`syswow64` (#35, PR #36).
- **Verified 11:40:** the launcher log shows `DXVK-Kegworks: v1.10.4-async`, `Found config file: C:\ember\dxvk.conf`, an Apple M4 Vulkan device, and the state cache loading. Every DXVK launch since has shown the same lines.
- **Consequence:** the #3 games played before 11:40 ran on wined3d and do not count toward the set.

## 3. M0 runs slower than the peer

Ember's per-15-second `Netplay [Ns]` lines report rift (frames ahead or behind the peer) and how much the game had to speed up to keep pace.

| Run | Windows | Median ping | Rift | Speed-up |
| --- | --- | --- | --- | --- |
| Highball (all logs) | 610 | 36 ms | −0.26 frames | 1.3 ms/s |
| M0, wined3d, 11:20 match | 7 | 86 ms | −4.71 frames | 26.1 ms/s |
| M0, 11:52–12:13 | 76 | avg 57–122 ms | mean −2.17, median −1.92 | 9.9 ms/s |

- The negative rift persisted at low ping: against one peer at 21–30 ms with zero rollbacks, rift still drifted to −5. So the M0 side was producing frames slower than its peer, independent of the network.
- SSFIV used about 3.5% CPU mid-match, so the game thread was blocked in a wait rather than busy. The cause (frame presentation, MoltenVK, or a Wine wait) is **not established**.
- Local network ruled out: gateway 0.71 ± 0.08 ms, 1.1.1.1 14 ± 2.3 ms. Large ping swings also appear in Highball's logs, so they are not M0-specific.
- **Status:** the 11:52–12:13 numbers came after the DXVK fix and are better, but still behind Highball. Remeasure after #36 merges, with `SF4E_ROLLBACK_DIAGNOSTICS=1` and the DXVK HUD (`m0.sh launch --hud`).

## 4. Rollbacks up close with auto input delay

- **Evidence:** Ember 1.1.1's auto delay picked 1 frame against a Wi-Fi peer at 55–150 ms, which produced visible rollbacks in close-range exchanges.
- **Stopgap:** set `autoInputDelay=false` and `inputDelay=2` in the prefix's `sf4e/settings.json`. No match with delay 2 was completed before the 1.1.2 switch.
- **Ember 1.1.2:** auto delay now follows average ping (up to 80 ms gives 1 frame, 81–150 ms gives 2). **To do:** set `autoInputDelay` back to `true`.

## 5. "The shader cache isn't being saved"

- **First answer, wrong:** `C:\sf4e-1.1.1\Launcher.dxvk-cache` was named as the game's cache. That 303-byte file belongs to Ember's launcher.
- **Correct:** SSFIV's cache is `R:\SteamLibrary\steamapps\shadercache\45760\DXVK_state_cache\SSFIV.dxvk-cache`. Steam sets that path and Highball shares the file.
- **Verdict:** the cache is saved. It grew from 1093 to 1107 entries across launches. Shader compiling does not explain the slow starts (see 6).

## 6. Slow startup: disk ruled out

- **Symptom (player reports):** about 11:45, "still taking forever to get to the menu"; about 13:05, "taking forever to start up again".
- **Evidence:** during the black screen SSFIV used about 5% CPU, so it was waiting rather than loading. Highball reads the same game files from the same drive and starts quickly. The Steam `CAPIJobRequestUserStats failed` message and the `steamerrorreporter.exe` launch (a Steam networking assert) also appear in fast boots, so they are not the cause.
- **Verdict:** not disk speed, not shader compiling. The cause is still unknown.

## 7. VS-screen hang (13:18)

- **Symptom:** a room match against peer `a962b1cf` (route `Relayed`) logged `game_ready` 13:18:38, `Netplay: starting match` 13:18:42 and `Battle jobs` 13:18:43, then stayed on the VS screen. Every completed match logs `Input: P1 plays with …` about 8 s after `Battle jobs`; that line never came. The opponent quit at 13:20:00 (`gameplay_peer_closed`, 77 s later) and the game then sat on a black Now Loading screen.
- **Evidence during the hang:** about 3% CPU, no disk reads, `wineserver` idle. The main thread kept running its frame loop (the screen still drew at 59.5 fps). The game's loader threads were all parked in waits.
- **Verdict:** the game was waiting for a signal that never came. Not slow disk, not shader compiling. The relay is unlikely to be the cause: relayed matches at 11:59, 12:01, 12:05 and 12:58 started normally. The hung match was the only one of the day against peer `a962b1cf`.
- **Do not repeat:** at 13:23:58 `winedbg` was attached to the hung game to read thread stacks, and the thread it injected crashed SSFIV. `sf4e-crash-20261009-132358-885-2624.dmp` is that artifact, not an Ember bug; do not send it upstream. Only use non-invasive capture (`sample`, `ps`, logs) on a live game.

## 8. Wrong metric: "startup always takes ~2 minutes"

- **What was measured:** startup as `Welcome to sf4e` → first `Battle jobs` line in `sf4e.log`. Several DXVK runs came out at 120–127 s, which was read as a fixed 2-minute timeout.
- **Why it was wrong:** `Battle jobs` is logged by `fJobManager::Start` (`src/sf4e/sf4e__Game__Battle.cxx:90`) when a battle begins, not when the game reaches the menu. In the 11:18 session it came 1 s after `Netplay: starting match`, so that "startup time" included menus, room join, character select and the VS screen.
- **Consequence:** the fast/slow split below reflects how quickly a battle was entered, not boot speed.

| Session | `Welcome` | First `Battle jobs` | Renderer |
| --- | --- | --- | --- |
| `sf4e.7.log` | 10:23:44 | 10:24:02 | wined3d |
| `sf4e.6.log` | 10:33:13 | 10:33:25 | wined3d |
| `sf4e.5.log` | 11:18:34 | 11:20:48 (online match) | wined3d |
| `sf4e.4.log` | 11:40:50 | 11:42:57 | DXVK |
| `sf4e.3.log` | 12:15:45 | 12:17:52 | DXVK |
| `sf4e.2.log` | 13:03:30 | 13:05:35 | DXVK |
| `sf4e.1.log` | 13:25:40 | 13:27:40 | DXVK, msync on |
| `sf4e.log` | 13:35:03 | 13:37:13 | DXVK, msync off, Ember 1.1.2 |

- `sf4e.log` has no line for reaching the title screen or menu. `Overlay: window messages arrive on thread` marks the first window message the overlay sees, not the menu. **Measure startup with a stopwatch** from `m0.sh launch` to the main menu until a log marker exists.

## 9. msync hypothesis

- **Idea:** Highball's Wine includes a fix for an msync bug (highball#224): when a thread waits on several objects and one other than the first is signalled, the registrations before it are dropped, so later wake-ups can be lost and threads wait forever. The M0 engine lacks that fix (see `2026-10-09-m0-highball-reference.md`, gaps table). Highball's Steam pin also runs with esync and msync off. The parked loader threads in 7 fit this.
- **Problem:** the main supporting evidence was the "fixed 2-minute timeout" from 8, which was a bad metric.
- **Test run 13:34:54:** `WINEMSYNC=0` with Ember 1.1.2 (manifest `/tmp/m0-manifest-1.1.2-nomsync.json`; switching sync mode requires `m0.sh kill`, then `steam-start`, then `launch`). The run started and played normally. The wrong metric gave 130 s, which says nothing.
- **Status:** unproven. What would settle it: stopwatch startup times and whether the VS-screen hang recurs over several matches with msync off versus on. A hang with msync off rules it out. The first 3 matches with msync off had no hang (see 11), but with msync on there was only one hang in 16 room matches on DXVK (10 in `sf4e.4.log`, 5 in `sf4e.3.log`, 1 in `sf4e.2.log`), so 3 clean matches prove nothing yet.

## 10. Ember 1.1.2

- Installed with `m0.sh ember-install` to `C:\sf4e-1.1.2` beside 1.1.1; 4755 files verified against `MANIFEST.txt`.
- Launched 13:34:54; `sf4e.log` shows `Sidecar build: revision=454a6fa00d8b` (1.1.1 was `3ee07e19436f`). Tracked in #37 / PR #38.
- 1.1.1 and 1.1.2 players cannot share rooms. Do not use Ember's in-game updater on the rig; it would overwrite `C:\sf4e-1.1.1`, which no longer matches the manifest's version.

## 11. Online play on Ember 1.1.2 with msync off (13:47–13:54)

- **Setup:** the 13:34:54 launch (Ember 1.1.2, `WINEMSYNC=0`, DXVK), manual input delay 2 (`applied=2`). Three relayed room matches against the same opponent, with one spectator. Player report: "seems way better now".
- **Every match started:** `Input: P1 plays with …` came 8–10 s after `Battle jobs` each time; no VS-screen hang.
- **Numbers** (Ember's `Netplay [15s]` windows, 20 in total):

| Run | Ping | Rift (mean) | Speed-up | Rollbacks |
| --- | --- | --- | --- | --- |
| Highball (all logs) | median 36 ms | −0.26 frames | 1.3 ms/s | — |
| M0, 1.1.1, msync on, 11:52–12:13 | avg 57–122 ms | −2.17 frames | 9.9 ms/s | — |
| M0, 1.1.2, msync off, match 1 | 125–166 ms | −0.66 frames | 1.13 ms/s | 8.4/s |
| M0, 1.1.2, msync off, match 2 | 74–120 ms | −0.56 frames | 0.28 ms/s | 4.9/s |
| M0, 1.1.2, msync off, match 3 | 76–120 ms (one 1108 ms spike at the end) | −0.54 frames | 1.63 ms/s | 4.0/s |
| M0, 1.1.2, msync off, all | 74–166 ms | −0.58 frames | 1.08 ms/s | 5.6/s |

- **Verdict:** the M0 rig no longer falls behind its opponent. Rift and speed-up are now at Highball's level, even at higher ping than the 11:52–12:13 matches.
- **Caveat:** two things changed at once (Ember 1.1.1 → 1.1.2 and msync on → off), plus a different opponent. It is not known which change fixed it. To separate them, play a few matches on 1.1.2 with msync **on** (`WINEMSYNC=1`, same kill / steam-start / launch steps). If rift stays near −0.5, the fix came from 1.1.2. If it goes back toward −2, msync was the cause.

## 12. Desync against a new opponent (13:56)

- **What the player saw:** "the match went 3 seconds, then kicked us out". The game showed "Match ended: the two games diverged (desync)". This is Ember's desync detector ending the match, not a dropped connection.
- **Setup:** same launch as 11 (Ember 1.1.2, `WINEMSYNC=0`, DXVK). New opponent `dfd90efc`, `route=Direct fixed_port=yes`, generation 10, `seats=2/2 applied=2`. GGPO synchronized normally at 13:56:57.477 (`sf4e.log` lines 2774–2795).
- **Divergence:** the first v2 checkpoint (frame 30, 13:57:02.838) already differed in `flow`, `chara0` and `chara1`, and so did every checkpoint after it. The v1 snapshot at frame 180 then showed `chara0 status 0 != 11`, `chara0 rootPos[0] -0x1.bae144p+0 != -0x1.ba6dfp+0` and `chara1 rootPos[0] 0x1.8f5c28p+0 != 0x1.8f4ce4p+0`, and the match was ended (`src/session/sf4e__SessionClient.cxx:177`).
- **Reading:** the floating-point state was `x87 pc=24 rc=near mxcsr=0x1fbf` at the start and at every report. That is the same as in every clean M0 match and on Highball. All three subsystems differ from the first checkpoint, so the two games were never in step. A floating-point drift would usually show up in one subsystem later in the match. [INFERENCE] The likelier causes are a different starting state or inputs applied on different frames. Which side was wrong cannot be told from one log.
- **Base rates:** Highball has 73 online matches with no desync. The M0 rig has had 1 desync in 24. Zero desyncs in 73 matches at a rate of 1 in 24 has a probability of about 5%, so this is weak evidence against the M0 rig. Ember's own release notes list desyncs as a known open issue (v0.8.5) and have fixed several since then (v0.9.5 throws, v0.9.9-rc2 shadow moves).
- **Next match:** at 13:59 against another new opponent, `952a5905` (Direct). It ran without a desync.
- **Opponent logs are not a realistic source.** After a desync the opponent leaves or the room locks the player out, so there is nobody to ask. Diagnostics on the M0 side are already on: `RollbackDiag [periodic]` blocks appear in `sf4e.log`. The practical test is the desync rate on this rig over many matches, compared with Highball's 0 in 73.

## 13. Five clean matches against one opponent (13:59–14:12)

- **Setup:** same launch as 11 and 12. Opponent `952a5905`: four direct matches and one relayed match. Player report: "felt pretty good". After that the rig spectated a match (generation 21, peer `17e955f4`).
- **Every match started and finished:** `Input: P1 plays` came 8.0 s after `Battle jobs` each time. No VS-screen hang, no desync, every match ended with a result.

| Gen | Route | Windows | Rift (mean) | Speed-up | Rollbacks | Longest prediction stall |
| --- | --- | --- | --- | --- | --- | --- |
| 11 | Direct | 10 | −0.23 frames | 0.95 ms/s | 0.7/s | 3267 ms (first 20 s) |
| 13 | Relayed | 8 | −0.28 frames | 1.94 ms/s | 1.0/s | 417 ms (one 2502 ms ping at start) |
| 15 | Direct | 7 | −0.21 frames | 0.51 ms/s | 1.2/s | 47 ms |
| 17 | Direct | 6 | −0.86 frames | 3.66 ms/s | 1.8/s | 914 ms |
| 19 | Direct | 8 | −0.51 frames | 2.84 ms/s | 0.8/s | 838 ms |
| All | | 39 | −0.39 frames | 1.88 ms/s | 1.0/s | |

- Only windows between match start and `Room: match ended` are counted. Windows that straddle the end of a match show rift down to −4.4 frames with no rollbacks, so they are menu and results-screen time.
- **Against Highball** (rift −0.26 frames, speed-up 1.3 ms/s): close, at a ping of 56–181 ms. The Highball logs have no `stall_duration` lines, so the stalls cannot be compared.
- **Totals since the switch to 1.1.2 with msync off (13:47):** 9 played matches, 0 VS-screen hangs, 1 desync. The msync on/off A/B from 11 is still open.
