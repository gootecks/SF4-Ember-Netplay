#!/usr/bin/env bash
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$PKG/build}"
SCRATCH="${SCRATCH:-$PKG/.build}"
VERSION="${EMBER_APP_VERSION:-0.1.0}"
BUILD_NUMBER="${EMBER_APP_BUILD:-1}"
APP="$BUILD/Ember.app"
DMG="$BUILD/Ember.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

step() { printf '==> %s\n' "$*"; }

build() {
    step "swift build -c release"
    swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" --arch arm64
    BIN_DIR="$(swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" --arch arm64 --show-bin-path)"
}

assemble() {
    step "assemble $APP"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN_DIR/Ember" "$APP/Contents/MacOS/Ember"
    sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" \
        "$PKG/Resources/Info.plist" > "$APP/Contents/Info.plist"
    for bundle in "$BIN_DIR"/*.bundle; do
        [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
    done
    plutil -lint "$APP/Contents/Info.plist"
}

sign() {
    step "codesign (identity: $SIGN_IDENTITY)"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
}

package_dmg() {
    step "create $DMG"
    local stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/ember-dmg.XXXXXX")"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    rm -f "$DMG"
    hdiutil create -volname Ember -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$stage"
}

build
assemble
sign
package_dmg

step "done"
ls -ld "$APP"
ls -l "$DMG"
