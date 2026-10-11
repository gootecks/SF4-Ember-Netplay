# Diagnostics bundle

`DiagnosticsBundle.create(paths:manifest:to:maxLogBytes:) async throws -> URL` writes one zip (`ditto -c -k --keepParent`) a tester can attach to an issue. `maxLogBytes` defaults to 5 MB.

## Contents

The zip has one top folder `ember-diagnostics-<UTC stamp>/`:

| Entry | Source |
| --- | --- |
| `emberkit-logs/**` | `EmberPaths.logsDir` (all files, recursive) |
| `wine/*.log` | `Prefix/drive_c/ember/*.log` and `Prefix/drive_c/ember/logs/*.log` (`DXVK_LOG_PATH=C:\ember\logs`, so `<exe>_d3d9.log` lands here) |
| `ember/<user>/` | `Prefix/drive_c/users/<user>/AppData/Roaming/sf4e/logs`: `sf4e*.log`, `session-*.log`, `launcher.log` |
| `steam/` | `Prefix/drive_c/Program Files (x86)/Steam/logs`: `connection_log.txt`, `steamui_login.txt` |
| `manifest.json` | the `EngineManifest` passed in, re-encoded |
| `prefix-marker.txt` | `Prefix/.ember-m0-prefix` |
| `system-info.txt` | `sw_vers`, `uname -m`, `sysctl hw.model`, `machdep.cpu.brand_string`, `hw.memsize` |
| `summary.txt` | included, missing, truncated and denied entries |

Each log keeps only its last `maxLogBytes` bytes; truncated files are listed in `summary.txt`. Missing files or directories never fail the build; they are listed under "Missing".

## Deny list

`DiagnosticsBundle.isDenied(_:)` is checked against every path component of every candidate. Denied: names starting with `ssfn`; extensions `.vdf` (covers `local.vdf`, `config.vdf`, `loginusers.vdf`), `.key`, `.pem`, `.p12`; names containing `token`, `identity`, `secret`, `credential`, `password`, `loginusers`, `auth`. Steam `config/` is never collected; the deny list is a second guard for files that appear inside collected folders (such as the EmberKit logs dir). Denied entries are listed in `summary.txt`.
