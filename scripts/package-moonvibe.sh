#!/bin/bash
# Build Moonvibe and package it as a self-contained DMG for Apple Silicon Macs,
# with the Sparkle appcast that announces it: build/release/Moonvibe-<version>.dmg
# and build/release/appcast.xml, both for the version's GitHub release.
#
# Without a Developer ID, the app is signed ad hoc: Gatekeeper asks the user to
# confirm the first launch (see README.md). Updates are verified with EdDSA
# instead: sign_update signs the DMG and the appcast with the private key in
# the login Keychain, which only the maintainer has.
#
# The DMG window (background, icon positions, volume icon) comes from dmgbuild,
# which the first run installs from PyPI into build/dmgbuild-env. Its layout is
# in scripts/dmg: settings.py, and make-background.swift for the background.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

VERSION=$(cat app/moonvibe-version.txt)
RELEASE_DIR=build/release
DMG=$RELEASE_DIR/Moonvibe-$VERSION.dmg

# The bundle is staged outside the source tree: in a folder synced by iCloud
# Drive, the file provider keeps tagging bundles with extended attributes
# that codesign rejects
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
APP=$STAGING/Moonvibe.app

fail()
{
    echo "$1" 1>&2
    exit 1
}

./build-mac.sh

echo "Staging Moonvibe $VERSION"
# macdeployqt rewrites the bundle in place, so it works on a copy: the dev
# build keeps linking against libs/qt
cp -R build/app/Moonvibe.app "$STAGING/"
xattr -cr "$APP"

# No QML modules: the SwiftUI shell loads no QML, which only serves the
# command line modes and the MOONVIBE_QML fallback of development builds
echo "Bundling Qt"
libs/qt/current/bin/macdeployqt "$APP" || fail "macdeployqt failed!"

# Sparkle's XPC services only serve sandboxed apps
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

# Moonvibe runs on Apple Silicon only (its Swift shell is built for arm64): drop the
# Intel half of the universal Qt, Sparkle and prebuilt libraries
echo "Keeping arm64 only"
ditto --arch arm64 "$APP" "$STAGING/arm64/Moonvibe.app" || fail "Thinning failed!"
rm -rf "$APP"
mv "$STAGING/arm64/Moonvibe.app" "$APP"

# Every library must come from the bundle or the system, and run on the macOS the
# app asks for: one built for a newer macOS doesn't load on older ones. A library's
# own install name (otool -D) doesn't matter for loading, only what it loads.
MINIMUM_MACOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
echo "Checking the bundled libraries (macOS $MINIMUM_MACOS and later)"
while IFS= read -r -d '' binary; do
    file "$binary" | grep -q "Mach-O" || continue
    ownName=$(otool -arch arm64 -D "$binary" | tail -n +2)
    outside=$(otool -arch arm64 -L "$binary" | tail -n +2 | awk '{print $1}' | grep -v -x -F "${ownName:-none}" \
        | grep -v -E "^(@rpath|@executable_path|@loader_path)/|^/usr/lib/|^/System/" || true)
    if [ -n "$outside" ]; then
        echo "$outside" 1>&2
        fail "$binary loads libraries from outside the bundle"
    fi
    minos=$(otool -arch arm64 -l "$binary" | awk '/LC_BUILD_VERSION/ { found = 1 } found && /minos/ { print $2; exit }')
    if [ -n "$minos" ] && [ "$(printf '%s\n%s\n' "$minos" "$MINIMUM_MACOS" | sort -V | tail -1)" != "$MINIMUM_MACOS" ]; then
        fail "$binary needs macOS $minos, newer than $MINIMUM_MACOS"
    fi
done < <(find "$APP" -type f -print0)

# Thinning broke the signatures. Sparkle's helpers sit where --deep doesn't look, and
# an unsigned Autoupdate would break every update after this one: inside out.
echo "Signing ad hoc"
xattr -cr "$APP"
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
codesign --force --sign - "$SPARKLE/Autoupdate" || fail "Signing Autoupdate failed!"
codesign --force --sign - "$SPARKLE/Updater.app" || fail "Signing Updater.app failed!"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework" || fail "Signing Sparkle failed!"
codesign --force --deep --sign - "$APP" || fail "Signing failed!"
codesign --verify --deep --strict "$APP" || fail "Signature check failed!"
codesign --verify --strict "$SPARKLE/Autoupdate" || fail "Autoupdate's signature check failed!"

echo "Creating the DMG"
# dmgbuild, pinned, in a virtual environment of its own under build/
DMGBUILD_ENV=build/dmgbuild-env
if [ ! -x "$DMGBUILD_ENV/bin/dmgbuild" ]; then
    python3 -m venv "$DMGBUILD_ENV" || fail "Couldn't create the dmgbuild environment"
    "$DMGBUILD_ENV/bin/pip" install --quiet --disable-pip-version-check dmgbuild==1.6.5 || fail "Couldn't install dmgbuild"
fi
mkdir -p "$RELEASE_DIR"
"$DMGBUILD_ENV/bin/dmgbuild" -s scripts/dmg/settings.py \
    -D app="$APP" -D background=scripts/dmg/background.tiff -D volume_icon=app/moonvibe.icns \
    "Moonvibe $VERSION" "$DMG" || fail "dmgbuild failed!"

# The release notes are the version's CHANGELOG.md section. sign_update may ask
# for access to the key in the login Keychain.
echo "Creating the appcast"
SPARKLE_BIN=libs/sparkle/bin
APPCAST=$RELEASE_DIR/appcast.xml
rm -f "$APPCAST"
ENCLOSURE=$("$SPARKLE_BIN/sign_update" "$DMG") || fail "Couldn't sign the DMG: is Sparkle's key in the login Keychain?"
python3 -I scripts/make-appcast.py "$VERSION" \
    "https://github.com/ciremek/moonvibe/releases/download/moonvibe-v$VERSION/Moonvibe-$VERSION.dmg" \
    "$ENCLOSURE" "$MINIMUM_MACOS" CHANGELOG.md > "$STAGING/appcast.xml" || fail "Couldn't create the appcast"
"$SPARKLE_BIN/sign_update" "$STAGING/appcast.xml" >/dev/null || fail "Couldn't sign the appcast"
cp "$STAGING/appcast.xml" "$APPCAST"

echo "Built: $(pwd)/$DMG"
echo "Built: $(pwd)/$APPCAST"
echo "Attach both to the moonvibe-v$VERSION release: Moonvibe reads the appcast of the latest release"
