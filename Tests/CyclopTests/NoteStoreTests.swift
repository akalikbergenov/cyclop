import Foundation
import Testing
@testable import Cyclop

/// Тесты на `NoteStore` — чтение `notes.json`, отказ писать поверх битого
/// файла и возврат к починенному.
///
/// Почему именно здесь: заметки — единственное место, где написанное живёт
/// только в этом файле. Нечитаемый файл раньше означал ноль заметок на
/// экране, а первое же нажатие клавиши писало этот ноль на диск. Ошибка не
/// требует ни одного вью, чтобы её увидеть, — только стор и временный файл.
///
/// Каждый тест работает со своим файлом во временной папке: настоящие
/// заметки того, кто запускает прогон, не читаются и не пишутся.
@MainActor
struct NoteStoreTests {

    private static func makeStore(contents: String? = nil) throws -> (store: NoteStore, file: URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.json")
        if let contents { try Data(contents.utf8).write(to: file) }
        return (NoteStore(file: file), file)
    }

    private static func read(_ file: URL) throws -> [Note] {
        try JSONDecoder().decode([Note].self, from: Data(contentsOf: file))
    }

    /// Файл с двумя заметками. Даты разные, чтобы порядок в файле был
    /// единственным, что задаёт порядок на экране.
    private static func twoNotes() -> String {
        """
        [
          {"id":"\(UUID().uuidString)","text":"свежая","edited":780000000},
          {"id":"\(UUID().uuidString)","text":"старая","edited":770000000}
        ]
        """
    }

    /// Незаконченный JSON: массив открыт и не закрыт. Запятая в конце или
    /// лишняя кавычка не годятся — на целевой macOS их разбор пропускает.
    private static let brokenJSON = #"[{"id":"B9D1A5F4-0000-0000-0000-000000000001","text":"важное"}"#

    // MARK: - Чтение

    /// Нет файла — это новая установка, а не поломка.
    @Test func aMissingFileIsNoNotesAndNotABreakage() throws {
        let (store, _) = try Self.makeStore()
        #expect(store.notes.isEmpty)
        #expect(store.fileBroken == false)
    }

    @Test func existingFileIsReadInItsOwnOrderWithTheTopOneSelected() throws {
        let (store, _) = try Self.makeStore(contents: Self.twoNotes())
        #expect(store.notes.map(\.text) == ["свежая", "старая"])
        #expect(store.selected == store.notes.first?.id)
    }

    // MARK: - Битый файл

    /// Главное: файл не разобрался — поднимаем флаг, а не делаем вид, что
    /// заметок нет.
    @Test func aBrokenFileRaisesTheFlag() throws {
        let (store, _) = try Self.makeStore(contents: Self.brokenJSON)
        #expect(store.fileBroken)
        #expect(store.notes.isEmpty)
    }

    /// То, из-за чего всё это: набранное после поломки не должно уезжать на
    /// диск поверх нечитаемого файла. В нём лежат чьи-то заметки, и разобрать
    /// его не смогли мы, а не человек.
    @Test func typingDoesNotWriteOverABrokenFile() throws {
        let (store, file) = try Self.makeStore(contents: Self.brokenJSON)
        let before = try Data(contentsOf: file)
        store.add()
        store.update(store.notes[0].id, text: "набрано при поломке")
        store.flush()
        #expect(try Data(contentsOf: file) == before)
    }

    /// Файл починили руками — при следующем заходе он читается, а набранное
    /// за это время остаётся и встаёт сверху.
    @Test func amendedFileIsReadAndWhatWasTypedMeanwhileSurvives() throws {
        let (store, file) = try Self.makeStore(contents: Self.brokenJSON)
        store.add()
        store.update(store.notes[0].id, text: "набрано при поломке")
        try Data(Self.twoNotes().utf8).write(to: file)

        store.retryIfBroken()

        #expect(store.fileBroken == false)
        #expect(store.notes.map(\.text) == ["набрано при поломке", "свежая", "старая"])
        store.flush()
        #expect(try Self.read(file).map(\.text) == ["набрано при поломке", "свежая", "старая"])
    }

    /// Файл всё ещё битый — ничего не происходит, и пустая заметка не
    /// затирает набранное.
    @Test func retryOnAStillBrokenFileChangesNothing() throws {
        let (store, _) = try Self.makeStore(contents: Self.brokenJSON)
        store.add()
        store.update(store.notes[0].id, text: "набрано")
        store.retryIfBroken()
        #expect(store.fileBroken)
        #expect(store.notes.map(\.text) == ["набрано"])
    }

    /// Починка не должна удваивать то, что уже есть в файле: заметка
    /// опознаётся по `id`, а не по тексту.
    @Test func amendedFileDoesNotDuplicateWhatItAlreadyHolds() throws {
        let (store, file) = try Self.makeStore(contents: Self.brokenJSON)
        store.add()
        store.update(store.notes[0].id, text: "одна")
        // Тот же `id` в файле: человек починил файл, в котором эта заметка
        // уже была, — а не дописал к ней вторую такую же.
        let id = store.notes[0].id
        let whole = """
        [{"id":"\(id.uuidString)","text":"одна","edited":780000000}]
        """
        try Data(whole.utf8).write(to: file)

        store.retryIfBroken()

        #expect(store.notes.count == 1)
    }

    // MARK: - Запись

    @Test func addAndUpdateReachTheFile() throws {
        let (store, file) = try Self.makeStore()
        store.add()
        store.update(store.notes[0].id, text: "телефон из звонка")
        store.flush()
        #expect(try Self.read(file).map(\.text) == ["телефон из звонка"])
    }

    @Test func removeReachesTheFileAndMovesTheSelection() throws {
        let (store, file) = try Self.makeStore()
        store.add()
        store.update(store.notes[0].id, text: "первая")
        store.add()
        store.update(store.notes[0].id, text: "вторая")
        store.remove(store.notes[0].id)
        store.flush()
        #expect(try Self.read(file).map(\.text) == ["первая"])
        #expect(store.selected == store.notes.first?.id)
    }

    /// Уход со вкладки выметает пустые карточки — и то, что осталось,
    /// оказывается на диске без ожидания.
    @Test func leavingSweepsBlankNotesAndWritesAtOnce() throws {
        let (store, file) = try Self.makeStore()
        store.add()
        store.update(store.notes[0].id, text: "с текстом")
        store.add()
        store.add()

        store.leave()

        #expect(store.notes.map(\.text) == ["с текстом"])
        #expect(try Self.read(file).map(\.text) == ["с текстом"])
    }

    /// Пробелы — это не текст. Карточка из одного пробела выметается так же,
    /// как пустая.
    @Test func aNoteOfOnlyWhitespaceIsBlank() throws {
        let (store, _) = try Self.makeStore()
        store.add()
        store.update(store.notes[0].id, text: "   \n  ")
        store.leave()
        #expect(store.notes.isEmpty)
    }
}
