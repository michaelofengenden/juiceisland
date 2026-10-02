import AppKit
import IslandEngine

/// A row's peek (P311): what the pointer resting on a row shows under it in the island, and only what the row does not
/// already say: the owner's last prompt, the agent's latest reply (or, for a finished Claude session, Claude Code's own
/// recap in their place, P446), the tool it waits on, and, for a Clean row, the branch, model, effort, mode and progress
/// Detailed rows show (`RowFacts`, P434). Built from the engine's state and, for a Claude session, a bounded read of its
/// transcript's tail (`SessionEngine.readPeek`); machine text is never a prompt or a reply (`PromptText`). Memory only,
/// while it shows: never logged or stored.
struct SessionPeek: Equatable, Sendable {
    struct Tool: Equatable, Sendable {
        var verb: String
        var text: String?
    }

    var sessionID: String
    /// The owner's last prompt, when the row says neither it (Clean's running line, Detailed's "You:") nor it as its
    /// title (P203).
    var prompt: String?
    /// The agent's latest reply, as plain text: the current turn's, or the finished turn's whole message, whose first
    /// words are all a row has room for.
    var reply: String?
    /// The tool the transcript says waits on its result, when the row's line names no tool.
    var tool: Tool?
    /// The model, mode and progress: Detailed rows say these themselves, so only a Clean row's peek does.
    var facts: RowFacts
    /// The branch, when it is not the repo's default (P434): as the facts, only a Clean row's peek says it.
    var branch: String? = nil
    /// Claude Code's own recap of a finished session (`away_summary`, written while the owner was away, P446): where it
    /// stands and what comes next, in place of the prompt and the reply it sums up.
    var recap: String?
    /// The reply is the one a finished row's own line begins: the peek takes it up where the line stops (`rest`), so it
    /// never says the line's words again ("every fact once").
    var replyContinuesLine = false
    /// Codex's reasoning summary while its turn runs (P720): what it is thinking now, after its latest message.
    var thinking: SessionWork.Thinking? = nil
    /// The agent's checklist while a step is still to do (P721): Claude's tasks or todos, Codex's plan, each step done,
    /// current or pending. The peek says it in place of the "2/5" the row says.
    var steps: [SessionWork.Step] = []
    /// The transcript's `TodoWrite` list as the peek's read found it: the checklist when the agent's live work has none.
    var readSteps: [SessionWork.Step]? = nil
    /// The row's own progress ("2/5", Clean only), said again only while no checklist shows.
    var rowProgress: String? = nil

    /// Lines of a reply the peek shows, at most.
    static let replyLines = 3
    /// A reply this short fits the row's own line whole: the peek does not say it again.
    static let rowRoom = 56

    /// Points kept in hand when finding where the row's line stops: a cut judged a little early repeats a word at most,
    /// never drops one.
    static let restMargin: CGFloat = 4

    /// What of `reply` a line `lineWidth` wide, in the system font at `fontSize` with a tail "…", does not show: from the
    /// start of the word the line cuts, after an ellipsis; nil when the line shows it whole.
    static func rest(of reply: String, lineWidth: CGFloat, fontSize: CGFloat) -> String? {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
        func width(_ text: Substring) -> CGFloat { NSAttributedString(string: String(text), attributes: attributes).size().width }
        guard width(reply[...]) > lineWidth else { return nil }
        let room = lineWidth - width("…") - restMargin
        // The longest prefix the line has room for: widths grow with the prefix, so a binary search finds it.
        var low = 0, high = reply.count
        while low < high {
            let middle = (low + high + 1) / 2
            if width(reply.prefix(middle)) <= room { low = middle } else { high = middle - 1 }
        }
        var start = reply.index(reply.startIndex, offsetBy: low)
        while start > reply.startIndex, !reply[reply.index(before: start)].isWhitespace { start = reply.index(before: start) }
        let rest = reply[start...].drop { $0.isWhitespace }
        return rest.isEmpty ? nil : "…" + rest
    }

    /// Nothing but its reply: with the reply shown whole on the row's line, there is nothing left to peek at.
    var saysOnlyItsReply: Bool {
        prompt == nil && tool == nil && recap == nil && facts.isEmpty && branch == nil && thinking == nil && steps.isEmpty
    }

    var isEmpty: Bool { reply == nil && saysOnlyItsReply }

    /// Lines of a checklist the peek shows, at most, the lines that say how many it leaves out included.
    static let stepLines = 6

    /// The live part as `work` says it now (`IslandPeeker` follows it while the peek shows): the thought only while the
    /// row runs; the agent's own checklist, else the transcript's todos, only while a step is still to do; and the row's
    /// progress back among the facts once no checklist shows.
    mutating func take(work: SessionWork?, running: Bool) {
        thinking = running ? work?.thinking : nil
        let live = work?.steps ?? []
        let list = live.isEmpty ? readSteps ?? [] : live
        steps = SessionWork(steps: list).hasOpenSteps ? list : []
        facts.progress = steps.isEmpty ? rowProgress : nil
    }

    /// The checklist as the peek lays it out in at most `limit` lines: every step when they fit; else a window around the
    /// current step (the first not done), one before it, with a line for the steps above it (`above`, `aboveLine`) and
    /// one for those below (`below`), each only when it hides something.
    static func window(_ steps: [SessionWork.Step], limit: Int = stepLines) -> (above: Int, shown: ArraySlice<SessionWork.Step>, below: Int) {
        guard steps.count > limit, limit >= 3 else { return (0, steps[...], 0) }
        let focus = steps.firstIndex { $0.state == .current } ?? steps.firstIndex { $0.state != .done } ?? steps.count - 1
        // From one before the focus: a window that reaches the end with no line below shows the last steps under one
        // line above; any other keeps a line each side it hides something on.
        var start = max(0, focus - 1)
        let above = start > 0 ? 1 : 0
        let room: Int
        if start + limit - above >= steps.count {
            room = limit - 1
            start = steps.count - room
        } else {
            room = limit - above - 1
        }
        let end = min(steps.count, start + room)
        return (start, steps[start..<end], steps.count - end)
    }

    /// The line for the `above` steps the window hides: "3 done" when every one is, else "3 earlier" (a skipped plan
    /// step, or a task parallel work left behind, P722).
    static func aboveLine(_ steps: [SessionWork.Step], above: Int) -> String {
        steps.prefix(above).allSatisfy { $0.state == .done } ? "\(above) done" : "\(above) earlier"
    }

    /// Lines of a recap the peek shows, at most (Claude Code caps one at 400 characters).
    static let recapLines = 4

    /// The peek for `row` as the island draws it (`clean`: its Clean style, else Detailed). `prompt` and `reply` are what
    /// the session's metadata last said (the finished turn's message, or a running Codex turn's latest one, which its
    /// rollout keeps current); `read` is the transcript tail's, which wins for a Claude turn still running, whose metadata
    /// has only the turn before's reply. `replyIsCurrent`: the metadata's reply is this turn's. Nil when it would say
    /// nothing the row does not.
    @MainActor static func make(row: SessionRow, clean: Bool, prompt: String?, reply: String?, replyIsCurrent: Bool,
                     read: SessionPeekRead?, work: SessionWork? = nil) -> SessionPeek? {
        let lastPrompt = (read?.prompt).flatMap(PromptText.human).map(EngineSessionsModel.oneLine) ?? prompt
        var shownPrompt: String?
        if let lastPrompt, !lastPrompt.isEmpty, !PromptText.isJSON(lastPrompt) {
            let titled = row.titleSource == .prompt && ChatTitleText.clean(lastPrompt) == row.task
            let onLine = clean ? IslandRowText.status(row).text == lastPrompt : DetailedRowText.status(row).prompt == lastPrompt
            if !titled, !onLine { shownPrompt = lastPrompt }
        }
        let current = row.bucket == .done ? reply : read != nil ? read?.reply : replyIsCurrent ? reply : nil
        var shownReply: String?
        var continuesLine = false
        if let current, !PromptText.isJSON(current) {
            let plain = MessageMarkup.plain(current)
            // The row's own line already says a short one whole; a longer one it begins, the peek takes up.
            let onLine = row.detail == plain && plain.count <= rowRoom
            if !plain.isEmpty, !onLine { shownReply = plain }
            continuesLine = row.detail == plain
        }
        var tool: Tool?
        if row.bucket == .running, let name = read?.tool, !name.isEmpty {
            // Both styles name a running tool on the row itself.
            if case .tool = row.status {} else { tool = Tool(verb: name, text: read?.toolDetail) }
        }
        // A finished Claude session Claude Code recapped while the owner was away (and nothing since): the recap says where
        // it stands, the prompt and the reply it sums up go (every fact once, least text).
        var recap: String?
        if row.bucket == .done, let text = read?.recap, !text.isEmpty {
            recap = text
            shownPrompt = nil
            shownReply = nil
        }
        var peek = SessionPeek(sessionID: row.id, prompt: shownPrompt, reply: shownReply, tool: tool, facts: clean ? row.facts : RowFacts(),
                               branch: clean ? row.branch : nil, recap: recap, replyContinuesLine: continuesLine && shownReply != nil,
                               readSteps: read?.todos, rowProgress: clean ? row.facts.progress : nil)
        peek.take(work: work, running: row.bucket == .running)
        return peek.isEmpty ? nil : peek
    }
}
