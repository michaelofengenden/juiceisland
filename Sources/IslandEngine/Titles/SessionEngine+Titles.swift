import Foundation
import OpenIslandCore

/// One session's Claude title reads (`SessionEngine.titleReads`).
struct TitleRead {
    var task: Task<Void, Never>?
    /// Another trigger came while a read was in flight: one more read follows it.
    var again = false
    var lastStartedAt: Date?
}

extension SessionEngine {
    /// How long a Claude session with no title yet waits between the reads its tool events ask for: the generated
    /// title lands about 2 s after the first prompt, often before the turn ends.
    static let untitledReadGap: TimeInterval = 3

    /// The session's chat title: the agent's own, else its first prompt; nil before any prompt (the row names the
    /// repo then). Never upstream's "<Agent> · <folder>": the agent is said by its mark and colour (P204).
    public func chatTitle(for session: AgentSession) -> ChatTitle? {
        if let text = agentTitles[session.id] { return ChatTitle(text: text, source: .agent) }
        if let prompt = firstPrompts[session.id] { return ChatTitle(text: prompt, source: .prompt) }
        // A restored or discovered session that has had no event yet: its prompt, found once.
        guard let prompt = ChatTitleText.firstPrompt(of: session) else { return nil }
        firstPrompts[session.id] = prompt
        return ChatTitle(text: prompt, source: .prompt)
    }

    /// The session's first prompt, as first seen, whatever titles its row: what Settings › Island › Mute rules match
    /// "First prompt" against (P421). Memory only, as titles are (P200).
    public func firstPrompt(for session: AgentSession) -> String? {
        firstPrompts[session.id] ?? ChatTitleText.firstPrompt(of: session)
    }

    /// After every applied event: the first prompt, as first seen, and a Claude title read on the hooks that can bring
    /// one (never on a timer, P201): a session's start (a resume's re-appended title lines), a prompt (a `/rename`
    /// made before it), a turn's end, and, while the session has no title yet, its other events at most every
    /// `untitledReadGap` (the generated title, mid-turn).
    func noteForTitle(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, before: AgentSession?, now: Date) {
        guard let session = state.session(id: sessionID) else { return }
        if firstPrompts[sessionID] == nil, let prompt = ChatTitleText.firstPrompt(of: session) ?? Self.promptText(event, ingress: ingress) {
            firstPrompts[sessionID] = prompt
        }
        guard ingress == .bridge, session.tool == .claudeCode,
              let path = session.claudeMetadata?.transcriptPath, !path.isEmpty else { return }
        let asked: Bool = switch event {
        case .sessionStarted, .sessionCompleted: true
        default: SignalPipeline.isNewPrompt(event, ingress: ingress, before: before)
        }
        if !asked {
            guard agentTitles[sessionID] == nil else { return }
            if let last = titleReads[sessionID]?.lastStartedAt, now.timeIntervalSince(last) < Self.untitledReadGap, now >= last { return }
        }
        readClaudeTitle(sessionID, now: now)
    }

    /// A bridge prompt's text, for an agent whose hooks keep no metadata (Grok): the bridge's "Prompt: …" (upstream's
    /// preview of it, at most 110 characters).
    static func promptText(_ event: AgentEvent, ingress: TrackedEventIngress) -> String? {
        guard ingress == .bridge, case let .activityUpdated(payload) = event, payload.summary.hasPrefix(SignalPipeline.promptPrefix) else { return nil }
        return ChatTitleText.prompt(String(payload.summary.dropFirst(SignalPipeline.promptPrefix.count)))
    }

    /// Reads the session's title lines off the main thread. One read per session at a time: a trigger during one asks
    /// for one more after it, which reads the transcript the session names then.
    func readClaudeTitle(_ sessionID: String, now: Date) {
        if titleReads[sessionID]?.task != nil {
            titleReads[sessionID]?.again = true
            return
        }
        titleReads[sessionID, default: TitleRead()].lastStartedAt = now
        let read = dependencies.readClaudeTitle
        titleReads[sessionID]?.task = Task { [weak self] in
            while let path = self?.state.session(id: sessionID)?.claudeMetadata?.transcriptPath, !path.isEmpty {
                let window = await Task.detached(priority: .utility) { read(path) }.value
                guard let self, !Task.isCancelled else { return }
                if let window { self.takeClaudeTitleLines(window, for: sessionID) }
                guard self.titleReads[sessionID]?.again == true else { break }
                self.titleReads[sessionID]?.again = false
                self.titleReads[sessionID]?.lastStartedAt = self.dependencies.now()
            }
            guard let self, !Task.isCancelled else { return }
            self.titleReads[sessionID]?.task = nil
        }
    }

    /// A later window of a Claude session's transcript: its title lines over those read before.
    func takeClaudeTitleLines(_ window: ClaudeTitleFold, for sessionID: String) {
        guard state.session(id: sessionID) != nil else { return }
        var fold = claudeTitleFolds[sessionID] ?? ClaudeTitleFold()
        fold.merge(window)
        claudeTitleFolds[sessionID] = fold
        setAgentTitle(fold.title, for: sessionID)
    }

    /// Codex threads whose name changed in their home's index (`CodexRolloutTracker.titleHandler`); a thread that is no
    /// session here (Codex's hidden titling thread has no rollout and no hook) is never kept (P205).
    func takeCodexTitles(_ names: [String: String?]) {
        for (sessionID, name) in names where state.session(id: sessionID)?.tool == .codex {
            setAgentTitle(name, for: sessionID)
        }
    }

    /// The launch's titles: Claude's from the transcripts the launch read, Codex's from the index for every Codex row
    /// with a rollout (the watched ones' names then move on with the tracker's poll). A Claude session a hook's read
    /// has titled while the launch's scan ran keeps that read's kinds: the scan read its transcript earlier, so it only
    /// fills the kinds the live read has not seen (P211).
    func takeStartupTitles(claude: [String: ClaudeTitleFold]) {
        for (sessionID, launch) in claude where state.session(id: sessionID)?.tool == .claudeCode {
            var fold = claudeTitleFolds[sessionID] ?? ClaudeTitleFold()
            fold.fill(from: launch)
            claudeTitleFolds[sessionID] = fold
            setAgentTitle(fold.title, for: sessionID)
        }
        let codex = state.sessions.compactMap { session -> CodexRolloutWatchTarget? in
            guard session.tool == .codex, let path = session.codexMetadata?.transcriptPath, !path.isEmpty else { return nil }
            return CodexRolloutWatchTarget(sessionID: session.id, transcriptPath: path)
        }
        discovery?.codexRolloutWatcher.nameOnce(codex)
    }

    /// Writes only a change, so a read that finds the same title redraws nothing. nil or empty clears it (P202).
    func setAgentTitle(_ title: String?, for sessionID: String) {
        let clean = ChatTitleText.clean(title)
        guard agentTitles[sessionID] != clean else { return }
        agentTitles[sessionID] = clean
    }

    func forgetTitle(_ sessionID: String) {
        titleReads.removeValue(forKey: sessionID)?.task?.cancel()
        claudeTitleFolds[sessionID] = nil
        firstPrompts[sessionID] = nil
        if agentTitles[sessionID] != nil { agentTitles[sessionID] = nil }
    }

    /// The Claude title read in flight for a session (tests wait on it).
    func titleReadTask(for sessionID: String) -> Task<Void, Never>? { titleReads[sessionID]?.task }

    // MARK: Preview

    /// A Claude session's transcript lines, folded as a live read folds them, for the demo and renders: nothing is
    /// opened. Only while the bridge is not running, like `loadPreviewEvents`.
    @discardableResult
    public func loadPreviewTranscript(sessionID: String, lines: [String]) -> Bool {
        guard bridgeServer == nil else { return false }
        var fold = ClaudeTitleFold()
        for line in lines { fold.apply(line) }
        takeClaudeTitleLines(fold, for: sessionID)
        return true
    }

    /// A Codex home's `session_index.jsonl` lines, as the tracker reads them, for the demo and renders: nothing is
    /// opened. Only while the bridge is not running, like `loadPreviewEvents`.
    @discardableResult
    public func loadPreviewCodexIndex(lines: [String]) -> Bool {
        guard bridgeServer == nil else { return false }
        takeCodexTitles(CodexTitleIndex.names(fromLines: lines).mapValues { $0.isEmpty ? nil : $0 })
        return true
    }
}
