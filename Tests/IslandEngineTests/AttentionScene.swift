import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
@testable import IslandEngine

/// A headless engine with its request broker stood in, driven the way the superset helper and upstream's bridge drive
/// the real one: a hook's context note (`HookContextNote.make`, as the prelude makes it), a PermissionRequest's broker
/// line (as the prelude builds it, held or not by `AttentionPolicy.holds`, as the broker replies), and the `AgentEvent`s
/// upstream's bridge emits for the same hooks. The clock is the test's; the 8 s windows and Done holds are scheduled
/// checks it runs. No socket, no process, no file but the fixtures the test writes itself.
@MainActor
final class AttentionScene {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box

    /// Stands in for `HookRequestBroker`: what was held, released or answered.
    final class StubBroker: HookRequestReceiving, @unchecked Sendable {
        let held = Box<Set<String>>([])
        let released = Box<[String]>([])
        let answers = Box<[(id: String, response: BridgeResponse)]>([])
        let stopped = Box(false)

        func answer(_ id: String, _ response: BridgeResponse) -> Bool {
            var was = false
            held.update { was = $0.remove(id) != nil }
            if was { answers.update { $0.append((id, response)) } }
            return was
        }

        func release(_ id: String) {
            held.update { if $0.remove(id) != nil { released.update { $0.append(id) } } }
        }

        func stop() {
            stopped.update { $0 = true }
            held.update { $0 = [] }
        }

        /// The helper went away (Claude answered at its own prompt and killed it, a timeout).
        func end(_ id: String) -> Bool {
            var was = false
            held.update { was = $0.remove(id) != nil }
            return was
        }
    }

    /// A transcript watch the test fires by hand (a `tool_result` written for the call).
    final class Watches: @unchecked Sendable {
        final class Watch: TranscriptWatching, @unchecked Sendable {
            let path: String, toolUseID: String, onFound: @Sendable () -> Void
            let stopped = Box(false)
            init(path: String, toolUseID: String, onFound: @escaping @Sendable () -> Void) {
                self.path = path
                self.toolUseID = toolUseID
                self.onFound = onFound
            }
            func stop() { stopped.update { $0 = true } }
        }
        let all = Box<[Watch]>([])
    }

    let clock = Box(F.now)
    let scheduled = Box<[F.ScheduledCheck]>([])
    let sent = Box<[BridgeCommand]>([])
    let front = Box<String?>(nil)
    let gone = Box<Set<Int32>>([])
    let watches = Watches()
    let broker = StubBroker()
    let engine: SessionEngine
    private(set) var signals: [EngineSignal] = []
    /// Each session's rollout as the tracker folds it (`rollout(_:_:)`).
    private var rollouts: [String: CodexAttention] = [:]
    let start: Date

    /// `armed`: the session's Claude profile runs our helper on `permission_prompt` (C19); false reads a profile whose
    /// hook config has no such Notification. `suppress` with `frontmost`: No alerts for focused sessions, with the
    /// session's own tab in front.
    init(armed: Bool = true, suppress: Bool = false, frontmost: Bool = false) {
        let watches = watches, gone = gone
        engine = F.engine(sent: sent, frontmost: frontmost, suppress: suppress, clock: clock, scheduled: scheduled,
                          frontmostApp: front, configure: { dependencies in
            dependencies.watchTranscript = { path, toolUseID, onFound in
                let watch = Watches.Watch(path: path, toolUseID: toolUseID, onFound: onFound)
                watches.all.update { $0.append(watch) }
                return watch
            }
            dependencies.processExists = { pid in !gone.current.contains(pid) }
            dependencies.readCodexSettings = { CodexSettingsReader.read(path: $0) }
            dependencies.notificationArming = { _ in armed }
        })
        start = clock.current
        engine.hookRequestBroker = broker
        engine.onSignal = { [weak self] in self?.signals.append($0) }
        if !armed {
            // One Claude profile whose hook config was read: every session falls back to it.
            engine.setProfiles(accounts: [Account(provider: .claude, folder: F.profile, alias: "Lab")], discovered: [])
        }
    }

    // MARK: Time

    /// Seconds since the scene began.
    var t: TimeInterval { clock.current.timeIntervalSince(start) }

    /// Moves the clock to `second`, running every check that falls due on the way (windows, Done holds).
    func at(_ second: TimeInterval) {
        F.runScheduledChecks(scheduled, clock: clock, for: max(0, second - t))
    }

    // MARK: Inputs

    /// A session as its SessionStart and first prompt reach the bridge.
    func begin(_ id: String = "s1", tool: AgentTool = .claudeCode, prompt: String = "fix the tests", transcript: String? = nil) {
        engine.ingest(F.started(id, tool: tool, transcript: transcript ?? Self.transcript(id, tool: tool)), ingress: .bridge)
        engine.ingest(F.prompt(id, prompt, at: clock.current), ingress: .bridge)
    }

    func bridge(_ events: AgentEvent...) {
        for event in events { engine.ingest(event, ingress: .bridge) }
    }

    /// One hook as the superset helper runs it: its note first, then, for a Claude or Codex PermissionRequest, its
    /// broker line. Returns the brokered request's id (nil for any other hook). A Codex subagent's other hooks end with
    /// their note (C5), as the prelude ends them. `countsKinds` false sends the note as the helper before P510 did,
    /// with `background_tasks` counted but not by kind (and no word of a SubagentStop's own agent, P515).
    @discardableResult
    func hook(_ object: [String: Any], source: String = "claude", entrypoint: String? = "cli", terminal: Bool = true,
              pid: Int32 = 900, host: String? = nil, version: Int = HookContextNote.currentVersion, countsKinds: Bool = true) -> String? {
        var environment: [String: String] = [:]
        if let entrypoint { environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint }
        if let host { environment["__CFBundleIdentifier"] = host }
        if var note = HookContextNote.make(object: object, environment: environment, agentPID: pid, source: source) {
            note.version = version
            if !countsKinds {
                note.backgroundTaskKinds = nil
                note.agentInBackground = nil
            }
            if version < 2 { note = Self.versionOne(note) }
            engine.ingest(note: note)
        }
        guard object["hook_event_name"] as? String == "PermissionRequest", HookPrelude.brokeredSources.contains(source),
              version >= 2 else { return nil }
        let input = try! JSONSerialization.data(withJSONObject: object)
        let line = HookRequestLine(source: source, input: input, digest: object["tool_input"].flatMap(HookInputDigest.of),
                                   entrypoint: entrypoint, agentPID: pid, hostBundleID: host, hasTerminal: terminal)
        // As the broker replies: with Answer subagents on the island on, a subagent's tool approval is held too, bounded
        // (P350); with Answer Codex on the island on, a Codex shell command or patch (P470).
        let hold = AttentionPolicy.brokerHold(line, object, answersSubagents: engine.answersSubagents, answersCodex: engine.answersCodex)
        let id = UUID().uuidString
        if hold.held { broker.held.update { _ = $0.insert(id) } }
        engine.takeBrokeredRequest(BrokeredRequest(id: id, line: line, object: object, held: hold.held, at: clock.current,
                                                   bound: hold.bound))
        return id
    }

    /// Lines appended to a session's rollout and read by the tracker (`CodexRolloutTracker`'s fold, handed over as it
    /// hands it).
    func rollout(_ sessionID: String, _ lines: [String]) {
        var attention = rollouts[sessionID] ?? CodexAttention()
        for line in lines { attention.apply(line) }
        let events = attention.takeEvents()
        rollouts[sessionID] = attention
        guard !events.isEmpty else { return }
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: sessionID, events: events, state: attention))
    }

    /// The transcript's `tool_result` for a call, as the watch finds it.
    func transcriptResult(_ toolUseID: String) async {
        for watch in watches.all.current where watch.toolUseID == toolUseID && !watch.stopped.current { watch.onFound() }
        await settle()
    }

    /// Lets the main actor run what a watch or a detached read handed to it.
    func settle(until condition: () -> Bool = { false }) async {
        for _ in 0..<50 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The process monitor's pass (the agents' pids looked at).
    func livenessPass() {
        engine.applyMonitoredState(engine.state)
    }

    // MARK: What the owner sees

    /// "!" or "?" (nil: nothing drawn), from the book's head.
    func glyph(_ sessionID: String = "s1") -> String? {
        guard let head = engine.attentionHead(for: sessionID) else { return nil }
        return head.kind.isQuestion ? "?" : "!"
    }

    func head(_ sessionID: String = "s1") -> AttentionRequest? { engine.attentionHead(for: sessionID) }

    func phase(_ sessionID: String = "s1") -> SessionPhase? { engine.state.session(id: sessionID)?.phase }

    var needsYou: [EngineSignal] { signals.filter { if case .needsYou = $0 { true } else { false } } }
    var dones: [EngineSignal] { signals.filter { if case .done = $0 { true } else { false } } }

    func request(_ id: String?) -> AttentionRequest? { engine.openRequests.first { $0.id == id } }

    func isOpen(_ id: String?) -> Bool { engine.openRequests.contains { $0.id == id } }

    func state(_ id: String?) -> AttentionRequest.State? { engine.openRequests.first { $0.id == id }?.state }

    // MARK: Fixtures

    static func transcript(_ id: String, tool: AgentTool = .claudeCode) -> String {
        tool == .codex ? "/tmp/juice-attention/sessions/rollout-\(id).jsonl" : "\(F.profile)/projects/-tmp-project/\(id).jsonl"
    }

    /// A Claude hook's input in the shape the hooks docs give (fictional values).
    static func claude(_ event: String, session: String = "s1", tool: String? = nil, input: [String: Any]? = nil,
                       toolUseID: String? = nil, agent: String? = nil, agentType: String? = nil, mode: String = "default",
                       extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["hook_event_name": event, "session_id": session, "cwd": "/tmp/project",
                                     "transcript_path": transcript(session), "permission_mode": mode]
        if let tool { object["tool_name"] = tool }
        if let input { object["tool_input"] = input }
        if let toolUseID { object["tool_use_id"] = toolUseID }
        if let agent {
            object["agent_id"] = agent
            object["agent_type"] = agentType ?? "worker"
        }
        return object.merging(extra) { $1 }
    }

    static let push: [String: Any] = ["command": "git push origin main", "description": "Push the branch"]
    static let read: [String: Any] = ["file_path": "/tmp/project/README.md"]
    static let edit: [String: Any] = ["file_path": "/tmp/project/a.swift", "old_string": "a", "new_string": "b"]
    static let questions: [String: Any] = ["questions": [
        ["question": "Which branch?", "header": "Branch", "multiSelect": false,
         "options": [["label": "main", "description": "The default."], ["label": "dev", "description": "The next one."]]],
        ["question": "Which checks?", "header": "Checks", "multiSelect": true,
         "options": [["label": "lint", "description": ""], ["label": "tests", "description": ""], ["label": "docs", "description": ""]]],
    ]]

    static func notification(_ type: String, session: String = "s1", agent: String? = nil) -> [String: Any] {
        claude("Notification", session: session, agent: agent,
               extra: ["notification_type": type, "message": "Claude needs your permission to use Bash"])
    }

    /// A Codex hook's input (codex-rs `hooks/src/schema.rs`; fictional values).
    static func codex(_ event: String, session: String = "c1", turn: String = "turn-1", tool: String? = "Bash",
                      input: [String: Any]? = ["command": "git push origin main"], agent: String? = nil,
                      mode: String = "default", transcript: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["hook_event_name": event, "session_id": session, "turn_id": turn, "cwd": "/tmp/project",
                                     "transcript_path": transcript ?? Self.transcript(session, tool: .codex), "model": "gpt-6",
                                     "permission_mode": mode]
        if let tool, event == "PermissionRequest" || event == "PreToolUse" { object["tool_name"] = tool }
        if let input, event == "PermissionRequest" || event == "PreToolUse" { object["tool_input"] = input }
        if let agent {
            object["agent_id"] = agent
            object["agent_type"] = "explorer"
        }
        return object.merging(extra) { $1 }
    }

    /// What upstream's helper before note version 2 sent: the same event, ids and handles, none of the new fields.
    static func versionOne(_ note: HookContextNote) -> HookContextNote {
        HookContextNote(version: 1, event: note.event, sessionID: note.sessionID, stopHookActive: note.stopHookActive,
                        itermSessionID: note.itermSessionID, tmux: note.tmux, tmuxPane: note.tmuxPane, agentPID: note.agentPID,
                        hostBundleID: note.hostBundleID, termProgram: note.termProgram)
    }
}

extension EngineFixtures {
    /// A Claude profile folder (fictional).
    static let profile = "/Users/test/.claude-lab"
}
