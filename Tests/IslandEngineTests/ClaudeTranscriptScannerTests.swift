import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Claude transcript lines in the shape Claude Code writes them (one JSON object per line), and transcripts in a
/// temporary projects folder. Paths, ids and prompts are fictional.
enum ClaudeFixtures {
    static let sessionID = "5f0c2a8e-3b1d-4c6e-9a7f-1d2e3f4a5b6c"

    static func stamp(_ second: Int, fractional: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.string(from: RolloutFixtures.time(second))
    }

    static func line(_ fields: [String: Any], at second: Int?, fractional: Bool = true, id: String = sessionID,
                     cwd: String? = "/tmp/project", entrypoint: String? = "cli") -> String {
        var object = fields
        object["sessionId"] = id
        if let cwd { object["cwd"] = cwd }
        if let entrypoint { object["entrypoint"] = entrypoint }
        if let second { object["timestamp"] = stamp(second, fractional: fractional) }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func user(_ text: String, at second: Int, fractional: Bool = true, id: String = sessionID) -> String {
        line(["type": "user", "message": ["role": "user", "content": text]], at: second, fractional: fractional, id: id)
    }

    static func userBlocks(_ text: String, at second: Int) -> String {
        line(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]], at: second)
    }

    static func assistant(_ text: String, model: String = "claude-test-1", at second: Int, fractional: Bool = true) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": text]]]],
             at: second, fractional: fractional)
    }

    static func toolUse(_ id: String, name: String = "Bash", input: Any = ["command": "ls -la"], at second: Int) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "model": "claude-test-1",
                                               "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]],
             at: second)
    }

    static func toolResult(_ id: String, at second: Int) -> String {
        line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]],
             at: second)
    }

    static func summary(_ text: String) -> String {
        line(["type": "summary", "summary": text, "leafUuid": "leaf-1"], at: nil, cwd: nil, entrypoint: nil)
    }

    /// A turn: the prompt, a tool call and its result, the reply.
    static func turn(prompt: String, reply: String, from second: Int, tool: String = "t1") -> [String] {
        [user(prompt, at: second), toolUse(tool, at: second + 1), toolResult(tool, at: second + 2), assistant(reply, at: second + 3)]
    }

    /// A new projects folder under the temporary folder, with one project folder in it.
    static func projectsFolder() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-island-transcripts-\(UUID().uuidString)/projects", isDirectory: true)
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("-tmp-project"), withIntermediateDirectories: true)
        return root
    }

    static func transcriptURL(in root: URL, id: String = sessionID) -> URL {
        root.appendingPathComponent("-tmp-project/\(id).jsonl")
    }

    /// Writes `lines`, each naming the session `id` instead of `sessionID`.
    static func write(_ lines: [String], to url: URL, id: String = sessionID, finalNewline: Bool = true) {
        let text = lines.map { $0.replacingOccurrences(of: sessionID, with: id) }.joined(separator: "\n") + (finalNewline ? "\n" : "")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// One user line whose text is `count` bytes long, written without holding it whole.
    static func appendLongLine(_ count: Int, at second: Int, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"message":{"content":[{"content":""#.utf8))
        let block = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)
        var left = count
        while left > 0 {
            let size = min(left, block.count)
            handle.write(block.prefix(size))
            left -= size
        }
        handle.write(Data(#"","tool_use_id":"t0","type":"tool_result"}],"role":"user"},"sessionId":"\#(sessionID)","timestamp":"\#(stamp(second))","type":"user"}"#.utf8))
        handle.write(Data("\n".utf8))
        handle.closeFile()
    }
}

/// Claude transcript discovery with bounded reads (P84): small transcripts give upstream's sessions exactly, a huge
/// one is read as its head and its last window, and no subagent folder is walked. Serialized because the large
/// fixtures are hundreds of megabytes of (mostly sparse) file each.
@Suite(.serialized)
struct ClaudeTranscriptScannerTests {
    typealias F = ClaudeFixtures
    typealias R = RolloutFixtures

    private func upstream(_ root: URL, now: Date) -> [AgentSession] {
        ClaudeTranscriptDiscovery(rootURL: root).discoverRecentSessions(now: now)
    }

    @Test
    func smallTranscriptsGiveUpstreamsSessions() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let long = String(repeating: "word\tand  more\r\nwords ", count: 400) + "🙂 end"
        let spaced = String(repeating: " ", count: 3_000) + "late text " + String(repeating: "x", count: 300)
        // A finished session from the desktop app, with a summary after its reply.
        F.write([F.line(["type": "user", "message": ["role": "user", "content": "first prompt"]], at: 0, entrypoint: "claude-desktop")]
                + F.turn(prompt: "second prompt", reply: "all done", from: 10) + [F.summary("Summed up")],
                to: F.transcriptURL(in: root, id: "a1"), id: "a1")
        // A tool still waiting, times without fractional seconds (upstream parses those), and a last line with no newline.
        F.write([F.user("look around", at: 0, fractional: false), F.toolUse("t9", input: ["command": long], at: 5),
                 F.assistant("working", at: 6, fractional: false)],
                to: F.transcriptURL(in: root, id: "a2"), id: "a2", finalNewline: false)
        // Long texts: one clipped from its first scalars, one whose first scalars are mostly spaces.
        F.write([F.userBlocks(long, at: 0), F.assistant(spaced, at: 1), F.toolUse("t2", name: "Write", input: ["content": long, "path": "/tmp/a"], at: 2)],
                to: F.transcriptURL(in: root, id: "a3"), id: "a3")
        // No working folder anywhere: no session, as upstream.
        F.write([F.line(["type": "user", "message": ["role": "user", "content": "lost"]], at: 0, cwd: nil)],
                to: F.transcriptURL(in: root, id: "a4"), id: "a4")
        // A hex-escaped folder, and a line that is not JSON.
        F.write(["not json", F.line(["type": "user", "message": ["role": "user", "content": "hex"]], at: 0, cwd: #"/tmp/caf\xc3\xa9"#)],
                to: F.transcriptURL(in: root, id: "a5"), id: "a5")

        let now = Date()
        let theirs = upstream(root, now: now)
        let scanner = ClaudeTranscriptScanner(rootURL: root)
        let ours = scanner.discoverRecentSessions(now: now)
        #expect(theirs.count == 4)
        // The same sessions as upstream's, but for the desktop session's title line, which upstream shows as Claude's
        // last message and ours leaves out (P155).
        #expect(ours.filter { $0.id != "a1" } == theirs.filter { $0.id != "a1" })
        var theirDesktop = try #require(theirs.first { $0.id == "a1" })
        theirDesktop.summary = "all done"
        theirDesktop.claudeMetadata?.lastAssistantMessage = "all done"
        #expect(ours.first { $0.id == "a1" } == theirDesktop)
        #expect(scanner.lastScanDiagnostics.windowedFileCount == 0)
        let sizes = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("-tmp-project"), includingPropertiesForKeys: [.fileSizeKey])
            .map { try #require($0.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        #expect(scanner.lastScanDiagnostics.bytesRead == sizes.reduce(0, +))

        let desktop = try #require(ours.first { $0.id == "a1" })
        #expect(desktop.jumpTarget?.terminalApp == "Claude.app")
        #expect(desktop.summary == "all done")
        #expect(desktop.claudeMetadata?.initialUserPrompt == "first prompt")
        #expect(ours.first { $0.id == "a2" }?.claudeMetadata?.currentTool == "Bash")
    }

    /// The owner's case in small: a first turn, 255 MB nobody reads, a 40 MB tool result on one line, then the last
    /// turn. The head gives the folder, the entrypoint and the first prompt; the last 4 MB the rest.
    @Test
    func aHugeTranscriptIsReadAsItsHeadAndItsLastWindow() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let url = F.transcriptURL(in: root)
        F.write(F.turn(prompt: "first prompt", reply: "first reply", from: 0), to: url)
        R.appendHole(255 << 20, to: url)
        F.appendLongLine(40 << 20, at: 400, to: url)
        R.append(F.turn(prompt: "last prompt", reply: "all done", from: 500, tool: "t5").joined(separator: "\n") + "\n", to: url)
        R.append(F.toolUse("t6", name: "Edit", at: 504) + "\n", to: url)
        let scanner = ClaudeTranscriptScanner(rootURL: root)

        let started = Date()
        let sessions = scanner.discoverRecentSessions()
        #expect(Date().timeIntervalSince(started) < 2)
        let diagnostics = scanner.lastScanDiagnostics
        #expect(diagnostics.windowedFileCount == 1)
        // The head looks `titleReach` past the first prompt for a title this transcript has not got.
        #expect(diagnostics.bytesRead <= (4 << 20) + 2 * 64 * 1_024 + ClaudeTranscriptScanner.titleReach + 1)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.id == F.sessionID)
        #expect(session.title == "Claude · project")
        #expect(session.summary == "all done")
        #expect(session.claudeMetadata?.initialUserPrompt == "first prompt")
        #expect(session.claudeMetadata?.lastUserPrompt == "last prompt")
        #expect(session.claudeMetadata?.currentTool == "Edit")
        #expect(session.claudeMetadata?.model == "claude-test-1")
        #expect(session.jumpTarget?.workingDirectory == "/tmp/project")
    }

    /// A transcript whose end is one line longer than both windows: the session stands on the head.
    @Test
    func aTailInsideOneLongLineIsWidenedOnceAndStaysBounded() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let url = F.transcriptURL(in: root)
        F.write(F.turn(prompt: "first prompt", reply: "first reply", from: 0), to: url)
        R.appendHole(200 << 20, to: url)
        F.appendLongLine(40 << 20, at: 400, to: url)
        let scanner = ClaudeTranscriptScanner(rootURL: root)

        let session = try #require(scanner.discoverRecentSessions().first)
        let diagnostics = scanner.lastScanDiagnostics
        #expect(diagnostics.bytesRead <= (4 << 20) + (32 << 20) + 3 * 64 * 1_024 + ClaudeTranscriptScanner.titleReach + 2)
        #expect(session.claudeMetadata?.initialUserPrompt == "first prompt")
        #expect(session.claudeMetadata?.lastUserPrompt == "first prompt")
        #expect(session.summary == "first reply")
    }

    /// Upstream walks every subagent's transcript before dropping it by its path; ours never enters the folder, and
    /// finds the same sessions.
    @Test
    func subagentFoldersAreNeverWalked() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        F.write(F.turn(prompt: "main", reply: "done", from: 0), to: F.transcriptURL(in: root))
        for index in 0..<30 {
            F.write(F.turn(prompt: "sub \(index)", reply: "done", from: 0),
                    to: root.appendingPathComponent("-tmp-project/\(F.sessionID)/subagents/agent-\(index).jsonl"))
        }
        let now = Date()
        let scanner = ClaudeTranscriptScanner(rootURL: root)
        let ours = scanner.discoverRecentSessions(now: now)
        #expect(ours == upstream(root, now: now))
        #expect(ours.map(\.id) == [F.sessionID])
        #expect(scanner.lastScanDiagnostics.visitedFileCount == 1)
    }

    /// Only the newest 40 of the last day are read, as upstream reads them.
    @Test
    func manyTranscriptsKeepTheNewestForty() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        for index in 0..<45 {
            let url = F.transcriptURL(in: root, id: String(format: "s%02d", index))
            F.write([F.user("prompt \(index)", at: index, id: String(format: "s%02d", index))], to: url)
            R.setModified(url, to: Date().addingTimeInterval(TimeInterval(-60 * index)))
        }
        let old = F.transcriptURL(in: root, id: "old")
        F.write([F.user("old prompt", at: 0, id: "old")], to: old)
        R.setModified(old, to: Date().addingTimeInterval(-2 * 86_400))
        let now = Date()
        let scanner = ClaudeTranscriptScanner(rootURL: root)
        let ours = scanner.discoverRecentSessions(now: now)
        #expect(ours.count == 40)
        #expect(ours == upstream(root, now: now))
        #expect(scanner.lastScanDiagnostics.candidateCount == 45)
        #expect(scanner.lastScanDiagnostics.parsedFileCount == 40)
    }

    /// Another Claude profile found at launch is read by the same scanner.
    @Test
    func anotherProfileIsReadWithinBounds() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let url = F.transcriptURL(in: root)
        F.write(F.turn(prompt: "first prompt", reply: "first reply", from: 0), to: url)
        R.appendHole(255 << 20, to: url)
        R.append(F.turn(prompt: "last prompt", reply: "all done", from: 500).joined(separator: "\n") + "\n", to: url)
        var payload = SessionDiscoveryCoordinator.StartupDiscoveryPayload(
            codexRecords: [], codexRecordsNeedPrune: false, claudeRecords: [], claudeRecordsNeedPrune: false,
            openCodeRecords: [], openCodeRecordsNeedPrune: false, cursorRecords: [], cursorRecordsNeedPrune: false,
            piRecords: [], piRecordsNeedPrune: false, discoveredCodexRecords: [], discoveredClaudeSessions: [], hooksBinaryURL: nil)
        let target = ProfileHookTarget(provider: .claude, folder: root.deletingLastPathComponent().path, alias: "work",
                                       isDefaultFolder: false, accountID: nil, isMonitored: true)

        let started = Date()
        SessionEngine.addProfileDiscoveries(to: &payload, from: [target])
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(payload.discoveredClaudeSessions.map(\.id) == [F.sessionID])
        #expect(payload.discoveredClaudeSessions.first?.claudeMetadata?.lastUserPrompt == "last prompt")
    }

    /// The clipped collapse gives upstream's text for every kind of long text.
    @Test
    func longTextsAreClippedToUpstreamsText() {
        let texts = [
            String(repeating: "a b\tc\nd ", count: 2_000),
            String(repeating: " ", count: 5_000) + "tail",
            String(repeating: "\r\n", count: 1_500) + String(repeating: "word ", count: 100),
            String(repeating: "🙂👩‍👩‍👧 é", count: 700),
            String(repeating: "x", count: 10_000),
            String(repeating: "y ", count: 1_025) + String(repeating: "\n", count: 3_000),
            "short text", "  ", String(repeating: "z", count: 140), String(repeating: "z", count: 141),
        ]
        for text in texts {
            #expect(ClaudeTranscriptFold.normalizedText(text) == Self.upstreamNormalizedText(text))
        }
    }

    /// The fast path refuses a time with fractional seconds without a formatter; this pins that the formatter
    /// refuses every one of them too, and that every other time still reaches the formatter.
    @Test
    func aTimeWithFractionalSecondsNeverParses() {
        let formatter = ISO8601DateFormatter()
        for date in ["2026-09-24T10:00:00", "1999-12-31T23:59:59", "2026-02-28T00:00:00"] {
            for count in 1...9 {
                for zone in ["Z", "+02:00", "-05:30", "+00:00"] {
                    let text = date + "." + String(repeating: "7", count: count) + zone
                    #expect(ClaudeTranscriptFold.hasFractionalSeconds(text))
                    #expect(formatter.date(from: text) == nil)
                }
            }
        }
        for text in ["2026-09-24T10:00:00Z", "2026-09-24T10:00:00+02:00", "2026-09-24T10:00:00Z.", "2026.09.24T10:00:00Z",
                     "2026-09-24T10:00:00.Z", "2026-09-24T10:00:00.123Zx", "2026-09-24T10:00:00.123+0200", "", "garbage"] {
            #expect(!ClaudeTranscriptFold.hasFractionalSeconds(text))
        }
        #expect(formatter.date(from: "2026-09-24T10:00:00Z") != nil)
    }

    /// Upstream's `ClaudeTranscriptDiscovery.normalizedText`, private there, copied as it is.
    private static func upstreamNormalizedText(_ value: String) -> String? {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > 140 else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 139)
        return "\(collapsed[..<endIndex])…"
    }
}
