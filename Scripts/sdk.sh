# Подключается из bundle.sh и test.sh: `source "$ROOT/Scripts/sdk.sh"`.
#
# Зачем. В SDK macOS 27 SwiftUI объявляет `@State` не только обёрткой, но и
# макросом — `#externalMacro(module: "SwiftUIMacros", ...)`, и компилятор
# выбирает макрос. Плагин `libSwiftUIMacros.dylib` ставится только с Xcode,
# в Command Line Tools его нет, и сборка падает на каждом `@State`:
# `plugin for module 'SwiftUIMacros' not found`. Код тут ни при чём.
#
# Что делает. Если плагина в тулчейне нет, а в SDK по умолчанию `@State` уже
# макрос, — выставляет SDKROOT на самый свежий SDK рядом, где `@State` ещё
# обёртка: CLT 27 кладёт рядом и 26.x. Свой SDKROOT не трогает.
#
# Xcode сюда не попадает: плагины у него лежат в Toolchains, а не в самом
# каталоге разработчика, и папки, которую проверяет первое условие, у него
# просто нет — значит и подстановки не будет.
#
# Пути берутся из `xcode-select -p`, а он слушает DEVELOPER_DIR. Поэтому обе
# ветки проверяются на поддельном каталоге, без macOS 27 под рукой:
#   DEVELOPER_DIR=/tmp/clt-27 ./Scripts/bundle.sh release

cyclop_sdk_has_state_macro() {
    grep -qs 'type: "StateMacro"' \
        "$1"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface
}

if [ -z "${SDKROOT:-}" ]; then
    _DEVELOPER="$(xcode-select -p 2>/dev/null)"
    _DEVELOPER="${_DEVELOPER%/}"
    _PLUGINS="$_DEVELOPER/usr/lib/swift/host/plugins"
    if [ -d "$_PLUGINS" ] && [ ! -e "$_PLUGINS/libSwiftUIMacros.dylib" ] \
        && cyclop_sdk_has_state_macro "$_DEVELOPER/SDKs/MacOSX.sdk"; then
        _FALLBACK=""
        # Версии по убыванию; симлинки вида MacOSX.sdk и MacOSX26.sdk
        # отсекает шаблон с точкой.
        for _SDK in $(ls -d "$_DEVELOPER"/SDKs/MacOSX*.*.sdk 2>/dev/null | sort -V -r); do
            if ! cyclop_sdk_has_state_macro "$_SDK"; then
                _FALLBACK="$_SDK"
                break
            fi
        done
        if [ -n "$_FALLBACK" ]; then
            echo "==> Command Line Tools без плагина SwiftUIMacros: собираю с $(basename "$_FALLBACK")"
            export SDKROOT="$_FALLBACK"
        else
            # Одинарные кавычки: в двойных обратные кавычки вокруг @State
            # прочитались бы как подстановка команды, и имя пропало бы из
            # сообщения (#124).
            echo '!!! `@State` в SDK — макрос из SwiftUIMacros, а плагина в тулчейне нет,' >&2
            echo '    и более старого SDK рядом тоже нет. Поставьте Xcode' >&2
            echo '    или задайте SDKROOT вручную.' >&2
            exit 1
        fi
        unset _SDK _FALLBACK
    fi
    unset _DEVELOPER _PLUGINS
fi
