#!/usr/bin/env bash
# Ember on macOS through a pinned `highball` CLI (spike #47). MIT, like the rest of Ember.
# Highball itself (GPL-3.0) stays a separate program that this script only starts. See scripts/highball/README.md.
# Run it (ember-hb.sh <command>) or source it and call the cmd_* functions. bash 3.2 compatible.
#
# Every highball call goes through hb(): it sets HIGHBALL_HOME so the user's own Highball data is never touched.
# Recipe and engine manifest are always passed as explicit paths (the CLI's id lookup needs a highball-db checkout).

EH_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EH_REPO=$(cd "$EH_HERE/../.." && pwd)

# Reuse the M0 helpers: manifest parsing, verified download, MANIFEST.txt check, Ember install/update, VDF helpers.
# shellcheck source=../macos-engine/lib.sh
. "$EH_REPO/scripts/macos-engine/lib.sh"
# shellcheck source=../macos-engine/ember.sh
. "$EH_REPO/scripts/macos-engine/ember.sh"

say() { printf '[ember-hb] %s\n' "$*"; }
warn() { printf '[ember-hb] WARN: %s\n' "$*" >&2; }
die() { printf '[ember-hb] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- pins and paths -----------------------------------------------------------
EH_TAG=${EMBER_HB_TAG:-v0.10.14}
EH_COMMIT=${EMBER_HB_COMMIT:-d3ae31779fd6dd93ae3ac15ed9c65518f60357e2}
EH_REPO_URL=${EMBER_HB_REPO_URL:-https://github.com/gauthierpiarrette/highball}
EH_ENGINE_ID=x64-sikarugir10.0_6-r23
EH_ENGINE_MANIFEST="$EH_REPO/docs/validation/macos-highball-engine-r23.json"
EH_RECIPE="$EH_HERE/ember-bottle.json"
EH_BOTTLE=${EMBER_HB_BOTTLE:-ember}
EH_ROOT=${EMBER_HB_ROOT:-$HOME/Library/Application Support/Ember/highball-cli}
EH_HOME=${EMBER_HB_HOME:-$EH_ROOT/home}   # becomes HIGHBALL_HOME
EH_SRC="$EH_ROOT/src"
EH_BIN=${EMBER_HB_BIN:-$EH_ROOT/bin/highball}
EH_LOGS="$EH_ROOT/logs"
EH_CACHE=${EMBER_HB_CACHE:-$EH_ROOT/cache}
EH_STEAM_ARGS="-silent -no-browser -nofriendsui"

eh_paths() { # fills the lib.sh variables so ember.sh and the VDF helpers work on the bottle
    command -v jq >/dev/null 2>&1 || die "required tool missing: jq"
    init_paths
    PFX="$EH_HOME/bottles/$EH_BOTTLE" CACHE="$EH_CACHE" LOGS="$EH_LOGS"
    STEAM_DIR="$PFX/drive_c/Program Files (x86)/Steam"
    LOGIN_LOG="$STEAM_DIR/logs/steamui_login.txt"
    mkdir -p "$EH_LOGS"
}

# The only place highball is invoked.
hb() {
    [ -x "$EH_BIN" ] || die "highball CLI not found at $EH_BIN; run: ember-hb.sh build-cli"
    HIGHBALL_HOME="$EH_HOME" "$EH_BIN" "$@"
}

hb_bg() { # <logfile> <highball args...>: detached; hb() is a shell function so run a subshell
    local lf=$1
    shift
    mkdir -p "$(dirname "$lf")"
    ( trap '' HUP; HIGHBALL_HOME="$EH_HOME" exec "$EH_BIN" "$@" >>"$lf" 2>&1 </dev/null ) &
    disown
}

need_bottle() { hb bottle list 2>/dev/null | awk -F'\t' '{print $1}' | grep -qx "$EH_BOTTLE" || die "bottle '$EH_BOTTLE' missing; run: ember-hb.sh setup"; }

# ---- build-cli ----------------------------------------------------------------
cmd_build_cli() {
    command -v git >/dev/null 2>&1 && command -v swift >/dev/null 2>&1 || die "git and swift are required"
    mkdir -p "$EH_ROOT"
    if [ ! -d "$EH_SRC/.git" ]; then
        say "cloning $EH_REPO_URL at $EH_TAG"
        git clone --quiet --depth 1 --branch "$EH_TAG" "$EH_REPO_URL" "$EH_SRC" || die "clone failed"
    fi
    local head
    head=$(git -C "$EH_SRC" rev-parse HEAD)
    [ "$head" = "$EH_COMMIT" ] || die "$EH_SRC is at $head, expected $EH_COMMIT (tag $EH_TAG); remove $EH_SRC and retry"
    say "swift build -c release --product highball ($EH_TAG, $head)"
    ( cd "$EH_SRC" && swift build -c release --product highball ) || die "swift build failed"
    mkdir -p "$(dirname "$EH_BIN")"
    cp "$EH_SRC/.build/release/highball" "$EH_BIN"
    cp "$EH_SRC/LICENSE" "$EH_ROOT/LICENSE-highball"
    say "binary: $EH_BIN"
    say "tag:    $EH_TAG"
    say "commit: $head"
    say "sha256: $(shasum -a 256 "$EH_BIN" | awk '{print $1}')"
    say "license: $EH_ROOT/LICENSE-highball (ship it with Ember.app, with the tag and $EH_REPO_URL)"
}

# ---- setup --------------------------------------------------------------------
# library <host-dir> [letter]: map a drive letter to the Steam library folder and list it in libraryfolders.vdf.
cmd_library() {
    local host=${1:-} letter=${2:-R} lc up link winp esc vdf next
    [ -n "$host" ] && [ -d "$host" ] || die "usage: library <host-dir> [letter]  (the directory containing the Steam library)"
    host=$(cd "$host" && pwd -P)
    lc=$(printf %s "$letter" | tr 'A-Z' 'a-z') up=$(printf %s "$letter" | tr 'a-z' 'A-Z')
    case "$lc" in [a-y]) ;; *) die "drive letter must be a single letter A-Y" ;; esac
    [ "$lc" != c ] || die "C: is the bottle's system drive"
    eh_paths
    need_bottle
    ! bottle_running || die "the bottle is running; run: ember-hb.sh kill (libraryfolders.vdf is only edited while Steam is stopped)"
    link="$PFX/dosdevices/$lc:"
    if [ -L "$link" ]; then
        [ "$(resolve_link "$link" || true)" = "$host" ] || die "$up: already maps to something else in this bottle"
    else
        [ ! -e "$link" ] || die "$link exists and is not a symlink"
        ln -s "$host" "$link"
        say "mapped $up: -> $host"
    fi
    local rel
    rel=$(find_lib_rel_eh "$host") || die "no 'steamapps' folder in $host or its subfolders"
    if [ "$rel" = . ]; then winp="$up:\\"; else winp="$up:\\$rel"; fi
    esc=$(printf %s "$winp" | sed 's/\\/\\\\/g')
    vdf="$STEAM_DIR/steamapps/libraryfolders.vdf"
    [ -f "$vdf" ] || die "$vdf missing; Steam must be in the bottle first (setup --steam-from <dir>)"
    if vdf_paths "$vdf" | tr 'A-Z' 'a-z' | sed 's/\\$//' | grep -qxF "$(printf %s "$winp" | tr 'A-Z' 'a-z' | sed 's/\\$//')"; then
        say "library $winp already in libraryfolders.vdf"
        return 0
    fi
    next=$(sed -nE 's/^[[:space:]]*"([0-9]+)"[[:space:]]*$/\1/p' "$vdf" | sort -n | tail -n 1)
    next=$(( ${next:--1} + 1 ))
    [ -f "$vdf.ehbak" ] || cp "$vdf" "$vdf.ehbak"
    BLK=$(vdf_block "$next" "$esc") awk '
        { l[NR] = $0 }
        END { last = 0
              for (i = NR; i > 0; i--) if (l[i] ~ /^[ \t]*}[ \t\r]*$/) { last = i; break }
              if (!last) exit 2
              for (i = 1; i <= NR; i++) { if (i == last) print ENVIRON["BLK"]; print l[i] } }' "$vdf" >"$vdf.new" \
        || { rm -f "$vdf.new"; die "libraryfolders.vdf has no closing brace; not modified"; }
    mv "$vdf.new" "$vdf"
    say "registered library $winp as entry \"$next\""
}

find_lib_rel_eh() { # "." when host itself is a library, else the child folder holding steamapps
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

# copy_login <wine prefix>: Steam keeps its saved sign-in in %LOCALAPPDATA%\Steam\local.vdf, encrypted with the
# prefix's MachineGuid. Both are needed for a copied Steam folder to stay signed in (otherwise: WaitingForCredentials).
copy_login() {
    local src=$1 user guid
    user=$(id -un)
    [ -f "$src/drive_c/users/$user/AppData/Local/Steam/local.vdf" ] || die "no local.vdf under $src"
    guid=$(sed -nE 's/^"MachineGuid"="([0-9a-fA-F-]{36})"$/\1/p' "$src/system.reg" | sed -n 1p)
    [ -n "$guid" ] || die "no MachineGuid in $src/system.reg"
    ! bottle_running || die "the bottle is running; run: ember-hb.sh kill"
    mkdir -p "$PFX/drive_c/users/$user/AppData/Local/Steam"
    cp "$src/drive_c/users/$user/AppData/Local/Steam/local.vdf" "$PFX/drive_c/users/$user/AppData/Local/Steam/local.vdf"
    hb run "$EH_BOTTLE" 'C:\windows\system32\reg.exe' -- add 'HKLM\Software\Microsoft\Cryptography' /v MachineGuid /t REG_SZ /d "$guid" /f >/dev/null \
        || die "could not set MachineGuid"
    hb bottle kill "$EH_BOTTLE" >/dev/null
    say "copied Steam sign-in (local.vdf) and MachineGuid $guid"
}

# setup [--steam-from <steam dir>] [--steam-recipe <steam.json>] [--login-from <wine prefix>] [--library <host-dir> [letter]]
cmd_setup() {
    local steam_from="" steam_recipe="" lib="" letter=R login_from=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --steam-from) steam_from=${2:?}; shift 2 ;;
            --steam-recipe) steam_recipe=${2:?}; shift 2 ;;
            --login-from) login_from=${2:?}; shift 2 ;;
            --library) lib=${2:?}; shift 2; case "${1:-}" in [A-Za-z]) letter=$1; shift ;; esac ;;
            *) die "setup: unknown option $1" ;;
        esac
    done
    eh_paths
    preflight_tools
    mkdir -p "$EH_HOME"
    [ -f "$EH_ENGINE_MANIFEST" ] || die "engine manifest missing: $EH_ENGINE_MANIFEST"
    if hb engine list 2>/dev/null | awk -F'\t' '{print $1}' | grep -qx "$EH_ENGINE_ID"; then
        say "engine $EH_ENGINE_ID already installed"
    else
        say "installing engine $EH_ENGINE_ID (no D3DMetal licence is accepted)"
        hb engine install "$EH_ENGINE_MANIFEST" | grep -v '^  [a-z0-9-]*: [0-9]* / [0-9]* MB$' || true
    fi
    if hb bottle list 2>/dev/null | awk -F'\t' '{print $1}' | grep -qx "$EH_BOTTLE"; then
        say "bottle $EH_BOTTLE already exists"
    else
        say "creating bottle $EH_BOTTLE (first wineboot takes about a minute)"
        hb bottle create "$EH_BOTTLE" --engine "$EH_ENGINE_ID" || die "bottle create failed"
    fi
    hb recipe apply "$EH_BOTTLE" "$EH_RECIPE" >/dev/null || die "recipe apply failed"
    hb bottle set "$EH_BOTTLE" dxvkasync 1 >/dev/null
    say "bottle settings: renderer dxmt (D3D9 goes to DXVK), msync, SSFIV.exe d3d9.maxFrameLatency=1, DXVK async on"
    if [ ! -f "$STEAM_DIR/steam.exe" ]; then
        if [ -n "$steam_from" ]; then
            [ -f "$steam_from/steam.exe" ] || die "no steam.exe in $steam_from"
            say "copying Steam from $steam_from (login state included)"
            mkdir -p "$(dirname "$STEAM_DIR")"
            ditto "$steam_from" "$STEAM_DIR"
            rm -rf "$STEAM_DIR/logs"
        elif [ -n "$steam_recipe" ]; then
            say "installing Steam with the recipe $steam_recipe (15 to 25 minutes on the first start)"
            hb recipe apply "$EH_BOTTLE" "$steam_recipe" || die "Steam recipe failed"
        else
            die "Steam is not in the bottle; pass --steam-from <dir with steam.exe> or --steam-recipe <steam.json>"
        fi
    fi
    if [ -n "$login_from" ]; then copy_login "$login_from"; fi
    if [ -n "$lib" ]; then cmd_library "$lib" "$letter"; fi
    local ver
    ver=$(jq_manifest '.ember.version')
    ember_install "$ver" "$(jq_manifest '.ember.url')" "$(jq_manifest '.ember.sha256')" "$(jq_manifest '.ember.asset // empty')"
    pin_ember "$ver"
}

pin_ember() { # <version dir suffix>
    local dir=sf4e-$1
    if hb pin list "$EH_BOTTLE" 2>/dev/null | awk -F'\t' '{print $1}' | grep -qx Ember; then return 0; fi
    hb pin add "$EH_BOTTLE" Ember "$dir/Launcher.exe" >/dev/null && say "pinned Ember -> $dir/Launcher.exe"
}

# ---- process state ------------------------------------------------------------
bottle_ps() { hb bottle ps "$EH_BOTTLE" 2>/dev/null || true; }
bottle_running() { [ -n "$(bottle_ps | grep -iE 'wineserver|steam\.exe|Launcher\.exe|SSFIV\.exe')" ]; }
has_proc() { bottle_ps | grep -qiF "$1"; }

# ---- steam-start --------------------------------------------------------------
cmd_steam_start() {
    eh_paths
    need_bottle
    [ -f "$STEAM_DIR/steam.exe" ] || die "Steam not in the bottle; run: ember-hb.sh setup --steam-from <dir>"
    local off=0 t=0 timeout=${EMBER_HB_STEAM_TIMEOUT:-180}
    if has_proc steam.exe && steam_logged_on 0; then say "Steam already running and logged on"; return 0; fi
    if ! has_proc steam.exe; then
        [ ! -f "$LOGIN_LOG" ] || off=$(stat -f %z "$LOGIN_LOG")
        say "starting Steam: $EH_STEAM_ARGS (log: $EH_LOGS/$STAMP-steam.log)"
        # shellcheck disable=SC2086
        hb_bg "$EH_LOGS/$STAMP-steam.log" run "$EH_BOTTLE" Steam -- $EH_STEAM_ARGS
    fi
    while [ "$t" -lt "$timeout" ]; do
        if steam_logged_on "$off"; then say "Steam logged on after ${t}s"; return 0; fi
        sleep 1
        t=$((t + 1))
        [ -f "$LOGIN_LOG" ] && [ "$off" -gt "$(stat -f %z "$LOGIN_LOG")" ] && off=0
    done
    die "Steam did not reach 'SetLoginState: Success' within ${timeout}s; last: $(conn_state "$off")"
}

# ---- launch -------------------------------------------------------------------
cmd_launch() {
    eh_paths
    need_bottle
    has_proc steam.exe && steam_logged_on 0 || die "Steam is not running/logged on; run: ember-hb.sh steam-start"
    grep -q '"45760"' "$STEAM_DIR/steamapps/libraryfolders.vdf" 2>/dev/null \
        || die "Steam has not adopted a library containing app 45760 (SSFIV would boot as Arcade Edition); run: kill, then steam-start"
    if has_proc SSFIV.exe; then say "SSFIV.exe already running"; return 0; fi
    ember_update
    local newest ver dir
    newest=$(ember_newest)
    [ -n "$newest" ] || die "Ember is not installed; run: ember-hb.sh setup"
    ver=${newest%% *} dir=${newest#* }
    say "launching Ember $ver: C:\\$dir\\Launcher.exe (log: $EH_LOGS/$STAMP-launcher.log)"
    hb_bg "$EH_LOGS/$STAMP-launcher.log" run "$EH_BOTTLE" "C:\\$dir\\Launcher.exe"
    sleep 5
    bottle_ps | grep -iE 'Launcher\.exe|SSFIV\.exe|sf4-net\.exe|ember-discord\.exe' || warn "no Ember processes visible yet; see $EH_LOGS"
}

cmd_kill() { eh_paths; need_bottle; hb bottle kill "$EH_BOTTLE"; }

cmd_status() {
    local f user
    eh_paths
    say "HIGHBALL_HOME=$EH_HOME"
    [ -x "$EH_BIN" ] || { say "cli: missing ($EH_BIN)"; return 0; }
    say "cli: $EH_BIN sha256 $(shasum -a 256 "$EH_BIN" | awk '{print $1}') (pinned tag $EH_TAG, $EH_COMMIT)"
    hb engine list || true
    hb bottle list || true
    say "ember: $(ember_installs | sort -V -k1,1 | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    say "processes:"
    bottle_ps | sed 's/^/    /'
    say "steam login: $(conn_state 0 | cut -c1-100)"
    user=$(id -un)
    for f in launcher.log sf4e.log; do
        f="$PFX/drive_c/users/$user/AppData/Roaming/sf4e/logs/$f"
        [ -f "$f" ] || continue
        say "tail $f"
        tail -n 12 "$f" | sed 's/^/    /'
    done
}

cmd_usage() {
    cat <<'EOF'
usage: ember-hb.sh <command>
  build-cli                 clone the pinned highball tag, build the CLI, print tag/commit/sha256
  setup [--steam-from DIR] [--steam-recipe steam.json] [--login-from WINEPREFIX] [--library HOST_DIR [LETTER]]
                            install engine r23, create the bottle, apply the Ember recipe, put Steam
                            and the Steam library in it, install Ember (verified) and pin it
  library HOST_DIR [LETTER] map a drive letter to a Steam library and list it in libraryfolders.vdf
  steam-start               start Steam hidden and wait for the logon
  launch                    check for an Ember update, then start Ember's Launcher through highball
  kill                      stop every process of the bottle
  status                    CLI, engine, bottle, processes, Steam logon, Ember logs
environment: EMBER_HB_ROOT, EMBER_HB_HOME (HIGHBALL_HOME), EMBER_HB_BIN, EMBER_HB_BOTTLE, EMBER_HB_TAG, EMBER_HB_COMMIT
EOF
}

eh_main() {
    local c=${1:-}
    [ $# -eq 0 ] || shift
    case "$c" in
        build-cli) cmd_build_cli "$@" ;;
        setup) cmd_setup "$@" ;;
        library) cmd_library "$@" ;;
        steam-start) cmd_steam_start "$@" ;;
        launch) cmd_launch "$@" ;;
        kill) cmd_kill "$@" ;;
        status) cmd_status "$@" ;;
        *) cmd_usage; [ -z "$c" ] || exit 2 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    eh_main "$@"
fi
