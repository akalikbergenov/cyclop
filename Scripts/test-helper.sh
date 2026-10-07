#!/bin/bash
# Проверяет одно: что Now Playing helper отвечает.
#
# Не что он отдаёт верный трек — на машине сборки ничего не играет, да и на живой
# может не играть. Проверяется контракт: получив "get", хелпер обязан выдать одну
# строку валидного JSON. Либо снимок, либо честную ошибку, если маршрут закрыт.
# Молчание — единственный неприемлемый ответ.
#
# Это ловит класс отказов, который не видит ни компилятор, ни подпись, ни проверка
# файлов в бандле: хелпер жив, процесс не падает, а строк не приходит. Так уже
# было — вызов за списком команд, вложенный в колбэк на той же последовательной
# очереди, не возвращал ответ, и вкладка «Музыка» становилась мёртвой в релизе,
# пройдя всю сборку зелёной.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DYLIB="${1:-$ROOT/build/Cyclop.app/Contents/Resources/libcyclopmedia.dylib}"
TIMEOUT="${TIMEOUT:-8}"

fail() { echo "!!! $1" >&2; exit 1; }

[ -f "$DYLIB" ] || fail "нет хелпера: $DYLIB (сначала ./Scripts/bundle.sh)"
[ -x /usr/bin/perl ] || fail "нет /usr/bin/perl — хелперу негде запускаться"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${PERL_PID:-}" ] && kill "$PERL_PID" 2>/dev/null' EXIT

FIFO="$WORK/in"
OUT="$WORK/out"
mkfifo "$FIFO"

# Держатель stdin: закрыться он должен позже, чем хелпер успеет ответить, иначе
# perl увидит конец ввода и выйдет раньше, чем придёт строка.
( exec 3>"$FIFO"; sleep 1; echo "get" >&3; sleep "$TIMEOUT"; exec 3>&- ) &

/usr/bin/perl -e '
    use DynaLoader;
    DynaLoader::dl_load_file($ARGV[0], 0x01);
    while (1) { sleep 3600; }
' "$DYLIB" < "$FIFO" > "$OUT" 2>&1 &
PERL_PID=$!

# Ждём первую строку, а не весь таймаут: хелпер обычно отвечает за десятки
# миллисекунд, и растягивать зелёный прогон на восемь секунд незачем.
for _ in $(seq 1 $((TIMEOUT * 10))); do
    [ -s "$OUT" ] && break
    sleep 0.1
done
kill "$PERL_PID" 2>/dev/null
wait "$PERL_PID" 2>/dev/null
PERL_PID=""

[ -s "$OUT" ] || fail "хелпер не ответил ни одной строкой за ${TIMEOUT}с — лента молчит"

python3 - "$OUT" <<'PY'
import json, sys

line = None
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    raw = raw.strip()
    if raw.startswith("{"):
        line = raw
        break

if line is None:
    print("!!! в выводе нет ни одной строки JSON:", file=sys.stderr)
    print(open(sys.argv[1]).read()[:400], file=sys.stderr)
    sys.exit(1)

try:
    payload = json.loads(line)
except json.JSONDecodeError as e:
    print(f"!!! строка не разбирается как JSON: {e}", file=sys.stderr)
    print(line[:400], file=sys.stderr)
    sys.exit(1)

# Закрытый маршрут — тоже ответ. Приложение на него рассчитывает: получив error,
# оно гасит хелпер и уходит на запасной путь.
if "error" in payload:
    print(f"  ✓ хелпер ответил честной ошибкой: {payload['error']}")
    sys.exit(0)

# Строка описывает все сессии разом: {"active": pid, "sessions": [...]}.
# Пустой список — тоже честный ответ: на машине сборки ничего не играет.
for key in ("active", "sessions"):
    if key not in payload:
        print(f"!!! в строке нет ключа {key!r}", file=sys.stderr)
        print(f"    пришло: {sorted(payload.keys())}", file=sys.stderr)
        sys.exit(1)

if not isinstance(payload["sessions"], list):
    print(f"!!! sessions должен быть списком, пришло {type(payload['sessions']).__name__}", file=sys.stderr)
    sys.exit(1)

required = {"pid", "playing", "title", "duration", "elapsed", "rate", "timestamp"}
for session in payload["sessions"]:
    missing = required - session.keys()
    if missing:
        print(f"!!! в сессии нет обязательных ключей: {sorted(missing)}", file=sys.stderr)
        print(f"    пришло: {sorted(session.keys())}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(session["playing"], bool):
        print(f"!!! playing должен быть булевым, пришло {type(session['playing']).__name__}", file=sys.stderr)
        sys.exit(1)

titles = ", ".join((s["title"] or "—")[:30] for s in payload["sessions"]) or "ничего не играет"
print(f"  ✓ хелпер ответил: сессий {len(payload['sessions'])} ({titles})")
PY
