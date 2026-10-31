import Foundation
import Testing
@testable import Cyclop

/// Тесты на `ConfigStore` — разбор `config.json`, перенос старых ключей и
/// отказ писать поверх того, что человек правил руками.
///
/// Почему именно здесь: этот файл обещан пользователю как редактируемый
/// (#67), и каждое такое обещание — правило, которое можно нарушить молча.
/// Два уже нарушались. Пропущенный ключ синтезированный декодер считает
/// поломкой файла, так что первая же новая настройка сделала бы каждый
/// существующий `config.json` нечитаемым (#121). А копия, прочитанная один
/// раз при запуске, писалась поверх ручной правки при следующем щелчке
/// переключателя. Ни то, ни другое не требует вью, чтобы увидеть.
///
/// Каждый тест работает со своим файлом во временной папке и со своим
/// `UserDefaults`: настоящие настройки того, кто запускает прогон, не
/// читаются и не пишутся.
@MainActor
struct ConfigStoreTests {

    private static func makeStore(
        contents: String? = nil,
        defaults: [String: Any] = [:]
    ) throws -> (store: ConfigStore, file: URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("config.json")
        if let contents { try Data(contents.utf8).write(to: file) }
        let suite = UserDefaults(suiteName: "cyclop.tests.\(UUID().uuidString)")!
        for (key, value) in defaults { suite.set(value, forKey: key) }
        return (ConfigStore(file: file, defaults: suite), file)
    }

    private static func json(_ file: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Незаконченный JSON: объект открыт и не закрыт.
    private static let brokenJSON = #"{"openDelay": 0.5"#

    // MARK: - Пропущенный ключ

    /// Главное правило этого файла: ключа нет — берётся значение по
    /// умолчанию, и файл остаётся читаемым. Иначе каждая новая настройка
    /// ломала бы все уже существующие файлы.
    @Test func aMissingKeyIsTheDefaultAndNotABrokenFile() throws {
        let (store, _) = try Self.makeStore(contents: #"{"openDelay": 0.35}"#)
        #expect(store.fileBroken == false)
        #expect(store.openDelay == 0.35)
        #expect(store.showOnAllDisplays == true)
        #expect(store.saveClipboardImages == true)
        #expect(store.hiddenTabs.isEmpty)
    }

    /// Пустой объект — это файл, в котором не сказано ничего. Все настройки
    /// по умолчанию, и это не поломка.
    @Test func anEmptyObjectIsAllDefaults() throws {
        let (store, _) = try Self.makeStore(contents: "{}")
        #expect(store.fileBroken == false)
        #expect(store.openDelay == 0.2)
    }

    // MARK: - Битый файл

    @Test func aBrokenFileRaisesTheFlagAndFallsBackToDefaults() throws {
        let (store, _) = try Self.makeStore(contents: Self.brokenJSON)
        #expect(store.fileBroken)
        #expect(store.openDelay == 0.2)
    }

    /// Переключатель не должен уносить настройки по умолчанию поверх файла,
    /// который не разобрали мы, а не человек.
    @Test func aSwitchDoesNotWriteOverABrokenFile() throws {
        let (store, file) = try Self.makeStore(contents: Self.brokenJSON)
        let before = try Data(contentsOf: file)
        store.showOnAllDisplays = false
        store.flush()
        #expect(try Data(contentsOf: file) == before)
    }

    /// Файл починили руками, пока приложение работало — `reload` снимает
    /// флаг и забирает то, что в нём теперь написано.
    @Test func anAmendedFileLowersTheFlag() throws {
        let (store, file) = try Self.makeStore(contents: Self.brokenJSON)
        try Data(#"{"openDelay": 0.45}"#.utf8).write(to: file)
        store.reload()
        #expect(store.fileBroken == false)
        #expect(store.openDelay == 0.45)
    }

    // MARK: - Ручная правка

    /// То, из-за чего всё это: правку в файле, сделанную при работающем
    /// приложении, не отменяет щелчок по другой настройке.
    @Test func aSwitchKeepsAHandEditToAnotherSetting() throws {
        let (store, file) = try Self.makeStore(contents: "{}")
        try Data(#"{"openDelay": 0.5}"#.utf8).write(to: file)

        store.saveClipboardImages = false
        store.flush()

        let written = try Self.json(file)
        #expect(written["openDelay"] as? Double == 0.5)
        #expect(written["saveClipboardImages"] as? Bool == false)
    }

    /// И наоборот: сама настройка доезжает до файла.
    @Test func aSwitchReachesTheFile() throws {
        let (store, file) = try Self.makeStore()
        store.hiddenTabs = ["calendar", "currency"]
        store.flush()
        #expect(try Self.json(file)["hiddenTabs"] as? [String] == ["calendar", "currency"])
    }

    /// Файл написан так, чтобы его открывали: с отступами и без экранирования
    /// слэшей — то же обещание, что и у `snippets.json`.
    @Test func theFileIsWrittenToBeReadByAHuman() throws {
        let (_, file) = try Self.makeStore()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\n"))
        #expect(!text.contains("\\/"))
    }

    // MARK: - Задержка открытия

    /// Файл не может попросить того, чего не показывает ползунок: значение
    /// за границами диапазона читается как ближайшее допустимое.
    @Test func openDelayIsClampedToWhatTheSliderOffers() throws {
        let (slow, _) = try Self.makeStore(contents: #"{"openDelay": 99}"#)
        #expect(slow.openDelay == ConfigStore.openDelayRange.upperBound)
        let instant = try Self.makeStore(contents: #"{"openDelay": -5}"#).store
        #expect(instant.openDelay == ConfigStore.openDelayRange.lowerBound)
    }

    // MARK: - Перенос старых ключей

    /// Нет файла — он собирается из старых ключей `UserDefaults` и сразу
    /// пишется. Это единственный путь, на котором их вообще читают.
    @Test func withNoFileTheOldKeysAreCarriedOverAndWritten() throws {
        let (store, file) = try Self.makeStore(defaults: [
            "showOnAllDisplays": false,
            "saveClipboardImages": false,
            "hiddenTabs": ["notes"],
            "teleprompter.speed": 2.5,
        ])
        #expect(store.showOnAllDisplays == false)
        #expect(store.saveClipboardImages == false)
        #expect(store.hiddenTabs == ["notes"])
        #expect(store.teleprompterSpeed == 2.5)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Ключа нет — остаётся значение по умолчанию, а не `false`, которое
    /// `bool(forKey:)` отдаёт за отсутствующий ключ.
    @Test func anAbsentOldKeyKeepsTheDefaultAndNotFalse() throws {
        let (store, _) = try Self.makeStore()
        #expect(store.showOnAllDisplays == true)
        #expect(store.saveClipboardImages == true)
    }

    /// Старый приватный режим был один на всё. Включённый, он переносится в
    /// четыре раздела, которые он тогда закрывал.
    @Test func theLegacyPrivacySwitchBecomesAllFourSections() throws {
        let (store, _) = try Self.makeStore(defaults: ["privacyMode": true])
        #expect(Set(store.privacy) == ["clipboard", "snippets", "calendar", "notes"])
    }

    /// А если разделы уже перечислены, берутся они, а не старый выключатель.
    @Test func listedSectionsWinOverTheLegacySwitch() throws {
        let (store, _) = try Self.makeStore(defaults: [
            "privacyMode": true,
            "privacyMode.sections": ["clipboard"],
        ])
        #expect(store.privacy == ["clipboard"])
    }

    /// Файл есть — старые ключи не читаются вовсе, даже если в них что-то
    /// лежит. Иначе откат на старую версию и обратно менял бы настройки.
    @Test func anExistingFileWinsOverTheOldKeys() throws {
        let (store, _) = try Self.makeStore(
            contents: #"{"showOnAllDisplays": true}"#,
            defaults: ["showOnAllDisplays": false]
        )
        #expect(store.showOnAllDisplays == true)
    }
}
