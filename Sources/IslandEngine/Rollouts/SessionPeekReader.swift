import Foundation

/// What a session peek shows of a Claude transcript's tail (P311): the owner's last prompt, the agent's latest text after
/// it, the tool it waits on, the model and effort its latest reply named, and Claude Code's recap of the session (P446). Every text as `ClaudeTranscriptFold` keeps it: the
/// owner's words only (`PromptText.human`: no meta line, task notification or tool result), never Claude Code's own
/// synthetic replies, whitespace collapsed and clipped to 140 characters (P84, P155). For the peek's view only: never
/// logged, persisted or kept once the peek goes.
public struct SessionPeekRead: Equatable, Sendable {
    public var prompt: String?
    /// The agent's latest text after `prompt`; nil when it has said nothing since (a turn that only just began).
    public var reply: String?
    /// The tool call still waiting on its result, and what upstream's fold shows of its input.
    public var tool: String?
    public var toolDetail: String?
    public var model: String?
    /// The reasoning effort the latest reply ran at (P443).
    public var effort: String?
    /// Claude Code's own recap of the session (`away_summary`), when nothing was prompted or replied after it (P446).
    public var recap: String?
    /// The latest `TodoWrite` list in the tail, bounded (`SessionWork.steps`, P721); nil when the tail holds none.
    public var todos: [SessionWork.Step]?

    public init(prompt: String? = nil, reply: String? = nil, tool: String? = nil, toolDetail: String? = nil, model: String? = nil,
                effort: String? = nil, recap: String? = nil, todos: [SessionWork.Step]? = nil) {
        self.prompt = prompt
        self.reply = reply
        self.tool = tool
        self.toolDetail = toolDetail
        self.model = model
        self.effort = effort
        self.recap = recap
        self.todos = todos
    }
}

/// Reads a Claude transcript's last `window` bytes (and one byte before, so a window that starts on a line's first byte
/// reads that line), off the main thread, as `ClaudeTitleReader` and `ToolCallReader` read theirs: only a `.jsonl` file
/// under a `projects` folder that is a regular file, read-only, one bounded read per peek (P311). The lines are folded
/// with the launch scan's own fold (`ClaudeTranscriptFold`), so what counts as a prompt or a reply is the same.
enum SessionPeekReader {
    static let window = 128 * 1024

    struct Read: Equatable, Sendable {
        var peek: SessionPeekRead
        var bytes: Int
    }

    static func read(path: String) -> Read? {
        guard ToolCallReader.isTranscript(path) else { return nil }
        return autoreleasepool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(), size > 0 else { return Read(peek: SessionPeekRead(), bytes: 0) }
            let start = size > UInt64(window) ? size - UInt64(window) - 1 : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start)) else { return nil }
            return Read(peek: fold(data, cut: start > 0), bytes: data.count)
        }
    }

    /// The peek among `data`'s complete lines, in order; `cut`: the data begins inside a line, which is skipped. A reply
    /// counts only after the last prompt: a turn that has said nothing yet shows no earlier turn's reply as its own, even
    /// when its prompt says what the turn before's did ("continue"), so a line is judged by whether it took a prompt or a
    /// reply, never by whether the text changed.
    static func fold(_ data: Data, cut: Bool) -> SessionPeekRead {
        var fold = ClaudeTranscriptFold(sessionID: "", updatedAt: .distantPast)
        var peek = SessionPeekRead()
        var start = data.startIndex
        if cut {
            guard let newline = data.firstIndex(of: 0x0A) else { return peek }
            start = data.index(after: newline)
        }
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start {
                let prompts = fold.prompts, replies = fold.replies
                fold.apply(String(decoding: data[start..<end], as: UTF8.self))
                if fold.prompts != prompts {
                    peek.prompt = fold.lastUserPrompt
                    peek.reply = nil
                }
                if fold.replies != replies { peek.reply = fold.lastAssistantMessage }
                if let todos = todoWrite(data[start..<end]) { peek.todos = todos }
            }
            start = end == data.endIndex ? end : data.index(after: end)
        }
        peek.tool = fold.currentTool
        peek.toolDetail = fold.currentToolInputPreview
        peek.model = fold.model
        peek.effort = fold.effort
        peek.recap = fold.recap
        return peek
    }

    /// An assistant line's `TodoWrite` call: its `todos` as steps (the last such call in the line), bounded; nil for any
    /// other line. Only a line that names the tool is parsed.
    static func todoWrite(_ line: Data) -> [SessionWork.Step]? {
        guard line.range(of: Data(#""TodoWrite""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["type"] as? String == "assistant",
              let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return nil }
        let calls = content.filter { $0["type"] as? String == "tool_use" && $0["name"] as? String == "TodoWrite" }
        return calls.last.flatMap { SessionWork.steps(todoWrite: $0["input"] as? [String: Any]) }
    }
}
