#!/bin/bash
# Выпуск версии: тег в гите и релиз на GitHub с приложенным образом.
#
# Номер берется из Scripts/version — единственного места, где он записан.
# Оттуда же он попадает в Info.plist приложения и в имя .dmg, так что тег,
# приложение и файл не могут разойтись: расходятся они молча, а замечается
# это у того, кому образ отдали.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version")"
TAG="v$VERSION"
DMG="$ROOT/build/Cyclop-$VERSION.dmg"

cd "$ROOT"

fail() { echo "!!! $1" >&2; exit 1; }

command -v gh >/dev/null || fail "нужен gh: brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh не авторизован: gh auth login"

# Тег указывает на коммит, а не на рабочее дерево. Если в дереве есть
# несохраненное, тег будет указывать не на то, что собрано.
[ -z "$(git status --porcelain)" ] || fail "есть несохраненные изменения — закоммить их сначала"

git fetch --quiet origin
[ -z "$(git rev-list @{u}..HEAD 2>/dev/null)" ] || fail "есть незапушенные коммиты — тег указывал бы на то, чего нет на GitHub"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    fail "тег $TAG уже есть. Подними номер в Scripts/version"
fi

# Заметки к релизу состоят из двух частей, и первую не напишет никто, кроме
# человека. Список коммитов отвечает на вопрос "что изменилось в коде";
# пришедший спрашивает "что мне это даст" — это разные ответы, и второй
# автоматически не получается. Поэтому файл обязателен: если его нет, скрипт
# заводит болванку и останавливается, вместо того чтобы выпустить версию,
# о которой нечего сказать.
NOTES="$ROOT/docs/releases/$VERSION.md"
if [ ! -f "$NOTES" ]; then
    mkdir -p "$(dirname "$NOTES")"
    cat > "$NOTES" <<TEMPLATE
Что нового в $VERSION — пара строк о том, что человек заметит, открыв
приложение. Список коммитов допишется сам, повторять его здесь не нужно.
TEMPLATE
    fail "нет заметок к релизу. Завел $NOTES — впиши, что нового, и запусти снова"
fi

echo "==> сборка образа $VERSION"
"$ROOT/Scripts/dmg.sh" >/dev/null
[ -f "$DMG" ] || fail "образ не собрался: $DMG"

echo "==> тег $TAG"
git tag -a "$TAG" -m "Cyclop $VERSION"
git push --quiet origin "$TAG"

echo "==> релиз на GitHub"
# Список коммитов берется у GitHub отдельным вызовом, а не флагом
# --generate-notes: флаг заменил бы собой все тело, и человеческая часть в него
# бы не попала. Так две части просто складываются в нужном порядке.
REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
PREVIOUS="$(git tag --sort=-v:refname | sed -n 2p)"
GENERATED="$(gh api "repos/$REPO/releases/generate-notes" \
    -f tag_name="$TAG" \
    ${PREVIOUS:+-f previous_tag_name="$PREVIOUS"} \
    --jq '.body' 2>/dev/null || echo "")"

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
cat "$NOTES" > "$BODY"

# Контрольная сумма в заметках — единственное, чем скачавший может проверить,
# что у него тот самый файл. Образ подписан ad-hoc, без Developer ID, так что
# подпись ему об этом не скажет: сумму приходится публиковать руками.
SUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
printf '\n\n**SHA-256** `%s`\n\nПроверить: `shasum -a 256 Cyclop-%s.dmg`\n' "$SUM" "$VERSION" >> "$BODY"

[ -n "$GENERATED" ] && printf '\n\n---\n\n%s\n' "$GENERATED" >> "$BODY"

gh release create "$TAG" "$DMG" \
    --title "Cyclop $VERSION" \
    --notes-file "$BODY" \
    --latest

echo "==> готово"
gh release view "$TAG" --json url --jq '"    " + .url'

if ! gh repo view --json visibility --jq '.visibility' | grep -qi public; then
    cat <<'NOTE'

    Репозиторий приватный, поэтому ссылка на релиз откроется только у тех,
    у кого есть доступ к нему. Чтобы образ мог скачать кто угодно по ссылке,
    репозиторий нужно сделать публичным.
NOTE
fi
