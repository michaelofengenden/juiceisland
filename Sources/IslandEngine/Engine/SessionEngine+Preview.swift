import Foundation
import IslandHookNotes
import OpenIslandCore

extension SessionEngine {
    /// A headless engine for the demo, previews and renders: no bridge, no discovery, no process monitor, no socket,
    /// no jump and no frontmost check. `clock` is its clock; every command its cards send goes to `commands` and
    /// never leaves the process (a throw is a send that failed). Sessions come only from `loadPreviewEvents(_:)`. A
    /// waiting approval's tool call comes from `toolCalls` (by call id), as a live one comes from its transcript; no
    /// file is opened. A reply goes to `replies`, never to a terminal; the agents a reply needs are named by
    /// `loadPreviewAgents(_:)` and taken to be at their prompts, with no process looked at.
    public static func preview(clock: @escaping @Sendable () -> Date = { Date() },
                               commands: @escaping @Sendable (BridgeCommand) throws -> Void = { _ in },
                               toolCalls: [String: ClaudeHookJSONValue] = [:],
                               replies: @escaping @Sendable (ReplyRoute, String) -> Bool = { _, _ in true },
                               fresh: @escaping @Sendable (FreshSessionLaunch) -> Bool = { _ in false }) -> SessionEngine {
        var configuration = Configuration.headless
        // A path nothing listens on: even a stray send could not reach a real island's socket.
        configuration.socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-island-preview-\(UUID().uuidString).sock")
        configuration.suppressWhenFrontmost = false
        configuration.excludedWorkingDirectories = []
        var dependencies = Dependencies()
        dependencies.sendCommand = { command in try commands(command) }
        dependencies.sendReply = replies
        // Never a real window: "Open in <account>" reaches only this (P703).
        dependencies.openFresh = fresh
        var runner = JumpRunner()
        runner.appURL = { _ in nil }
        runner.isAppRunning = { _ in false }
        runner.appleScript = { _, _ in throw CocoaError(.featureUnsupported) }
        runner.open = { _, _ in throw CocoaError(.featureUnsupported) }
        runner.command = { _, _, _ in false }
        runner.capture = { _, _, _ in throw CocoaError(.featureUnsupported) }
        runner.isExecutable = { _ in false }
        runner.frontmostBundleID = { nil }
        runner.appForPID = { _ in nil }
        dependencies.jumpRunner = runner
        // A made-up tty per agent `loadPreviewAgents` named, so a demo Terminal turn has its tab (P1300); no process is
        // looked at, and no route types anywhere but `replies`.
        dependencies.ttyForPID = { pid in "/dev/ttys" + String(format: "%03d", Int(pid) % 1000) }
        dependencies.appForPID = { _ in nil }
        dependencies.agentAtPrompt = { _ in true }
        // The demo's Codex background service, by its made-up pid; no real process is asked (P1485).
        dependencies.isCodexServer = { $0 == SessionEngine.previewCodexServicePID }
        dependencies.isSessionFrontmost = { _ in false }
        dependencies.frontmostBundleID = { nil }
        dependencies.updateProcessRoots = { _ in }
        dependencies.isOtherIslandRunning = { false }
        dependencies.socketHasOwner = { _ in false }
        dependencies.startBridge = { _ in throw CocoaError(.featureUnsupported) }
        dependencies.startRuntime = { _ in }
        dependencies.now = clock
        dependencies.scheduleSignalCheck = { _, _ in }
        dependencies.toolCallReads = .fixtures(toolCalls)
        // Titles come from `loadPreviewTranscript` and `loadPreviewCodexIndex`: no transcript is opened.
        dependencies.readClaudeTitle = { _ in nil }
        dependencies.readPeek = nil
        // A fixture's request is one that already waited: shown at once.
        dependencies.confirmsRequestsAtOnce = true
        dependencies.scheduleAttentionCheck = { _, _ in }
        dependencies.notificationArming = { _ in false }
        dependencies.watchTranscript = { _, _, _ in nil }
        dependencies.processExists = { _ in true }
        // No process is looked at for a fold's agent either (P1415).
        dependencies.parentPID = { _ in nil }
        dependencies.processName = { _ in nil }
        // A demo rollout is fictional and never read: a request's reviewer is the one `loadPreviewRollout` folded.
        dependencies.readCodexSettings = { _ in nil }
        dependencies.watchesSubagentRollouts = false
        dependencies.readForkParent = { _ in nil }
        dependencies.scheduleSubagentCheck = { _, _ in }
        return SessionEngine(configuration: configuration, dependencies: dependencies)
    }

    /// Feeds `events` through the normal ingest path, as the bridge would have sent them, for the demo and previews.
    /// Only while the bridge is not running: then it returns false and changes nothing, so preview sessions never
    /// mix with live ones.
    @discardableResult
    public func loadPreviewEvents(_ events: [AgentEvent]) -> Bool {
        guard bridgeServer == nil else { return false }
        for event in events { ingest(event, ingress: .bridge) }
        // A fixture's request is one that already waited: shown at once, sounding nothing.
        for request in attention.all where request.state != .confirmed {
            attention.update(request.id) { $0.sounded = true }
            if let confirmed = attention.confirm(request.id, at: request.openedAt) { noteConfirmed(confirmed, revived: false) }
        }
        return true
    }

    /// A Codex rollout's lines, read as the tracker reads a watched one: upstream's reducer for the row (its events,
    /// through the normal ingest path) and `CodexAttention` beside it for questions, the reviewer and call outputs. For
    /// the demo and renders; nothing is opened on disk. Only while the bridge is not running, like `loadPreviewEvents`.
    /// A rollout that is not a chat (Codex's reviewer, a helper, a subagent) is taken as the tracker takes one (P212):
    /// never a row, a subagent kept on its chat with its turn's state.
    @discardableResult
    public func loadPreviewRollout(sessionID: String, transcriptPath: String, lines: [String]) -> Bool {
        guard bridgeServer == nil else { return false }
        var folder = RolloutFolder(CodexRolloutSnapshot())
        var codex = codexAttention[sessionID] ?? CodexAttention()
        var work = CodexWorkFold()
        for line in lines {
            folder.apply(line)
            codex.apply(line)
            work.apply(line)
        }
        let snapshot = folder.finish()
        if let kind = codex.threadKind, !kind.isChat, codex.threadID == nil || codex.threadID == sessionID {
            let child = (kind.subagent ?? kind.review).map { thread in
                CodexChildThread(id: sessionID, parentID: thread.parentID, rootID: thread.rootID, name: thread.name,
                                 isRunning: snapshot.phase == .running, updatedAt: snapshot.updatedAt ?? dependencies.now(),
                                 transcriptPath: transcriptPath, isReview: kind.review != nil)
            }
            hideCodexThread(sessionID, kind: kind, child: child)
            // A review not folded into its chat is a row of its own (P217).
            if kind.review == nil || codexThreads.isHidden(sessionID) { return true }
        }
        for event in CodexRolloutReducer.events(from: CodexRolloutSnapshot(), to: snapshot, sessionID: sessionID, transcriptPath: transcriptPath) {
            ingest(event, ingress: .rollout)
        }
        let events = codex.takeEvents()
        codexAttention[sessionID] = codex
        takeCodexWork(sessionID, work.work)
        if !events.isEmpty { ingestCodexAttention(CodexAttentionUpdate(sessionID: sessionID, events: events, state: codex)) }
        return true
    }

    /// A Claude or Codex PermissionRequest as the superset helper hands it to the request broker (held where the
    /// policy holds it, as the broker replies), for the demo and renders: no broker listens, so nothing is held and an
    /// answer goes nowhere. `input` is the hook's JSON. A Codex subagent's is entered after a read off the main thread.
    /// Only while the bridge is not running, like `loadPreviewEvents`.
    @discardableResult
    public func loadPreviewHookRequest(_ input: [String: Any], source: String, entrypoint: String? = nil, hasTerminal: Bool = true,
                                       hostBundleID: String? = nil) -> Bool {
        guard bridgeServer == nil, let data = try? JSONSerialization.data(withJSONObject: input) else { return false }
        let line = HookRequestLine(source: source, input: data, digest: input["tool_input"].flatMap(HookInputDigest.of),
                                   entrypoint: entrypoint, hostBundleID: hostBundleID, hasTerminal: hasTerminal)
        let hold = AttentionPolicy.brokerHold(line, input, answersSubagents: answersSubagents, answersCodex: answersCodex)
        takeBrokeredRequest(BrokeredRequest(id: UUID().uuidString, line: line, object: input, held: hold.held, at: dependencies.now(),
                                            bound: hold.bound))
        return true
    }

    /// A hook's context note with no request behind it (a `Notification`'s type, a `StopFailure`, the session's permission
    /// mode, a tool call's id, its effort), as the superset helper sends it (Claude's unless `source` says), for the demo
    /// and renders. Only while the bridge is not running, like `loadPreviewEvents`.
    @discardableResult
    public func loadPreviewNote(event: String, sessionID: String, notificationType: String? = nil, permissionMode: String? = nil,
                                source: String = "claude", toolUseID: String? = nil, effort: String? = nil) -> Bool {
        guard bridgeServer == nil else { return false }
        ingest(note: HookContextNote(event: event, sessionID: sessionID, toolUseID: toolUseID, notificationType: notificationType,
                                     permissionMode: permissionMode, source: source, effort: effort))
        return true
    }

    /// The made-up pid of the demo's Codex background service: a session whose notes name it runs there (P1486).
    public nonisolated static let previewCodexServicePID: Int32 = 4399

    /// Sends sessions to the island as Send to island does, newest last in `ids`, with no window tucked (P1300): for the
    /// demo and renders. Only while the bridge is not running, like `loadPreviewEvents`; a session that cannot fold is
    /// left out.
    @discardableResult
    public func loadPreviewFolds(_ ids: [String]) -> Bool {
        guard bridgeServer == nil else { return false }
        for (index, id) in ids.enumerated() where canFold(sessionID: id) {
            var fold = FoldedSession(sessionID: id, since: dependencies.now().addingTimeInterval(Double(index - ids.count)),
                                     session: state.session(id: id))
            fold.turnOpen = state.session(id: id).map { $0.phase != .completed } ?? false
            fold.host = state.session(id: id).flatMap { replyRoute(for: $0) }.flatMap(FoldedSession.hostWord)
            folds[id] = fold
        }
        return true
    }

    /// Names each session's agent by a pid, as a hook's context note does, so a finished turn in a known terminal
    /// offers a reply (P139). Only while the bridge is not running, like `loadPreviewEvents`.
    @discardableResult
    public func loadPreviewAgents(_ pids: [String: Int32]) -> Bool {
        guard bridgeServer == nil else { return false }
        for (sessionID, pid) in pids { ingest(note: HookContextNote(event: "SessionStart", sessionID: sessionID, agentPID: pid)) }
        return true
    }
}
