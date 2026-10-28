#!/bin/bash
# Builds Cyclop.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and signs it — ad-hoc by default, with a
# Developer ID when CODESIGN_IDENTITY names one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Cyclop.app"
source "$ROOT/Scripts/sdk.sh"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"
IDENTITY="${CODESIGN_IDENTITY:--}"

# Публичный ключ обновлений. По нему Sparkle сверяет подпись каждого
# скачанного образа, и он навсегда вшит в каждую выпущенную копию: заменить
# его потом нельзя, не потеряв обновления у всех, кто уже поставил. Пока в
# файле заглушка, ключа в бандле нет и приложение не запускает Sparkle
# вовсе: без ключа тот не стартует и говорит об этом окном. Настоящая
# подпись с заглушкой отказывается собираться: релиз, который никогда не
# обновится, хуже релиза, который не вышел.
SPARKLE_KEY="$(head -n 1 "$ROOT/Scripts/sparkle-public-key" | tr -d '[:space:]')"
if ! printf '%s' "$SPARKLE_KEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
    if [ "$IDENTITY" != "-" ]; then
        echo "!!! в Scripts/sparkle-public-key нет публичного ключа Sparkle — см. docs/signing.md" >&2
        exit 1
    fi
    echo "==> ключа Sparkle нет (Scripts/sparkle-public-key): обновления в этой сборке выключены"
    SPARKLE_KEY=""
fi

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
    <key>SUFeedURL</key>
    <string>https://github.com/akalikbergenov/cyclop/releases/latest/download/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUEnableSystemProfiling</key><false/>
</dict>
</plist>
PLIST

# Ключ дописывается отдельно, а не строкой в шаблоне выше: без ключа ключа
# не должно быть вовсе — пустая строка для Sparkle та же ошибка, что и его
# отсутствие, а приложение по отсутствию решает не запускать обновления.
if [ -n "$SPARKLE_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_KEY" "$APP/Contents/Info.plist"
fi

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

# Sparkle — бинарная зависимость SwiftPM: фреймворк лежит рядом с бинарником,
# а ищет его бинарник в Contents/Frameworks (rpath в Package.swift).
# Заголовки и модуль нужны компилятору, а не приложению — их Xcode тоже
# выбрасывает при копировании. XPC-сервисы Sparkle включаются только ключами
# Info.plist для приложения в песочнице; Cyclop не в песочнице, и без этих
# ключей Sparkle их не запускает — нечего подписывать и нотаризовать.
echo "==> Sparkle.framework"
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$FW"
rm -rf "$FW/Headers" "$FW/PrivateHeaders" "$FW/Modules" "$FW/XPCServices" \
    "$FW/Versions/B/Headers" "$FW/Versions/B/PrivateHeaders" \
    "$FW/Versions/B/Modules" "$FW/Versions/B/XPCServices"
# Sparkle приходит универсальным, а приложение собирается под одну
# архитектуру — под ту, на которой собирали. Вторая половина фреймворка
# никогда не исполнится, а весит столько же, сколько первая.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Cyclop")"
if [ "$(echo "$ARCHS" | wc -w)" -eq 1 ]; then
    for f in "$FW/Versions/B/Sparkle" "$FW/Versions/B/Autoupdate" \
        "$FW/Versions/B/Updater.app/Contents/MacOS/Updater"; do
        lipo "$f" -thin "$ARCHS" -output "$f"
    done
fi

# Подпись. Кем — решает CODESIGN_IDENTITY: пусто или «-» — ad-hoc, как для
# любой локальной сборки; «Developer ID Application: …» — настоящая, с
# hardened runtime и отметкой времени, как для релиза. Ключ и сертификат
# в скрипте не живут, они в связке ключей того, кто выпускает, или в
# секретах раннера (см. docs/signing.md).
if [ "$IDENTITY" = "-" ]; then
    echo "==> ad-hoc signing"
else
    echo "==> signing as $IDENTITY"
fi

# Расширенные атрибуты снимаются первыми. iCloud вешает на файлы
# com.apple.FinderInfo, а codesign отказывается подписывать что-либо с ним —
# «resource fork, Finder information, or similar detritus not allowed». Папка
# «Рабочий стол» синхронизируется с iCloud у многих по умолчанию, так что клон
# репозитория там перестает подписываться, стоило его туда перенести.
xattr -cr "$APP"

# Сначала вложенное, потом бандл, и без --deep: Apple объявила его устаревшим,
# он подписывает вложенное теми же условиями, что и бандл, и молча пропускает
# часть случаев. Подпись бандла запечатывает Resources целиком, dylib в том
# числе: подменённый хелпер с настоящей подписью не пройдёт Gatekeeper, и
# отдельная сверка хеша из #1 становится не нужна.
#
# Hardened runtime — только с настоящей подписью. Связка «ad-hoc + runtime +
# чужой perl» ломала Now Playing без единого сообщения (#20), а даёт она
# ad-hoc-сборке ничего: нотаризовать её всё равно нельзя.
#
# Ошибка не глушится и не понижается до предупреждения. Раньше отказ печатал
# мягкую строку и возвращал ноль: скрипт доходил до «done», а в build лежал
# бандл, про который codesign говорит «code object is not signed at all».
# Заметить это можно было только по возвращающимся запросам TCC — то есть у
# того, кто уже поставил приложение.
#
# Порядок внутри Sparkle — тот, что требует его документация: Autoupdate и
# Updater.app запускаются отдельными процессами и подписываются как свои
# программы, потом фреймворк, который их запечатывает. Под hardened runtime
# фреймворк обязан быть подписан той же командой, что и приложение, иначе
# library validation не даст его загрузить — поэтому он переподписывается,
# а не едет с подписью Sparkle.
sign_code() {
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --sign - "$@"
    else
        codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"
    fi
}
sign_bundle() {
    sign_code "$FW/Versions/B/Autoupdate" &&
    sign_code "$FW/Versions/B/Updater.app" &&
    sign_code "$FW" &&
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --sign - "$APP/Contents/Resources/libcyclopmedia.dylib" &&
        codesign --force --sign - "$APP"
    else
        codesign --force --timestamp --sign "$IDENTITY" \
            "$APP/Contents/Resources/libcyclopmedia.dylib" &&
        codesign --force --timestamp --options runtime \
            --entitlements "$ROOT/Resources/Cyclop.entitlements" \
            --sign "$IDENTITY" "$APP"
    fi
}
# Цепочка через &&, а не построчно: под `||` set -e не действует, и отказ
# на середине иначе прошёл бы незамеченным, стоило последней подписи удаться.
sign_bundle || {
    echo "!!! codesign не смог подписать бандл — см. вывод выше" >&2
    exit 1
}
codesign --verify --strict --deep "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

echo "==> done: $APP"
