import Foundation
import Testing
@testable import Cyclop

/// Тесты на `ClaudeUsage` — разбор чужих файлов: истории лимитов приложения
/// Claude и логов Claude Code. Оба формата не наши и меняются без
/// предупреждения, так что проверяется главное: знакомое читается, незнакомое
/// пропускается, а не превращается в неправильные цифры.
struct ClaudeUsageTests {

    private static func history(_ samples: [(t: Double, fh: Double?, sd: Double?)], version: Int = 2) -> Data {
        let entries = samples.map { sample -> [String: Any] in
            var values: [String: Any] = [:]
            if let fh = sample.fh { values["fh"] = fh }
            if let sd = sample.sd { values["sd"] = sd }
            return version == 1 ? values.merging(["t": sample.t * 1000]) { a, _ in a } : ["t": sample.t * 1000, "u": values]
        }
        return try! JSONSerialization.data(withJSONObject: ["version": version, "samples": entries])
    }

    // MARK: - Лимиты

    @Test func unknownVersionIsSkipped() {
        let data = try! JSONSerialization.data(withJSONObject: ["version": 7, "samples": []])
        #expect(ClaudeUsage.samples(from: data) == nil)
    }

    @Test func versionOneKeepsValuesBesideTime() {
        let samples = ClaudeUsage.samples(from: Self.history([(1000, 12, 40)], version: 1))
        #expect(samples?.first?.used == ["fh": 12, "sd": 40])
    }

    /// Сессия началась не позже первого чтения выше нуля — от него и пять часов.
    @Test func sessionRenewsFiveHoursAfterItsFirstReading() throws {
        let start: Double = 1_800_000_000
        let samples = try #require(ClaudeUsage.samples(from: Self.history([
            (start - 600, 0, 10), (start, 5, 11), (start + 600, 20, 12),
        ])))
        let now = Date(timeIntervalSince1970: start + 900)
        let limits = try #require(ClaudeUsage.limits(from: samples, now: now))
        let session = try #require(limits.windows.first { $0.kind == .session })
        #expect(session.usedPercent == 20)
        #expect(session.resetsAt == Date(timeIntervalSince1970: start + 5 * 3600))
    }

    /// Чтение старше сессии ничего не говорит о той, что идёт сейчас.
    @Test func staleSessionIsLeftOut() throws {
        let samples = try #require(ClaudeUsage.samples(from: Self.history([(1_800_000_000, 50, 10)])))
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 6 * 3600)
        let limits = try #require(ClaudeUsage.limits(from: samples, now: now))
        #expect(!limits.windows.contains { $0.kind == .session })
        #expect(limits.windows.contains { $0.kind == .weekly })
    }

    /// Неделя обновляется по расписанию, которое выдаёт последнее падение.
    @Test func weekRenewsOnTheHourOfItsLastDrop() throws {
        // 1_800_000_000 — это 15:20 UTC; падение между 15:20 и 15:50 не
        // содержит часа, между 15:50 и 16:20 — содержит 16:00.
        let base: Double = 1_800_000_000
        let samples = try #require(ClaudeUsage.samples(from: Self.history([
            (base, 0, 60), (base + 1800, 0, 61), (base + 3600, 0, 2), (base + 7200, 0, 5),
        ])))
        let now = Date(timeIntervalSince1970: base + 7300)
        let week = try #require(ClaudeUsage.limits(from: samples, now: now)?.windows.first { $0.kind == .weekly })
        let hour = (base + 1800) / 3600
        let drop = (hour.rounded(.down) + 1) * 3600
        #expect(week.resetsAt == Date(timeIntervalSince1970: drop + 7 * 86_400))
    }

    // MARK: - Логи

    private static func assistant(
        id: String, model: String = "claude-opus-5-5", output: Int, stop: String?,
        sidechain: Bool = false, at time: String = "2026-10-20T10:00:00.000Z"
    ) -> Data {
        var message: [String: Any] = [
            "id": id, "model": model,
            "usage": ["input_tokens": 10, "output_tokens": output,
                      "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 200],
        ]
        message["stop_reason"] = stop ?? NSNull()
        let line: [String: Any] = ["type": "assistant", "timestamp": time, "requestId": "req-\(id)",
                                   "isSidechain": sidechain, "message": message]
        return try! JSONSerialization.data(withJSONObject: line)
    }

    private static func user(_ content: Any, at time: String = "2026-10-20T10:00:00.000Z") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "user", "timestamp": time, "isSidechain": false, "message": ["content": content],
        ])
    }

    @Test func replyIsReadWithItsCost() throws {
        let reply = try #require(ClaudeUsage.reply(from: Self.assistant(id: "m1", output: 100, stop: "end_turn")))
        #expect(reply.key == "m1|req-m1")
        #expect(reply.tokens.output == 100)
        let cost = try #require(ClaudeUsage.cost(reply.tokens, model: reply.model))
        // 10×4 + 100×20 + 1000×0.2 + 200×5, за миллион.
        #expect(abs(cost - 3240.0 / 1_000_000) < 1e-12)
    }

    @Test func toolOutputIsNotAReply() {
        #expect(ClaudeUsage.reply(from: Self.user("hello")) == nil)
    }

    /// Дата после имени — та же модель; число после имени — другая версия.
    @Test func modelsMatchTheirOwnPrice() {
        #expect(ClaudeUsage.price(for: "claude-opus-5-5")?.id == "claude-opus-5-5")
        #expect(ClaudeUsage.price(for: "claude-sonnet-4-5-20250929")?.id == "claude-sonnet-4-5")
        #expect(ClaudeUsage.price(for: "claude-opus-5-9") == nil)
        #expect(ClaudeUsage.price(for: "gpt-5") == nil)
    }

    @Test func turnRunsUntilAFinalReply() throws {
        let open = ClaudeUsage.lastTurn(lines: [
            Self.user("fix the bug", at: "2026-10-20T10:00:00.000Z"),
            Self.assistant(id: "a", output: 300, stop: "tool_use", at: "2026-10-20T10:00:05.000Z"),
            Self.user([["type": "tool_result", "content": "ok"]], at: "2026-10-20T10:00:06.000Z"),
            Self.assistant(id: "b", output: 200, stop: "tool_use", sidechain: true, at: "2026-10-20T10:00:07.000Z"),
        ])
        let turn = try #require(open)
        #expect(turn.isWorking)
        #expect(turn.outputTokens == 500)
        #expect(turn.start == ClaudeUsage.date("2026-10-20T10:00:00.000Z"))

        let closed = ClaudeUsage.lastTurn(lines: [
            Self.user("fix the bug"),
            Self.assistant(id: "a", output: 300, stop: "end_turn"),
        ])
        #expect(closed?.isWorking == false)
    }

    @Test func interruptionEndsTheTurn() {
        let turn = ClaudeUsage.lastTurn(lines: [
            Self.user("go"),
            Self.assistant(id: "a", output: 50, stop: "tool_use"),
            Self.user([["type": "text", "text": "[Request interrupted by user]"]]),
        ])
        #expect(turn?.isWorking == false)
    }
}
