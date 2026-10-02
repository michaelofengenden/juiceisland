// Changed from Open Island 1.2.1's Sources/OpenIslandCore/ClaudeTranscriptDiscovery.swift (GPL-3.0), September 2026:
// its ClaudeTranscriptDiscovery, with every read bounded.
import Foundation
import OpenIslandCore

/// What one pass of `ClaudeTranscriptScanner` did.
public struct ClaudeTranscriptScanDiagnostics: Equatable, Sendable {
    /// Transcripts modified within `maxAge`, before the `maxFiles` cap.
    public var candidateCount = 0
    public var bytesRead = 0
    public var parsedFileCount = 0
    /// Transcripts read as a head and a tail window instead of whole.
    public var windowedFileCount = 0
    /// Lines dropped for being longer than `Limits.maxLineLength`.
    public var skippedLineCount = 0
    /// Files the walk looked at; a `subagents` folder is never entered.
    public var visitedFileCount = 0

    public init() {}
}

/// Upstream's `ClaudeTranscriptDiscovery` with every read bounded (P84), as `CodexRolloutScanner` is upstream's rollout
/// discovery: the same transcripts (modified in the last day, the newest 40, never a subagent's) and the same
/// sessions, but for machine text, which is never a prompt or a reply here (P155, `ClaudeTranscriptFold`). `SessionDiscoveryCoordinator` holds one for ~/.claude at launch (`Patches/bounded-transcripts.patch`),
/// and `SessionEngine.addProfileDiscoveries` makes one for each other Claude profile.
///
/// Upstream folds each transcript whole, cutting lines by searching and copying its whole buffer again for every
/// line, with a date formatter per line and no autorelease pool: 40 transcripts of the owner's default profile (187 MB)
/// took 6.3 s and a 360 MB peak, every launch, and every other profile the same. Here a transcript up to
/// `wholeFileLimit` is read whole, as upstream reads it; a larger one is read as its head (until it has a working
/// folder, the entrypoint and the first prompt) and the lines that start in its last 4 MB. The middle is never read,
/// so a large transcript's session can miss what only the middle has: the last prompt and the last reply when the
/// tail holds none (they stay the head's), and a tool still waiting on a result from before the tail.
public final class ClaudeTranscriptScanner: @unchecked Sendable {
    public typealias Limits = CodexRolloutScanner.Limits

    private struct Candidate {
        var fileURL: URL
        var modifiedAt: Date
        var createdAt: Date?
        var fileSize: Int
    }

    private static let chunkSize = 64 * 1_024
    /// How far past the first prompt a large transcript's head looks for the generated title, which Claude writes a
    /// few lines after that prompt (P201).
    static let titleReach = 256 * 1_024

    private let rootURL: URL
    private let fileManager: FileManager
    private let maxAge: TimeInterval
    private let maxFiles: Int
    private let limits: Limits
    private let lock = NSLock()
    private var _lastScanDiagnostics = ClaudeTranscriptScanDiagnostics()
    private var _lastScanTitles: [String: ClaudeTitleFold] = [:]

    public var lastScanDiagnostics: ClaudeTranscriptScanDiagnostics {
        lock.withLock { _lastScanDiagnostics }
    }

    /// The title lines the last pass folded, by session, for sessions that had any (the chat title, P200): the engine
    /// takes them into its memory beside the sessions, never into a session's `title`.
    public var lastScanTitles: [String: ClaudeTitleFold] {
        lock.withLock { _lastScanTitles }
    }

    public init(rootURL: URL = ClaudeTranscriptDiscovery.defaultRootURL, fileManager: FileManager = .default,
                maxAge: TimeInterval = 86_400, maxFiles: Int = 40, limits: Limits = Limits()) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.maxAge = maxAge
        self.maxFiles = maxFiles
        self.limits = limits
    }

    public func discoverRecentSessions(now: Date = .now) -> [AgentSession] {
        var diagnostics = ClaudeTranscriptScanDiagnostics()
        var titles: [String: ClaudeTitleFold] = [:]
        defer {
            lock.withLock {
                _lastScanDiagnostics = diagnostics
                _lastScanTitles = titles
            }
            TranscriptReadTally.add(considered: min(diagnostics.candidateCount, maxFiles), read: diagnostics.parsedFileCount,
                                    bytes: diagnostics.bytesRead)
        }
        let candidates = recentCandidates(now: now, diagnostics: &diagnostics)
        let found = candidates.compactMap { candidate -> Found? in
            autoreleasepool {
                guard let fold = parseSession(candidate, diagnostics: &diagnostics),
                      let session = fold.session(transcriptPath: candidate.fileURL.path) else { return nil }
                if !fold.titles.isEmpty { titles[session.id] = fold.titles }
                return Found(session: session, forkedFrom: fold.forkedFrom, modifiedAt: candidate.modifiedAt, createdAt: candidate.createdAt)
            }
        }
        let parents = Self.forkedParents(found)
        for parent in parents { titles[parent] = nil }
        return found.map(\.session).filter { !parents.contains($0.id) }
    }

    struct Found {
        var session: AgentSession
        var forkedFrom: String?
        var modifiedAt: Date
        /// When the file began (its birth time); nil where the file system keeps none.
        var createdAt: Date? = nil
    }

    /// How much later than its fork a parent's file may have been written and still be the conversation the fork took
    /// over: the `/branch` line itself lands in the parent (P442).
    static let forkGrace: TimeInterval = 60

    /// The sessions a fork found in the same pass carries on (P442): a parent whose file was last written no later than
    /// its fork's (and `forkGrace`) is the same conversation up to the fork, which the process left for the fork. A parent
    /// the owner resumed and wrote to later is a conversation of its own and stays; so does one last written well before
    /// its fork's file began (`forkGrace`), which a `/branch` would have written to as it forked: a fork made from another
    /// terminal (`--fork-session`), whose parent may still be open there (P498).
    static func forkedParents(_ found: [Found]) -> Set<String> {
        var modified: [String: Date] = [:]
        for item in found { modified[item.session.id] = max(modified[item.session.id] ?? .distantPast, item.modifiedAt) }
        var parents: Set<String> = []
        for child in found {
            guard let parent = child.forkedFrom, parent != child.session.id, let parentModified = modified[parent],
                  parentModified <= child.modifiedAt.addingTimeInterval(forkGrace) else { continue }
            if let created = child.createdAt, parentModified < created.addingTimeInterval(-forkGrace) { continue }
            parents.insert(parent)
        }
        return parents
    }

    private func recentCandidates(now: Date, diagnostics: inout ClaudeTranscriptScanDiagnostics) -> [Candidate] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = now.addingTimeInterval(-maxAge)
        var candidates: [Candidate] = []
        for case let fileURL as URL in enumerator {
            // Upstream walks every subagent's transcript only to drop it by its path; here the folder is not entered.
            if fileURL.lastPathComponent == "subagents",
               (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension == "jsonl", !fileURL.path.contains("/subagents/") else { continue }
            diagnostics.visitedFileCount += 1
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate, modifiedAt >= cutoff else { continue }
            candidates.append(Candidate(fileURL: fileURL, modifiedAt: modifiedAt, createdAt: values.creationDate, fileSize: values.fileSize ?? 0))
        }
        diagnostics.candidateCount = candidates.count
        return Array(candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFiles))
    }

    private func parseSession(_ candidate: Candidate, diagnostics: inout ClaudeTranscriptScanDiagnostics) -> ClaudeTranscriptFold? {
        guard let handle = try? FileHandle(forReadingFrom: candidate.fileURL) else { return nil }
        defer { try? handle.close() }
        diagnostics.parsedFileCount += 1

        var fold = ClaudeTranscriptFold(sessionID: candidate.fileURL.deletingPathExtension().lastPathComponent,
                                        updatedAt: candidate.modifiedAt)
        if candidate.fileSize <= limits.wholeFileLimit {
            foldLines(handle, from: 0, skippingFirstLine: false, budget: .max, into: &fold, diagnostics: &diagnostics) { _, _ in true }
        } else {
            diagnostics.windowedFileCount += 1
            // The head goes on past the first prompt, at most `titleReach`, for the generated title Claude writes a few
            // lines after it (its re-appended copies, at an exit, a resume or a compaction, are in the tail).
            var promptAt: Int?
            foldLines(handle, from: 0, skippingFirstLine: false, budget: limits.headLimit, keepsTrailingLine: false,
                      into: &fold, diagnostics: &diagnostics) { fold, read in
                if fold.cwd == nil || fold.entrypoint == nil || fold.initialUserPrompt == nil { return true }
                guard fold.titles.isEmpty else { return false }
                let at = promptAt ?? read
                promptAt = at
                return read - at < Self.titleReach
            }
            // What was pending in the head is unknown by the tail: its result may be in the middle.
            fold.forgetPendingTools()
            let head = fold
            for window in [limits.tailWindow, limits.widenedTailWindow] {
                let start = max(0, candidate.fileSize - window)
                fold = head
                // One byte early, so a window that starts right after a newline keeps its first line.
                let lines = foldLines(handle, from: max(0, start - 1), skippingFirstLine: start > 0, budget: .max,
                                      into: &fold, diagnostics: &diagnostics) { _, _ in true }
                if lines > 0 || start == 0 { break }
            }
        }
        return fold
    }

    /// Folds the lines from `offset` on until the end of the file, `budget` bytes, or `more` (given the fold and the
    /// bytes read so far) returns false; a last line
    /// with no newline counts too, as upstream counts it, unless the read stopped early. Each read and its lines run in
    /// their own autorelease pool. Returns the lines folded.
    @discardableResult
    private func foldLines(_ handle: FileHandle, from offset: Int, skippingFirstLine: Bool, budget: Int,
                           keepsTrailingLine: Bool = true, into fold: inout ClaudeTranscriptFold,
                           diagnostics: inout ClaudeTranscriptScanDiagnostics,
                           more: (ClaudeTranscriptFold, Int) -> Bool) -> Int {
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return 0 }
        var splitter = RolloutLineSplitter(maxLineLength: limits.maxLineLength, skippingFirstLine: skippingFirstLine)
        var read = 0
        var lines = 0
        var reachedEnd = false
        while read < budget {
            let goOn = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: min(Self.chunkSize, budget - read)), !chunk.isEmpty else {
                    reachedEnd = true
                    return false
                }
                read += chunk.count
                splitter.feed(chunk) { line in
                    fold.apply(line)
                    lines += 1
                }
                return more(fold, read)
            }
            guard goOn else { break }
        }
        diagnostics.bytesRead += read
        diagnostics.skippedLineCount += splitter.skippedLineCount
        if keepsTrailingLine, reachedEnd, !splitter.pending.isEmpty {
            fold.apply(String(decoding: splitter.pending, as: UTF8.self))
            lines += 1
        }
        return lines
    }
}

/// One Claude transcript folded line by line, as upstream's `ClaudeTranscriptDiscovery.parseSession` folds it, with one
/// timestamp formatter for the whole fold and each text clipped before it is collapsed (P84). It leaves upstream's fold
/// on purpose for machine text (P155): a user line the owner did not write never becomes a prompt, Claude Code's own
/// synthetic replies never become the last message, and the title lines (a `summary` among them) never become either:
/// they go to `titles`, the chat title's fold, which never reaches the session (P200).
struct ClaudeTranscriptFold {
    var sessionID: String
    var cwd: String?
    var entrypoint: String?
    var updatedAt: Date
    var initialUserPrompt: String?
    var lastUserPrompt: String?
    var lastAssistantMessage: String?
    /// How many lines took a prompt and a reply so far: a prompt sent again, or a reply that says the same words, is a
    /// new one all the same (the peek's turn, P311).
    private(set) var prompts = 0
    private(set) var replies = 0
    var model: String?
    /// The reasoning effort the latest reply ran at (the assistant line's own `effort`, P443).
    var effort: String?
    var currentTool: String?
    var currentToolInputPreview: String?
    /// The session this one was forked from (`/branch`, a rewind run as a fork): the `forkedFrom.sessionId` its copied lines
    /// carry (P442).
    var forkedFrom: String?
    /// Claude Code's own recap of the session (`system` `away_summary`, written while the owner is away, P446), only while
    /// no prompt or reply has come after it; collapsed and cut at `recapLimit`.
    var recap: String?
    /// The title lines (`ClaudeTitleFold`), kept beside the session, never in it.
    var titles = ClaudeTitleFold()
    private var pendingToolUses: [String: (name: String, preview: String?)] = [:]
    private var formatter: ISO8601DateFormatter?

    init(sessionID: String, updatedAt: Date) {
        self.sessionID = sessionID
        self.updatedAt = updatedAt
    }

    mutating func forgetPendingTools() {
        pendingToolUses = [:]
        currentTool = nil
        currentToolInputPreview = nil
    }

    mutating func apply(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        titles.apply(object: object)

        // A fork's copied lines name the session they were copied from; the fork's own id is its file's and its own lines'.
        let copied = (object["forkedFrom"] as? [String: Any])?["sessionId"] as? String
        if forkedFrom == nil, let copied, !copied.isEmpty { forkedFrom = copied }
        if copied == nil, let value = object["sessionId"] as? String, !value.isEmpty {
            sessionID = value
        }
        if object["type"] as? String == "system", object["subtype"] as? String == Self.recapSubtype {
            recap = (object["content"] as? String).flatMap(Self.recapText)
            return
        }
        if let value = object["cwd"] as? String, !value.isEmpty {
            cwd = HexEscapedUTF8.decodeIfNeeded(value)
        }
        if entrypoint == nil, let value = object["entrypoint"] as? String, !value.isEmpty {
            entrypoint = value
        }
        if let timestampText = object["timestamp"] as? String, let timestamp = parse(timestampText) {
            updatedAt = timestamp
        }

        let message = object["message"] as? [String: Any]
        let role = message?["role"] as? String

        if role == "user" {
            // Machine text written as a user line is never the owner's prompt (P155): meta lines (skill bodies,
            // caveats), compaction summaries, background-task notifications and tool results.
            if !Self.isMachineUserLine(object, content: message?["content"]),
               let prompt = Self.promptText(from: message?["content"]) {
                if initialUserPrompt == nil {
                    initialUserPrompt = prompt
                }
                lastUserPrompt = prompt
                prompts += 1
                recap = nil
            }
            if let toolResultIDs = Self.toolResultIDs(from: message?["content"]) {
                for toolResultID in toolResultIDs {
                    pendingToolUses.removeValue(forKey: toolResultID)
                }
                if pendingToolUses.isEmpty {
                    currentTool = nil
                    currentToolInputPreview = nil
                } else if let lastPending = pendingToolUses.values.first {
                    currentTool = lastPending.name
                    currentToolInputPreview = lastPending.preview
                }
            }
        } else if role == "assistant", !Self.isSyntheticAssistantLine(object, message: message) {
            if let assistantText = Self.assistantText(from: message?["content"]) {
                lastAssistantMessage = assistantText
                replies += 1
                recap = nil
            }
            // A subagent's line written into its parent's transcript (`isSidechain`, older Claude Code) runs on the
            // subagent's own model and effort, never the session's (P444).
            if object["isSidechain"] as? Bool != true {
                if let value = message?["model"] as? String, !value.isEmpty {
                    model = value
                }
                if let value = (object["effort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                   value.count <= Self.effortLimit {
                    effort = value
                }
            }
            if let toolUses = Self.toolUses(from: message?["content"]) {
                for toolUse in toolUses {
                    pendingToolUses[toolUse.id] = (name: toolUse.name, preview: toolUse.preview)
                }
                if let lastToolUse = toolUses.last {
                    currentTool = lastToolUse.name
                    currentToolInputPreview = lastToolUse.preview
                }
            }
        }
        // A `summary` line is the conversation's title, not Claude's last message: only `titles` keeps it (P155).
    }

    /// A user line that holds no prompt of the owner's: `isMeta`, `isCompactSummary`, a background task's
    /// notification (`origin.kind`), or one carrying a tool result (whose text beside it is an interrupt marker).
    static func isMachineUserLine(_ object: [String: Any], content: Any?) -> Bool {
        if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return true }
        if let origin = object["origin"] as? [String: Any], origin["kind"] as? String == "task-notification" { return true }
        if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return true }
        return false
    }

    /// Claude Code's own assistant lines: "No response requested.", an API error or a usage-limit text
    /// (`model: "<synthetic>"`, `isApiErrorMessage`). The Done row keeps the last real reply; a failed turn is the
    /// StopFailure path's.
    static func isSyntheticAssistantLine(_ object: [String: Any], message: [String: Any]?) -> Bool {
        object["isApiErrorMessage"] as? Bool == true || message?["model"] as? String == "<synthetic>"
    }

    /// Upstream's session, or nil when no line named a working folder.
    func session(transcriptPath: String) -> AgentSession? {
        guard let cwd else { return nil }
        let workspaceName = WorkspaceNameResolver.workspaceName(for: cwd)
        let metadata = ClaudeSessionMetadata(
            transcriptPath: transcriptPath,
            initialUserPrompt: initialUserPrompt,
            lastUserPrompt: lastUserPrompt,
            lastAssistantMessage: lastAssistantMessage,
            currentTool: currentTool,
            currentToolInputPreview: currentToolInputPreview,
            model: model)
        return AgentSession(
            id: sessionID,
            title: "Claude · \(workspaceName)",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .stale,
            phase: .completed,
            summary: lastAssistantMessage ?? lastUserPrompt ?? "Recovered Claude session in \(workspaceName).",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                // Every Claude Desktop surface, Code (`claude-desktop`, `claude-desktop-3p`) and Cowork (`local-agent`),
                // lives while Claude.app runs and opens there (upstream tags `claude-desktop` only, P485).
                terminalApp: AttentionPolicy.claudePlace(entrypoint ?? "") == .claudeApp ? "Claude.app" : "Unknown",
                workspaceName: workspaceName,
                paneTitle: "Claude \(sessionID.prefix(8))",
                workingDirectory: cwd),
            claudeMetadata: metadata.isEmpty ? nil : metadata)
    }

    /// Upstream parses each line's time with a new `ISO8601DateFormatter` of the default options, which refuse
    /// fractional seconds, so a time as Claude writes it (`2026-09-24T10:00:00.123Z`) never parses and the session
    /// keeps its file's date. The same formatter, made once, gives the same dates, and a time in exactly that shape is
    /// refused without it (`ClaudeTranscriptScannerTests.aTimeWithFractionalSecondsNeverParses` checks the formatter
    /// still refuses every such time).
    private mutating func parse(_ text: String) -> Date? {
        if Self.hasFractionalSeconds(text) { return nil }
        if formatter == nil { formatter = ISO8601DateFormatter() }
        return formatter?.date(from: text)
    }

    /// `YYYY-MM-DDTHH:MM:SS.` then one or more digits, then `Z` or `±HH:MM`, and nothing else.
    static func hasFractionalSeconds(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func digits(_ range: Range<Int>) -> Bool { range.allSatisfy { bytes[$0] >= 0x30 && bytes[$0] <= 0x39 } }
        func byte(_ index: Int, _ character: Character) -> Bool { bytes[index] == character.asciiValue }
        guard bytes.count >= 22, digits(0..<4), byte(4, "-"), digits(5..<7), byte(7, "-"), digits(8..<10), byte(10, "T"),
              digits(11..<13), byte(13, ":"), digits(14..<16), byte(16, ":"), digits(17..<19), byte(19, ".") else { return false }
        var index = 20
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        guard index > 20, index < bytes.count else { return false }
        if byte(index, "Z") { return index == bytes.count - 1 }
        guard byte(index, "+") || byte(index, "-"), bytes.count - index == 6 else { return false }
        return digits((index + 1)..<(index + 3)) && byte(index + 3, ":") && digits((index + 4)..<(index + 6))
    }

    /// The owner's words (`PromptText.human`), from the text or its first text block that holds some.
    private static func promptText(from content: Any?) -> String? {
        if let text = content as? String {
            return PromptText.human(text).flatMap(normalizedText)
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            if block["type"] as? String == "text", let text = block["text"] as? String,
               let normalized = PromptText.human(text).flatMap(normalizedText) {
                return normalized
            }
        }
        return nil
    }

    private static func assistantText(from content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            if block["type"] as? String == "text", let text = block["text"] as? String, let normalized = normalizedText(text) {
                return normalized
            }
        }
        return nil
    }

    private static func toolResultIDs(from content: Any?) -> [String]? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let ids = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "tool_result" else { return nil }
            return block["tool_use_id"] as? String
        }
        return ids.isEmpty ? nil : ids
    }

    private static func toolUses(from content: Any?) -> [(id: String, name: String, preview: String?)]? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let uses = blocks.compactMap { block -> (id: String, name: String, preview: String?)? in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String,
                  let id = block["id"] as? String else { return nil }
            return (id: id, name: name, preview: block["input"].flatMap(previewText(for:)))
        }
        return uses.isEmpty ? nil : uses
    }

    private static func previewText(for value: Any) -> String? {
        if let text = value as? String {
            return normalizedText(text)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return normalizedText(text)
    }

    /// Upstream's text rule: newlines and tabs become spaces, runs of spaces one, and past 140 characters the first
    /// 139 and an ellipsis. Only those survive, so a long text is collapsed from its first `clipScalars` scalars when
    /// that already gives well over 140 characters; upstream collapsed the whole text, a tool's input of several
    /// megabytes included.
    static func normalizedText(_ value: String) -> String? {
        if value.utf8.count > clipScalars {
            let clipped = collapsed(String(value.unicodeScalars.prefix(clipScalars)))
            if clipped.count >= clipCharacters {
                return "\(clipped.prefix(139))…"
            }
        }
        let collapsed = collapsed(value)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > 140 else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 139)
        return "\(collapsed[..<endIndex])…"
    }

    static let recapSubtype = "away_summary"
    /// Claude Code caps a recap at 400 characters (its changelog); a longer one is cut here too.
    static let recapLimit = 400
    static let effortLimit = 16

    /// A recap as the peek shows it: whitespace collapsed, at most `recapLimit` characters, from its first
    /// `clipScalars` scalars.
    static func recapText(_ value: String) -> String? {
        let text = collapsed(String(value.unicodeScalars.prefix(clipScalars)))
        guard !text.isEmpty else { return nil }
        return text.count > recapLimit ? "\(text.prefix(recapLimit - 1))…" : text
    }

    /// Well past the 139 characters kept, so the cut never touches them.
    static let clipScalars = 2_048
    static let clipCharacters = 160

    private static func collapsed(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
