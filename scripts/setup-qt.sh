#!/bin/bash
# Download the official Qt build Moonvibe compiles against, as Moonlight's own CI does:
# libs/qt/<version>/macos. Homebrew's Qt drags in dependencies (ICU, glib, OpenSSL…)
# built for the macOS it was installed on, which the app would then require; the
# official build runs from macOS 13, below Moonvibe's own macOS 14.4 minimum.
# aqtinstall checks each archive against the SHA-256 Qt publishes.
# Run it once after cloning, and again when QT_VERSION changes.
set -euo pipefail
cd "$(dirname "$0")/.."

# Moonlight's macOS build pins the same version (.github/workflows/build-win-mac.yml)
QT_VERSION=6.11.2
AQT_VERSION=3.3.0
TARGET=libs/qt
AQT_ENV=build/aqt-env

if [ ! -x "$AQT_ENV/bin/aqt" ]; then
    python3 -m venv "$AQT_ENV"
    "$AQT_ENV/bin/pip" install --quiet --disable-pip-version-check "aqtinstall==$AQT_VERSION"
fi

echo "Downloading Qt $QT_VERSION"
# Only the modules Moonvibe uses: Core, Gui, Network, Quick, Quick Controls and Svg, plus
# the tools (macdeployqt comes with qtbase)
PYTHONWARNINGS=ignore "$AQT_ENV/bin/aqt" install-qt mac desktop "$QT_VERSION" clang_64 \
    --archives qtbase qtdeclarative qtsvg qttools \
    --outputdir "$TARGET"

# build-mac.sh and the packaging script use libs/qt/current
ln -sfn "$QT_VERSION/macos" "$TARGET/current"
echo "Qt $QT_VERSION is in $TARGET/current"
