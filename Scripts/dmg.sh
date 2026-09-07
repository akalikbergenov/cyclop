#!/bin/bash
# Packs the built app into a disk image — the form a Mac app is handed over in.
# Собирает приложение, если его еще нет, и кладет рядом ярлык /Applications,
# чтобы установка была одним перетаскиванием.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Cyclop.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"
DMG="$ROOT/build/Cyclop-$VERSION.dmg"

# Всегда, а не только когда приложения нет. Иначе образ уносит то, что лежало в
# build с прошлого раза: номер на образе новый, приложение внутри старое, и
# заметить это можно лишь запустив его.
"$ROOT/Scripts/bundle.sh" release

# Настоящая подпись (CODESIGN_IDENTITY) и NOTARIZE=1 — релизный путь: сначала
# нотаризуется и скрепляется приложение, потом подписывается, нотаризуется и
# скрепляется образ. Два раунда, а не один, потому что билет скрепляется к
# тому, что подавали: скрепка на образе не доходит до приложения внутри, а
# именно оно запускается офлайн у того, кто скачал образ вчера.
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGNED=false
[ "$IDENTITY" != "-" ] && SIGNED=true
if [ "$SIGNED" = true ] && [ "${NOTARIZE:-0}" = 1 ]; then
    ZIP="$ROOT/build/Cyclop-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    "$ROOT/Scripts/notarize.sh" "$ZIP" "$APP"
    rm -f "$ZIP"
fi

echo "==> раскладка образа"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Cyclop.app"
ln -s /Applications "$STAGE/Applications"

echo "==> сборка $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "Cyclop $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

if [ "$SIGNED" = true ]; then
    echo "==> подпись образа"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if [ "${NOTARIZE:-0}" = 1 ]; then
        "$ROOT/Scripts/notarize.sh" "$DMG"
    fi
fi

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> готово: $DMG ($SIZE)"

# Имя образа обещает версию, и обещание стоит проверить: расходятся они молча.
INSIDE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
if [ "$INSIDE" != "$VERSION" ]; then
    echo "!!! в образе лежит версия $INSIDE, а имя обещает $VERSION" >&2
    exit 1
fi
echo "==> версия внутри совпадает: $INSIDE"

# Сказано здесь, потому что узнать это иначе можно только от человека, у
# которого приложение не открылось. Для релизной сборки это не предупреждение,
# а провал: подписанный и нотаризованный образ обязан проходить Gatekeeper.
if [ "$SIGNED" = true ]; then
    spctl -a -vv "$APP" || { echo "!!! Gatekeeper не принимает приложение" >&2; exit 1; }
    if [ "${NOTARIZE:-0}" = 1 ]; then
        spctl -a -t open --context context:primary-signature -vv "$DMG" \
            || { echo "!!! Gatekeeper не принимает образ" >&2; exit 1; }
    fi
elif ! spctl -a "$APP" >/dev/null 2>&1; then
    cat <<'NOTE'

    Внимание: сборка подписана ad-hoc, без Developer ID, и не нотаризована.
    На твоей машине она запускается, на любой другой Gatekeeper ее не пустит.
    Тому, кому отдаешь образ, придется один раз зайти в Системные настройки →
    Конфиденциальность и безопасность → "Все равно открыть". В macOS 15
    открытие через Control-клик для такого случая больше не работает.

    Чтобы этого не требовалось, нужен Apple Developer ID и нотаризация.
NOTE
fi
