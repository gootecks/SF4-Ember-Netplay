#!/usr/bin/env bash
# M0 spike: build a fresh WoW64 Wine prefix for Ember/USF4 on macOS without Highball.
# Driven only by docs/validation/macos-engine-manifest.json. See scripts/macos-engine/README.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() {
    cat <<'EOF'
usage: m0.sh [options] <subcommand> [args]

subcommands:
  engine                  download + verify + install the Wine engine (atomic, rollback on failure)
  prefix                  create the Wine prefix (wineboot, Windows version, DXVK, overrides, registry)
  steam-install           download SteamSetup.exe (SHA-checked) and run it silently
  library <dir> [letter]  map an existing Steam library (default letter E) and register it with Steam
  steam-login             start Steam visibly for a one-time interactive login
  steam-start             start Steam hidden, wait for "SetLoginState: Success" in steamui_login.txt
  ember-install           download, verify and install Ember into C:\sf4e-<version>
  game-check              locate SSFIV.exe in the Steam libraries and compare build/SHA-256
  launch [--hud]          start Ember's Launcher.exe detached (Steam must be logged on)
  status                  show engine/prefix/Steam/Ember state for THIS prefix only
  kill                    wineserver -k for THIS prefix only
  all                     engine -> prefix -> steam-install

options: --manifest <file>  --cache-from <dir>  --renderer dxvk|wined3d  --hud  --debug  --force
env:     EMBER_M0_ROOT (default ~/Library/Application Support/Ember-M0)
EOF
}

kill_ours() {
    [ -n "$WINESERVER" ] && [ -d "$PFX" ] || return 0
    WINEPREFIX="$PFX" "$WINESERVER" -k 2>/dev/null || true
    WINEPREFIX="$PFX" "$WINESERVER" -w 2>/dev/null || true
}

# ---- engine ------------------------------------------------------------------
step_engine() {
    preflight_tools
    need_space
    local id wine_rel tmp n i
    id=$(jq_manifest '.id')
    wine_rel=$(jq_manifest '.engine.wine')
    ENGINE_DIR="$ENGINES/$id"
    if [ -x "$ENGINE_DIR/$wine_rel" ]; then say "engine $id already installed: $ENGINE_DIR (nothing to do)"; return 0; fi
    [ ! -e "$ENGINE_DIR" ] || die "$ENGINE_DIR exists but has no $wine_rel; remove it and rerun"
    mkdir -p "$CACHE" "$ENGINES"
    tmp="$ENGINE_DIR.tmp"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    add_cleanup "$tmp"
    n=$(jq_manifest '.components | length')
    for ((i = 0; i < n; i++)); do install_component "$i" engine "$tmp"; done
    [ -x "$tmp/$wine_rel" ] || die "install finished but $wine_rel is missing/not executable in the engine"
    xattr -dr com.apple.quarantine "$tmp" 2>/dev/null || true
    mv "$tmp" "$ENGINE_DIR"
    drop_extracted
    clear_cleanup
    say "engine installed: $ENGINE_DIR"
}

# ---- prefix ------------------------------------------------------------------
step_prefix() {
    preflight_tools
    need_space
    load_engine
    local cur winver n i rows k v name type data
    if [ -f "$MARKER" ]; then
        cur=$(sed -n 's/^renderer=//p' "$MARKER")
        if [ -n "$RENDERER" ] && [ "$RENDERER" != "$cur" ]; then
            die "prefix already built with renderer=$cur; delete $PFX to rebuild with $RENDERER"
        fi
        say "prefix already built (renderer=$cur): $PFX (nothing to do)"
        return 0
    fi
    [ ! -e "$PFX" ] || die "$PFX exists without a completed-build marker; remove it and rerun"
    RENDERER=${RENDERER:-dxvk}
    resolve_renderer
    mkdir -p "$ROOT" "$CACHE"
    ON_FAIL_FN=kill_ours
    add_cleanup "$PFX"
    wine_env
    log_env
    say "wineboot -i"
    if [ -n "$WINEBOOT" ]; then
        WINEDLLOVERRIDES="mscoree,mshtml=" "$WINEBOOT" -i
    else
        WINEDLLOVERRIDES="mscoree,mshtml=" run_wine wineboot -i
    fi
    wait_wineserver
    winver=$(jq_manifest '.prefix.windowsVersion // "win10"')
    say "Windows version: $winver"
    run_wine winecfg /v "$winver"
    wait_wineserver
    mkdir -p "$PFX/drive_c/ember/logs"
    if [ "$RENDERER" = dxvk ]; then
        printf 'dxvk.enableAsync = True\n[SSFIV.exe]\nd3d9.maxFrameLatency = 1\n' >"$PFX/drive_c/ember/dxvk.conf"
        say "wrote C:\\ember\\dxvk.conf"
    fi
    n=$(jq_manifest '.components | length')
    for ((i = 0; i < n; i++)); do install_component "$i" prefix "$PFX"; done
    if [ "$RENDERER" = wined3d ]; then
        say "renderer wined3d: applying fallback DLL overrides ($(jq_manifest '.fallback.notes // ""'))"
        rows=$(jq_manifest '(.fallback.dllOverrides // {}) | to_entries[] | [.key, .value] | join("\u001f")')
    else
        rows=$(jq_manifest '(.prefix.dllOverrides // {}) | to_entries[] | [.key, .value] | join("\u001f")')
    fi
    while IFS="$US" read -r k v; do
        [ -n "$k" ] || continue
        say "DllOverride $k=$v"
        run_wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$k" /d "$v" /f >/dev/null
    done <<<"$rows"
    rows=$(jq_manifest '(.prefix.registry // [])[] | [.key, .name, .type, (.data | tostring)] | join("\u001f")')
    while IFS="$US" read -r k name type data; do
        [ -n "$k" ] || continue
        say "registry $k [${name:-(Default)}] ($type)"
        if [ -n "$name" ]; then
            run_wine reg add "$k" /v "$name" /t "$type" /d "$data" /f >/dev/null
        else
            run_wine reg add "$k" /ve /t "$type" /d "$data" /f >/dev/null
        fi
    done <<<"$rows"
    wait_wineserver
    printf 'renderer=%s\nengine=%s\ncreated=%s\n' "$RENDERER" "$(jq_manifest '.id')" "$(date -u +%FT%TZ)" >"$MARKER"
    drop_extracted
    clear_cleanup
    ON_FAIL_FN=""
    say "prefix ready: $PFX"
}

# ---- steam -------------------------------------------------------------------
need_prefix() { [ -f "$MARKER" ] || die "prefix not built; run: m0.sh prefix"; }
need_steam_exe() { [ -f "$STEAM_DIR/steam.exe" ] || die "Steam not installed in the prefix; run: m0.sh steam-install"; }

step_steam_install() {
    preflight_tools
    need_space
    need_prefix
    if [ -f "$STEAM_DIR/steam.exe" ]; then say "Steam already installed: $STEAM_DIR (nothing to do)"; return 0; fi
    local url sha file
    url=$(jq_manifest '.steam.setupUrl') sha=$(jq_manifest '.steam.sha256')
    file="$CACHE/$(cache_name "$url")"
    mkdir -p "$CACHE"
    fetch_verified "$url" "$sha" "$file"
    wine_env
    log_env
    local args=()
    while IFS= read -r a; do [ -z "$a" ] || args+=("$a"); done < <(jq_manifest '.steam.installArgs[]?')
    say "running SteamSetup.exe ${args[*]:-}"
    run_wine "$file" ${args[@]+"${args[@]}"}
    wait_wineserver
    [ -f "$STEAM_DIR/steam.exe" ] || die "SteamSetup finished but $STEAM_DIR/steam.exe is missing"
    say "Steam installed: $STEAM_DIR"
}

highball_conflict() { # <host-dir>
    local d t
    pgrep -f 'Highball/engines/.*/wineserver' >/dev/null 2>&1 || return 1
    for d in "$HIGHBALL_DIR"/bottles/*/dosdevices/*; do
        [ -L "$d" ] || continue
        t=$(resolve_link "$d") || continue
        if [ "$t" = "$1" ]; then printf '%s\n' "$d"; return 0; fi
    done
    return 1
}

find_lib_rel() { # prints "." when host itself is a library, else the child folder name
    local host=$1 d best=""
    [ ! -d "$host/steamapps" ] || { echo .; return 0; }
    for d in "$host"/*/; do
        [ -d "${d}steamapps" ] || continue
        [ -n "$best" ] || best=$(basename "$d")
        if [ -f "${d}steamapps/appmanifest_45760.acf" ]; then best=$(basename "$d"); break; fi
    done
    [ -n "$best" ] || return 1
    echo "$best"
}

vdf_block() { # <index> <escaped-path>
    printf '\t"%s"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"label"\t\t""\n\t\t"contentid"\t\t"0"\n\t\t"totalsize"\t\t"0"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}' "$1" "$2"
}

step_library() {
    local host=${1:-} letter=${2:-E} lc up link cur rel winp esc vdf have next hit
    [ -n "$host" ] && [ -d "$host" ] || die "usage: m0.sh library <host-dir> [letter]  (directory must exist)"
    host=$(cd "$host" && pwd -P)
    lc=$(printf %s "$letter" | tr 'A-Z' 'a-z') up=$(printf %s "$letter" | tr 'a-z' 'A-Z')
    case "$lc" in [a-y]) ;; *) die "drive letter must be a single letter A-Y" ;; esac
    [ "$lc" != c ] || die "C: is the prefix system drive"
    need_prefix
    if hit=$(highball_conflict "$host"); then
        die "Highball's wineserver is running and its bottle uses the same directory ($hit -> $host).
       Two Steam clients must not share one library at the same time (appmanifest/lock corruption).
       Quit Steam and the bottle in Highball first, then rerun."
    fi
    if steam_running; then die "our Steam is running; run 'm0.sh kill' first (libraryfolders.vdf is only edited while Steam is stopped)"; fi
    link="$PFX/dosdevices/$lc:"
    if [ -L "$link" ]; then
        cur=$(resolve_link "$link" || true)
        [ "$cur" = "$host" ] || die "$up: already maps to '$cur' in this prefix"
        say "$up: -> $host already mapped"
    else
        [ ! -e "$link" ] || die "$link exists and is not a symlink"
        ln -s "$host" "$link"
        say "mapped $up: -> $host"
    fi
    rel=$(find_lib_rel "$host") || die "no 'steamapps' folder in $host or its subfolders; pass the directory containing the Steam library"
    if [ "$rel" = . ]; then winp="$up:\\"; else winp="$up:\\$(printf %s "$rel" | tr / '\\')"; fi
    esc=$(printf %s "$winp" | sed 's/\\/\\\\/g')
    vdf="$STEAM_DIR/steamapps/libraryfolders.vdf"
    mkdir -p "$STEAM_DIR/steamapps"
    if [ ! -f "$vdf" ]; then
        { printf '"libraryfolders"\n{\n'
          vdf_block 0 'C:\\Program Files (x86)\\Steam'; printf '\n'
          vdf_block 1 "$esc"; printf '\n}\n'; } >"$vdf"
        say "created $vdf with library $winp"
        return 0
    fi
    have=$(vdf_paths "$vdf" | tr 'A-Z' 'a-z' | sed 's/\\$//' | grep -cxF "$(printf %s "$winp" | tr 'A-Z' 'a-z' | sed 's/\\$//')" || true)
    if [ "${have:-0}" -gt 0 ]; then say "library $winp already registered in libraryfolders.vdf (nothing to do)"; return 0; fi
    next=$(sed -nE 's/^[[:space:]]*"([0-9]+)"[[:space:]]*$/\1/p' "$vdf" | sort -n | tail -n 1)
    next=$(( ${next:--1} + 1 ))
    [ -f "$vdf.m0bak" ] || cp "$vdf" "$vdf.m0bak"
    BLK=$(vdf_block "$next" "$esc") awk '
        { l[NR] = $0 }
        END { last = 0
              for (i = NR; i > 0; i--) if (l[i] ~ /^[ \t]*}[ \t\r]*$/) { last = i; break }
              if (!last) exit 2
              for (i = 1; i <= NR; i++) { if (i == last) print ENVIRON["BLK"]; print l[i] } }' "$vdf" >"$vdf.new" \
        || { rm -f "$vdf.new"; die "libraryfolders.vdf has no closing brace; not modified"; }
    mv "$vdf.new" "$vdf"
    say "registered library $winp as entry \"$next\" (backup: $vdf.m0bak)"
}

start_steam() { # <args...>; detached, output to logs/<stamp>-steam.log
    wine_env
    log_env
    say "starting Steam: steam.exe $*"
    spawn_detached "$LOGS/$STAMP-steam.log" "$STEAM_DIR" "$WINE" 'C:\Program Files (x86)\Steam\steam.exe' "$@"
}

step_steam_login() {
    need_prefix
    need_steam_exe
    if steam_running; then say "Steam is already running in this prefix (nothing to do)"; return 0; fi
    start_steam
    say "Steam window should appear shortly; log in once (Steam Guard if asked), tick 'Remember my password'."
}

step_steam_start() {
    need_prefix
    need_steam_exe
    local off=0 timeout t=0 args=()
    timeout=$(jq_manifest '.steam.readyTimeoutSeconds // 120')
    if steam_running && steam_logged_on 0; then say "Steam already running and logged on (nothing to do)"; return 0; fi
    while IFS= read -r a; do [ -z "$a" ] || args+=("$a"); done < <(jq_manifest '.steam.hiddenArgs[]?')
    if steam_running; then
        say "Steam running but not logged on; waiting"
    else
        [ ! -f "$LOGIN_LOG" ] || off=$(stat -f %z "$LOGIN_LOG")
        start_steam ${args[@]+"${args[@]}"}
    fi
    while [ "$t" -lt "$timeout" ]; do
        if steam_logged_on "$off"; then say "Steam logged on after ${t}s"; return 0; fi
        sleep 1
        t=$((t + 1))
        [ -f "$LOGIN_LOG" ] && [ "$off" -gt "$(stat -f %z "$LOGIN_LOG")" ] && off=0
    done
    warn "last login state: $(conn_state "$off")"
    tail -n 20 "$LOGS/$STAMP-steam.log" 2>/dev/null || true
    die "Steam did not reach 'SetLoginState: Success' within ${timeout}s (not logged in yet? run: m0.sh steam-login)"
}

# ---- ember -------------------------------------------------------------------
step_ember_install() {
    preflight_tools
    need_prefix
    local ver url sha file dest tmp top n list out
    ver=$(jq_manifest '.ember.version') url=$(jq_manifest '.ember.url') sha=$(jq_manifest '.ember.sha256')
    dest="$PFX/drive_c/sf4e-$ver"
    if [ -f "$dest/Launcher.exe" ]; then say "Ember $ver already installed: $dest (nothing to do)"; return 0; fi
    [ ! -e "$dest" ] || die "$dest exists without Launcher.exe; remove it and rerun"
    file="$CACHE/$(jq_manifest '.ember.asset // empty')"
    [ "$file" != "$CACHE/" ] || file="$CACHE/$(cache_name "$url")"
    mkdir -p "$CACHE"
    fetch_verified "$url" "$sha" "$file"
    tmp="$dest.tmp"
    rm -rf "$tmp" "$tmp.x"
    mkdir -p "$tmp"
    add_cleanup "$tmp"
    add_cleanup "$tmp.x"
    ditto -x -k "$file" "$tmp"
    rm -rf "$tmp/__MACOSX"
    top=""
    n=$(find "$tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    if [ "$n" -eq 1 ] && [ -d "$(find "$tmp" -mindepth 1 -maxdepth 1)" ]; then
        top=$(basename "$(find "$tmp" -mindepth 1 -maxdepth 1)")
        mv "$tmp" "$tmp.x"
        mv "$tmp.x/$top" "$tmp"
        rm -rf "$tmp.x"
        say "flattened top-level folder '$top'"
    fi
    [ -f "$tmp/MANIFEST.txt" ] || die "MANIFEST.txt not found in the Ember archive"
    list=$(mktemp "$CACHE/manifest.XXXXXX")
    add_cleanup "$list"
    # Lines are "<64-hex>  <path>" (optionally "*path" binary marker, CRLF, ./ or top-folder prefix).
    tr -d '\r' <"$tmp/MANIFEST.txt" | awk -v top="$top" '
        length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ {
            h = tolower($1); p = $0
            sub(/^[0-9a-fA-F]+[ \t]+\*?/, "", p)
            gsub(/\\/, "/", p); sub(/^\.\//, "", p)
            if (top != "" && index(p, top "/") == 1) p = substr(p, length(top) + 2)
            print h "  " p }' >"$list"
    n=$(wc -l <"$list" | tr -d ' ')
    [ "$n" -gt 0 ] || die "MANIFEST.txt has no 'sha256  path' lines; format not understood"
    say "verifying $n files against MANIFEST.txt"
    if ! out=$(cd "$tmp" && shasum -a 256 -c "$list" 2>&1); then
        printf '%s\n' "$out" | grep -v ': OK$' | sed -n 1,20p >&2 || true
        die "Ember files do not match MANIFEST.txt"
    fi
    rm -f "$list"
    [ -f "$tmp/Launcher.exe" ] || die "Launcher.exe missing from the Ember package"
    mv "$tmp" "$dest"
    clear_cleanup
    say "Ember $ver installed: $dest ($n files verified)"
}

step_game_check() {
    need_prefix
    local vdf dirs p root acf inst exe got want build seen=0 rc=0 abuild
    vdf="$STEAM_DIR/steamapps/libraryfolders.vdf"
    dirs="$PFX/drive_c/Program Files (x86)/Steam"$'\n'
    if [ -f "$vdf" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            root=$(win_to_unix "$p") || { warn "cannot map library $p (no dosdevices entry)"; continue; }
            dirs="$dirs$root"$'\n'
        done < <(vdf_paths "$vdf")
    fi
    want=$(jq_manifest '.game.ssfivSha256 // empty') build=$(jq_manifest '.game.build')
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        acf="$root/steamapps/appmanifest_$(jq_manifest '.game.steamAppId').acf"
        [ -f "$acf" ] || continue
        seen=1
        inst=$(acf_val "$acf" installdir)
        abuild=$(acf_val "$acf" buildid)
        exe="$root/steamapps/common/$inst/SSFIV.exe"
        say "library:   $root"
        say "install:   $inst  appmanifest buildid=$abuild (manifest build=$build)"
        if [ "$abuild" = "$build" ]; then say "build:     MATCH"; else warn "build:     MISMATCH"; rc=1; fi
        if [ ! -f "$exe" ]; then warn "SSFIV.exe missing: $exe"; rc=1; continue; fi
        got=$(sha256_of "$exe")
        say "SSFIV.exe: $got"
        if [ -z "$want" ]; then
            say "sha256:    manifest game.ssfivSha256 is null (not pinned); pin the value above"
        elif [ "$got" = "$(printf %s "$want" | tr 'A-F' 'a-f')" ]; then
            say "sha256:    MATCH"
        else
            warn "sha256:    MISMATCH (expected $want)"
            rc=1
        fi
    done <<<"$dirs"
    [ "$seen" -eq 1 ] || die "appmanifest_45760.acf not found in any library (run: m0.sh library <dir>, or install via steam://install/45760)"
    return "$rc"
}

step_launch() {
    need_prefix
    local ver exe_dir
    ver=$(jq_manifest '.ember.version')
    exe_dir="$PFX/drive_c/sf4e-$ver"
    [ -f "$exe_dir/Launcher.exe" ] || die "Ember not installed; run: m0.sh ember-install"
    steam_running && steam_logged_on 0 || die "Steam is not running/logged on in this prefix; run: m0.sh steam-start"
    if ours_has_proc SSFIV.exe; then say "SSFIV.exe already running in this prefix (nothing to do)"; return 0; fi
    wine_env
    if [ "$HUD" -eq 1 ]; then export DXVK_HUD=fps,frametimes MTL_HUD_ENABLED=1; fi
    log_env
    say "launching C:\\sf4e-$ver\\Launcher.exe (detached; output: $LOGS/$STAMP-launcher-wine.log)"
    spawn_detached "$LOGS/$STAMP-launcher-wine.log" "$exe_dir" "$WINE" "C:\\sf4e-$ver\\Launcher.exe"
    sleep 5
    ours_tasklist | grep -iE 'Launcher\.exe|SSFIV\.exe|sf4-net\.exe|ember-discord\.exe' || warn "no Ember processes visible yet; see logs"
}

step_status() {
    local id wine_rel f user t
    id=$(jq_manifest '.id') wine_rel=$(jq_manifest '.engine.wine')
    user=$(id -un)
    if [ -x "$ENGINES/$id/$wine_rel" ]; then say "engine:  present ($ENGINES/$id)"; else say "engine:  MISSING"; fi
    if [ -f "$MARKER" ]; then say "prefix:  present ($PFX) $(tr '\n' ' ' <"$MARKER")"; else say "prefix:  MISSING"; return 0; fi
    if [ -f "$STEAM_DIR/steam.exe" ]; then say "steam:   installed"; else say "steam:   not installed"; fi
    if ours_alive; then
        say "wineserver: running for this prefix (pids: $(ours_pids | tr '\n' ' '))"
        load_engine
        t=$(ours_tasklist | grep -iE 'steam\.exe|steamwebhelper|Launcher\.exe|SSFIV\.exe|sf4-net\.exe|ember-discord\.exe' || true)
        printf '%s\n' "${t:-(no Steam/Ember processes)}" | sed 's/^/    /'
    else
        say "wineserver: not running for this prefix"
    fi
    say "steam login: $(conn_state 0 | cut -c1-100)"
    for f in launcher.log sf4e.log; do
        f="$PFX/drive_c/users/$user/AppData/Roaming/sf4e/logs/$f"
        [ -f "$f" ] || continue
        say "tail $f"
        tail -n 12 "$f" | sed 's/^/    /'
    done
}

step_kill() {
    [ -d "$PFX" ] || { say "no prefix at $PFX (nothing to do)"; return 0; }
    load_engine
    ours_alive || { say "no wineserver for this prefix (nothing to do)"; return 0; }
    say "wineserver -k for $PFX"
    WINEPREFIX="$PFX" "$WINESERVER" -k || true
    WINEPREFIX="$PFX" "$WINESERVER" -w || true
}

# ---- driver ------------------------------------------------------------------
run_step() {
    local name=$1 log rc
    shift
    mkdir -p "$LOGS"
    log="$LOGS/$STAMP-$name.log"
    set +e
    ( set -e; trap on_exit EXIT; "$@" ) 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
    set -e
    [ "$rc" -eq 0 ] || { printf '[m0] step %s failed (rc=%s); log: %s\n' "$name" "$rc" "$log" >&2; exit "$rc"; }
}

POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --manifest) MANIFEST=${2:?--manifest needs a file}; shift 2 ;;
        --cache-from) CACHE_FROM=${2:?--cache-from needs a dir}; shift 2 ;;
        --renderer) RENDERER=${2:?--renderer needs dxvk|wined3d}; shift 2 ;;
        --hud) HUD=1; shift ;;
        --debug) DEBUG_WINE=1; shift ;;
        --force) FORCE=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) POS+=("$1"); shift ;;
    esac
done
[ ${#POS[@]} -gt 0 ] || { usage >&2; exit 2; }
CMD=${POS[0]}
ARGS=()
[ ${#POS[@]} -le 1 ] || ARGS=("${POS[@]:1}")

command -v jq >/dev/null 2>&1 || die "required tool missing: jq"
init_paths

case "$CMD" in
    engine) run_step engine step_engine ;;
    prefix) run_step prefix step_prefix ;;
    steam-install) run_step steam-install step_steam_install ;;
    library) run_step library step_library ${ARGS[@]+"${ARGS[@]}"} ;;
    steam-login) run_step steam-login step_steam_login ;;
    steam-start) run_step steam-start step_steam_start ;;
    ember-install) run_step ember-install step_ember_install ;;
    game-check) run_step game-check step_game_check ;;
    launch)
        for a in ${ARGS[@]+"${ARGS[@]}"}; do [ "$a" = --hud ] && HUD=1; done
        run_step launch step_launch ;;
    status) run_step status step_status ;;
    kill) run_step kill step_kill ;;
    all)
        run_step engine step_engine
        run_step prefix step_prefix
        run_step steam-install step_steam_install ;;
    *) usage >&2; exit 2 ;;
esac
