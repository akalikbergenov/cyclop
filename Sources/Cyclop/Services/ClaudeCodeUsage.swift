import Foundation

/// Asks Claude Code for the account's limits, the way its `/usage` does.
///
/// The Claude app's history file is only as fresh as the app's last check,
/// and that can be many hours old while Claude Code is in heavy use. Claude
/// Code itself can ask the account: started in its structured mode, it takes
/// a `get_usage` request and answers with the same windows `/usage` shows.
/// The request is Claude Code's, with its own sign-in — Cyclop holds no
/// token and opens no connection of its own. No prompt, no model, no tools,
/// no MCP servers, no hooks, and nothing written to the session history.
enum ClaudeCodeUsage {
    /// Where Claude Code can be: its installer's and Homebrew's places, then
    /// the copy the Claude app keeps for its Code tab, newest version first.
    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        var candidates = [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0) }
        candidates += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map { URL(fileURLWithPath: $0) }
        let bundled = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let folder = bundled.appendingPathComponent(version)
            for build in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                candidates.append(folder.appendingPathComponent("\(build)/claude.app/Contents/MacOS/claude"))
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Blocks for up to `timeout`; call it off the main thread.
    static func fetch(timeout: TimeInterval = 20) -> ClaudeUsage.Limits? {
        guard let executable = executable() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.arguments = [
            "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#,
        ]
        // Not a session nested in ours, and never one that updates itself.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // The pid, not the process object, crosses to the timer's thread; the
        // timer is cancelled before this function returns, so the pid cannot
        // have been handed to another process by then.
        let pid = process.processIdentifier
        let deadline = DispatchWorkItem { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ id: String, _ request: [String: Any]) {
            let request: [String: Any] = ["type": "control_request", "request_id": id, "request": request]
            guard var data = try? JSONSerialization.data(withJSONObject: request) else { return }
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
        }

        send("init", ["subtype": "initialize"])
        var buffer = Data()
        var asked = false
        while true {
            // Empty once the process ends — on its own or at the deadline.
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any] else { continue }
                guard response["subtype"] as? String == "success" else { return nil }
                switch response["request_id"] as? String {
                case "init" where !asked:
                    asked = true
                    send("usage", ["subtype": "get_usage", "skip_behaviors": true])
                case "usage":
                    return ClaudeUsage.limits(fromUsage: response["response"] as? [String: Any] ?? [:], at: Date())
                default:
                    break
                }
            }
        }
    }
}
