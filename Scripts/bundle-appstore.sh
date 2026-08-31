#!/bin/bash
# Собирает вариант Cyclop.app для Mac App Store.
#
# От обычного bundle.sh отличается тремя вещами, и все три обязательные:
#   1. сборка с -DAPP_STORE — маршрут через MediaRemote не компилируется;
#   2. хелпер Now Playing не собирается и в бандл не кладётся;
#   3. подпись с правами сэндбокса из Scripts/appstore.entitlements.
#
# Медиа в этой сборке умеет ровно Apple Music и Spotify. Так и задумано:
# см. docs/app-store.md о том, почему большего в магазине быть не может.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/appstore/Cyclop.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"
# Номер сборки живёт отдельно от версии: App Store Connect не примет второй
# загруженный бинарь с тем же CFBundleVersion, даже если версия не менялась.
BUILD="${BUILD:-1}"
# Ad-hoc по умолчанию — этого хватает, чтобы запустить и посмотреть. Для
# настоящей отправки: IDENTITY="3rd Party Mac Developer Application: …"
IDENTITY="${IDENTITY:--}"

echo "==> swift build -c $CONFIG -DAPP_STORE"
swift build -c "$CONFIG" --package-path "$ROOT" -Xswiftc -DAPP_STORE
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" -Xswiftc -DAPP_STORE --show-bin-path)/Cyclop"

echo "==> сборка $APP"
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
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
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

[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

echo "==> локализации"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# Хелпера здесь нет намеренно. Лишний Mach-O в Resources — нарушение упаковки
# сам по себе, а его содержимое отбраковал бы автомат ещё до ревью.

echo "==> проверка: приватного маршрута в бинаре быть не должно"
LEAKS=0
for needle in MediaRemote /usr/bin/perl libcyclopmedia DynaLoader; do
    if strings -a "$APP/Contents/MacOS/Cyclop" | grep -qF "$needle"; then
        echo "    !!! в бинаре найдено: $needle" >&2
        LEAKS=1
    fi
done
[ -f "$APP/Contents/Resources/libcyclopmedia.dylib" ] && {
    echo "    !!! хелпер попал в бандл" >&2; LEAKS=1
}
[ "$LEAKS" -eq 0 ] || {
    echo "!!! сборка непригодна для App Store — см. выше" >&2
    exit 1
}
echo "    чисто"

echo "==> подпись ($([ "$IDENTITY" = "-" ] && echo "ad-hoc" || echo "$IDENTITY"))"
xattr -cr "$APP"
codesign --force --options runtime \
    --entitlements "$ROOT/Scripts/appstore.entitlements" \
    --sign "$IDENTITY" "$APP" || {
    echo "!!! codesign не смог подписать бандл" >&2
    exit 1
}
codesign --verify --strict "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

echo "==> права в подписанном бандле"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert xml1 -o - - \
    | grep -E "app-sandbox|apple-events|calendars|pictures|bookmarks" \
    | sed 's/^/    /'

echo "==> готово: $APP"
