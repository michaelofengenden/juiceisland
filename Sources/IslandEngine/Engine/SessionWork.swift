import Foundation
import OpenIslandCore

/// What a session is at, for the island's peek only (P720 to P723): Codex's reasoning summary while it thinks, and the
/// agent's task checklist (Claude's tasks or todos, Codex's plan) with each step's state. Memory only: never logged,
/// persisted or kept once the session goes. Every text is bounded where it is read.
public struct SessionWork: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public enum State: Equatable, Sendable { case done, current, pending }

        public var text: String
        public var state: State

        public init(_ text: String, _ state: State) {
            self.text = text
            self.state = state
        }
    }

    /// Codex's latest reasoning summary in the turn, after its latest message: a short title (the summary's bold
    /// first line) and what follows it.
    public struct Thinking: Equatable, Sendable {
        public var title: String?
        public var text: String?

        public init(title: String? = nil, text: String? = nil) {
            self.title = title
            self.text = text
        }
    }

    public var thinking: Thinking?
    public var steps: [Step]

    public init(thinking: Thinking? = nil, steps: [Step] = []) {
        self.thinking = thinking
        self.steps = steps
    }

    public var isEmpty: Bool { thinking == nil && steps.isEmpty }

    /// A checklist with something still to do: a finished list, or none, says nothing (as `TaskProgress.isOpen`).
    public var hasOpenSteps: Bool { steps.contains { $0.state != .done } }

    /// Steps kept, at most: a plan or a todo list is a handful of steps (as `CodexAttention.planLimit` counts).
    public static let stepLimit = 64
    /// A step's text, at most (characters, whitespace collapsed).
    public static let stepTextLimit = 160
    /// A summary's title and text, at most.
    public static let titleLimit = 80
    public static let thinkingLimit = 320

    /// A status as the agents write it (`pending`, `in_progress`, `completed`; Claude's tasks, Claude's todos, Codex's
    /// plan alike); anything else reads as pending.
    public static func state(_ raw: String?) -> Step.State {
        switch raw {
        case "completed": .done
        case "in_progress": .current
        default: .pending
        }
    }

    /// `[{text, status}]` as the agent wrote it, bounded; a step with no text is left out.
    static func steps(_ items: [(text: String?, status: String?)]) -> [Step] {
        items.prefix(stepLimit).compactMap { item in
            clipped(item.text, stepTextLimit).map { Step($0, state(item.status)) }
        }
    }

    /// Claude's task list as upstream's bridge keeps it from `TaskCreate` and `TaskUpdate`.
    public static func steps(tasks: [ClaudeTaskInfo]) -> [Step] {
        steps(tasks.map { (text: $0.title, status: $0.status.rawValue) })
    }

    /// Claude's `TodoWrite` input (`{todos: [{content, status, activeForm}]}`) or Codex's `update_plan` arguments
    /// (`{plan: [{step, status}]}`), bounded; nil when it is neither.
    static func steps(todoWrite input: [String: Any]?) -> [Step]? {
        guard let list = input?["todos"] as? [[String: Any]] else { return nil }
        return steps(list.map { (text: $0["content"] as? String, status: $0["status"] as? String) })
    }

    static func steps(plan raw: Any?) -> [Step]? {
        guard let list = raw as? [[String: Any]] else { return nil }
        return steps(list.map { (text: $0["step"] as? String, status: $0["status"] as? String) })
    }

    /// A reasoning summary as Codex writes it ("**Checking the keys**\n\nThe migration…"): the bold first line as the
    /// title, the rest as the text, each whitespace collapsed and bounded; nil when it says nothing.
    public static func thinking(_ raw: String?) -> Thinking? {
        guard var rest = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !rest.isEmpty else { return nil }
        var title: String?
        if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
            title = clipped(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]), titleLimit)
            rest = String(rest[close.upperBound...])
        }
        let text = clipped(rest.replacingOccurrences(of: "**", with: ""), thinkingLimit)
        guard title != nil || text != nil else { return nil }
        return Thinking(title: title, text: text)
    }

    /// Whitespace collapsed, cut at `limit` characters with "…"; nil when empty.
    static func clipped(_ raw: String?, _ limit: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What a Codex rollout says the thread is at (`SessionWork`), folded beside `CodexAttention` over the lines the tracker
/// already reads (P720): the latest reasoning summary (`agent_reasoning`, or a `reasoning` item's `summary_text`) since
/// the turn's latest message, cleared at each message and at every turn's start and end, and the latest plan's steps
/// (`update_plan`). Pure; only lines that hold one of its markers are parsed.
struct CodexWorkFold: Equatable, Sendable {
    private(set) var work = SessionWork()

    static let markers = ["agent_reasoning", "summary_text", "update_plan", "agent_message", "\"role\":\"assistant\"", "task_started",
                          "turn_started", "task_complete", "turn_complete", "turn_aborted"]

    static func mayMatter(_ line: String) -> Bool { markers.contains { line.contains($0) } }

    mutating func apply(_ line: String) {
        guard Self.mayMatter(line), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("event_msg", "agent_reasoning"):
            take(SessionWork.thinking(payload["text"] as? String))
        case ("response_item", "reasoning"):
            let summary = (payload["summary"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if let summary, !summary.isEmpty { take(SessionWork.thinking(summary)) }
        case ("event_msg", "agent_message"), ("event_msg", "task_started"), ("event_msg", "turn_started"),
             ("event_msg", "task_complete"), ("event_msg", "turn_complete"), ("event_msg", "turn_aborted"):
            work.thinking = nil
        case ("response_item", "message"):
            if payload["role"] as? String == "assistant" { work.thinking = nil }
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
            guard let name = payload["name"] as? String,
                  CodexAttention.callName(name, namespace: payload["namespace"] as? String) == "update_plan",
                  let steps = SessionWork.steps(plan: CodexAttention.object(payload["arguments"] ?? payload["input"])?["plan"]) else { return }
            work.steps = steps
        default:
            break
        }
    }

    private mutating func take(_ thinking: SessionWork.Thinking?) {
        guard let thinking else { return }
        work.thinking = thinking
    }
}
