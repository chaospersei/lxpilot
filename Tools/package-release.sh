#!/bin/bash
# Собирает LxPilot.app под Apple silicon (arm64) и упаковывает его для релиза:
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
ARCH=arm64 VERSION="$VERSION" BUILD="$BUILD" OUT="$DIST/app" ./build-app.sh

APP="$DIST/app/LxPilot.app"
echo "== архитектура"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/LxPilot")"
echo "$ARCHS"
if [ "$ARCHS" != "arm64" ]; then
    echo "Ожидалась сборка только под arm64" >&2
    exit 1
fi
echo "== подпись"
codesign --verify --strict --verbose=2 "$APP"

echo "== zip"
# zip сохраняет подпись и атрибуты только через ditto.
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"

echo "== dmg"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# `hdiutil create` в macOS 27 объявлен устаревшим в пользу `diskutil image create from`, а на
# раннерах GitHub временами падает с «Resource busy» (том ещё держит системная проверка).
# Поэтому пробуем новый способ, затем старый, и повторяем; вывод не глушим — причина нужна в логе.
make_dmg() {
    rm -f "$DIST/$NAME.dmg"
    if diskutil image create from --help >/dev/null 2>&1; then
        if diskutil image create from --format UDZO --volumeName "LxPilot $VERSION" "$STAGE" "$DIST/$NAME.dmg"; then
            return 0
        fi
        echo "diskutil image create не справился, пробуем hdiutil" >&2
        rm -f "$DIST/$NAME.dmg"
    fi
    hdiutil create -volname "LxPilot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg"
}
made=0
for attempt in 1 2 3 4 5 6; do
    if make_dmg; then
        made=1
        break
    fi
    echo "dmg: попытка $attempt не удалась, повтор через 5 с" >&2
    sleep 5
done
if [ "$made" != "1" ] || [ ! -s "$DIST/$NAME.dmg" ]; then
    echo "Не удалось создать $NAME.dmg" >&2
    exit 1
fi
rm -rf "$STAGE" "$DIST/app"

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
echo "Готово:"
ls -lh "$DIST"
