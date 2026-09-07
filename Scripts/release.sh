#!/bin/bash
# Выпуск версии: проверки и тег. Образ, контрольную сумму и релиз на GitHub
# собирает .github/workflows/release.yml по пушу тега — так релиз не зависит
# от машины, на которой его выпускают, и от того, кто за ней сидит.
#
# Номер берется из Scripts/version — единственного места, где он записан.
# Оттуда же он попадает в Info.plist приложения и в имя .dmg, так что тег,
# приложение и файл не могут разойтись: расходятся они молча, а замечается
# это у того, кому образ отдали.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version")"
TAG="v$VERSION"

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
    fail "нет заметок к релизу. Завел $NOTES — впиши, что нового, закоммить и запусти снова"
fi

# Выпускать красное нельзя, а раннер этого не проверит: он соберёт то, на
# что указывает тег.
HEAD_SHA="$(git rev-parse HEAD)"
CI="$(gh run list --commit "$HEAD_SHA" --workflow build.yml --json conclusion --jq '.[0].conclusion // "none"')"
[ "$CI" = "success" ] || fail "CI на $HEAD_SHA: $CI. Выпускается только зелёный коммит"

cat <<'NOTE'

    Перед выпуском — docs/release-checklist.md. Две минуты руками; всё, что там,
    сборка и CI не проверяют по своей природе.

NOTE

echo "==> тег $TAG"
git tag -a "$TAG" -m "Cyclop $VERSION"
git push --quiet origin "$TAG"

echo "==> раннер собирает образ и публикует релиз; следить: gh run watch"
echo "    https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/actions/workflows/release.yml"
