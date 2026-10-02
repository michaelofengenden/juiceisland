import Foundation

/// Claude Code's title lines in a session transcript, as the CLI writes them (2.1.x: `saveAgentName`,
/// `saveCustomTitle`, `saveAiGeneratedTitle`; the legacy `summary`):
///
///     {"type":"agent-name","agentName":"auth-refactor","sessionId":"…"}      every rename, a plan accepted
///     {"type":"custom-title","customTitle":"auth-refactor","sessionId":"…"}  /rename, -n, the picker, a desktop rename
///     {"type":"ai-title","aiTitle":"Fix login redirect loop","sessionId":"…"} generated from the first prompt
///     {"type":"summary","summary":"…","leafUuid":"…"}                         older versions
///
/// Each kind is last-wins and an empty value clears it (Claude sets `value || undefined`). The title is Claude's own
/// listing order, `agentName || customTitle || aiTitle || summary`, so the island says what Claude's session picker
/// says. The desktop app and the IDE rename through the same lines in the same file, so nothing of theirs is read.
public struct ClaudeTitleFold: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case agentName = "agent-name", customTitle = "custom-title", aiTitle = "ai-title", summary

        /// The line's field that holds the text.
        var field: String {
            switch self {
            case .agentName: "agentName"
            case .customTitle: "customTitle"
            case .aiTitle: "aiTitle"
            case .summary: "summary"
            }
        }

        /// What a line of this kind contains, found before any JSON is decoded (the CLI writes `"type"` first, with no
        /// spaces, and its own readers look for it the same way).
        var needle: Data { Data("\"type\":\"\(rawValue)\"".utf8) }
    }

    /// The last value of each kind seen; a kind seen with an empty value is held as nil.
    private(set) var values: [Kind: String?] = [:]

    public init() {}

    /// Nothing seen.
    public var isEmpty: Bool { values.isEmpty }

    /// The title, in Claude's order; nil when no kind holds text.
    public var title: String? {
        for kind in Kind.allCases {
            if case let .some(.some(text)) = values[kind], let clean = ChatTitleText.clean(text) { return clean }
        }
        return nil
    }

    /// A line of the transcript: kept when it is one of the four kinds with its text field, else ignored. Anything
    /// else that merely contains the words (a prompt quoting a title line) decodes as another type and is ignored.
    mutating func apply(_ line: Data) {
        guard Kind.allCases.contains(where: { line.range(of: $0.needle) != nil }),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        apply(object: object)
    }

    /// A line already decoded (the launch's fold decodes every line anyway).
    mutating func apply(object: [String: Any]) {
        guard let type = object["type"] as? String, let kind = Kind(rawValue: type),
              let text = object[kind.field] as? String else { return }
        values.updateValue(ChatTitleText.clean(text).map { _ in text }, forKey: kind)
    }

    mutating func apply(_ line: String) { apply(Data(line.utf8)) }

    /// A later window of the same transcript: every kind it saw replaces this one's, the others stay.
    public mutating func merge(_ later: ClaudeTitleFold) {
        for (kind, value) in later.values { values.updateValue(value, forKey: kind) }
    }

    /// An earlier read of the same transcript (the launch's, landing after a live read): only the kinds this one has
    /// not seen, a clear included, are taken from it (P211).
    public mutating func fill(from earlier: ClaudeTitleFold) {
        for (kind, value) in earlier.values where !values.keys.contains(kind) { values.updateValue(value, forKey: kind) }
    }
}

/// Reads a live Claude session's title lines from the end of its transcript (P201): the last 64 KB only, a line cut by
/// the window's start skipped (a title line is short: one longer than the window is not one), only lines that hold a
/// kind's `"type"` decoded. The same path rule as `ToolCallReader`: an absolute `.jsonl` under a `projects` folder, no
/// `..`, a regular file and not a link. What it finds goes to the engine's memory, never further (P200).
enum ClaudeTitleReader {
    static let window = 64 * 1024

    struct Read: Equatable, Sendable {
        var fold: ClaudeTitleFold
        var bytes: Int
    }

    static func read(path: String) -> Read? {
        guard ToolCallReader.isTranscript(path) else { return nil }
        return autoreleasepool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(), size > 0 else { return Read(fold: ClaudeTitleFold(), bytes: 0) }
            // One byte before the window, so a window that starts on a line's first byte reads that line.
            let start = size > UInt64(window) ? size - UInt64(window) - 1 : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start)) else { return nil }
            return Read(fold: fold(data, cut: start > 0), bytes: data.count)
        }
    }

    /// The title lines among `data`'s complete lines, in order; `cut`: the data begins inside a line, which is skipped.
    static func fold(_ data: Data, cut: Bool) -> ClaudeTitleFold {
        var fold = ClaudeTitleFold()
        var start = data.startIndex
        if cut {
            guard let newline = data.firstIndex(of: 0x0A) else { return fold }
            start = data.index(after: newline)
        }
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start { fold.apply(Data(data[start..<end])) }
            start = end == data.endIndex ? end : data.index(after: end)
        }
        return fold
    }
}
