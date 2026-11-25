#!/bin/bash
# Собирает универсальный LxPilot.app и упаковывает его для релиза:
#   dist/LxPilot-<версия>.dmg, dist/LxPilot-<версия>.zip, dist/SHA256SUMS
#
#   Tools/package-release.sh 0.2.0 [номер сборки]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?версия, например 0.2.0}"
BUILD="${2:-1}"
DIST="dist"
NAME="LxPilot-$VERSION"

rm -rf "$DIST"
mkdir -p "$DIST"
UNIVERSAL=1 VERSION="$VERSION" BUILD="$BUILD" OUT="$DIST/app" ./build-app.sh

APP="$DIST/app/LxPilot.app"
lipo -archs "$APP/Contents/MacOS/LxPilot"
codesign --verify --strict "$APP"

# zip сохраняет подпись и атрибуты только через ditto.
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"

STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "LxPilot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg"
rm -rf "$STAGE" "$DIST/app"

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
echo "Готово:"
ls -lh "$DIST"
