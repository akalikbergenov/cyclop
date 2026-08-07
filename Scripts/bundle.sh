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

# Чем подписывать. Ad-hoc — запасной вариант, а не первый выбор, и вот почему:
# у ad-hoc подписи нет устойчивого designated requirement, поэтому TCC привязывает
# выданные разрешения к хешу конкретного бинарника. Пересобрал — хеш другой, и
# галочка «Универсальный доступ», которую пользователь уже поставил, относится к
# приложению, которого больше нет. Со стороны это выглядит как «я разрешил, а оно
# снова спрашивает».
#
# Порядок: явно заданная личность, затем Developer ID, затем любая самоподписанная
# с именем Cyclop, и только потом ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Cyclop[^"]*\)".*/\1/p' | head -1)"
fi

echo "==> signing"
# Расширенные атрибуты снимаются первыми. iCloud вешает на файлы
# com.apple.FinderInfo, а codesign отказывается подписывать что-либо с ним —
# «resource fork, Finder information, or similar detritus not allowed». Папка
# «Рабочий стол» синхронизируется с iCloud у многих по умолчанию, так что клон
# репозитория там перестает подписываться, стоило его туда перенести.
xattr -cr "$APP"

# Ошибка не глушится и не понижается до предупреждения. Раньше отказ печатал
# мягкую строку и возвращал ноль: скрипт доходил до «done», а в build лежал
# бандл, про который codesign говорит «code object is not signed at all».
# Заметить это можно было только по возвращающимся запросам TCC — то есть у
# того, кто уже поставил приложение.
if [ -n "$IDENTITY" ]; then
    echo "    личность: $IDENTITY"
else
    echo "    ad-hoc (устойчивой личности не нашлось)"
    IDENTITY="-"
fi

codesign --force --deep --sign "$IDENTITY" "$APP" || {
    echo "!!! codesign не смог подписать бандл — см. вывод выше" >&2
    exit 1
}
codesign --verify --strict "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

if [ "$IDENTITY" = "-" ]; then
    cat <<'NOTE'

    Подписано ad-hoc. Это работает, но выданные приложению разрешения
    (Универсальный доступ для автовставки) переживут ровно до следующей
    пересборки: TCC привязывает их к хешу бинарника, а он меняется каждый раз.
    Симптом — «галочка стоит, а окно с запросом всё равно вылезает».

    Лечится устойчивой личностью подписи. Самоподписанной достаточно, если
    приложение никуда не уезжает с этой машины:

        Связка ключей → Ассистент сертификации → Создать сертификат…
        имя: Cyclop, тип: Подписывание кода, самоподписанный

    Скрипт подхватит её сам. Для раздачи другим людям нужен Apple Developer ID
    и нотаризация — самоподписанная Gatekeeper не убеждает.

NOTE
fi

echo "==> done: $APP"
