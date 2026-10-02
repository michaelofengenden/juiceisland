import Foundation
import OpenIslandCore

/// A waiting approval's tool call, to find in its session's transcript.
public struct ToolCallQuery: Equatable, Sendable {
    /// The session's transcript (Claude's `transcript_path`); nil reads nothing.
    public var transcriptPath: String?
    /// The call's id (`toolu_…`); nil when the bridge could not tell it (no PreToolUse hook saw the call).
    public var toolUseID: String?
    public var toolName: String?
    /// What upstream's request shows of the call's input (its `affectedPath`).
    public var preview: String

    public init(transcriptPath: String?, toolUseID: String?, toolName: String?, preview: String) {
        self.transcriptPath = transcriptPath
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.preview = preview
    }
}

/// Finds a waiting tool call's input in its Claude transcript (spec §4.2's plan read, for every approval): upstream's
/// permission request carries the fixed sentence "Claude wants to run Bash." and at most 110 characters of the input,
/// newlines collapsed, and Core is never edited. The call is the `tool_use` whose id is the request's `toolUseID`;
/// with no id, the newest call of the request's tool that has no result yet and whose input upstream would show as the
/// request does. Reads the transcript's last 256 KB, and its last 4 MB once when the call is not in it and a long line
/// begins before it (a Write of a large file, whose id is at the line's start). Only a `.jsonl` file under a `projects` folder is opened, read-only; the input is
/// returned to the engine and never logged or kept anywhere else (P83, P84).
enum ToolCallReader {
    static let window = 256 * 1024
    static let widenedWindow = 4 * 1024 * 1024
    /// With no id, at most this many lines are decoded looking for the call.
    static let candidateLimit = 64
    /// A line cut by the window's start that is this long may be the call: the wider window is read.
    static let longLine = 16 * 1024

    static func read(_ query: ToolCallQuery) -> ClaudeHookJSONValue? {
        guard let path = query.transcriptPath, isTranscript(path) else { return nil }
        return autoreleasepool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
            var windowSize = window
            while true {
                // One byte before the window, so a window that starts on a line's first byte reads that line.
                let start = size > UInt64(windowSize) ? size - UInt64(windowSize) - 1 : 0
                guard (try? handle.seek(toOffset: start)) != nil,
                      let data = try? handle.read(upToCount: Int(size - start)) else { return nil }
                let found = find(query, in: data, cut: start > 0)
                if let input = found.input { return input }
                // A long line begins before the window, perhaps the call's: read the wider window once.
                guard found.longLineCut, windowSize < widenedWindow else { return nil }
                windowSize = widenedWindow
            }
        }
    }

    /// An absolute `.jsonl` path under a `projects` folder, no `..`, that is a regular file (not a link).
    static func isTranscript(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return false }
        let components = path.split(separator: "/")
        guard !components.contains(".."), components.dropLast().contains("projects") else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG
    }

    /// The call's input among `data`'s lines, newest first. `cut`: the data begins inside a line, which is not read;
    /// `longLineCut` says that line's part in the data is long (`longLine`).
    static func find(_ query: ToolCallQuery, in data: Data, cut: Bool) -> (input: ClaudeHookJSONValue?, longLineCut: Bool) {
        var body = data[...]
        var longLineCut = false
        if cut {
            let end = data.firstIndex(of: 0x0A) ?? data.endIndex
            longLineCut = data.distance(from: data.startIndex, to: end) >= longLine
            body = end == data.endIndex ? data[end...] : data[data.index(after: end)...]
        }
        let complete = lineRanges(body)
        if let id = query.toolUseID, !id.isEmpty {
            let needle = Data(id.utf8)
            for range in complete.reversed() where data[range].range(of: needle) != nil {
                if let input = toolUse(in: data[range], where: { block in block.string("id") == id }) { return (input, false) }
            }
            return (nil, longLineCut)
        }
        guard let name = query.toolName, !name.isEmpty else { return (nil, longLineCut) }
        let needle = Data("\"tool_use\"".utf8)
        var decoded = 0
        for (index, range) in complete.enumerated().reversed() where data[range].range(of: needle) != nil {
            guard decoded < candidateLimit else { break }
            decoded += 1
            let later = complete.dropFirst(index + 1)
            let input = toolUse(in: data[range]) { block in
                guard block.string("name") == name, let id = block.string("id"),
                      let input = block["input"], ToolCallPreview.affectedPath(of: input) == query.preview else { return false }
                // An earlier call with the same preview has its result below it; the waiting one has none.
                let result = Data("\"tool_use_id\":\"\(id)\"".utf8)
                return !later.contains { data[$0].range(of: result) != nil }
            }
            if let input { return (input, false) }
        }
        return (nil, longLineCut)
    }

    /// The input of the last `tool_use` block in the line's `message.content` that `matches`.
    private static func toolUse(in line: Data, where matches: ([String: ClaudeHookJSONValue]) -> Bool) -> ClaudeHookJSONValue? {
        guard let root = try? JSONDecoder().decode(ClaudeHookJSONValue.self, from: line),
              case let .object(message)? = root["message"], case let .array(blocks)? = message["content"] else { return nil }
        for case let .object(block) in blocks.reversed() where block.string("type") == "tool_use" && matches(block) {
            return block["input"]
        }
        return nil
    }

    /// Every line's byte range, newlines left out, empty lines dropped.
    private static func lineRanges(_ data: Data.SubSequence) -> [Range<Data.Index>] {
        var ranges: [Range<Data.Index>] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start { ranges.append(start..<end) }
            start = end == data.endIndex ? end : data.index(after: end)
        }
        return ranges
    }
}

/// What upstream's Claude hook shows of a tool call's input as the request's `affectedPath`
/// (`ClaudeHookPayload.permissionAffectedPath`, without its last fallback, the working folder): the first path field,
/// else the first of its preview fields, else the whole input written out, whitespace collapsed and clipped to 110
/// characters. Kept equal to upstream's by `ToolCallReaderTests`; the fixtures shape their requests with it.
public enum ToolCallPreview {
    static let pathKeys = ["file_path", "path", "notebook_path", "target_file", "working_directory"]
    static let previewKeys = ["command", "file_path", "pattern", "query", "prompt", "description", "skill", "url"]
    static let limit = 110

    public static func affectedPath(of input: ClaudeHookJSONValue) -> String? {
        if case let .object(object) = input {
            for key in pathKeys { if let value = object.string(key), !value.isEmpty { return value } }
            for key in previewKeys { if let value = object.string(key), !value.isEmpty { return clipped(value) } }
        }
        return clipped(written(input))
    }

    /// Whitespace collapsed and at most 110 characters, the last "…" (upstream's `clipped`, Claude's and Codex's).
    public static func clipped(_ value: String) -> String? {
        let collapsed = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return "\(collapsed.prefix(limit - 1))…"
    }

    static func written(_ value: ClaudeHookJSONValue) -> String {
        switch value {
        case let .string(text): text
        case let .number(number): String(number)
        case let .boolean(flag): flag ? "true" : "false"
        case .null: "null"
        case let .array(items): "[\(items.map(written).joined(separator: ", "))]"
        case let .object(object): "{\(object.keys.sorted().map { "\($0): \(object[$0].map(written) ?? "null")" }.joined(separator: ", "))}"
        }
    }
}

extension ClaudeHookJSONValue {
    subscript(key: String) -> ClaudeHookJSONValue? {
        if case let .object(object) = self { object[key] } else { nil }
    }
}

extension Dictionary where Key == String, Value == ClaudeHookJSONValue {
    func string(_ key: String) -> String? {
        if case let .string(value)? = self[key] { value } else { nil }
    }
}
