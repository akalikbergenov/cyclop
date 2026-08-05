#!/bin/bash
# Builds Cyclop.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Cyclop.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Cyclop"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cyclop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cyclop</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Cyclop</string>
    <key>CFBundleIdentifier</key><string>com.cyclop.app</string>
    <key>CFBundleExecutable</key><string>Cyclop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Cyclop читает название текущего трека и управляет воспроизведением в Apple Music и Spotify.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Cyclop показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Cyclop показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Таблицы строк кладутся прямо в бандл, а не через ресурсы SwiftPM: бандл здесь
# собирается вручную, и .lproj рядом с исполняемым файлом — то, где их ищет сама
# macOS. Язык она выбирает потом сама, по списку предпочитаемых у пользователя.
echo "==> локализации"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "    $(basename "$lproj")"
done

# Now Playing helper. Built here rather than by SwiftPM because it is not linked
# into the app: it is loaded into /usr/bin/perl at runtime. See helper.m.
echo "==> building Now Playing helper"
clang -dynamiclib -fobjc-arc -O2 \
    -mmacosx-version-min=15.0 \
    -framework Foundation \
    -o "$APP/Contents/Resources/libcyclopmedia.dylib" \
    "$ROOT/Sources/CyclopMediaHelper/helper.m"

# Подписывается сначала вложенное, потом бандл. --deep для этого Apple объявила
# устаревшей и сама не рекомендует: она подписывает вложенное теми же условиями,
# что и бандл, и молча пропускает часть случаев. Ошибка здесь не глушится —
# неподписанная сборка должна останавливать скрипт, а не обнаруживаться у того,
# кому ее отдали.
echo "==> ad-hoc signing"
codesign --force --options runtime \
    --entitlements "$ROOT/Resources/Cyclop.entitlements" \
    --sign - "$APP/Contents/Resources/libcyclopmedia.dylib"

# Хеш хелпера запечатывается в Info.plist, и приложение сверяет его перед тем,
# как отдать библиотеку в perl. perl подписан без валидации библиотек — он
# загрузит что угодно, что лежит по этому пути, и оно окажется внутри процесса,
# которому доверяет медиа-демон. Проверять это, кроме самого приложения, некому.
CDHASH="$(codesign -d -vvv "$APP/Contents/Resources/libcyclopmedia.dylib" 2>&1 \
    | sed -n 's/^CDHash=//p')"
[ -n "$CDHASH" ] || { echo "!!! не удалось прочитать CDHash хелпера" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Add :CyclopHelperCDHash string $CDHASH" "$APP/Contents/Info.plist"

# Бандл подписывается последним: подпись должна накрыть Info.plist уже с хешем.
codesign --force --options runtime \
    --entitlements "$ROOT/Resources/Cyclop.entitlements" \
    --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> done: $APP"
