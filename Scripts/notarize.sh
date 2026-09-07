#!/bin/bash
# Нотаризация одного файла — .zip с приложением или .dmg — и скрепка билета
# к тому, что внутри. Без билета Gatekeeper проверяет подпись у Apple по сети
# при первом запуске; со скрепкой — офлайн.
#
# Учётные данные — App Store Connect API key, двумя способами:
#   NOTARY_PROFILE      имя профиля из `xcrun notarytool store-credentials`
#                       (локально: ключ лежит в связке ключей, а не в окружении);
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH
#                       сам ключ .p8 и его идентификаторы (на раннере, из секретов).
#
#   Scripts/notarize.sh build/Cyclop.zip build/Cyclop.app
#   Scripts/notarize.sh build/Cyclop-1.0.dmg
set -euo pipefail

FILE="${1:?что нотаризовать}"
STAPLE="${2:-$FILE}"

fail() { echo "!!! $1" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
    fail "нет учётных данных нотаризации: NOTARY_PROFILE или NOTARY_KEY_ID + NOTARY_ISSUER_ID + NOTARY_KEY_PATH"
fi

echo "==> нотаризация $(basename "$FILE")"
# --wait: обычно минута-две. Лог запрашивается всегда, а не только при
# отказе: предупреждения Apple приходят и в принятом ответе, и увидеть их
# можно только так.
OUT="$(xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --output-format json)"
ID="$(printf '%s' "$OUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
STATUS="$(printf '%s' "$OUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
xcrun notarytool log "$ID" "${AUTH[@]}" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
log = json.load(sys.stdin)
for issue in log.get("issues") or []:
    print("    {}: {}: {}".format(issue.get("severity"), issue.get("path"), issue.get("message")))
' || true
[ "$STATUS" = "Accepted" ] || fail "нотаризация: $STATUS (id $ID)"

echo "==> скрепка билета к $(basename "$STAPLE")"
xcrun stapler staple -q "$STAPLE"
xcrun stapler validate -q "$STAPLE"
