# Ember install and update steps for scripts/macos-engine/m0.sh (sourced after lib.sh, bash 3.2 compatible).
# shellcheck shell=bash

ember_dir() { printf '%s/drive_c/sf4e-%s' "$PFX" "$1"; }

# ember_install <version> <url> <sha256> <cache file name>: verified, atomic install to C:\sf4e-<version>.
ember_install() {
    local ver=$1 url=$2 sha=$3 file dest tmp top n list out
    dest=$(ember_dir "$ver")
    if [ -f "$dest/Launcher.exe" ]; then say "Ember $ver already installed: $dest (nothing to do)"; return 0; fi
    [ ! -e "$dest" ] || die "$dest exists without Launcher.exe; remove it and rerun"
    file="$CACHE/${4:-$(cache_name "$url")}"
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

step_ember_install() {
    preflight_tools
    need_prefix
    ember_install "$(jq_manifest '.ember.version')" "$(jq_manifest '.ember.url')" "$(jq_manifest '.ember.sha256')" \
        "$(jq_manifest '.ember.asset // empty')"
}

# "<version> <dir name>" per install with Launcher.exe. The version comes from BUILD_INFO.txt, because Ember's
# own updater replaces an install in place and leaves the folder name behind.
ember_installs() {
    local d v
    for d in "$PFX"/drive_c/sf4e-*; do
        [ -f "$d/Launcher.exe" ] || continue
        v=$(tr -d '\r' <"$d/BUILD_INFO.txt" 2>/dev/null | sed -n 's/^Release: *//p' | sed -n 1p)
        printf '%s %s\n' "${v:-${d##*/sf4e-}}" "${d##*/}"
    done
}

# Newest installed Ember as "<version> <dir name>"; empty when none.
ember_newest() { ember_installs | sort -V -k1,1 | sed -n '$p'; }

ver_newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n '$p')" = "$1" ]; }

# Sets LATEST_VER, LATEST_URL, LATEST_SHA, LATEST_ASSET from the repo's latest stable release (drafts and
# pre-releases excluded by /releases/latest). The zip is checked against the asset's GitHub "digest", as Ember's
# own updater does; a release without one is refused.
ember_latest() {
    local repo json tag
    repo=$(jq_manifest '.ember.repo')
    json=$(curl -fsSL --connect-timeout 10 --max-time 30 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases/latest") || return 1
    tag=$(jq -r '.tag_name // empty' <<<"$json")
    [ -n "$tag" ] || return 1
    LATEST_VER=${tag#v}
    LATEST_ASSET="sf4-ember-netplay-$LATEST_VER.zip"
    LATEST_URL=$(jq -r --arg n "$LATEST_ASSET" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$json")
    LATEST_SHA=$(jq -r --arg n "$LATEST_ASSET" '.assets[] | select(.name == $n) | .digest // empty' <<<"$json")
    LATEST_SHA=${LATEST_SHA#sha256:}
    [ -n "$LATEST_URL" ] || die "Ember $tag has no $LATEST_ASSET asset"
    [[ "$LATEST_SHA" =~ ^[0-9a-fA-F]{64}$ ]] || die "Ember $tag: $LATEST_ASSET has no sha256 digest on GitHub; refusing to install"
}

# Installs the latest stable release when it is newer than every installed Ember. A failed check (offline,
# rate limit) only warns: the installed build still launches. A failed install of a found update is fatal.
ember_update() {
    local cur
    cur=$(ember_newest)
    cur=${cur%% *}
    if ! ember_latest; then
        warn "Ember update check failed (offline or GitHub unavailable); using installed ${cur:-none}"
        return 0
    fi
    if [ -n "$cur" ] && ! ver_newer "$LATEST_VER" "$cur"; then
        say "Ember $cur is up to date (latest release: $LATEST_VER)"
        return 0
    fi
    say "Ember $LATEST_VER available (installed: ${cur:-none}); installing"
    preflight_tools
    ember_install "$LATEST_VER" "$LATEST_URL" "$LATEST_SHA" "$LATEST_ASSET"
}

step_ember_update() {
    need_prefix
    ember_update
}
