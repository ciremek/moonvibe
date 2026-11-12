#!/bin/bash
# Lists the SwiftUI shell's text that has no English translation yet, and the
# translations nothing uses anymore.
#
# The code's text is French and serves as the key: the compiler extracts every key
# the UI uses, and each one needs a line in app/swiftui/Localization/en.lproj.
# Messages from the Qt host (swiftuishell.cpp) aren't extracted: add them by hand.
# They count as used, so their translations aren't reported.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -emit-library -parse-as-library -module-name MoonvibeUI -target arm64-apple-macos14.4 \
    -F libs/sparkle -Xlinker -undefined -Xlinker dynamic_lookup \
    -emit-localized-strings -emit-localized-strings-path "$WORK" \
    -o "$WORK/libcheck.dylib" app/swiftui/*.swift 2>/dev/null

echo '{"sourceLanguage":"fr","strings":{},"version":"1.0"}' > "$WORK/Localizable.xcstrings"
xcrun xcstringstool sync "$WORK/Localizable.xcstrings" --stringsdata "$WORK"/*.stringsdata >/dev/null

plutil -convert json -o "$WORK/en.json" app/swiftui/Localization/en.lproj/Localizable.strings
python3 - "$WORK/Localizable.xcstrings" "$WORK/en.json" app/swiftui/swiftuishell.cpp <<'PY'
import json, re, sys
keys = set(json.load(open(sys.argv[1]))["strings"]) - {""}
translated = set(json.load(open(sys.argv[2])))
literals = re.findall(r'QStringLiteral\("((?:[^"\\]|\\.)*)"\)', open(sys.argv[3], encoding="utf-8").read())
host = {literal.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\") for literal in literals}
missing = sorted(keys - translated)
unused = sorted(translated - keys - host)
for key in missing:
    print("Missing:", repr(key))
for key in unused:
    print("Unused:", repr(key))
print(f"{len(keys) - len(missing)}/{len(keys)} keys translated, {len(unused)} unused")
sys.exit(1 if missing or unused else 0)
PY
