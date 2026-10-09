# Shared helpers for scripts/macos-engine/m0.sh (sourced, bash 3.2 compatible).
# shellcheck shell=bash

US=$'\x1f' # field separator for jq rows (never appears in manifest values)
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="$SELF_DIR/../../docs/validation/macos-engine-manifest.json"
ROOT="${EMBER_M0_ROOT:-$HOME/Library/Application Support/Ember-M0}"
STAMP=$(date +%Y%m%d-%H%M%S)
FORCE=0 DEBUG_WINE=0 HUD=0 RENDERER="" CACHE_FROM=""
WINE="" WINESERVER="" WINEBOOT="" ENGINE_DIR=""
CLEANUP_PATHS=""
HIGHBALL_DIR="$HOME/Library/Application Support/Highball"

say() { printf '[m0] %s\n' "$*"; }
warn() { printf '[m0] WARN: %s\n' "$*" >&2; }
die() { printf '[m0] ERROR: %s\n' "$*" >&2; exit 1; }

init_paths() {
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"
    CACHE="$ROOT/cache" ENGINES="$ROOT/engine" PFX="$ROOT/prefix" LOGS="$ROOT/logs"
    STEAM_DIR="$PFX/drive_c/Program Files (x86)/Steam"
    LOGIN_LOG="$STEAM_DIR/logs/steamui_login.txt"
    MARKER="$PFX/.ember-m0-prefix"
}

jq_manifest() { jq -r "$@" "$MANIFEST"; }

sha256_of() { shasum -a 256 "$1" | awk '{print tolower($1)}'; }

# ---- cleanup / rollback ------------------------------------------------------
add_cleanup() { CLEANUP_PATHS="$CLEANUP_PATHS$1"$'\n'; }
clear_cleanup() { CLEANUP_PATHS=""; }
on_exit() {
    local rc=$? p
    if [ "$rc" -ne 0 ] && [ -n "$CLEANUP_PATHS" ]; then
        if [ -n "${ON_FAIL_FN:-}" ]; then "$ON_FAIL_FN" || true; fi
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            warn "rolling back: removing $p"
            rm -rf "$p"
        done <<<"$CLEANUP_PATHS"
    fi
    return "$rc"
}

# ---- preflight ---------------------------------------------------------------
preflight_tools() {
    local t
    for t in jq curl shasum ditto tar awk; do
        command -v "$t" >/dev/null 2>&1 || die "required tool missing: $t"
    done
    arch -x86_64 /usr/bin/true >/dev/null 2>&1 \
        || die "Rosetta 2 not available (softwareupdate --install-rosetta --agree-to-license)"
}

need_space() {
    local kb
    mkdir -p "$ROOT"
    kb=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
    if [ "$kb" -lt $((4 * 1024 * 1024)) ]; then
        if [ "$FORCE" -eq 1 ]; then
            warn "only $((kb / 1024)) MB free on the volume of $ROOT (continuing: --force)"
        else
            die "only $((kb / 1024)) MB free on the volume of $ROOT; need >= 4 GB (override with --force)"
        fi
    fi
}

# ---- download / extract ------------------------------------------------------
# fetch_verified <url> <sha256> <dest>
fetch_verified() {
    local url=$1 want got dest=$3 base
    want=$(printf %s "$2" | tr 'A-F' 'a-f')
    base=$(basename "$dest")
    case "$want" in
        [0-9a-f]*) [ "${#want}" -eq 64 ] || die "manifest sha256 for $base is not 64 hex chars" ;;
        *) die "manifest sha256 for $base is missing" ;;
    esac
    if [ -f "$dest" ]; then
        got=$(sha256_of "$dest")
        if [ "$got" = "$want" ]; then say "cache hit: $base"; return 0; fi
        warn "cached $base has wrong SHA-256; refetching"
        rm -f "$dest"
    fi
    if [ -n "$CACHE_FROM" ] && [ -f "$CACHE_FROM/$base" ]; then
        got=$(sha256_of "$CACHE_FROM/$base")
        if [ "$got" = "$want" ]; then
            say "copying $base from $CACHE_FROM (SHA matches)"
            cp "$CACHE_FROM/$base" "$dest.part" && mv "$dest.part" "$dest"
            return 0
        fi
        warn "$CACHE_FROM/$base has a different SHA-256 ($got); downloading instead"
    fi
    say "downloading $url"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" || { rm -f "$dest.part"; die "download failed: $url"; }
    got=$(sha256_of "$dest.part")
    if [ "$got" != "$want" ]; then
        rm -f "$dest.part"
        die "SHA-256 mismatch for $url
         expected: $want
         actual:   $got
       The upstream file changed (e.g. Valve rotated the Steam installer, or a release asset was replaced).
       Review it, then update the manifest sha256 deliberately."
    fi
    mv "$dest.part" "$dest"
}

cache_name() { basename "${1%%\?*}"; }

extract_archive() { # <format> <file> <dir>
    case "$1" in
        tar.xz) tar -xJf "$2" -C "$3" ;;
        tar.gz | tgz) tar -xzf "$2" -C "$3" ;;
        zip) ditto -x -k "$2" "$3" ;;
        *) die "unsupported archive format: $1" ;;
    esac
}

copy_item() { # <src> <dst>: dir -> contents copied into dst; file -> dst is the full destination file path. Symlinks stay symlinks.
    local src=$1 dst=$2
    [ -e "$src" ] || [ -L "$src" ] || die "install source missing in archive: ${src#"$ROOT"/}"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
        mkdir -p "$dst"
        cp -Rpf "$src"/. "$dst"/
    else
        mkdir -p "$(dirname "$dst")"
        if [ -L "$dst" ] || [ -f "$dst" ]; then rm -f "$dst"; fi
        cp -Rpf "$src" "$dst"
    fi
}

# Archives are extracted once per run and shared between components with the same sha256.
EXTRACTED=""
X_DIR=""
extracted_dir() { # <sha256> <format> <file> -> sets X_DIR (no subshell: state must persist)
    local sha=$1 line x
    while IFS= read -r line; do
        [ "${line%%=*}" = "$sha" ] || continue
        X_DIR=${line#*=}
        return 0
    done <<<"$EXTRACTED"
    x=$(mktemp -d "$CACHE/extract.XXXXXX")
    add_cleanup "$x"
    extract_archive "$2" "$3" "$x"
    EXTRACTED="$EXTRACTED$sha=$x"$'\n'
    X_DIR=$x
}
drop_extracted() {
    local line
    while IFS= read -r line; do [ -z "$line" ] || rm -rf "${line#*=}"; done <<<"$EXTRACTED"
    EXTRACTED=""
}

# install_component <index> <engine|prefix> <base-dir>
install_component() {
    local i=$1 scope=$2 base=$3 name url sha fmt rows file x from to rel
    name=$(jq_manifest --argjson i "$i" '.components[$i].name')
    if [ "$scope" = prefix ] && [ "$RENDERER" = wined3d ] && [ "$name" = dxvk ]; then
        say "renderer wined3d: skipping DXVK files"
        return 0
    fi
    rows=$(jq_manifest --argjson i "$i" --arg s "$scope:" \
        '.components[$i].install[]? | select(.to | startswith($s)) | [.from, .to] | join("\u001f")')
    [ -n "$rows" ] || return 0
    url=$(jq_manifest --argjson i "$i" '.components[$i].url')
    sha=$(jq_manifest --argjson i "$i" '.components[$i].sha256' | tr 'A-F' 'a-f')
    fmt=$(jq_manifest --argjson i "$i" '.components[$i].format')
    file="$CACHE/$(cache_name "$url")"
    say "component $name ($scope)"
    fetch_verified "$url" "$sha" "$file"
    extracted_dir "$sha" "$fmt" "$file"
    x=$X_DIR
    while IFS="$US" read -r from to; do
        [ -n "$to" ] || continue
        rel=${to#"$scope:"}
        case "/$from/$rel/" in */../*) die "refusing path traversal in install step: $from -> $to" ;; esac
        if [ -z "$from" ] || [ "$from" = . ]; then copy_item "$x" "$base/$rel"; else copy_item "$x/$from" "$base/$rel"; fi
    done <<<"$rows"
}

# ---- wine --------------------------------------------------------------------
load_engine() {
    [ -z "$WINE" ] || return 0
    local id w ws wb
    id=$(jq_manifest '.id')
    ENGINE_DIR="$ENGINES/$id"
    w=$(jq_manifest '.engine.wine') ws=$(jq_manifest '.engine.wineserver')
    wb=$(jq_manifest '.engine.wineboot // empty')
    WINE="$ENGINE_DIR/$w" WINESERVER="$ENGINE_DIR/$ws"
    WINEBOOT=""
    [ -z "$wb" ] || WINEBOOT="$ENGINE_DIR/$wb"
    [ -x "$WINE" ] || die "engine not installed ($ENGINE_DIR); run: m0.sh engine"
}

resolve_renderer() {
    if [ -z "$RENDERER" ]; then
        RENDERER=dxvk
        [ ! -f "$MARKER" ] || RENDERER=$(sed -n 's/^renderer=//p' "$MARKER")
    fi
    case "$RENDERER" in dxvk | wined3d) ;; *) die "unknown renderer: $RENDERER (dxvk|wined3d)" ;; esac
}

export_env_block() { # <jq object path>
    local rows k v
    rows=$(jq_manifest "($1 // {}) | to_entries[] | [.key, (.value | tostring)] | join(\"\\u001f\")")
    while IFS="$US" read -r k v; do
        [ -n "$k" ] || continue
        export "$k=$v"
    done <<<"$rows"
}

wine_env() {
    load_engine
    resolve_renderer
    local fw="$ENGINE_DIR/frameworks" gst="$ENGINE_DIR/frameworks/GStreamer.framework/Versions/1.0/lib"
    export WINEPREFIX="$PFX"
    export WINEDEBUG=-all
    PATH="$(dirname "$WINE"):$PATH"
    export PATH
    export DYLD_FALLBACK_FRAMEWORK_PATH="$fw"
    export DYLD_FALLBACK_LIBRARY_PATH="$fw:$gst"
    [ ! -d "$ENGINE_DIR/lib" ] || DYLD_FALLBACK_LIBRARY_PATH="$DYLD_FALLBACK_LIBRARY_PATH:$ENGINE_DIR/lib"
    export GST_PLUGIN_PATH="$gst/gstreamer-1.0"
    # Manifest env wins over the -all default above (it sets WINEDEBUG=fixme-all); --debug restores Wine's default.
    if [ "$RENDERER" = wined3d ]; then export_env_block '.fallback.env'; else export_env_block '.prefix.env'; fi
    if [ "$DEBUG_WINE" -eq 1 ]; then unset WINEDEBUG; fi
}

run_wine() { "$WINE" "$@"; }
wait_wineserver() { "$WINESERVER" -w; }

log_env() {
    say "effective environment (renderer=$RENDERER):"
    env | sort | grep -E '^(WINE|DXVK|MTL_|MVK_|DYLD_|PATH=)' | sed 's/^/    /' || true
}

# ---- process inspection (our prefix only) -------------------------------------
# PID of this prefix's wineserver: it keeps /tmp/.wine-<uid>/server-<dev>-<ino>/lock open (hex, Wine's server dir naming).
# ps cannot see WINEPREFIX in Wine processes' environments, and macOS lsof cannot match unix sockets by path.
ours_pids() {
    local f
    [ -d "$PFX" ] || return 0
    f="/tmp/.wine-$(id -u)/server-$(printf '%x-%x' "$(stat -f %d "$PFX")" "$(stat -f %i "$PFX")")/lock"
    [ -f "$f" ] || return 0
    lsof -t "$f" 2>/dev/null | sort -un || true
}
ours_alive() { [ -n "$(ours_pids)" ]; }

ours_tasklist() {
    ours_alive || return 0
    wine_env
    "$WINE" tasklist 2>/dev/null | tr -d '\r' || true
}
ours_has_proc() { ours_tasklist | grep -qiF "$1"; }
steam_running() { ours_has_proc steam.exe; }

# Last "SetLoginState: <state>" line in steamui_login.txt after byte offset $1.
conn_state() {
    local off=${1:-0} size
    [ -f "$LOGIN_LOG" ] || return 0
    size=$(stat -f %z "$LOGIN_LOG")
    [ "$off" -le "$size" ] || off=0
    { tail -c +$((off + 1)) "$LOGIN_LOG" | grep -a 'SetLoginState: ' | tail -n 1; } || true
}
steam_logged_on() { case "$(conn_state "${1:-0}")" in *'SetLoginState: Success'*) return 0 ;; *) return 1 ;; esac; }

# spawn_detached <logfile> <cwd> <cmd...>: survives the calling shell.
# No nohup: /usr/bin/nohup is SIP-protected, so exec'ing through it strips DYLD_* and wineserver can't find its dylibs.
spawn_detached() {
    local lf=$1 cwd=$2
    shift 2
    mkdir -p "$(dirname "$lf")"
    ( cd "$cwd" && trap '' HUP && exec "$@" >>"$lf" 2>&1 </dev/null ) &
    disown || die "failed to spawn: $*"
}

# ---- paths / VDF ---------------------------------------------------------------
resolve_link() { # symlink -> absolute physical dir
    local t
    t=$(readlink "$1") || return 1
    case "$t" in /*) ;; *) t="$(dirname "$1")/$t" ;; esac
    ( cd "$t" 2>/dev/null && pwd -P )
}

win_to_unix() { # C:\foo\bar -> host path via dosdevices
    local p=$1 l base rest
    l=$(printf %s "${p:0:1}" | tr 'A-Z' 'a-z')
    [ "${p:1:1}" = ":" ] || return 1
    rest=$(printf %s "${p:2}" | tr '\\' '/')
    if [ "$l" = c ]; then base="$PFX/drive_c"; else base=$(resolve_link "$PFX/dosdevices/$l:") || return 1; fi
    printf '%s%s\n' "$base" "$rest"
}

vdf_paths() { # unescaped Windows paths from libraryfolders.vdf
    sed -nE 's/^[[:space:]]*"path"[[:space:]]+"(.*)"[[:space:]]*$/\1/p' "$1" | sed 's/\\\\/\\/g'
}

acf_val() { sed -nE "s/^[[:space:]]*\"$2\"[[:space:]]+\"([^\"]*)\".*/\\1/p" "$1" | sed -n 1p; }
