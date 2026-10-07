import Foundation
import Testing
@testable import Cyclop

/// Тесты на `SourcePicker` — какую из нескольких сессий Now Playing показывает
/// вкладка «Музыка».
///
/// Правила здесь — та часть, которая ломается без единого вью: YouTube на паузе
/// держал звание «сейчас играет», и панель показывала его, пока играла
/// Яндекс Музыка. Pid'ы ниже условные: 10 — браузер, 20 — плеер.
@MainActor
struct SourcePickerTests {

    private static let browser: pid_t = 10
    private static let player: pid_t = 20

    private static func session(_ pid: pid_t, playing: Bool) -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.pid = pid
        snapshot.title = "track \(pid)"
        snapshot.isPlaying = playing
        return snapshot
    }

    // MARK: - Без ручного выбора

    /// Ровно тот случай, ради которого всё затевалось: система назвала главным
    /// видео на паузе, а звук идёт из плеера. Показывается плеер.
    @Test func playingBeatsSystemChoiceThatIsPaused() {
        var picker = SourcePicker()
        let chosen = picker.choose(
            from: [Self.session(Self.browser, playing: false), Self.session(Self.player, playing: true)],
            active: Self.browser
        )
        #expect(chosen?.pid == Self.player)
    }

    /// Играют оба, и оба новые для нас — первый кадр. Решает система.
    @Test func systemSettlesTheFirstFrame() {
        var picker = SourcePicker()
        let chosen = picker.choose(
            from: [Self.session(Self.browser, playing: true), Self.session(Self.player, playing: true)],
            active: Self.player
        )
        #expect(chosen?.pid == Self.player)
    }

    /// Играло видео, потом запустили музыку, а видео не остановили. Система
    /// может так и держать видео главным — побеждает последний запуск.
    @Test func latestStartWinsEvenAgainstTheSystem() {
        var picker = SourcePicker()
        _ = picker.choose(from: [Self.session(Self.browser, playing: true)], active: Self.browser)
        let chosen = picker.choose(
            from: [Self.session(Self.browser, playing: true), Self.session(Self.player, playing: true)],
            active: Self.browser
        )
        #expect(chosen?.pid == Self.player)
    }

    /// Музыку поставили на паузу, а видео на паузе давно. Панель остаётся на
    /// музыке, а не прыгает на видео, которое система всё ещё зовёт главным.
    @Test func pausingKeepsWhatWasShown() {
        var picker = SourcePicker()
        _ = picker.choose(
            from: [Self.session(Self.browser, playing: false), Self.session(Self.player, playing: true)],
            active: Self.browser
        )
        let chosen = picker.choose(
            from: [Self.session(Self.browser, playing: false), Self.session(Self.player, playing: false)],
            active: Self.browser
        )
        #expect(chosen?.pid == Self.player)
    }

    @Test func noSessionsMeansNothing() {
        var picker = SourcePicker()
        #expect(picker.choose(from: [], active: Self.browser) == nil)
    }

    // MARK: - Ручной выбор

    /// Выбрать можно и то, что стоит на паузе, пока играет другое: иначе не до
    /// чего было бы дотянуться, чтобы нажать play.
    @Test func pickHoldsAgainstSomethingAlreadyPlaying() {
        var picker = SourcePicker()
        let sessions = [Self.session(Self.browser, playing: true), Self.session(Self.player, playing: false)]
        _ = picker.choose(from: sessions, active: Self.browser)
        picker.pin(Self.player)
        #expect(picker.choose(from: sessions, active: Self.browser)?.pid == Self.player)
        #expect(picker.choose(from: sessions, active: Self.browser)?.pid == Self.player)
    }

    /// Выбранное запустили — оно и остаётся, это не «другой источник».
    @Test func pickedSessionStartingKeepsThePick() {
        var picker = SourcePicker()
        _ = picker.choose(
            from: [Self.session(Self.browser, playing: true), Self.session(Self.player, playing: false)],
            active: Self.browser
        )
        picker.pin(Self.player)
        let chosen = picker.choose(
            from: [Self.session(Self.browser, playing: true), Self.session(Self.player, playing: true)],
            active: Self.browser
        )
        #expect(chosen?.pid == Self.player)
        #expect(picker.pinned == Self.player)
    }

    /// Выбрали плеер, а потом запустили видео. Запуск — последнее слово.
    @Test func anotherStartReleasesThePick() {
        var picker = SourcePicker()
        _ = picker.choose(
            from: [Self.session(Self.browser, playing: false), Self.session(Self.player, playing: false)],
            active: Self.browser
        )
        picker.pin(Self.player)
        let chosen = picker.choose(
            from: [Self.session(Self.browser, playing: true), Self.session(Self.player, playing: false)],
            active: Self.browser
        )
        #expect(chosen?.pid == Self.browser)
        #expect(picker.pinned == nil)
    }

    /// Выбранное приложение закрыли — выбор уходит вместе с ним и не
    /// возвращается, если под тем же pid'ом что-то появится снова.
    @Test func pickGoesWithItsSession() {
        var picker = SourcePicker()
        _ = picker.choose(
            from: [Self.session(Self.browser, playing: false), Self.session(Self.player, playing: false)],
            active: Self.browser
        )
        picker.pin(Self.player)
        _ = picker.choose(from: [Self.session(Self.browser, playing: false)], active: Self.browser)
        #expect(picker.pinned == nil)
    }
}
