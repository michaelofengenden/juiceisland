import Foundation
import OpenIslandCore

/// A task list's progress as the agent reports it: Claude's tasks (`TaskCreate`/`TaskUpdate`, which upstream's bridge
/// folds into `activeTasks`), Codex's plan (`update_plan`, read beside the rollout fold by `CodexAttention`).
public struct TaskProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// A list with something still to do: a finished list, or none, says nothing (every fact once, least text).
    public var isOpen: Bool { total > 0 && done < total }
}

/// What a row may say of a session beyond its state (the rows lane, P310): the model it runs, its reasoning effort (P443),
/// its permission mode and its task list's progress, as the agent last reported them. Raw values: the app words them
/// (`RowFacts`). The model, effort and mode are also kept across a relaunch as small labels (`SessionLabels`, P445);
/// nothing else here is persisted or logged.
public struct SessionFacts: Equatable, Sendable {
    /// The model's id as the agent names it (`claude-opus-5-5[1m]`, `gpt-6-astra`); nil when unknown.
    public var model: String?
    /// The permission mode as the hooks name it (`default`, `plan`, `acceptEdits`, `bypassPermissions`, `dontAsk`,
    /// `auto`); nil when no hook said.
    public var mode: String?
    public var tasks: TaskProgress?
    /// The reasoning effort as the agent names it (Claude's `effort.level`: `low` to `max`; Codex's `turn_context.effort`:
    /// `minimal` to `xhigh` and on); nil when the agent did not say.
    public var effort: String?

    public init(model: String? = nil, mode: String? = nil, tasks: TaskProgress? = nil, effort: String? = nil) {
        self.model = model
        self.mode = mode
        self.tasks = tasks
        self.effort = effort
    }
}

extension SessionEngine {
    /// The session's model, effort, mode and task progress. The model: Claude's from its SessionStart hook or the launch's
    /// transcript read (upstream's metadata), else a peek's read of its transcript (`peekModels`); Codex's from its
    /// rollout's latest `turn_context`. The effort: the context note's `effort.level` (Claude's hooks, the session's own,
    /// never a subagent's), else a peek's read of its transcript (`peekEfforts`), else Codex's `turn_context.effort`. The
    /// mode: the context note's `permission_mode` (either agent, the session's own hooks, never a subagent's), else
    /// Claude's hook payload as upstream keeps it. Tasks: Claude's task list, Codex's latest plan. A model, effort or mode
    /// no live source says yet is the one kept from before a relaunch (`SessionLabels`, P445); an effort Codex's latest
    /// turn left out is none, never the kept one (P497).
    public func facts(for session: AgentSession) -> SessionFacts {
        var facts = liveFacts(for: session)
        if let kept = labelBook.labels(for: session.id) {
            facts.model = facts.model ?? kept.model
            facts.mode = facts.mode ?? kept.mode
            facts.effort = facts.effort ?? (effortSaid(session.id) ? nil : kept.effort)
        }
        return facts
    }

    /// A live source says the session's effort, none included: Codex's latest `turn_context` (a turn with no effort has
    /// none). Claude's hooks and transcript only ever name one, so its kept effort stands until they do.
    func effortSaid(_ sessionID: String) -> Bool { codexAttention[sessionID]?.readTurn == true }

    /// What the session's agent says now, without the labels kept from before a relaunch.
    func liveFacts(for session: AgentSession) -> SessionFacts {
        let codex = codexAttention[session.id]
        let context = hookNotes.contexts[session.id]
        let model = Self.nonEmpty(peekModels[session.id]) ?? Self.nonEmpty(session.claudeMetadata?.model) ?? Self.nonEmpty(codex?.model)
        let mode = Self.nonEmpty(context?.permissionMode) ?? Self.nonEmpty(session.claudeMetadata?.permissionMode?.rawValue)
        let effort = Self.nonEmpty(context?.effort) ?? Self.nonEmpty(peekEfforts[session.id]) ?? Self.nonEmpty(codex?.effort)
        var tasks: TaskProgress?
        if let list = session.claudeMetadata?.activeTasks, !list.isEmpty {
            tasks = TaskProgress(done: list.count { $0.status == .completed }, total: list.count)
        } else {
            tasks = codex?.plan
        }
        return SessionFacts(model: model, mode: mode, tasks: tasks, effort: effort)
    }

    /// Keeps the session's model, effort and mode as labels for a relaunch (P445), when the engine has a labels file and
    /// one of them changed: a subagent's session is never kept (its labels are its own, never its parent's).
    func keepLabels(_ sessionID: String) {
        guard let store = configuration.sessionLabels, let session = state.session(id: sessionID), !session.isSubagentSession else { return }
        let live = liveFacts(for: session)
        guard labelBook.take(sessionID, model: live.model, mode: live.mode, effort: live.effort, effortSaid: effortSaid(sessionID),
                             at: dependencies.now()) else { return }
        store.save(labelBook.labels)
    }

    /// Reads the kept labels, once, at the start (a missing or unreadable file keeps none).
    func loadLabels() {
        guard !labelsLoaded, let store = configuration.sessionLabels else { return }
        labelsLoaded = true
        labelBook = SessionLabelBook(labels: store.load(), now: dependencies.now())
    }

    /// When the session's oldest tool call still in flight began, for a running session (P440): the context notes' calls
    /// (`ToolFlightBook`). A session whose helper never named a call (a helper before note version 2, an agent with no
    /// helper of ours) and a Codex chat (a tool its hooks do not cover, a code-mode cell, still shows in its rollout) also
    /// count upstream's own word that a tool began and has not ended: a current tool and the summary its start gave
    /// ("Running …"; the end says "… finished." or "Thinking."). nil: nothing in flight.
    public func toolInFlightSince(for session: AgentSession) -> Date? {
        guard session.phase == .running else { return nil }
        if let since = toolFlights.inFlightSince(session.id) { return since }
        guard session.tool == .codex || !toolFlights.noted.contains(session.id),
              let tool = session.currentToolName, !tool.isEmpty, session.summary.hasPrefix(Self.toolStartPrefix) else { return nil }
        return activityClocks[session.id]?.toolStartedAt ?? session.updatedAt
    }

    /// The summary upstream's bridge and rollout fold give a tool's start ("Running Bash: npm test", "Running exec_command.").
    static let toolStartPrefix = "Running "

    /// When the session last showed a sign of life: its last event (upstream's `updatedAt`, which every hook and
    /// rollout event moves) or its last context note, whichever is later. A stall is measured from here (P312).
    public func lastActivity(for session: AgentSession) -> Date {
        guard let noted = hookNotes.contexts[session.id]?.updatedAt, noted > session.updatedAt else { return session.updatedAt }
        return noted
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
