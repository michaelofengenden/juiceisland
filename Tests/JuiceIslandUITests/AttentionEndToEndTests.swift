import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Tier 1 of the needs-you test plan (§5.2): the key rows of both truth tables, and replays of the owner's two
/// messages (§5.3, R1-R4), through the built helper, the engine's real sockets, the engine and the session model, with
/// a stand-in for upstream's bridge (`AttentionRig`). Fixtures are fictional, in the hooks docs' and codex-rs's shapes.
@MainActor
@Suite(.serialized)
struct AttentionEndToEndTests {
    // MARK: Fixtures

    static let push: [String: Any] = ["command": "git push origin main", "description": "Push the branch"]
    static let questions: [String: Any] = ["questions": [
        ["question": "Which branch?", "header": "Branch", "multiSelect": false,
         "options": [["label": "main", "description": "The default."], ["label": "dev", "description": "The next one."]]],
    ]]

    static func transcript(_ rig: AttentionRig, _ id: String) -> String {
        rig.folder.appendingPathComponent("projects/-tmp-project/\(id).jsonl").path
    }

    static func claude(_ rig: AttentionRig, _ event: String, session: String = "s1", tool: String? = nil, input: [String: Any]? = nil,
                       toolUseID: String? = nil, agent: String? = nil, mode: String = "default",
                       extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["hook_event_name": event, "session_id": session, "cwd": "/tmp/project",
                                     "transcript_path": transcript(rig, session), "permission_mode": mode]
        if let tool { object["tool_name"] = tool }
        if let input { object["tool_input"] = input }
        if let toolUseID { object["tool_use_id"] = toolUseID }
        if let agent {
            object["agent_id"] = agent
            object["agent_type"] = "worker"
        }
        return object.merging(extra) { $1 }
    }

    static func codex(_ event: String, session: String = "c1", turn: String = "turn-1", agent: String? = nil, transcript: String,
                      input: [String: Any] = ["command": "git push origin main"], mode: String = "default",
                      extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["hook_event_name": event, "session_id": session, "turn_id": turn, "cwd": "/tmp/project",
                                     "transcript_path": transcript, "model": "gpt-6", "permission_mode": mode]
        if event == "PermissionRequest" || event == "PreToolUse" {
            object["tool_name"] = "Bash"
            object["tool_input"] = input
        }
        if let agent {
            object["agent_id"] = agent
            object["agent_type"] = "explorer"
        }
        return object.merging(extra) { $1 }
    }

    static func started(_ id: String, tool: AgentTool = .claudeCode, transcript: String? = nil, terminal: String = "Terminal") -> AgentEvent {
        .sessionStarted(SessionStarted(
            sessionID: id, title: tool == .codex ? "Codex · project" : "Claude · project", tool: tool, origin: .live,
            initialPhase: .running, summary: "Started.", timestamp: .now,
            jumpTarget: JumpTarget(terminalApp: terminal, workspaceName: "project", paneTitle: "agent", workingDirectory: "/tmp/project"),
            codexMetadata: tool == .codex ? CodexSessionMetadata(transcriptPath: transcript) : nil,
            claudeMetadata: tool == .claudeCode ? ClaudeSessionMetadata(transcriptPath: transcript, startupSource: .startup) : nil))
    }

    /// UserPromptSubmit as the bridge reports it: the session's metadata as the bridge keeps it (merged: the
    /// transcript path stays), then the prompt's activity.
    static func prompt(_ id: String, _ text: String, tool: AgentTool = .claudeCode, transcript: String? = nil) -> [AgentEvent] {
        let metadata: AgentEvent = tool == .codex
            ? .sessionMetadataUpdated(SessionMetadataUpdated(sessionID: id, codexMetadata: CodexSessionMetadata(
                transcriptPath: transcript, lastUserPrompt: text), timestamp: .now))
            : .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: transcript, lastUserPrompt: text), timestamp: .now))
        return [metadata, .activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Prompt: " + text, phase: .running, timestamp: .now))]
    }

    static func running(_ id: String, _ summary: String = "Running Bash: git push origin main") -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: summary, phase: .running, timestamp: .now))
    }

    /// Stop as the bridge reports it: its merged metadata (the last prompt it saw, which may be machine text) with
    /// the reply, then the completion.
    static func stop(_ id: String, lastPrompt: String?, message: String = "Done.") -> [AgentEvent] {
        [.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: lastPrompt, lastAssistantMessage: message), timestamp: .now)),
         .sessionCompleted(SessionCompleted(sessionID: id, summary: message, timestamp: .now))]
    }

    /// A Claude session its SessionStart and first prompt began, through the helper.
    private func begin(_ rig: AttentionRig, _ id: String = "s1", prompt text: String = "fix the tests", entrypoint: String = "cli") async {
        await rig.finished(Self.claude(rig, "SessionStart", session: id, extra: ["source": "startup"]), entrypoint: entrypoint,
                           events: [Self.started(id, transcript: Self.transcript(rig, id))])
        await rig.finished(Self.claude(rig, "UserPromptSubmit", session: id, extra: ["prompt": text]), entrypoint: entrypoint,
                           events: Self.prompt(id, text, transcript: Self.transcript(rig, id)))
    }

    /// CL2's request: its PreToolUse, then the PermissionRequest, held by the broker.
    private func askBash(_ rig: AttentionRig, entrypoint: String = "cli", agent: String? = nil) async -> HelperRun {
        await rig.finished(Self.claude(rig, "PreToolUse", tool: "Bash", input: Self.push, toolUseID: "U1", agent: agent),
                           entrypoint: entrypoint, events: [Self.running("s1")])
        let count = rig.engine.openRequests.count
        let run = rig.hook(Self.claude(rig, "PermissionRequest", tool: "Bash", input: Self.push, agent: agent), entrypoint: entrypoint)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        return run
    }

    private func notice(_ rig: AttentionRig, entrypoint: String = "cli", agent: String? = nil) async {
        await rig.finished(Self.claude(rig, "Notification", agent: agent,
                                       extra: ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]),
                           entrypoint: entrypoint)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The decision the helper printed for Claude (`hookSpecificOutput.decision`).
    private static func decision(_ result: HelperRun.Result?) -> [String: Any]? {
        guard let result, let output = object(result.stdout)?["hookSpecificOutput"] as? [String: Any] else { return nil }
        return output["decision"] as? [String: Any]
    }

    // MARK: Claude

    /// CL2: held; nothing drawn before Claude's notice; then "!", an answerable card and one sound; the island's Allow
    /// is printed by the helper with the original input; the row runs on, no Done.
    @Test
    func cl2TheIslandsAllowReachesTheHelper() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let run = await askBash(rig)
        #expect(run.isRunning)
        rig.advance(5)
        #expect(rig.row("s1")?.bucket == .running && rig.card("s1") == nil && rig.needsYou.isEmpty)
        rig.advance(1)
        await notice(rig)
        #expect(rig.row("s1")?.bucket == .needsYou && rig.row("s1")?.glyph == .bang && rig.needsYou.count == 1)
        guard case let .approval(card)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.request?.answerable == true && card.tool == "Bash" && card.request?.more == 0)
        await rig.model.decide("s1", .allowOnce)
        let result = await run.result(within: 30)
        #expect(result?.status == 0)
        let decision = try #require(Self.decision(result))
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedInput"] as? [String: Any])?["command"] as? String == "git push origin main")
        await rig.settle()
        #expect(rig.row("s1")?.bucket == .running && rig.card("s1") == nil)
        rig.advance(10)
        #expect(rig.dones.isEmpty)
    }

    /// CL3, R4 (second half): answered at the keyboard within seconds: never drawn, no sound; the helper ends at 8 s
    /// with no decision.
    @Test
    func cl3AQuickKeyboardAnswerIsNeverDrawnAndTheHelperEndsSilent() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let run = await askBash(rig)
        rig.advance(2)
        #expect(run.isRunning)
        rig.advance(6)
        let result = await run.result(within: 30)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true)
        #expect(rig.row("s1")?.bucket == .running && rig.signals.isEmpty)
    }

    /// CL6: a subagent's request: the helper ends silent within the ack; read-only on the parent once confirmed.
    @Test
    func cl6ASubagentsHelperEndsAtOnceAndItsCardIsReadOnly() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let run = await askBash(rig, agent: "w1")
        let result = await run.result(within: 30)
        let released = await rig.released(1)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true && released)
        rig.advance(6)
        await notice(rig, agent: "w1")
        guard case let .approval(card)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.request?.answerable == false && card.request?.agentType == "worker" && card.request?.dismissable == true)
        #expect(card.alwaysAllowLabel == nil && !card.canStop)
        rig.model.dismissRequest("s1")
        #expect(rig.card("s1") == nil && rig.row("s1")?.bucket == .running)
    }

    /// CL7: a question held and answered on the island: the helper prints allow with `answers`.
    @Test
    func cl7TheIslandsAnswersReachTheHelper() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let count = rig.engine.openRequests.count
        let run = rig.hook(Self.claude(rig, "PermissionRequest", tool: "AskUserQuestion", input: Self.questions, mode: "bypassPermissions"))
        await rig.waitUntil { rig.engine.openRequests.count > count }
        rig.advance(6)
        await notice(rig)
        #expect(rig.row("s1")?.glyph == .ques)
        guard case let .question(card)? = rig.card("s1") else {
            Issue.record("no question card")
            return
        }
        #expect(card.request?.answerable == true && card.options.map(\.label) == ["main", "dev"])
        #expect(rig.model.answerQuestion("s1", .option(1)))
        let result = await run.result(within: 30)
        let decision = try #require(Self.decision(result))
        #expect(decision["behavior"] as? String == "allow")
        let answers = (decision["updatedInput"] as? [String: Any])?["answers"] as? [String: String]
        #expect(answers == ["Which branch?": "dev"])
    }

    /// CL15, CL16: a headless run and `dontAsk`: the helper ends at once, nothing is shown.
    @Test
    func cl15cl16HeadlessRequestsEndAtOnce() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        for (index, (entrypoint, mode)) in [("sdk-cli", "default"), ("cli", "dontAsk")].enumerated() {
            let result = await rig.hook(Self.claude(rig, "PermissionRequest", tool: "Bash", input: Self.push, mode: mode),
                                        entrypoint: entrypoint).result(within: 30)
            let released = await rig.released(index + 1)
            #expect(result?.status == 0 && result?.stdout.isEmpty == true && released)
        }
        rig.advance(30)
        #expect(rig.engine.openRequests.isEmpty && rig.row("s1")?.bucket == .running)
    }

    /// CL18: quitting while a request is held: the helper ends at once with no decision.
    @Test
    func cl18QuittingEndsTheHeldHelper() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let run = await askBash(rig)
        rig.engine.stop()
        let result = await run.result(within: 30)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true)
    }

    /// CL20, C16: an app with no broker: the helper runs upstream's; the bridge holds the request; the island answers
    /// through the bridge, and the helper prints it.
    @Test
    func cl20WithNoBrokerTheBridgeHoldsAndTheIslandAnswers() async throws {
        let rig = try await AttentionRig(broker: false)
        defer { rig.stop() }
        await begin(rig)
        await rig.finished(Self.claude(rig, "PreToolUse", tool: "Bash", input: Self.push, toolUseID: "U1"), events: [Self.running("s1")])
        let request = PermissionRequest(title: "Allow Bash", summary: "Claude Code wants to run Bash.", affectedPath: "git push origin main",
                                        toolName: "Bash")
        let run = rig.hook(Self.claude(rig, "PermissionRequest", tool: "Bash", input: Self.push),
                           events: [.permissionRequested(PermissionRequested(sessionID: "s1", request: request, timestamp: .now))])
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        #expect(rig.upstream.current?.commands.contains { $0.event == "PermissionRequest" } == true)
        rig.advance(6)
        await notice(rig)
        guard case let .approval(card)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.request?.answerable == true)
        await rig.model.decide("s1", .allowOnce)
        let result = await run.result(within: 30)
        #expect(Self.decision(result)?["behavior"] as? String == "allow")
        await rig.settle()
        #expect(rig.card("s1") == nil)
    }

    /// CL22 (C12, P169): an island No reads running (Denied · Bash), No and stop reads interrupted; never a Done.
    @Test
    func cl22AnIslandNoIsNeverADone() async throws {
        for stop in [false, true] {
            let rig = try await AttentionRig()
            defer { rig.stop() }
            await begin(rig)
            let run = await askBash(rig)
            rig.advance(6)
            await notice(rig)
            await rig.model.decide("s1", stop ? .denyAndStop : .deny)
            let decision = try #require(Self.decision(await run.result(within: 30)))
            #expect(decision["behavior"] as? String == "deny" && decision["message"] as? String == ApprovalChoices.denyMessage)
            #expect((decision["interrupt"] as? Bool ?? false) == stop)
            await rig.settle()
            #expect(rig.row("s1")?.status == (stop ? .interrupted : .denied(tool: "Bash")), "stop: \(stop)")
            rig.advance(10)
            // No Done: no signal, and no finished card (an interrupted turn's card says so when the row is opened).
            #expect(rig.dones.isEmpty, "stop: \(stop)")
            if stop {
                guard case let .done(card)? = rig.card("s1") else {
                    Issue.record("no interrupted card")
                    continue
                }
                #expect(card.interrupted && !card.failed)
            } else {
                #expect(rig.card("s1") == nil)
            }
        }
    }

    /// R4 (first half): a desktop question in bypass, answered in the app at 90 s: "?" from 6 s, gone at 90 with its
    /// helper.
    @Test
    func r4ADesktopQuestionAnsweredInTheAppEndsWithItsHelper() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig, entrypoint: "claude-desktop")
        await rig.finished(Self.claude(rig, "PreToolUse", tool: "AskUserQuestion", input: Self.questions, toolUseID: "UQ",
                                       mode: "bypassPermissions"), entrypoint: "claude-desktop",
                           events: [Self.running("s1", "Running AskUserQuestion")])
        let run = rig.hook(Self.claude(rig, "PermissionRequest", tool: "AskUserQuestion", input: Self.questions, mode: "bypassPermissions"),
                           entrypoint: "claude-desktop")
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        rig.advance(6)
        await notice(rig, entrypoint: "claude-desktop")
        #expect(rig.row("s1")?.glyph == .ques && rig.needsYou.count == 1)
        guard case let .question(card)? = rig.card("s1") else {
            Issue.record("no question card")
            return
        }
        #expect(card.request?.place == .claudeApp)
        rig.advance(84)
        await rig.finished(Self.claude(rig, "PostToolUse", tool: "AskUserQuestion", input: Self.questions, toolUseID: "UQ",
                                       mode: "bypassPermissions"), entrypoint: "claude-desktop",
                           events: [Self.running("s1", "AskUserQuestion finished.")])
        let result = await run.result(within: 30)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true)
        #expect(rig.card("s1") == nil && rig.row("s1")?.bucket == .running)
    }

    /// R2 (the second screenshot row): a `<task-notification>` turn never becomes the row's prompt, and the Done card
    /// says the last real reply.
    @Test
    func r2ATaskNotificationIsNeverTheRowsPrompt() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig, prompt: "summarise the figures")
        let machine = "<task-notification>\n<task-id>b7x2</task-id>\n<status>completed</status>\n<summary>Background command finished</summary>\n</task-notification>"
        await rig.finished(Self.claude(rig, "UserPromptSubmit", extra: ["prompt": machine]),
                           events: Self.prompt("s1", machine, transcript: Self.transcript(rig, "s1")))
        #expect(rig.row("s1")?.lastPrompt == "summarise the figures")
        await rig.finished(Self.claude(rig, "Stop"), events: Self.stop("s1", lastPrompt: machine, message: "The figures are summarised in notes.md."))
        rig.advance(2)
        #expect(rig.row("s1")?.lastPrompt?.hasPrefix("<") == false)
        guard case let .done(card)? = rig.card("s1") else {
            Issue.record("no done card")
            return
        }
        #expect(card.message == "The figures are summarised in notes.md.")
        #expect(rig.dones == [.done(sessionID: "s1")])
    }

    // MARK: Codex

    /// A Codex session its SessionStart and prompt began through the helper, with its rollout (a scratch file) watched by
    /// a real tracker, wired as the runtime wires it.
    private func beginCodex(_ rig: AttentionRig, _ id: String = "c1", app: Bool = false, reviewer: String = "user",
                            lines: [String] = []) async throws -> (url: URL, tracker: CodexRolloutTracker) {
        let url = rig.folder.appendingPathComponent("rollout-\(id).jsonl")
        let meta = RolloutLines.line("session_meta", ["id": id, "cwd": "/tmp/project", "originator": app ? "codex_desktop" : "codex_cli_rs",
                                                      "source": app ? "vscode" : "cli"], at: 0)
        try RolloutLines.text([meta, RolloutLines.turnContext(reviewer: reviewer), RolloutLines.event("task_started", at: 0)] + lines)
            .write(to: url, atomically: true, encoding: .utf8)
        await rig.finished(Self.codex("SessionStart", session: id, transcript: url.path), source: "codex", entrypoint: nil,
                           events: [Self.started(id, tool: .codex, transcript: url.path)])
        await rig.finished(Self.codex("UserPromptSubmit", session: id, transcript: url.path, extra: ["prompt": "tidy the paper"]),
                           source: "codex", entrypoint: nil, events: Self.prompt(id, "tidy the paper", tool: .codex, transcript: url.path))
        if app, var thread = rig.engine.state.session(id: id) {
            thread.isCodexAppSession = true
            rig.engine.replace(thread)
        }
        let tracker = CodexRolloutTracker(pollInterval: 60)
        tracker.attentionHandler = { [weak engine = rig.engine] update in
            Task { @MainActor in engine?.ingestCodexAttention(update) }
        }
        tracker.eventHandler = { [weak engine = rig.engine] event in
            Task { @MainActor in engine?.ingest(event, ingress: .rollout) }
        }
        tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: id, transcriptPath: url.path)])
        tracker.waitUntilIdle()
        await rig.settle()
        return (url, tracker)
    }

    /// When a request's call starts, in `RolloutLines`' seconds: a second before the request, which the engine opens at
    /// the earlier of its clock and the broker's real time. A call more than 5 s after its request is never its call
    /// (C7), and `RolloutLines`' times count from their first use in the run, which a slow rig start in a loaded full
    /// run puts well after the engine's clock (as `ReplayCodexCodeModeTests.beforeNow`); `advance` puts the engine's
    /// clock ahead of real time.
    static func askedAt(_ rig: AttentionRig) -> Int {
        Int(min(rig.now, Date()).timeIntervalSince(RolloutLines.start).rounded(.down)) - 1
    }

    private func append(_ lines: [String], to watch: (url: URL, tracker: CodexRolloutTracker), _ rig: AttentionRig,
                        sessionID: String = "c1") async {
        let handle = try! FileHandle(forWritingTo: watch.url)
        handle.seekToEndOfFile()
        handle.write(Data(RolloutLines.text(lines).utf8))
        try? handle.close()
        watch.tracker.pollNow(sessionID: sessionID)
        watch.tracker.waitUntilIdle()
        await rig.settle()
    }

    /// CX1: the helper ends at once (Codex shows its own prompt); a read-only "!" at 8 s; its call's output ends it.
    @Test
    func cx1ACodexApprovalIsHandedBackAndShownReadOnly() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        let watch = try await beginCodex(rig)
        defer { watch.tracker.stop() }
        let result = await rig.hook(Self.codex("PermissionRequest", transcript: watch.url.path), source: "codex", entrypoint: nil)
            .result(within: 30)
        let released = await rig.released(1)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true && released)
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        #expect(rig.upstream.current?.commands.contains { $0.event == "PermissionRequest" } == false)
        let asked = Self.askedAt(rig)
        rig.advance(8)
        guard case let .approval(card)? = rig.card("c1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.request?.answerable == false && card.request?.place == .terminal && rig.needsYou.count == 1)
        await append([RolloutLines.call("exec_command", "call_1", #"{"cmd":"git push origin main"}"#, at: asked),
                      RolloutLines.output("call_1", "ok", at: asked + 9)], to: watch, rig)
        await rig.waitUntil { rig.card("c1") == nil }
        #expect(rig.card("c1") == nil && rig.row("c1")?.bucket != .needsYou)
    }

    /// CX9, CX18: a Codex PreToolUse and a child's hooks never reach upstream's bridge; the root's rollout path and
    /// prompt stay its own.
    @Test
    func cx9cx18NeitherAPreToolUseNorAChildsHookReachesUpstream() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        let watch = try await beginCodex(rig)
        defer { watch.tracker.stop() }
        let before = rig.upstream.current?.commands.count ?? 0
        let child = rig.folder.appendingPathComponent("rollout-k1.jsonl").path
        for object in [Self.codex("PreToolUse", transcript: watch.url.path, extra: ["tool_use_id": "call_1"]),
                       Self.codex("UserPromptSubmit", agent: "k1", transcript: child, extra: ["prompt": "child task"])] {
            let result = await rig.finished(object, source: "codex", entrypoint: nil)
            #expect(result.status == 0 && result.stdout.isEmpty)
        }
        #expect(rig.upstream.current?.commands.count == before)
        #expect(rig.engine.state.session(id: "c1")?.codexMetadata?.transcriptPath == watch.url.path)
        #expect(rig.row("c1")?.lastPrompt == "tidy the paper" && rig.engine.openRequests.isEmpty)
    }

    /// CX17 (C4): with no broker, upstream's helper holds Codex's request for the bridge: answerable, sounded even with
    /// Codex in front, and the island's answer reaches the helper.
    @Test
    func cx17TheBridgesCodexRequestIsAnsweredOnTheIsland() async throws {
        let rig = try await AttentionRig(broker: false, suppress: true)
        defer { rig.stop() }
        let watch = try await beginCodex(rig, app: true)
        defer { watch.tracker.stop() }
        rig.front.update { $0 = ExactJump.codexBundleID }
        let request = PermissionRequest(title: "Run Bash command", summary: "Codex wants to run: git push origin main",
                                        affectedPath: "git push origin main", toolName: "Bash")
        let run = rig.hook(Self.codex("PermissionRequest", transcript: watch.url.path), source: "codex", entrypoint: nil,
                           events: [.permissionRequested(PermissionRequested(sessionID: "c1", request: request, timestamp: .now))])
        await rig.waitUntil { rig.card("c1") != nil }
        #expect(rig.needsYou.count == 1)
        guard case let .approval(card)? = rig.card("c1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.request?.answerable == true && card.request?.dismissable == false)
        rig.advance(30)
        #expect(rig.card("c1") != nil)
        await rig.model.decide("c1", .allowOnce)
        let result = await run.result(within: 30)
        #expect(result?.printed.contains("allow") == true)
    }

    /// R1 (the first screenshot): a Codex app thread asks an async question and reasons on: the row says Question with
    /// "?", one sound, a read-only card with the question and its options that opens the thread; the reply envelope
    /// ends it and never becomes the row's prompt; the Stop is one Done. Unanswered, the turn's end ends it.
    @Test
    func r1TheCodexAppsAsyncQuestionShowsUntilItsReply() async throws {
        for replied in [true, false] {
            let rig = try await AttentionRig()
            defer { rig.stop() }
            let watch = try await beginCodex(rig, app: true)
            defer { watch.tracker.stop() }
            let arguments = #"{"questions":[{"title":"Should I also remove Figure N?","options":["Remove it","Keep it","Move it to the appendix"]}]}"#
            await append([RolloutLines.call("request_user_input_async", "call_A1", arguments),
                          RolloutLines.output("call_A1", #"{"accepted":true}"#),
                          RolloutLines.item("reasoning", ["summary": [["type": "summary_text", "text": "**Checking figures**"]]], at: 3)],
                         to: watch, rig)
            await rig.waitUntil { rig.card("c1") != nil }
            let row = try #require(rig.row("c1"))
            #expect(row.glyph == .ques && row.status == .question && row.bucket == .needsYou && rig.needsYou.count == 1)
            guard case let .question(card)? = rig.card("c1") else {
                Issue.record("no question card")
                return
            }
            #expect(card.question == "Should I also remove Figure N?" && card.options.map(\.label) == ["Remove it", "Keep it", "Move it to the appendix"])
            #expect(card.request?.answerable == false && card.request?.place == .codexApp)
            if replied {
                let envelope = #"<send_user_message_question_reply>[{"answer":"Keep it","question":"Should I also remove Figure N?","questionItemId":"[\"request_user_input_async\",\"call_A1\",0]"}]</send_user_message_question_reply>"#
                await rig.finished(Self.codex("UserPromptSubmit", transcript: watch.url.path, extra: ["prompt": envelope]), source: "codex",
                                   entrypoint: nil, events: Self.prompt("c1", envelope, tool: .codex, transcript: watch.url.path))
                #expect(rig.card("c1") == nil && rig.row("c1")?.lastPrompt == "tidy the paper")
                await rig.finished(Self.codex("Stop", transcript: watch.url.path, extra: ["last_assistant_message": "Kept it."]),
                                   source: "codex", entrypoint: nil,
                                   events: [.sessionCompleted(SessionCompleted(sessionID: "c1", summary: "Kept it.", timestamp: .now))])
                rig.advance(2)
                #expect(rig.dones == [.done(sessionID: "c1")])
            } else {
                // The turn's end closes the question: its card goes (the turn's own Done card may take its place).
                await append([RolloutLines.event("task_complete", at: 9)], to: watch, rig)
                await rig.waitUntil { if case .question? = rig.card("c1") { false } else { true } }
                if case .question? = rig.card("c1") { Issue.record("the question card stayed") }
                #expect(rig.row("c1")?.glyph != .ques && rig.engine.openRequests.isEmpty)
            }
        }
    }

    /// R3 (the second message, Codex): an app thread keeps working while two subagents ask 40 s apart: both helpers end
    /// at once, two read-only entries from 8 s, each ended by its own child's output; the parent's work is never "!";
    /// the root's rollout is never repointed. On auto review nothing is drawn at all.
    @Test
    func r3SubagentsOfAWorkingAppThreadAreReadOnlyAndCloseOnTheirOwn() async throws {
        for reviewer in ["user", "auto_review"] {
            let rig = try await AttentionRig()
            defer { rig.stop() }
            let watch = try await beginCodex(rig, app: true, reviewer: reviewer)
            defer { watch.tracker.stop() }
            var children: [URL] = []
            for (index, child) in ["k1", "k2"].enumerated() {
                if index == 1 { rig.advance(40) }
                let url = rig.folder.appendingPathComponent("rollout-\(child).jsonl")
                try RolloutLines.text([RolloutLines.line("session_meta", ["id": child, "cwd": "/tmp/project", "source": ["subagent": "spawn"]], at: 0),
                                       RolloutLines.turnContext(reviewer: reviewer), RolloutLines.event("task_started", at: 0),
                                       RolloutLines.call("exec_command", "call_\(child)", #"{"cmd":"make \#(child)"}"#,
                                                         at: Self.askedAt(rig))])
                    .write(to: url, atomically: true, encoding: .utf8)
                children.append(url)
                let result = await rig.hook(Self.codex("PermissionRequest", agent: child, transcript: url.path,
                                                       input: ["command": "make \(child)"]), source: "codex", entrypoint: nil)
                    .result(within: 30)
                let released = await rig.released(index + 1)
                #expect(result?.stdout.isEmpty == true && released)
                // The parent works on meanwhile.
                await append([RolloutLines.call("exec_command", "call_p\(index)", #"{"cmd":"ls"}"#),
                              RolloutLines.output("call_p\(index)", "ok")], to: watch, rig)
            }
            await rig.settle()
            rig.advance(9)
            await rig.settle()
            #expect(rig.engine.state.session(id: "c1")?.codexMetadata?.transcriptPath == watch.url.path)
            if reviewer == "auto_review" {
                #expect(rig.engine.openRequests.isEmpty && rig.row("c1")?.glyph != .bang && rig.signals.isEmpty)
                continue
            }
            await rig.waitUntil { rig.engine.attentionQueue(for: "c1").count == 2 }
            guard case let .approval(card)? = rig.card("c1") else {
                Issue.record("no approval card")
                return
            }
            #expect(card.request?.answerable == false && card.request?.agentType == "explorer" && card.request?.more == 1)
            for (index, url) in children.enumerated() {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(Data(RolloutLines.text([RolloutLines.output("call_k\(index + 1)", "ok")]).utf8))
                try handle.close()
                let request = rig.engine.attentionQueue(for: "c1").first
                if let request { rig.engine.childRollouts?.pollNow(sessionID: request.id) }
                rig.engine.childRollouts?.waitUntilIdle()
                await rig.waitUntil { rig.engine.attentionQueue(for: "c1").count == 1 - index }
            }
            #expect(rig.card("c1") == nil && rig.row("c1")?.glyph != .bang)
        }
    }
}

/// Codex rollout lines in the shape Codex writes them (codex-rs `rollout_payload.rs`), for the end-to-end suite.
enum RolloutLines {
    static let start = Date()

    static func stamp(_ second: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start.addingTimeInterval(TimeInterval(second)))
    }

    static func line(_ type: String, _ payload: [String: Any], at second: Int) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return #"{"timestamp":"\#(stamp(second))","type":"\#(type)","payload":\#(String(decoding: data, as: UTF8.self))}"#
    }

    static func turnContext(reviewer: String) -> String {
        line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6", "approval_policy": "on-request", "approvals_reviewer": reviewer], at: 0)
    }

    static func event(_ type: String, _ fields: [String: Any] = [:], at second: Int) -> String {
        line("event_msg", fields.merging(["type": type]) { $1 }, at: second)
    }

    static func item(_ type: String, _ fields: [String: Any] = [:], at second: Int) -> String {
        line("response_item", fields.merging(["type": type]) { $1 }, at: second)
    }

    static func call(_ name: String, _ callID: String, _ arguments: String, at second: Int = 1) -> String {
        item("function_call", ["name": name, "arguments": arguments, "call_id": callID], at: second)
    }

    static func output(_ callID: String, _ output: String, at second: Int = 2) -> String {
        item("function_call_output", ["call_id": callID, "output": output], at: second)
    }

    static func text(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }
}
