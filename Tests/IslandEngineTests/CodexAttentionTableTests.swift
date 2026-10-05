import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// The Codex truth table (§2.2 and §5.1 CX1-CX20 of the needs-you design) and the other agents' rows (OC1, OC2,
/// OT1-OT3), through the engine: hooks as the superset helper hands them over, rollout lines as the tracker folds
/// them, and upstream's bridge events. Child rollouts are fixture files in a temporary folder.
@MainActor
@Suite(.serialized)
struct CodexAttentionTableTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests

    static let turn = R.event("task_started", ["model_context_window": 272_000], at: 0)

    static func reviewer(_ name: String, at second: Int = 0) -> String {
        R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6", "approval_policy": "on-request",
                                "approvals_reviewer": name], at: second)
    }

    static func exec(_ callID: String, _ command: String = "git push origin main", at second: Int = 1) -> String {
        C.call("exec_command", callID, arguments: #"{"cmd":"\#(command)"}"#, at: second)
    }

    /// A Codex session known to the engine, with its rollout's turn and reviewer read.
    private func codexScene(reviewer: String = "user", app: Bool = false, suppress: Bool = false, frontmost: Bool = false) -> S {
        let s = S(suppress: suppress, frontmost: frontmost)
        s.begin("c1", tool: .codex)
        if app {
            var thread = s.engine.state.session(id: "c1")!
            thread.isCodexAppSession = true
            s.engine.replace(thread)
        }
        s.rollout("c1", [R.meta(id: "c1"), Self.reviewer(reviewer), Self.turn])
        return s
    }

    private func folder() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("juice-attn-\(UUID().uuidString.prefix(8))",
                                                                                     isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Approvals the new helper hands back to Codex

    /// CX1: released at once; read-only "!" and Open (terminal) at 8 s with one sound; closed by its call's output.
    @Test
    func cx1AnApprovalIsReleasedAndShownReadOnlyAtEightSeconds() throws {
        let s = codexScene()
        let id = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        #expect(s.broker.held.current.isEmpty)
        s.at(7.9)
        #expect(s.glyph("c1") == nil)
        s.at(8)
        let head = try #require(s.head("c1"))
        #expect(head.id == id && !head.isAnswerable && head.place == .terminal && s.glyph("c1") == "!")
        #expect(s.needsYou == [.needsYou(sessionID: "c1")])
        s.rollout("c1", [Self.exec("call_1", at: 1)])
        #expect(s.request(id)?.callID == "call_1")
        s.at(30)
        s.rollout("c1", [C.output("call_1", "ok", at: 30)])
        #expect(s.glyph("c1") == nil && !s.isOpen(id))
    }

    /// CX1: a call and its output read together (one tracker read) still close the approval it matched.
    @Test
    func cx1ACallAndItsOutputInOneReadCloseTheApproval() throws {
        let s = codexScene()
        let id = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        s.at(8)
        s.rollout("c1", [Self.exec("call_1", at: 1), C.output("call_1", "ok", at: 9)])
        #expect(!s.isOpen(id) && s.glyph("c1") == nil)
    }

    /// CX2, CX3: an auto-review thread and a full-access thread: nothing shown.
    @Test
    func cx2cx3WhatCodexSettlesItselfIsNeverShown() {
        let review = codexScene(reviewer: "auto_review", app: true)
        review.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil)
        let bypass = codexScene()
        bypass.hook(S.codex("PermissionRequest", mode: "bypassPermissions"), source: "codex", entrypoint: nil)
        for s in [review, bypass] {
            s.at(30)
            #expect(s.engine.openRequests.isEmpty && s.signals.isEmpty && s.broker.held.current.isEmpty)
        }
        #expect(review.engine.attentionTally.notShown["autoReview"] == 1)
        #expect(bypass.engine.attentionTally.notShown["bypass"] == 1)
    }

    /// CX4, CX12 (C5): subagents' requests sit on the parent row, each closed by its own child's rollout, never by the
    /// parent's work or its Stop; nothing is held.
    @Test
    func cx4cx12SubagentRequestsCloseOnTheirOwnRollouts() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = codexScene(app: true)
        var ids: [String] = []
        for child in ["k1", "k2"] {
            if child == "k2" { s.at(1) }
            let url = dir.appendingPathComponent("rollout-\(child).jsonl")
            try R.text([R.meta(id: child), Self.reviewer("user"), Self.turn, Self.exec("call_\(child)", "make \(child)")])
                .write(to: url, atomically: true, encoding: .utf8)
            let id = try #require(s.hook(S.codex("PermissionRequest", input: ["command": "make \(child)"], agent: child,
                                                 transcript: url.path), source: "codex", entrypoint: nil))
            ids.append(id)
        }
        await s.settle { s.engine.openRequests.count == 2 }
        #expect(s.broker.held.current.isEmpty && s.engine.openRequests.allSatisfy { $0.agentID != nil })
        s.at(9)
        #expect(s.engine.attentionQueue(for: "c1").map(\.id) == ids && s.head("c1")?.agentType == "explorer")
        s.engine.childRollouts?.waitUntilIdle()
        await s.settle { ids.allSatisfy { s.request($0)?.callID != nil } }
        #expect(s.request(ids[0])?.callID == "call_k1" && s.request(ids[1])?.callID == "call_k2")
        // The parent's own work and its Stop leave them.
        s.rollout("c1", [Self.exec("call_p"), C.output("call_p", "ok")])
        s.bridge(F.completed("c1", at: s.clock.current))
        #expect(s.engine.openRequests.count == 2 && s.glyph("c1") == "!")
        R.append(R.text([C.output("call_k2", "ok", at: 20)]), to: dir.appendingPathComponent("rollout-k2.jsonl"))
        s.engine.childRollouts?.pollNow(sessionID: ids[1])
        s.engine.childRollouts?.waitUntilIdle()
        await s.settle { !s.isOpen(ids[1]) }
        #expect(s.isOpen(ids[0]) && !s.isOpen(ids[1]))
        R.append(R.text([R.event("task_complete", at: 21)]), to: dir.appendingPathComponent("rollout-k1.jsonl"))
        s.engine.childRollouts?.pollNow(sessionID: ids[0])
        s.engine.childRollouts?.waitUntilIdle()
        await s.settle { s.engine.openRequests.isEmpty }
        #expect(s.engine.openRequests.isEmpty)
    }

    // MARK: Questions (P160)

    /// CX5: Plan mode's blocking question: "?" read-only with its questions and options; closed by its output, an
    /// abort or the turn's end.
    @Test
    func cx5ABlockingQuestionIsShownUntilItsOutputOrTurnEnd() throws {
        for end in [C.output("call_Q1", #"{"answers":{"figure":{"answers":["Keep it"]}}}"#, at: 9),
                    R.event("turn_aborted", ["reason": "interrupted"], at: 9), R.event("task_complete", at: 9)] {
            let s = codexScene()
            s.rollout("c1", [C.call("request_user_input", "call_Q1", arguments: C.blockingArguments)])
            let head = try #require(s.head("c1"))
            #expect(s.glyph("c1") == "?" && !head.isAnswerable && head.source == .rollout)
            let prompt = try #require(head.questionPrompt)
            #expect(prompt.questions.first?.question == "Remove the second figure too?")
            #expect(prompt.questions.first?.options.map(\.label) == ["Remove it (Recommended)", "Keep it"])
            #expect(s.needsYou.count == 1)
            s.rollout("c1", [end])
            #expect(s.glyph("c1") == nil, "\(end)")
        }
    }

    /// CX6, CX10: the async question: "?" and "Question" while the model reasons on; its reply envelope (through the
    /// UserPromptSubmit hook at once, or the rollout) closes it and is never the row's prompt; so do the next human
    /// prompt and the turn's end.
    @Test
    func cx6cx10TheAsyncQuestionShowsUntilItsReply() throws {
        func asked() -> S {
            let s = codexScene(app: true)
            s.bridge(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: "c1", codexMetadata: CodexSessionMetadata(
                lastUserPrompt: "tidy the paper"), timestamp: s.clock.current)))
            s.rollout("c1", [C.call("request_user_input_async", "call_A1", arguments: C.asyncArguments),
                             C.output("call_A1", #"{"accepted":true}"#)])
            s.engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "c1", summary: "Thinking.", phase: .running,
                                                                    timestamp: s.clock.current)), ingress: .rollout)
            return s
        }
        let s = asked()
        let session = try #require(s.engine.state.session(id: "c1"))
        #expect(s.glyph("c1") == "?" && s.engine.statusWord(for: session) == .question && s.needsYou.count == 1)
        // The reply, through the hook: closed at once; the row's prompt stays the owner's.
        let envelope = C.reply(["call_A1"], wrapped: true)
        s.bridge(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: "c1", codexMetadata: CodexSessionMetadata(
            lastUserPrompt: envelope), timestamp: s.clock.current)), F.prompt("c1", envelope, at: s.clock.current))
        #expect(s.glyph("c1") == nil && s.engine.openRequests.isEmpty)
        #expect(s.engine.state.session(id: "c1")?.codexMetadata?.lastUserPrompt == "tidy the paper")
        // The same reply read from the rollout, a human prompt, the turn's end.
        for end in [R.message("user", C.reply(["call_A1"]), at: 9), R.message("user", "skip that, go on", at: 9),
                    R.event("task_complete", at: 9)] {
            let other = asked()
            #expect(other.glyph("c1") == "?")
            other.rollout("c1", [end])
            #expect(other.glyph("c1") == nil, "\(end)")
        }
        let human = asked()
        human.bridge(F.prompt("c1", "skip that, go on", at: human.clock.current))
        #expect(human.glyph("c1") == nil)
    }

    /// CX7: the call, a legacy agent message and a paginated item for one question: one request.
    @Test
    func cx7OneQuestionInThreeEncodingsIsOneRequest() {
        let s = codexScene()
        s.rollout("c1", [C.call("request_user_input_async", "call_A1", arguments: C.asyncArguments),
                         R.event("agent_message", ["message": "…", "delivery": "async",
                                                   "questions": [["title": "Section E also has a second figure. Should I remove it?",
                                                                  "options": ["Remove it", "Keep it"]]]], at: 1),
                         R.event("item_completed", ["item": ["type": "AgentMessage", "id": "call_A1", "delivery": "async",
                                                             "questions": [["title": "Section E also has a second figure. Should I remove it?",
                                                                            "options": ["Remove it", "Keep it"]]]]], at: 1)])
        #expect(s.engine.openRequests.count == 1 && s.needsYou.count == 1)
    }

    /// CX8, CX9 (P161): a rollout request event and a Codex PreToolUse draw nothing.
    @Test
    func cx8cx9NeitherARolloutRequestEventNorAPreToolUseDraws() {
        let s = codexScene()
        s.rollout("c1", [R.event("exec_approval_request", ["call_id": "call_1", "command": ["git", "push"]], at: 1)])
        s.engine.ingest(.permissionRequested(PermissionRequested(sessionID: "c1", request: PermissionRequest(
            title: "Run Bash command", summary: "", affectedPath: "git push"), timestamp: s.clock.current)), ingress: .rollout)
        s.engine.ingest(.questionAsked(QuestionAsked(sessionID: "c1", prompt: QuestionPrompt(title: "Which?", options: ["a"]),
                                                     timestamp: s.clock.current)), ingress: .rollout)
        s.hook(S.codex("PreToolUse", extra: ["tool_use_id": "call_1"]), source: "codex", entrypoint: nil)
        s.at(30)
        #expect(s.glyph("c1") == nil && s.phase("c1") == .running && s.engine.openRequests.isEmpty && s.signals.isEmpty)
    }

    /// CX11 (C15, C4): with the Codex app in front, its question still sounds; an approval Codex shows itself is shown
    /// and counted, not sounded.
    @Test
    func cx11AQuestionSoundsWithTheCodexAppInFrontAndAReleasedApprovalDoesNot() {
        let s = codexScene(app: true, suppress: true, frontmost: true)
        s.front.update { $0 = ExactJump.codexBundleID }
        s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil)
        s.at(8)
        #expect(s.glyph("c1") == "!" && s.engine.needsYouCount == 1 && s.needsYou.isEmpty)
        s.rollout("c1", [C.call("request_user_input_async", "call_A1", arguments: C.asyncArguments)])
        #expect(s.engine.attentionQueue(for: "c1").count == 2 && s.needsYou == [.needsYou(sessionID: "c1")])
    }

    /// CX13 (C6): a mid-turn switch to auto review, from the tracker or from the rollout's tail: nothing shown.
    @Test
    func cx13AMidTurnSwitchToAutoReviewHidesTheRequest() async throws {
        let applied = R.event("thread_settings_applied", ["thread_settings": ["model": "gpt-6", "approval_policy": "on-request",
                                                                               "approvals_reviewer": "auto_review"]], at: 2)
        let known = codexScene()
        known.rollout("c1", [applied])
        known.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil)
        known.at(30)
        #expect(known.engine.openRequests.isEmpty)

        // Not yet read by the tracker: one bounded read of the rollout's tail.
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-c2.jsonl")
        try R.text([R.meta(id: "c2"), Self.reviewer("user"), Self.turn, applied]).write(to: url, atomically: true, encoding: .utf8)
        let s = S()
        s.begin("c2", tool: .codex, transcript: url.path)
        s.hook(S.codex("PermissionRequest", session: "c2", transcript: url.path), source: "codex", entrypoint: nil)
        await s.settle { s.engine.attentionTally.notShown["autoReview"] == 1 }
        s.at(30)
        #expect(s.engine.openRequests.isEmpty && s.engine.attentionTally.notShown["autoReview"] == 1)
    }

    /// CX14 (C6): after a strict-review grant the turn's requests go to Guardian; the next turn's are shown.
    @Test
    func cx14AStrictReviewTurnShowsNothingUntilTheNextTurn() {
        let s = codexScene()
        s.rollout("c1", [C.call("request_permissions", "call_P", arguments: "{}"),
                         C.output("call_P", #"{"permissions":{},"scope":"turn","strict_auto_review":true}"#)])
        for _ in 0..<3 { s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil) }
        s.at(10)
        #expect(s.engine.openRequests.isEmpty)
        s.rollout("c1", [R.event("task_complete", at: 10), R.event("task_started", at: 11)])
        s.hook(S.codex("PermissionRequest", turn: "turn-2"), source: "codex", entrypoint: nil)
        s.at(20)
        #expect(s.glyph("c1") == "!")
    }

    /// CX15 (C7): a network approval has no call of its own: shown at 8 s, never matched, closed by the turn's end,
    /// by Open or by ✕.
    @Test
    func cx15ANetworkApprovalClosesOnTurnEndOpenOrClose() async throws {
        for ending in ["turn", "open", "close"] {
            let s = codexScene()
            s.rollout("c1", [Self.exec("call_Y", "npm install", at: 0)])
            let id = try #require(s.hook(S.codex("PermissionRequest", input: ["command": "npm install",
                                                                               "description": "network-access registry.example.org"]),
                                         source: "codex", entrypoint: nil))
            s.at(8)
            #expect(s.glyph("c1") == "!" && s.request(id)?.hasOwnCall == false && s.request(id)?.callID == nil)
            s.rollout("c1", [C.output("call_Y", "added 3 packages", at: 9)])
            #expect(s.isOpen(id), "\(ending)")
            switch ending {
            case "turn": s.rollout("c1", [R.event("task_complete", at: 10)])
            case "open": _ = await s.engine.openRequest(requestID: id)
            default: s.engine.dismissRequest(requestID: id)
            }
            #expect(!s.isOpen(id), "\(ending)")
        }
    }

    /// CX16 (C8): a prompt steered into the running turn leaves the approval; a new turn closes it.
    @Test
    func cx16OnlyANewTurnClosesAnApproval() throws {
        let s = codexScene()
        let id = try #require(s.hook(S.codex("PermissionRequest", turn: "turn-1"), source: "codex", entrypoint: nil))
        s.at(8)
        s.hook(S.codex("UserPromptSubmit", turn: "turn-1", extra: ["prompt": "use the staging remote"]), source: "codex", entrypoint: nil)
        #expect(s.isOpen(id))
        s.hook(S.codex("UserPromptSubmit", turn: "turn-2", extra: ["prompt": "now the docs"]), source: "codex", entrypoint: nil)
        #expect(!s.isOpen(id))
    }

    /// CX17 (C4, P166): the old helper holds Codex's request and Codex shows nothing: the card is answerable, sounds
    /// even with Codex in front, has no ✕, and no rollout, window or frontmost rule hides it; only the island's answer
    /// or the hook's end does.
    @Test
    func cx17TheOldHelpersCodexRequestIsNeverHidden() async {
        for ending in ["answer", "disconnect"] {
            let s = codexScene(app: true, suppress: true, frontmost: true)
            s.front.update { $0 = ExactJump.codexBundleID }
            s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil, version: 1)
            s.bridge(F.permission("c1", toolUseID: nil, at: s.clock.current))
            #expect(s.glyph("c1") == "!" && s.head("c1")?.isHeldCodexLegacy == true && s.needsYou.count == 1)
            s.at(9)
            s.rollout("c1", [Self.exec("call_Z", "ls"), C.output("call_Z", "ok"), R.event("task_complete", at: 9)])
            s.engine.dismissRequest(requestID: s.head("c1")?.id ?? "")
            #expect(s.glyph("c1") == "!", "\(ending)")
            if ending == "answer" {
                #expect(await s.engine.approve(sessionID: "c1", decision: .deny) == .sent)
                #expect(s.sent.current == [.resolvePermission(sessionID: "c1", resolution: .deny(message: ApprovalChoices.denyMessage,
                                                                                                 interrupt: false))])
            } else {
                s.bridge(.actionableStateResolved(ActionableStateResolved(sessionID: "c1", summary: "Hook process disconnected.",
                                                                          timestamp: s.clock.current)))
            }
            #expect(s.glyph("c1") == nil, "\(ending)")
        }
    }

    /// CX18 (C5, P167): a child's hooks never touch the root session: its transcript path and prompt stay the
    /// root's, and the root's async question still opens.
    @Test
    func cx18AChildsHooksLeaveTheRootAlone() async throws {
        let s = codexScene()
        let root = try #require(s.engine.state.session(id: "c1")?.codexMetadata?.transcriptPath)
        s.hook(S.codex("UserPromptSubmit", agent: "k1", transcript: "/tmp/juice-attention/sessions/rollout-k1.jsonl",
                       extra: ["prompt": "child task"]), source: "codex", entrypoint: nil)
        s.hook(S.codex("PermissionRequest", agent: "k1", transcript: "/tmp/juice-attention/sessions/rollout-k1.jsonl"),
               source: "codex", entrypoint: nil)
        await s.settle { !s.engine.openRequests.isEmpty }
        #expect(s.engine.state.session(id: "c1")?.codexMetadata?.transcriptPath == root)
        #expect(s.engine.state.session(id: "c1")?.codexMetadata?.lastUserPrompt != "child task")
        s.rollout("c1", [C.call("request_user_input_async", "call_A1", arguments: C.asyncArguments)])
        #expect(s.engine.openRequests.contains { $0.kind == .question && $0.source == .rollout })
    }

    /// CX19 (C15): `codex exec` asks nothing.
    @Test
    func cx19AnExecRunAsksNothing() {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.line("session_meta", ["id": "c1", "cwd": "/tmp/project", "originator": "codex_exec", "source": "exec"], at: 0),
                         C.call("request_user_input_async", "call_A1", arguments: C.asyncArguments)])
        #expect(s.engine.openRequests.isEmpty && s.signals.isEmpty)
    }

    /// CX20 (C7): the call's line lands after the hook: matched late, closed by its output.
    @Test
    func cx20ACallThatLandsLateIsStillMatched() throws {
        let s = codexScene()
        let id = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        s.at(1)
        s.rollout("c1", [Self.exec("call_L", at: 1)])
        #expect(s.request(id)?.callID == "call_L")
        s.at(30)
        s.rollout("c1", [C.output("call_L", "ok", at: 30)])
        #expect(!s.isOpen(id))
    }

    // MARK: Other agents

    /// OC1, OT1, OT3: OpenCode's plugin, Cursor's blocking hook and a Claude fork's PermissionRequest stay on
    /// upstream's path: shown at once, answerable through the bridge. Cursor's is shown read-only: the table marks it
    /// Watch, so its own prompt decides and a Yes sends nothing (P930, P1159).
    @Test
    func oc1ot1ot3OtherAgentsKeepTheBridgesAnswerPath() async {
        for (tool, source) in [(AgentTool.openCode, "opencode"), (.cursor, "cursor"), (.qwenCode, "qwen")] {
            let s = S()
            s.begin("o1", tool: tool)
            #expect(s.hook(S.claude("PermissionRequest", session: "o1", tool: "Bash", input: S.push), source: source) == nil)
            s.bridge(F.permission("o1", toolUseID: nil, at: s.clock.current))
            let watched = tool == .cursor
            #expect(s.glyph("o1") == "!" && s.head("o1")?.channel == (watched ? .open : .answer(.bridge)), "\(tool)")
            #expect(await s.engine.approve(sessionID: "o1", decision: .allowOnce) == (watched ? .nothingToSend : .sent))
            #expect(s.sent.current == (watched ? [] : [.resolvePermission(sessionID: "o1", resolution: .allowOnce())]), "\(tool)")
        }
    }

    /// OC2: a restored OpenCode wait draws nothing; OT2: Gemini's Notification gives no request it could answer. Since
    /// wave 4 (P1103) its ToolPermission, sent just before Gemini's own prompt shows, is a notice: "!" with nothing to
    /// answer. Its other types, and a Claude type it never sends, open nothing.
    @Test
    func oc2ot2NoWaitWithoutARequest() {
        let s = S()
        let restored = AgentSession(id: "oc", title: "OpenCode · project", tool: .openCode, phase: .waitingForAnswer,
                                    summary: "Which?", updatedAt: F.now.addingTimeInterval(-60))
        s.engine.state = SessionState(sessions: [restored])
        s.engine.settleRestoredWaits()
        #expect(s.glyph("oc") == nil && s.engine.needsYouCount == 0)
        s.begin("g1", tool: .geminiCLI)
        s.hook(S.notification("permission_prompt", session: "g1"), source: "gemini")
        s.hook(["hook_event_name": "Notification", "session_id": "g1", "cwd": "/tmp/project", "notification_type": "Other",
                "message": "Gemini says hello"], source: "gemini")
        #expect(s.glyph("g1") == nil && s.engine.openRequests.isEmpty)
        s.hook(["hook_event_name": "Notification", "session_id": "g1", "cwd": "/tmp/project", "notification_type": "ToolPermission",
                "message": "Gemini needs permission"], source: "gemini")
        s.bridge(.activityUpdated(SessionActivityUpdated(sessionID: "g1", summary: "Gemini needs permission", phase: .running,
                                                         timestamp: s.clock.current)))
        #expect(s.glyph("g1") == "!" && s.engine.openRequests.count == 1)
        #expect(s.head("g1")?.content == .notice && s.head("g1")?.isAnswerable == false)
    }
}
