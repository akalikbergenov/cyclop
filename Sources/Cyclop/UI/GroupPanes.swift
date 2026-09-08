import SwiftUI

/// Переключатель внутри вкладки.
///
/// Рельс отвечает на вопрос «куда я иду», и вопросов этих должно быть немного.
/// «Заготовка или заметка», «перевести или пересчитать» — это не другое место,
/// а другой режим уже пришедшего сюда человека, и такой выбор живёт внутри
/// вкладки, а не отдельной иконкой снаружи.
struct SegmentBar: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button {
                    selection = index
                } label: {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selection == index ? Color.white : Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background(
                            Capsule().fill(selection == index ? Theme.surfaceHover : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .animation(Theme.contentAnimation, value: selection)
    }
}

/// Заготовки и заметки — одно место: и то и другое текст, который держат под
/// рукой. Разница между ними во времени жизни, а не в том, где их искать.
struct WritingPane: View {
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var notes: NoteStore
    @ObservedObject var privacy: PrivacyMode
    @Binding var wantsKeyboard: Bool

    @State private var segment = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SegmentBar(titles: [localized("Snippets"), localized("Notes")], selection: $segment)
            if segment == 0 {
                SnippetsPane(snippets: snippets, privacy: privacy, wantsKeyboard: $wantsKeyboard)
            } else {
                NotesPane(notes: notes, privacy: privacy, wantsKeyboard: $wantsKeyboard)
            }
        }
        // Уход с заметок выметает пустые — та же уборка, что раньше делалась
        // при уходе с вкладки, просто теперь граница проходит здесь.
        .onChange(of: segment) { old, _ in
            if old == 1 { notes.leave() }
        }
    }
}

/// Перевод, конвертер и суфлёр — режимы: в них заходят с задачей и выходят,
/// когда задача кончилась. На рельсе они занимали три иконки из десяти, а
/// открывались реже всего остального.
struct ToolsPane: View {
    @ObservedObject var translator: Translator
    @ObservedObject var currencies: CurrencyStore
    @ObservedObject var teleprompter: TeleprompterStore
    @Binding var wantsKeyboard: Bool

    @State private var segment = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SegmentBar(
                titles: [localized("Translate"), localized("Currency"), localized("Teleprompter")],
                selection: $segment
            )
            switch segment {
            case 0:
                TranslatePane(translator: translator, wantsKeyboard: $wantsKeyboard)
            case 1:
                CurrencyPane(currencies: currencies, wantsKeyboard: $wantsKeyboard)
            default:
                TeleprompterPane(prompter: teleprompter, wantsKeyboard: $wantsKeyboard)
            }
        }
        .onChange(of: segment) { old, new in
            // Суфлёр держит панель открытой, пока едет текст. Уходя с него,
            // прокрутку надо остановить здесь же: снаружи вкладка не менялась.
            if old == 2, new != 2 { teleprompter.suspend() }
            if new == 1 { currencies.refreshIfNeeded() }
        }
    }
}
