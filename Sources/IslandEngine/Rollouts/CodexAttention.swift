import Foundation

/// What a Codex rollout says about waiting on the owner (P160, C5-C7, C15), folded beside `RolloutFolder` over the lines
/// the tracker already reads. Pure.
///
/// Codex has no hook for questions, and never writes its request events (`request_user_input`,
/// `exec_approval_request`, …) to the rollout (`rollout/src/policy.rs`). What it does write:
/// - a question tool's `function_call` before the tool runs: `request_user_input` (blocking, Plan mode) and
///   `request_user_input_async` (GPT-6 models, any mode; the tool returns `{"accepted":true}` at once and the model
///   goes on). The async one also appears as a legacy `agent_message` or a paginated `item_completed` `AgentMessage`
///   with `delivery: "async"` and `questions`, whose id is the call's;
/// - the owner's answer: the call's output (blocking), or a user message holding the reply envelope
///   `<send_user_message_question_reply>` whose `questionItemId` names the call (async), or its plain-text fallback;
/// - the thread's reviewer and approval policy (`turn_context`, and `thread_settings_applied` for a mid-thread change),
///   and a `request_permissions` grant with `strict_auto_review` that sends the rest of the turn to Guardian (C6);
/// - every call and its output, which close an approval the hook handed back to Codex (C7);
/// - the turn's model and reasoning effort (`turn_context`) and the latest plan (`update_plan`), for the row's facts (P310,
///   P443);
/// - why the latest turn stopped on a limit or an API error (P700): its end's `error` (`task_complete`'s `ErrorEvent`,
///   which Codex keeps in the rollout where it drops the `error` event itself, `rollout/src/policy.rs`), or a rate-limit
///   reading that says the limit was reached (`rate_limit_reached_type`).
struct CodexAttention: Equatable, Sendable {
    enum QuestionKind: String, Equatable, Sendable { case blocking, async }

    struct Item: Equatable, Sendable {
        var question: String
        var header: String?
        var options: [String]
    }

    struct Question: Equatable, Sendable {
        var callID: String
        var kind: QuestionKind
        var items: [Item]
        var at: Date?
        /// The items already answered: Codex sends one reply envelope per answered question of a call (P184).
        var answered: Set<Int> = []

        /// As many items answered as it has.
        var isAnswered: Bool { answered.count >= max(1, items.count) }
    }

    struct Call: Equatable, Sendable {
        var callID: String
        /// The tool's name; an MCP tool's is joined with its namespace as its hook names it (`callName`).
        var name: String
        /// Bounded by `commandLimit`: only ever compared with a request's command, bounded the same way.
        var command: String?
        var at: Date?
        /// When its output was read, for a call whose output came in the same read as the call: a call still running
        /// is matched before it (a failed first run, an earlier turn's call with the same command).
        var outputAt: Date?
    }

    enum Event: Equatable, Sendable {
        case questionOpened(Question)
        case questionClosed(callID: String, byReply: Bool)
        /// A call's output: whatever waited on that call is over.
        case output(callID: String)
        case callSeen(Call)
        /// `task_complete`, `turn_complete` or `turn_aborted`, with the line's `turn_id` and time: only the request's own
        /// turn end closes it, never an earlier one read late (§2.2).
        case turnEnded(turnID: String?, at: Date?)
        case turnStarted
        /// The reviewer, the approval policy or the turn's strict review changed, at the line's time: a request's filter
        /// reads them (C6), a request asked after it too.
        case settingsChanged(at: Date?)
        /// The model, the plan's progress or the turn's limit changed: nothing waits on it; the update carries the state to
        /// the row (P310, P700).
        case factsChanged
    }

    /// Bounds (P152's kind): a question's text, items, options and option text.
    static let questionLimit = 1_024
    static let itemLimit = 4
    static let optionLimit = 8
    static let optionTextLimit = 200
    /// Calls kept without an output, newest last.
    static let openCallLimit = 64
    /// A call's command is kept to this many Unicode scalars (at most 4 KB): a patch or a heredoc can be megabytes, and
    /// the command is only compared (P185).
    static let commandLimit = 1_024
    /// A model id longer than this is no model name: it is not kept.
    static let modelLimit = 64
    /// An effort longer than this is no effort word.
    static let effortLimit = 16
    /// Plan steps counted, at most (a plan is a handful of steps).
    static let planLimit = 200
    /// Code mode's tools (the Codex app's GPT-6 threads): a cell runs a script whose nested `tools.exec_command(…)` has no
    /// line of its own, so the cell is the call a `Bash` request waits on (P183).
    static let codeModeCells: Set<String> = ["exec", "js"]
    static let cellYield = "Script running with cell ID "
    /// Lines that can matter here; any other line is never parsed.
    static let markers = ["request_user_input", "function_call", "custom_tool_call", "local_shell_call", "turn_context",
                          "thread_settings_applied", "task_complete", "turn_complete", "turn_aborted", "task_started",
                          "turn_started", "\"role\":\"user\"", "user_message", "\"delivery\":\"async\"", "session_meta",
                          // Only a reading that says the limit was reached: every other `token_count` line is never parsed.
                          "\"rate_limit_reached_type\":\""]

    static let replyOpen = "<send_user_message_question_reply>"
    static let replyClose = "</send_user_message_question_reply>"

    /// `session_meta.source` is `exec`: no UI, so no question is ever opened (C15).
    private(set) var isExec = false
    private(set) var originator: String?
    /// Who started the thread, from its first `session_meta` (P212): a reviewer's, a helper's or a subagent's rollout is
    /// never a row of its own. nil until that line is read.
    private(set) var threadKind: CodexThreadKind?
    /// The thread's own id, from the same line: a session whose metadata names another thread's rollout (a subagent's,
    /// filed under its root, P167) is not that thread.
    private(set) var threadID: String?
    /// Who started the thread, from its first `session_meta` (`SessionScopeRules.codex`): a child, a scripted run or
    /// the owner's; nil before one is read. A fork's copied history never changes it.
    private(set) var scope: SessionScope?
    /// That line's originator.
    private(set) var scopeOriginator: String?
    /// The thread's latest reviewer (`user` or `auto_review`), from whichever came later of `turn_context` and
    /// `thread_settings_applied`.
    private(set) var reviewer: String?
    private(set) var approvalPolicy: String?
    /// The latest turn's model (`turn_context.model`), bounded by `modelLimit`.
    private(set) var model: String?
    /// The latest turn's reasoning effort (`turn_context.effort`, P443); nil when that turn set none.
    private(set) var effort: String?
    /// A `turn_context` was read: `effort` is what the latest turn says, nil included (P497).
    private(set) var readTurn = false
    /// The latest plan's progress (`update_plan`): steps completed of all its steps; nil before any plan.
    private(set) var plan: TaskProgress?
    /// This turn's commands go to Guardian (a `request_permissions` grant with `strict_auto_review`).
    private(set) var strictAutoReview = false
    /// Why the latest turn stopped, when that was a limit or an API error (P700); nil from the next turn's start or prompt.
    private(set) var limit: SessionLimit?
    private(set) var questions: [String: Question] = [:]
    private(set) var openCalls: [Call] = []
    /// Code-mode cells that yielded while still running, by cell id, and the `wait` calls on them, by call id.
    private(set) var yieldedCells: [String: String] = [:]
    private(set) var waits: [String: String] = [:]
    /// Events since the tracker last took them.
    private(set) var events: [Event] = []

    mutating func takeEvents() -> [Event] {
        defer { events = [] }
        return events
    }

    /// After a bootstrap: only what is still open is news.
    mutating func announceOpenQuestions() {
        events = questions.values.sorted { ($0.at ?? .distantPast, $0.callID) < ($1.at ?? .distantPast, $1.callID) }
            .map(Event.questionOpened)
    }

    static func mayMatter(_ line: String) -> Bool { markers.contains { line.contains($0) } }

    mutating func apply(_ line: String) {
        guard Self.mayMatter(line), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        let at = (object["timestamp"] as? String).flatMap(Self.date)
        switch object["type"] as? String {
        case "session_meta":
            isExec = Self.sourceName(payload["source"]) == "exec"
            originator = payload["originator"] as? String
            // The first one is the thread's own: a fork's copied history can hold another's.
            if threadKind == nil {
                threadKind = CodexThreadKind.of(payload: payload)
                threadID = payload["id"] as? String
            }
            if scope == nil {
                scope = SessionScopeRules.codex(source: Self.sourceName(payload["source"]),
                                                  threadSource: payload["thread_source"] as? String, originator: originator)
                scopeOriginator = originator
            }
        case "turn_context":
            readTurn = true
            takeSettings(payload, at: at)
            takeModel(payload["model"])
            takeEffort(payload["effort"])
        case "event_msg":
            applyEvent(payload, at: at)
        case "response_item":
            applyItem(payload, at: at)
        default:
            break
        }
    }

    private mutating func takeModel(_ raw: Any?) {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= Self.modelLimit, text != model else { return }
        model = text
        events.append(.factsChanged)
    }

    /// A turn's effort: a word (`low`, `xhigh`, a model's own), at most `effortLimit` characters; a turn with none has none.
    private mutating func takeEffort(_ raw: Any?) {
        let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = text.flatMap { !$0.isEmpty && $0.count <= Self.effortLimit ? $0 : nil }
        guard next != effort else { return }
        effort = next
        events.append(.factsChanged)
    }

    /// A new limit, or none (a new turn): the row hears of it with the read (P700).
    private mutating func takeLimit(_ next: SessionLimit?) {
        guard next != limit else { return }
        limit = next
        events.append(.factsChanged)
    }

    /// `update_plan`'s `{plan: [{step, status}]}`: how many steps are `completed` of how many there are.
    private mutating func takePlan(_ raw: Any?) {
        guard let steps = raw as? [[String: Any]] else { return }
        let counted = steps.prefix(Self.planLimit)
        let progress = TaskProgress(done: counted.count { $0["status"] as? String == "completed" }, total: counted.count)
        guard progress != plan else { return }
        plan = progress
        events.append(.factsChanged)
    }

    private mutating func takeSettings(_ settings: [String: Any], at: Date?) {
        let before = (reviewer, approvalPolicy)
        if let reviewer = settings["approvals_reviewer"] as? String {
            self.reviewer = reviewer == "guardian_subagent" ? "auto_review" : reviewer
        }
        if let policy = settings["approval_policy"] {
            approvalPolicy = (policy as? String) ?? "granular"
        }
        if before != (reviewer, approvalPolicy) { events.append(.settingsChanged(at: at)) }
    }

    private mutating func applyEvent(_ payload: [String: Any], at: Date?) {
        switch payload["type"] as? String {
        case "thread_settings_applied":
            if let settings = payload["thread_settings"] as? [String: Any] { takeSettings(settings, at: at) }
        case "task_started", "turn_started":
            strictAutoReview = false
            closeAllQuestions()
            takeLimit(nil)
            events.append(.turnStarted)
        case "token_count":
            if let reading = payload["rate_limits"] as? [String: Any], let reached = LimitText.codexReading(reading, at: at ?? Date()) {
                takeLimit(reached)
            }
        case "task_complete", "turn_complete", "turn_aborted":
            // The turn end's own error says why it stopped; a reading that said the limit was reached stands without one.
            if let error = payload["error"] as? [String: Any] {
                takeLimit(LimitText.codex(error: error, at: at ?? Date()) ?? limit)
            }
            strictAutoReview = false
            closeAllQuestions()
            openCalls = []
            yieldedCells = [:]
            waits = [:]
            events.append(.turnEnded(turnID: payload["turn_id"] as? String, at: at))
        case "user_message":
            if PromptText.human(payload["message"] as? String ?? "") != nil { takeLimit(nil) }
            userText(payload["message"] as? String)
        case "agent_message":
            asyncMessage(payload, id: nil, at: at)
        case "item_completed":
            if let item = payload["item"] as? [String: Any], item["type"] as? String == "AgentMessage" {
                asyncMessage(item, id: item["id"] as? String, at: at)
            }
        default:
            break
        }
    }

    private mutating func applyItem(_ payload: [String: Any], at: Date?) {
        switch payload["type"] as? String {
        case "function_call", "custom_tool_call":
            guard let name = payload["name"] as? String, let callID = payload["call_id"] as? String else { return }
            if name == "request_user_input" || name == "request_user_input_async" {
                let arguments = Self.object(payload["arguments"] ?? payload["input"])
                open(Question(callID: callID, kind: name == "request_user_input" ? .blocking : .async,
                              items: Self.items(arguments?["questions"]), at: at))
                return
            }
            let arguments = Self.object(payload["arguments"]) ?? [:]
            let called = Self.callName(name, namespace: payload["namespace"] as? String)
            if called == "update_plan" { takePlan(arguments["plan"]) }
            if called == "wait", let cell = Self.cellID(arguments["cell_id"]), let exec = yieldedCells[cell] {
                waits[callID] = exec
                if waits.count > Self.openCallLimit, let first = waits.keys.first { waits[first] = nil }
            }
            let command = Self.clipped(Self.command(arguments, raw: payload["input"] as? String))
            seeCall(Call(callID: callID, name: called, command: command, at: at))
        case "local_shell_call":
            guard let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) else { return }
            let action = payload["action"] as? [String: Any] ?? [:]
            seeCall(Call(callID: callID, name: "local_shell_call", command: Self.clipped(Self.command(action, raw: nil)), at: at))
        case "function_call_output", "custom_tool_call_output":
            guard let callID = payload["call_id"] as? String else { return }
            let output = Self.text(payload["output"])
            if let question = questions[callID] {
                // The async tool answers `{"accepted":true}` at once: the question stays open.
                if question.kind == .async, output.contains(#""accepted":true"#) { return }
                questions[callID] = nil
                events.append(.questionClosed(callID: callID, byReply: question.kind == .blocking))
                return
            }
            let name = openCalls.first { $0.callID == callID }?.name
            if name == "request_permissions" || name == nil, output.contains(#""strict_auto_review":true"#), !strictAutoReview {
                strictAutoReview = true
                events.append(.settingsChanged(at: at))
            }
            // A code-mode cell that yields is still running: it ends with its own completion, or with the output of the
            // `wait` on its cell id that is not another yield (P183).
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, Self.codeModeCells.contains(name), trimmed.hasPrefix(Self.cellYield) {
                let cell = String(trimmed.dropFirst(Self.cellYield.count).prefix { !$0.isWhitespace })
                yieldedCells[cell] = callID
                if yieldedCells.count > Self.openCallLimit, let first = yieldedCells.keys.first { yieldedCells[first] = nil }
                return
            }
            closeCall(callID, at: at)
            if let exec = waits.removeValue(forKey: callID), !trimmed.hasPrefix(Self.cellYield) {
                yieldedCells = yieldedCells.filter { $0.value != exec }
                closeCall(exec, at: at)
            }
        case "message":
            guard payload["role"] as? String == "user", let blocks = payload["content"] as? [[String: Any]] else { return }
            let texts = blocks.compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
            for text in texts { userText(text) }
        default:
            break
        }
    }

    /// A call's output: it is no longer open, and the event that saw it, if still here, learns when it finished.
    private mutating func closeCall(_ callID: String, at: Date?) {
        openCalls.removeAll { $0.callID == callID }
        if let index = events.lastIndex(where: { if case let .callSeen(call) = $0 { call.callID == callID } else { false } }),
           case var .callSeen(call) = events[index] {
            call.outputAt = at
            events[index] = .callSeen(call)
        }
        events.append(.output(callID: callID))
    }

    private mutating func seeCall(_ call: Call) {
        openCalls.removeAll { $0.callID == call.callID }
        openCalls.append(call)
        if openCalls.count > Self.openCallLimit { openCalls.removeFirst(openCalls.count - Self.openCallLimit) }
        events.append(.callSeen(call))
    }

    private mutating func open(_ question: Question) {
        guard !isExec, questions[question.callID] == nil, !question.items.isEmpty else { return }
        questions[question.callID] = question
        events.append(.questionOpened(question))
    }

    /// A legacy `agent_message` or a paginated `AgentMessage` with `delivery: "async"`: the same question as its
    /// call's, opened once (the paginated item's id is the call's; a legacy one names none, so it is matched by text).
    private mutating func asyncMessage(_ message: [String: Any], id: String?, at: Date?) {
        guard message["delivery"] as? String == "async", let raw = message["questions"] else { return }
        let items = Self.items(raw)
        guard !items.isEmpty else { return }
        if let id {
            open(Question(callID: id, kind: .async, items: items, at: at))
            return
        }
        guard !questions.values.contains(where: { $0.items.map(\.question) == items.map(\.question) }) else { return }
        let key = "message:" + items.map(\.question).joined(separator: "|").prefix(256)
        open(Question(callID: String(key), kind: .async, items: items, at: at))
    }

    /// A user text: a reply envelope closes the questions it names; the plain-text fallback (`> <question>`) the one it
    /// quotes; any other human prompt every async question (Skip leaves no trace, so the next prompt ends it).
    private mutating func userText(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        if let start = text.range(of: Self.replyOpen) {
            let rest = text[start.upperBound...]
            let body = rest.range(of: Self.replyClose).map { rest[..<$0.lowerBound] } ?? rest
            let named = Self.replyItems(String(body))
            for callID in Self.uniqued(named.map(\.callID)) {
                guard var question = questions[callID] else { continue }
                let items = named.filter { $0.callID == callID }
                question.answered.formUnion(items.compactMap(\.index))
                if items.contains(where: { $0.index == nil }) || question.isAnswered {
                    questions[callID] = nil
                    events.append(.questionClosed(callID: callID, byReply: true))
                } else {
                    questions[callID] = question
                }
            }
            if named.isEmpty { closeQuestions(kind: .async, byReply: true) }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("> ") {
            let quoted = trimmed.dropFirst(2).prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            if let match = questions.values.first(where: { $0.items.contains { $0.question == quoted } }) {
                questions[match.callID] = nil
                events.append(.questionClosed(callID: match.callID, byReply: true))
                return
            }
        }
        guard PromptText.human(text) != nil else { return }
        closeQuestions(kind: .async, byReply: false)
    }

    private mutating func closeQuestions(kind: QuestionKind, byReply: Bool) {
        for question in questions.values.sorted(by: { $0.callID < $1.callID }) where question.kind == kind {
            questions[question.callID] = nil
            events.append(.questionClosed(callID: question.callID, byReply: byReply))
        }
    }

    private mutating func closeAllQuestions() {
        closeQuestions(kind: .blocking, byReply: false)
        closeQuestions(kind: .async, byReply: false)
    }

    // MARK: Parsing

    /// The call ids an envelope's `questionItemId`s name.
    static func replyCallIDs(_ body: String) -> [String] { uniqued(replyItems(body).map(\.callID)) }

    /// What an envelope's answers name (`tui/src/async_question_reply.rs`, `async_questions/state.rs`
    /// `resolve_answers`): a list of answers or a single one; each `questionItemId` is
    /// `JSON.stringify([tool, call id, index])` for one question of the call, or, from an older desktop, the call id
    /// itself for the whole message (index nil) (P184).
    static func replyItems(_ body: String) -> [(callID: String, index: Int?)] {
        let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8))
        let answers = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        return answers.compactMap { answer in
            guard let itemID = (answer["questionItemId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !itemID.isEmpty else { return nil }
            guard itemID.hasPrefix("[") else { return (itemID, nil) }
            guard let parts = try? JSONSerialization.jsonObject(with: Data(itemID.utf8)) as? [Any], parts.count >= 2,
                  let callID = parts[1] as? String else { return nil }
            return (callID, parts.count >= 3 ? (parts[2] as? NSNumber)?.intValue : nil)
        }
    }

    static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// An MCP tool's call is `{"name":"create_issue","namespace":"mcp__github"}` and its hook's `tool_name` the joined
    /// `mcp__github__create_issue` (codex-rs `mcp.rs` `join_tool_name`, `ensure_mcp_prefix`), so the call is named as
    /// the hook names it; a built-in tool's namespace is `functions` (P183).
    static func callName(_ name: String, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty, namespace != "functions" else { return name }
        let joined = String(namespace.reversed().drop { $0 == "_" }.reversed()) + "__" + String(name.drop { $0 == "_" })
        return joined.hasPrefix("mcp__") ? joined : "mcp__" + joined
    }

    /// A `wait` call's `cell_id`: a string or a number.
    static func cellID(_ raw: Any?) -> String? {
        if let text = raw as? String { return text.isEmpty ? nil : text }
        return (raw as? NSNumber).map { "\($0.intValue)" }
    }

    /// A command as it is kept and compared (`commandLimit`).
    static func clipped(_ command: String?) -> String? {
        guard let command, command.unicodeScalars.count > commandLimit else { return command }
        return String(String.UnicodeScalarView(command.unicodeScalars.prefix(commandLimit)))
    }

    /// Both tools' shapes: `{question, header, options: [{label, description}]}` (blocking) and
    /// `{title, options: [String]}` (async), bounded.
    static func items(_ raw: Any?) -> [Item] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.prefix(itemLimit).compactMap { entry in
            guard let text = (entry["question"] as? String) ?? (entry["title"] as? String) else { return nil }
            let question = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(questionLimit))
            guard !question.isEmpty else { return nil }
            let options = (entry["options"] as? [Any] ?? []).prefix(optionLimit).compactMap { option -> String? in
                let label = (option as? String) ?? ((option as? [String: Any])?["label"] as? String)
                return label.map { String($0.prefix(optionTextLimit)) }
            }
            let header = (entry["header"] as? String).map { String($0.prefix(optionTextLimit)) }
            return Item(question: question, header: header?.isEmpty == false ? header : nil, options: options)
        }
    }

    /// A call's arguments: a JSON string (function calls) or an object.
    static func object(_ raw: Any?) -> [String: Any]? {
        if let object = raw as? [String: Any] { return object }
        guard let text = raw as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// The command a call runs: `cmd` or `command`, a string or an argument list (`bash -lc <script>` gives the script).
    static func command(_ arguments: [String: Any], raw: String?) -> String? {
        let value = arguments["cmd"] ?? arguments["command"]
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let list = value as? [String], !list.isEmpty {
            if list.count >= 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(list[0]), list[1].hasPrefix("-") {
                return list.last?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return list.joined(separator: " ")
        }
        return raw
    }

    /// An output's text: a string, or its content items' text.
    static func text(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let object = raw as? [String: Any] {
            if let content = object["content"] as? String { return content }
            return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        if let list = raw as? [[String: Any]] { return list.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    static func sourceName(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        return (raw as? [String: Any])?.keys.first
    }

    /// One formatter per shape for every fold (a new one per line costs most of a fold's time, P83); parsing with a
    /// shared `ISO8601DateFormatter` is safe from any thread.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

    static func date(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }
}

/// One read's news from a watched rollout, and where its thread stands after it.
struct CodexAttentionUpdate: Sendable {
    var sessionID: String
    var events: [CodexAttention.Event]
    var state: CodexAttention
}
