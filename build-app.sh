#!/bin/bash
# Собирает LxPilot.app из Swift-пакета. Нужен Xcode 15+ (или Command Line Tools со Swift 5.9+), macOS 13+.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/LxPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LxPilot" "$APP/Contents/MacOS/LxPilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc подпись: достаточно для запуска на своём Mac.
codesign --force --sign - "$APP"

echo "Готово: $(pwd)/$APP"
echo "Запуск: open \"$APP\""
