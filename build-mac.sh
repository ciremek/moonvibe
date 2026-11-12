#!/bin/bash
# Build Moonlight (release) into build/app/Moonvibe.app, with the official Qt that
# scripts/setup-qt.sh downloads
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

QMAKE=$(pwd)/libs/qt/current/bin/qmake6
if [ ! -x "$QMAKE" ]; then
    echo "Qt is missing: run scripts/setup-qt.sh" 1>&2
    exit 1
fi

mkdir -p build && cd build
"$QMAKE" -r ../moonlight-qt.pro CONFIG+=release
make -j"$(sysctl -n hw.ncpu)"
echo "Built: $(pwd)/app/Moonvibe.app"
