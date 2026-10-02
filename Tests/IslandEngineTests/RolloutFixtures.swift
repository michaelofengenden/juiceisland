import Foundation
import OpenIslandCore

/// Codex rollout lines in the shape Codex writes them (`{"timestamp":…,"type":…,"payload":…}`, one per line), and
/// rollout files in a temporary sessions folder. Paths and prompts are fictional.
enum RolloutFixtures {
    static let sessionID = "019d516f-71ee-7e40-bcff-502fedac0928"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func time(_ second: Int) -> Date { start.addingTimeInterval(TimeInterval(second)) }

    static func stamp(_ second: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: time(second))
    }

    static func line(_ type: String, _ payload: [String: Any], at second: Int) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return #"{"timestamp":"\#(stamp(second))","type":"\#(type)","payload":\#(String(decoding: data, as: UTF8.self))}"#
    }

    /// The same line as newer Codex versions write it, with an `ordinal` after the timestamp.
    static func numbered(_ line: String, _ ordinal: Int) -> String {
        let end = line.range(of: #"",""#)!
        return line.replacingCharacters(in: end, with: #"","ordinal":\#(ordinal),"#)
    }

    static func meta(id: String = sessionID, cwd: String = "/tmp/project", at second: Int = 0) -> String {
        line("session_meta", ["id": id, "timestamp": stamp(second), "cwd": cwd, "originator": "codex_cli_rs",
                              "cli_version": "0.40.0", "source": "cli"], at: second)
    }

    static func turnContext(at second: Int) -> String {
        line("turn_context", ["cwd": "/tmp/project", "model": "gpt-5-codex", "approval_policy": "on-request"], at: second)
    }

    static func event(_ type: String, _ fields: [String: Any] = [:], at second: Int) -> String {
        line("event_msg", fields.merging(["type": type]) { $1 }, at: second)
    }

    static func item(_ type: String, _ fields: [String: Any] = [:], at second: Int) -> String {
        line("response_item", fields.merging(["type": type]) { $1 }, at: second)
    }

    static func message(_ role: String, _ text: String, at second: Int) -> String {
        item("message", ["role": role, "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]]],
             at: second)
    }

    /// A turn as Codex writes it: the prompt twice (event and item), reasoning, one command, the reply, the end.
    static func turn(prompt: String, reply: String, from second: Int, output: String = "ok") -> [String] {
        [turnContext(at: second),
         event("user_message", ["message": prompt, "images": []], at: second),
         message("user", prompt, at: second),
         event("task_started", ["model_context_window": 272_000], at: second + 1),
         item("reasoning", ["summary": [], "encrypted_content": "e30="], at: second + 2),
         event("agent_reasoning", ["text": "Looking."], at: second + 2),
         item("function_call", ["name": "exec_command", "arguments": #"{"cmd":"ls"}"#, "call_id": "c1"], at: second + 3),
         event("exec_command_begin", ["command": ["bash", "-lc", "ls"], "call_id": "c1"], at: second + 3),
         item("function_call_output", ["call_id": "c1", "output": output], at: second + 4),
         event("exec_command_end", ["call_id": "c1", "exit_code": 0], at: second + 4),
         event("token_count", ["info": ["total_token_usage": ["input_tokens": 10]]], at: second + 5),
         message("assistant", reply, at: second + 6),
         event("agent_message", ["message": reply], at: second + 6),
         event("task_complete", ["last_agent_message": reply], at: second + 7)]
    }

    /// The lines before the first turn: the session_meta, a developer message and an injected context block.
    static func head(id: String = sessionID) -> [String] {
        [meta(id: id),
         message("developer", "<permissions instructions>sandboxed</permissions instructions>", at: 0),
         message("user", "<environment_context><cwd>/tmp/project</cwd></environment_context>", at: 0)]
    }

    static func text(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

    /// A new sessions folder under the temporary folder, with the dated subfolders Codex makes.
    static func sessionsFolder() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-island-rollouts-\(UUID().uuidString)/sessions", isDirectory: true)
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("2026/09/24"), withIntermediateDirectories: true)
        return root
    }

    static func rolloutURL(in root: URL, id: String = sessionID, second: Int = 0) -> URL {
        root.appendingPathComponent(String(format: "2026/09/24/rollout-2026-09-24T10-00-%02d-%@.jsonl", second % 60, id))
    }

    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    static func append(_ text: String, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        handle.closeFile()
    }

    /// Grows the file by `count` bytes of NULs without writing them (a sparse hole), then ends that stretch with a
    /// newline, so it reads as one long line nobody should ever read.
    static func appendHole(_ count: Int, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        let end = handle.seekToEndOfFile()
        try! handle.truncate(atOffset: end + UInt64(count))
        handle.seekToEndOfFile()
        handle.write(Data("\n".utf8))
        handle.closeFile()
    }

    /// One `function_call_output` line whose output is `count` bytes long.
    static func appendLongLine(_ count: Int, at second: Int, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"timestamp":"\#(stamp(second))","type":"response_item","payload":{"type":"function_call_output","call_id":"c9","output":""#.utf8))
        let block = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)
        var left = count
        while left > 0 {
            let size = min(left, block.count)
            handle.write(block.prefix(size))
            left -= size
        }
        handle.write(Data("\"}}\n".utf8))
        handle.closeFile()
    }

    static func setModified(_ url: URL, to date: Date = .now) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// The bytes this process has allocated and not freed, over every malloc zone. Unlike the footprint, this does not
    /// count pages malloc keeps after they are freed, so a read that reuses them still counts what it holds.
    static func liveHeapBytes() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }
}
