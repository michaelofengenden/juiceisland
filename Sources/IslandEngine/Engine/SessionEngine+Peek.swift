import Foundation

extension SessionEngine {
    /// A session peek's read of a Claude session's transcript tail (`SessionPeekReader`, P311), off the main thread, for
    /// the island's peek only: nil for any other agent (Codex's rollout tracker already keeps its prompt, reply and tool
    /// current in the session's metadata, and the other agents' hooks theirs), for a session with no transcript, and for
    /// one gone by the time the read is back. The model and the effort the tail names become the session's (`facts(for:)`):
    /// a `/model` switch reaches no hook. Nothing else of the read is kept.
    public func readPeek(sessionID: String) async -> SessionPeekRead? {
        guard let reader = dependencies.readPeek, let session = state.session(id: sessionID), session.tool == .claudeCode,
              let path = session.claudeMetadata?.transcriptPath, !path.isEmpty else { return nil }
        let read = await Task.detached(priority: .userInitiated) { reader(path) }.value
        guard let read, state.session(id: sessionID) != nil else { return nil }
        if let model = Self.nonEmpty(read.model), model != peekModels[sessionID] { peekModels[sessionID] = model }
        if let effort = Self.nonEmpty(read.effort), effort != peekEfforts[sessionID] { peekEfforts[sessionID] = effort }
        keepLabels(sessionID)
        return read
    }

    /// What the session is at now, for the peek only (P720): a Codex chat's reasoning summary and plan steps, as its
    /// rollout last said (`codexWork`), or a Claude session's task list as its hooks keep it (`TaskCreate`, `TaskUpdate`);
    /// nil when there is nothing. Observed: a peek that reads it follows it while it shows. Claude's `TodoWrite` list is
    /// in its transcript only, so the peek's read finds it (`SessionPeekRead.todos`).
    public func work(for sessionID: String) -> SessionWork? {
        guard let session = state.session(id: sessionID) else { return nil }
        if session.tool == .codex { return codexWork[sessionID] }
        guard let tasks = session.claudeMetadata?.activeTasks, !tasks.isEmpty else { return nil }
        return SessionWork(steps: SessionWork.steps(tasks: tasks))
    }

    /// A Codex chat's work as its rollout's latest read left it: written only when it changed, and only for a session
    /// still here; an empty one is none.
    func takeCodexWork(_ sessionID: String, _ work: SessionWork) {
        guard state.session(id: sessionID) != nil else { return }
        let next = work.isEmpty ? nil : work
        if codexWork[sessionID] != next { codexWork[sessionID] = next }
    }
}
