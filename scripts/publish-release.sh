#!/bin/bash
# Publish the version in app/moonvibe-version.txt on GitHub, from what
# package-moonvibe.sh built: push the moonvibe branch, create the moonvibe-v<version>
# release with its CHANGELOG.md section as notes and the DMG and appcast attached, then
# download both back through the URLs Sparkle uses and check their signatures.
# GitHub's download servers sometimes answer 504 for a while: the check retries for
# up to 10 minutes.
#
# --dry-run runs the checks and prints the notes without publishing anything.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=ciremek/moonvibe
VERSION=$(cat app/moonvibe-version.txt)
TAG=moonvibe-v$VERSION
DMG=build/release/Moonvibe-$VERSION.dmg
APPCAST=build/release/appcast.xml
SPARKLE_BIN=libs/sparkle/bin

fail()
{
    echo "$1" 1>&2
    exit 1
}

# What gets published must be exactly what's committed and packaged
[ "$(git branch --show-current)" = moonvibe ] || fail "Publish from the moonvibe branch"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "Commit your changes first"
[ -f "$DMG" ] && [ -f "$APPCAST" ] || fail "Run scripts/package-moonvibe.sh first"
[ "$(stat -f %m "$DMG")" -ge "$(git log -1 --format=%ct)" ] || fail "$DMG is older than the last commit: package again"
grep -q "<sparkle:version>$VERSION</sparkle:version>" "$APPCAST" || fail "$APPCAST isn't for $VERSION: package again"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && fail "$TAG is already published"

# "## 0.6.0 · Check-up · November 9, 2026": the name, then the section's text
HEADING=$(grep -m1 -E "^## $VERSION( |$)" CHANGELOG.md) || fail "CHANGELOG.md has no section for $VERSION"
NAME=$(echo "$HEADING" | awk -F ' · ' '{print $2}')
TITLE="Moonvibe $VERSION${NAME:+ · $NAME}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
NOTES=$WORK/notes.md
awk -v heading="$HEADING" '$0 == heading { found = 1; next } found && /^## / { exit } found' CHANGELOG.md > "$NOTES"
cat >> "$NOTES" <<EOF

## Install

**Already on 0.5.0 or later?** Moonvibe offers this update itself: click the badge in the sidebar, or **Check Now…** in Settings, Advanced.

Otherwise: Apple Silicon Mac on macOS 14.4 or later, and a PC running Sunshine or Apollo.

1. Download **Moonvibe-$VERSION.dmg** below.
2. Open the DMG and drag **Moonvibe** to **Applications**, replacing the previous version: your PCs and settings stay.
3. On first launch, macOS blocks Moonvibe because it isn't signed by an identified Apple developer: open **System Settings → Privacy & Security** and click **Open Anyway**. Or, in Terminal:

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/Moonvibe.app
\`\`\`

From then on, Moonvibe updates itself. \`appcast.xml\` is the signed update feed it reads.
EOF

if [ "${1:-}" = "--dry-run" ]; then
    echo "Would publish \"$TITLE\" ($TAG) at $(git rev-parse --short HEAD) with:"
    cat "$NOTES"
    exit 0
fi

echo "Pushing moonvibe"
git push origin moonvibe

echo "Publishing $TITLE"
gh release create "$TAG" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "$TITLE" --notes-file "$NOTES" "$DMG" "$APPCAST"

# Through the same URLs as Sparkle: the latest release's appcast, then its enclosure
echo "Checking the published files"
download()
{
    for _ in $(seq 1 60); do
        if curl -fsSL -o "$2" "$1" 2>/dev/null && cmp -s "$2" "$3"; then
            return 0
        fi
        sleep 10
    done
    return 1
}
download "https://github.com/$REPO/releases/latest/download/appcast.xml" "$WORK/appcast.xml" "$APPCAST" \
    || fail "The published appcast doesn't match $APPCAST"
"$SPARKLE_BIN/sign_update" --verify "$WORK/appcast.xml" >/dev/null || fail "The published appcast's signature is wrong"
URL=$(grep -o 'enclosure url="[^"]*"' "$WORK/appcast.xml" | cut -d'"' -f2)
SIGNATURE=$(grep -o 'sparkle:edSignature="[^"]*"' "$WORK/appcast.xml" | cut -d'"' -f2)
download "$URL" "$WORK/Moonvibe.dmg" "$DMG" || fail "The published DMG doesn't match $DMG"
"$SPARKLE_BIN/sign_update" --verify "$WORK/Moonvibe.dmg" "$SIGNATURE" >/dev/null || fail "The published DMG's signature is wrong"

echo "Moonvibe $VERSION is out: https://github.com/$REPO/releases/tag/$TAG"
