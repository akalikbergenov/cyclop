#!/bin/bash
# swift test — в том числе на машине без Xcode.
#
# Сторы тестируются, панель нет: см. CONTRIBUTING.md и #65.
#
# Зачем обёртка. Голый `swift test` на машине, где стоят только Command Line
# Tools, падает с `no such module 'Testing'`, и это легко принять за «нужен
# Xcode». Не нужен: `Testing.framework` и `lib_TestingInterop.dylib` в CLT
# лежат, просто не подставлены в пути поиска — ни при компиляции, ни при
# загрузке. Здесь они подставляются, и тесты идут те же самые.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
source "$ROOT/Scripts/sdk.sh"

DEVELOPER="$(xcode-select -p 2>/dev/null)"
ARGS=()

# Полный Xcode собирает тесты сам — добавлять ему пути не надо и вредно.
if [ "${DEVELOPER%/}" = "/Library/Developer/CommandLineTools" ]; then
    FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
    LIBS="$DEVELOPER/Library/Developer/usr/lib"
    if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
        echo "!!! нет $FRAMEWORKS/Testing.framework" >&2
        echo "    обновите Command Line Tools: xcode-select --install" >&2
        exit 1
    fi
    echo "==> Command Line Tools без Xcode: подставляю пути к Testing.framework"
    ARGS=(
        -Xswiftc -F -Xswiftc "$FRAMEWORKS"
        -Xlinker -F -Xlinker "$FRAMEWORKS"
        # Два rpath, а не один: Testing.framework тянет за собой
        # lib_TestingInterop.dylib, и лежит он в соседней папке.
        -Xlinker -rpath -Xlinker "$FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$LIBS"
    )
fi

# `${ARGS[@]+...}` вместо простого `${ARGS[@]}`: под `set -u` в bash 3.2 —
# а это тот bash, что стоит на macOS и на раннере — раскрытие пустого массива
# считается обращением к неустановленной переменной. При полном Xcode массив
# как раз пустой.
exec swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
