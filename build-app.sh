#!/bin/bash
# Собирает LxPilot.app из Swift-пакета. Нужны macOS 26+ и Xcode 26+ (Swift 6.2+).
#
#   ./build-app.sh                  под архитектуру этого Mac → build/LxPilot.app
#   UNIVERSAL=1 ./build-app.sh      универсальная сборка (arm64 + x86_64)
#   VERSION=0.2.0 BUILD=42 ...      версия в Info.plist (по умолчанию — как в Resources/Info.plist)
#   OUT=dist ./build-app.sh         другой каталог вместо build/
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="${OUT:-build}/LxPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LxPilot" "$APP/Contents/MacOS/LxPilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # пересборка иконки: swift Tools/make-icon.swift

if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi

# Ad-hoc подпись: Developer ID у проекта нет, поэтому скачанную сборку Gatekeeper спросит отдельно (см. README).
codesign --force --sign - "$APP"

echo "Готово: $(pwd)/$APP"
echo "Запуск: open \"$APP\""
