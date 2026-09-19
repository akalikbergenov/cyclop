# Подключается из bundle.sh и test.sh: `source "$ROOT/Scripts/sdk.sh"`.
#
# Зачем. В SDK macOS 27 SwiftUI объявляет `@State` не только обёрткой, но и
# макросом — `#externalMacro(module: "SwiftUIMacros", ...)`, и компилятор
# выбирает макрос. Плагин `libSwiftUIMacros.dylib` ставится только с Xcode,
# в Command Line Tools его нет, и сборка падает на каждом `@State`:
# `plugin for module 'SwiftUIMacros' not found`. Код тут ни при чём.
#
# Что делает. Если стоят только CLT, плагина нет, а `@State` в SDK по
# умолчанию — макрос, выставляет SDKROOT на самый свежий SDK из CLT, где
# `@State` ещё обычная обёртка (CLT 27 кладёт рядом и 26.x). Свой SDKROOT и полный Xcode
# не трогает.

cyclop_sdk_has_state_macro() {
    grep -qs 'type: "StateMacro"' \
        "$1"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface
}

if [ -z "${SDKROOT:-}" ]; then
    _DEVELOPER="$(xcode-select -p 2>/dev/null)"
    if [ "${_DEVELOPER%/}" = "/Library/Developer/CommandLineTools" ] \
        && [ ! -e "$_DEVELOPER/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
        && cyclop_sdk_has_state_macro "$(xcrun --show-sdk-path)"; then
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
            echo "!!! `@State` в SDK — макрос из SwiftUIMacros, а в Command Line Tools его нет," >&2
            echo "    и более старого SDK рядом тоже нет. Поставьте Xcode" >&2
            echo "    или задайте SDKROOT вручную." >&2
            exit 1
        fi
        unset _SDK _FALLBACK
    fi
    unset _DEVELOPER
fi
