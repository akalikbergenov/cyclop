#!/bin/bash
# appcast.xml для Sparkle: одна запись, про эту версию. Его кладут в релиз
# рядом с образом, и приложение берёт его по адресу
# releases/latest/download/appcast.xml — GitHub сам отдаёт файл последнего
# релиза. Истории версий в нём нет и не нужно: Sparkle спрашивает только
# «есть ли что-то новее моего».
#
# Закрытый ключ — в SPARKLE_ED_PRIVATE_KEY (base64 из `generate_keys -x`),
# путь к sign_update из того же релиза Sparkle — в SIGN_UPDATE. Ключ
# передаётся через stdin, а не аргументом: аргументы видны в списке процессов.
#
#   SIGN_UPDATE=…/bin/sign_update SPARKLE_ED_PRIVATE_KEY=… \
#   Scripts/appcast.sh build/Cyclop-1.0.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:?какой образ}"
APP="${APP:-$ROOT/build/Cyclop.app}"
OUT="${OUT:-$ROOT/build/appcast.xml}"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version")"
REPO="https://github.com/akalikbergenov/cyclop"

fail() { echo "!!! $1" >&2; exit 1; }

[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || fail "нет SPARKLE_ED_PRIVATE_KEY — см. docs/signing.md"
[ -x "${SIGN_UPDATE:-}" ] || fail "нет sign_update (SIGN_UPDATE)"
[ -f "$DMG" ] || fail "нет образа $DMG"

# Ключ, с которым сверяют те, кто обновится, — тот, что вшит в приложение
# внутри образа, а не тот, что лежит в репозитории: разойтись они могут, если
# образ собран с другого коммита.
PUBLIC="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null)" \
    || fail "в $APP нет SUPublicEDKey — такая сборка не обновляется, и appcast для неё бессмыслен"

echo "==> подпись образа для Sparkle"
SIGNATURE="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" -p --ed-key-file - "$DMG")"
LENGTH="$(stat -f %z "$DMG")"

# Подпись проверяется открытым ключом приложения, независимо от Sparkle.
# Закрытый ключ, не парный вшитому, дал бы appcast, который каждая копия
# молча отвергнет, — и узнать об этом было бы не от кого.
echo "==> проверка подписи ключом из приложения"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
cat > "$CHECK/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let key = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]),
      let file = FileManager.default.contents(atPath: args[3]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
else { exit(2) }
exit(publicKey.isValidSignature(signature, for: file) ? 0 : 1)
SWIFT
swift "$CHECK/verify.swift" "$PUBLIC" "$SIGNATURE" "$DMG" \
    || fail "подпись образа не сходится с SUPublicEDKey в приложении: SPARKLE_ED_PRIVATE_KEY не от того ключа"

NOTES="$ROOT/docs/releases/$VERSION.md"
[ -f "$NOTES" ] || NOTES=""

# XML собирается питоном: в заметках бывают <, & и кавычки, и экранировать
# их руками в heredoc — верный способ однажды выпустить битый appcast.
echo "==> $OUT"
/usr/bin/python3 -I - "$OUT" "$VERSION" "$SIGNATURE" "$LENGTH" "$REPO" "$NOTES" <<'PY'
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape

out, version, signature, length, repo, notes = sys.argv[1:7]
page = f"{repo}/releases/tag/v{version}"
url = f"{repo}/releases/download/v{version}/Cyclop-{version}.dmg"
# RFC 822, как ждёт Sparkle; formatdate не зависит от локали раннера.
date = formatdate().replace("-0000", "+0000")
v = escape(version)

# Заметки — те же, что в релизе на GitHub, markdown как есть: Sparkle 2
# рисует его сам, и окно обновления ничего не грузит из сети ради текста.
description = ""
if notes:
    with open(notes, encoding="utf-8") as f:
        text = f.read().strip()
    description = f'\n      <description sparkle:format="markdown">{escape(text)}</description>'

xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cyclop</title>
    <link>{repo}</link>
    <item>
      <title>Cyclop {v}</title>
      <pubDate>{date}</pubDate>
      <link>{page}</link>
      <sparkle:version>{v}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{page}</sparkle:fullReleaseNotesLink>{description}
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{escape(signature)}"/>
    </item>
  </channel>
</rss>
'''
with open(out, "w", encoding="utf-8") as f:
    f.write(xml)
PY

xmllint --noout "$OUT" || fail "appcast.xml не разбирается как XML"
echo "==> готово: $OUT ($VERSION, $LENGTH байт)"
