import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// The Claude Code truth table (§2.1 and §5.1 CL1-CL28 of the needs-you design), row by row, through the engine: each
/// hook as the superset helper hands it over (its note, its broker line) and as upstream's bridge reports it (its
/// events). The tier-1 end-to-end suite runs the key rows again through the built helper binary.
@MainActor
struct ClaudeAttentionTableTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    static let pre = S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "U1")
    static let ask = S.claude("PermissionRequest", tool: "Bash", input: S.push)
    static let post = S.claude("PostToolUse", tool: "Bash", input: S.push, toolUseID: "U1", extra: ["tool_response": ["stdout": ""]])

    /// The request of CL2's shape: PreToolUse, then its PermissionRequest.
    private func askBash(_ s: S, entrypoint: String? = "cli", terminal: Bool = true) -> String? {
        s.hook(Self.pre, entrypoint: entrypoint, terminal: terminal)
        s.bridge(F.running("s1", summary: "Running Bash: git push origin main", at: s.clock.current))
        return s.hook(Self.ask, entrypoint: entrypoint, terminal: terminal)
    }

    private func allowResponse(_ s: S, _ id: String?) -> ClaudePermissionRequestDecision? {
        guard let answer = s.broker.answers.current.first(where: { $0.id == id }),
              case let .claudeHookDirective(.permissionRequest(decision)) = answer.response else { return nil }
        return decision
    }

    // MARK: Rows

    /// CL1: bypass, every call auto-allowed: no "!", one Done.
    @Test
    func cl1ABypassTurnShowsNoApprovalAndOneDone() {
        let s = S()
        s.begin()
        s.hook(S.claude("UserPromptSubmit", mode: "bypassPermissions", extra: ["prompt": "fix the tests"]))
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "U1", mode: "bypassPermissions"))
        s.bridge(F.running("s1", at: s.clock.current))
        s.hook(S.claude("PostToolUse", tool: "Bash", input: S.push, toolUseID: "U1", mode: "bypassPermissions"))
        s.bridge(F.running("s1", summary: "Bash finished.", at: s.clock.current))
        s.hook(S.claude("Stop", mode: "bypassPermissions"))
        s.bridge(F.completed("s1", at: s.clock.current))
        s.at(10)
        #expect(s.glyph() == nil && s.engine.openRequests.isEmpty)
        #expect(s.signals == [.done(sessionID: "s1")])
    }

    /// CL2: nothing until Claude's own notice at 6; then "!", the card and one sound; the island's Allow goes out as
    /// allow with the original input; then running, no Done.
    @Test
    func cl2AnApprovalShowsAtTheNoticeAndTheIslandsAllowGoesOut() async throws {
        let s = S()
        s.begin()
        let id = try #require(askBash(s))
        #expect(s.broker.held.current.contains(id))
        s.at(5.9)
        #expect(s.glyph() == nil && s.engine.needsYouCount == 0 && s.needsYou.isEmpty && s.phase() == .running)
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        #expect(s.glyph() == "!" && s.head()?.id == id && s.head()?.isAnswerable == true)
        #expect(s.phase() == .waitingForApproval && s.engine.needsYouCount == 1 && s.needsYou.count == 1)
        #expect(s.head()?.toolUseID == "U1" && s.engine.state.session(id: "s1")?.permissionRequest?.toolUseID == "U1")
        #expect(await s.engine.approve(requestID: id, decision: .allowOnce) == .sent)
        let decision = try #require(allowResponse(s, id))
        #expect(decision == .allow(updatedInput: .object(["command": .string("git push origin main"),
                                                         "description": .string("Push the branch")]), updatedPermissions: []))
        #expect(s.glyph() == nil && s.phase() == .running)
        s.at(20)
        #expect(s.dones.isEmpty && s.needsYou.count == 1)
    }

    /// CL3: answered at the keyboard within seconds: never drawn, never sounded; released (no decision) at 8 s and
    /// kept dormant; its PostToolUse forgets it.
    @Test
    func cl3AnApprovalAnsweredAtTheKeyboardIsNeverDrawn() throws {
        let s = S()
        s.begin()
        let id = try #require(askBash(s))
        s.at(7.9)
        #expect(s.state(id) == .pending && s.broker.released.current.isEmpty)
        s.at(8)
        #expect(s.state(id) == .dormant && s.broker.released.current == [id] && s.broker.answers.current.isEmpty)
        #expect(s.glyph() == nil && s.signals.isEmpty && s.phase() == .running)
        s.at(9)
        s.hook(Self.post)
        #expect(!s.isOpen(id))
        #expect(s.engine.attentionTally.releasedByWindow["cli"] == 1)
    }

    /// CL4: confirmed, then approved in the terminal: "!" until the tool ends (the documented residual); a deny or Esc
    /// in the terminal ends it at its transcript `tool_result`.
    @Test
    func cl4AConfirmedApprovalAnsweredInTheTerminalLastsUntilItsCallEnds() async throws {
        let s = S()
        s.begin()
        let id = try #require(askBash(s))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        s.at(20)
        #expect(s.glyph() == "!")
        s.at(140)
        s.hook(Self.post)
        #expect(s.glyph() == nil && !s.isOpen(id) && s.broker.released.current == [id])

        let denied = S()
        denied.begin()
        let second = try #require(askBash(denied))
        denied.at(6)
        denied.hook(S.notification("permission_prompt"))
        #expect(denied.watches.all.current.map(\.path) == [S.transcript("s1")])
        denied.at(20)
        await denied.transcriptResult("U1")
        #expect(denied.glyph() == nil && !denied.isOpen(second) && denied.broker.released.current == [second])
        #expect(denied.watches.all.current.allSatisfy { $0.stopped.current })
    }

    /// CL5: a sibling's PostToolUse never closes the Bash approval (probe S5).
    @Test
    func cl5ASiblingsPostToolUseLeavesTheApproval() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "U2"))
        let id = try #require(askBash(s))
        s.hook(S.claude("PostToolUse", tool: "Read", input: S.read, toolUseID: "U2"))
        s.bridge(F.running("s1", summary: "Read finished.", at: s.clock.current))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.id == id && s.head()?.toolUseID == "U1" && s.glyph() == "!")
    }

    /// CL6: two subagents ask: both released at once, nothing until the notices, then the parent row with the
    /// subagent's name and "· 1 more"; each closes on its own evidence only.
    @Test
    func cl6SubagentRequestsAreReleasedAndQueuedOnTheParent() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Edit", input: S.edit, toolUseID: "UW1", agent: "w1"))
        let first = try #require(s.hook(S.claude("PermissionRequest", tool: "Edit", input: S.edit, agent: "w1")))
        s.at(1)
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UW2", agent: "w2", agentType: "tester"))
        let second = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "w2", agentType: "tester")))
        #expect(s.broker.held.current.isEmpty)
        #expect(s.request(first)?.channel == .open && s.request(second)?.channel == .open)
        s.at(5.9)
        #expect(s.glyph() == nil)
        s.at(6)
        s.hook(S.notification("permission_prompt", agent: "w1"))
        s.at(7)
        s.hook(S.notification("permission_prompt", agent: "w2"))
        #expect(s.head()?.id == first && s.head()?.agentType == "worker" && s.head()?.isAnswerable == false)
        #expect(s.engine.attentionQueue(for: "s1").map(\.id) == [first, second])
        #expect(s.needsYou.count == 2)
        // The parent's own work and a sibling's tool leave them.
        s.hook(S.claude("PostToolUse", tool: "Bash", input: S.push, toolUseID: "U9"))
        s.hook(S.claude("PostToolUse", tool: "Bash", input: S.push, toolUseID: "UW2", agent: "w2", agentType: "tester"))
        #expect(s.engine.attentionQueue(for: "s1").map(\.id) == [first])
        s.hook(S.claude("SubagentStop", agent: "w1"))
        #expect(s.engine.openRequests.isEmpty && s.glyph() == nil)
    }

    /// CL7: AskUserQuestion in bypass: "?", and the island's answers go out as allow with `answers` (multi-select joined).
    @Test
    func cl7AQuestionIsAnsweredWithTheAnswersField() async throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "AskUserQuestion", input: S.questions, toolUseID: "UQ", mode: "bypassPermissions"))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "AskUserQuestion", input: S.questions, mode: "bypassPermissions")))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        #expect(s.glyph() == "?" && s.phase() == .waitingForAnswer && s.head()?.isAnswerable == true)
        let response = QuestionPromptResponse(answers: ["Which branch?": "dev", "Which checks?": "lint, tests"])
        #expect(await s.engine.answer(requestID: id, response: response) == .sent)
        guard case let .allow(updatedInput?, _) = try #require(allowResponse(s, id)),
              case let .object(fields) = updatedInput, case let .object(answers)? = fields["answers"] else {
            Issue.record("no answers")
            return
        }
        #expect(answers == ["Which branch?": .string("dev"), "Which checks?": .string("lint, tests")])
        #expect(fields["questions"] != nil)
        #expect(s.glyph() == nil && s.phase() == .running)

        // Answered in the terminal instead: its PostToolUse ends it.
        let t = S()
        t.begin()
        t.hook(S.claude("PreToolUse", tool: "AskUserQuestion", input: S.questions, toolUseID: "UQ"))
        let other = try #require(t.hook(S.claude("PermissionRequest", tool: "AskUserQuestion", input: S.questions)))
        t.at(6)
        t.hook(S.notification("permission_prompt"))
        t.hook(S.claude("PostToolUse", tool: "AskUserQuestion", input: S.questions, toolUseID: "UQ"))
        #expect(!t.isOpen(other) && t.broker.released.current == [other])
    }

    /// CL8: the desktop's question, answered in the app at 30 s: closed then, and its helper released (no orphan).
    @Test
    func cl8ADesktopQuestionAnsweredInTheAppEndsWithItsHelper() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "AskUserQuestion", input: S.questions, toolUseID: "UQ"), entrypoint: "claude-desktop",
               terminal: false)
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "AskUserQuestion", input: S.questions),
                                     entrypoint: "claude-desktop", terminal: false))
        #expect(s.broker.held.current.contains(id) && s.request(id)?.place == .claudeApp)
        s.at(6)
        s.hook(S.notification("permission_prompt"), entrypoint: "claude-desktop", terminal: false)
        #expect(s.glyph() == "?")
        s.at(30)
        s.hook(S.claude("PostToolUse", tool: "AskUserQuestion", input: S.questions, toolUseID: "UQ"), entrypoint: "claude-desktop",
               terminal: false)
        #expect(s.glyph() == nil && s.broker.held.current.isEmpty && s.broker.released.current == [id])
    }

    /// CL9: a desktop approval answered at 3 s: never drawn, released at 8, no sound.
    @Test
    func cl9ADesktopApprovalAnsweredQuicklyIsNeverDrawn() throws {
        let s = S()
        s.begin()
        let id = try #require(askBash(s, entrypoint: "claude-desktop", terminal: false))
        s.at(3)
        s.at(8)
        #expect(s.state(id) == .dormant && s.broker.released.current == [id] && s.signals.isEmpty && s.glyph() == nil)
    }

    /// CL10: a plan: "Plan ready", closed by the transcript's rejection; an island Allow never carries a mode change.
    @Test
    func cl10APlanNeverSendsAModeChange() async throws {
        let plan: [String: Any] = ["plan": "1. Read the code\n2. Fix the tests"]
        for rejected in [false, true] {
            let s = S()
            s.begin()
            s.hook(S.claude("PreToolUse", tool: "ExitPlanMode", input: plan, toolUseID: "UP", mode: "plan"))
            let id = try #require(s.hook(S.claude("PermissionRequest", tool: "ExitPlanMode", input: plan, mode: "plan",
                                                  extra: ["permission_suggestions": [["type": "setMode", "mode": "acceptEdits",
                                                                                      "destination": "session"]]])))
            s.at(6)
            s.hook(S.notification("permission_prompt"))
            #expect(s.head()?.kind == .plan && s.glyph() == "!")
            if rejected {
                await s.transcriptResult("UP")
                #expect(!s.isOpen(id) && s.glyph() == nil)
            } else {
                #expect(await s.engine.approve(requestID: id, decision: .allowOnce) == .sent)
                #expect(allowResponse(s, id) == .allow(updatedInput: .object(["plan": .string("1. Read the code\n2. Fix the tests")]),
                                                       updatedPermissions: []))
            }
        }
    }

    /// CL11: Esc at Claude's prompt writes the call's result; no Stop is needed.
    @Test
    func cl11EscAtThePromptClosesAtOnce() async throws {
        let s = S()
        s.begin()
        let id = try #require(askBash(s))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        await s.transcriptResult("U1")
        #expect(!s.isOpen(id) && s.glyph() == nil)
    }

    /// CL12 (P159): a failed turn needs you once and goes at the next activity; the next Stop is a plain Done.
    @Test
    func cl12AFailedTurnGoesAtTheNextActivity() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("StopFailure", extra: ["error": "rate_limit"]))
        s.bridge(F.completed("s1", at: s.clock.current))
        let failed = try #require(s.engine.state.session(id: "s1"))
        #expect(s.engine.hasFailedTurn(failed) && s.engine.needsAttention(failed) && s.glyph() == nil)
        #expect(s.needsYou == [.needsYou(sessionID: "s1")])
        s.at(1)
        s.hook(Self.pre)
        s.bridge(F.running("s1", at: s.clock.current))
        #expect(!s.engine.hasFailedTurn(try #require(s.engine.state.session(id: "s1"))))
        s.hook(Self.post)
        s.bridge(F.running("s1", summary: "Bash finished.", at: s.clock.current))
        s.hook(S.claude("Stop"))
        s.bridge(F.completed("s1", at: s.clock.current))
        s.at(5)
        let done = try #require(s.engine.state.session(id: "s1"))
        #expect(!s.engine.hasFailedTurn(done) && s.engine.statusWord(for: done) == .done)
        #expect(s.dones == [.done(sessionID: "s1")] && s.needsYou.count == 1)
    }

    /// CL13: a prompt with no hook behind it (a sandbox network prompt): read-only "!" until the main thread moves on.
    @Test
    func cl13APromptWithNoHookIsReadOnlyUntilTheMainThreadMovesOn() throws {
        let s = S()
        s.begin()
        s.hook(S.notification("permission_prompt"))
        let head = try #require(s.head())
        #expect(s.glyph() == "!" && head.content == .notice && !head.isAnswerable && head.place == .terminal)
        #expect(s.needsYou.count == 1)
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UX", agent: "w1"))
        #expect(s.glyph() == "!")
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UY"))
        #expect(s.glyph() == nil && s.engine.openRequests.isEmpty)
    }

    /// CL14: an MCP form: read-only "?" until it is answered.
    @Test
    func cl14AnMCPFormIsAReadOnlyQuestion() {
        let s = S()
        s.begin()
        s.hook(S.notification("elicitation_dialog"))
        #expect(s.glyph() == "?" && s.head()?.kind == .elicitation && s.head()?.isAnswerable == false)
        s.hook(S.notification("elicitation_complete"))
        #expect(s.glyph() == nil)
    }

    /// CL15, CL16: a headless run and `dontAsk`: released at once, never shown.
    @Test
    func cl15cl16HeadlessAndDontAskAreNeverShown() {
        for (entrypoint, mode) in [("sdk-cli", "default"), ("sdk-py", "default"), ("cli", "dontAsk")] {
            let s = S()
            s.begin()
            s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, mode: mode), entrypoint: entrypoint)
            s.at(30)
            #expect(s.broker.held.current.isEmpty && s.engine.openRequests.isEmpty && s.signals.isEmpty, "\(entrypoint) \(mode)")
        }
    }

    /// CL17: a restored waiting phase draws nothing and sounds nothing.
    @Test
    func cl17ARestoredWaitDrawsNothing() {
        let s = S()
        s.begin()
        let restored = AgentSession(id: "restored", title: "Claude · project", tool: .claudeCode, phase: .waitingForApproval,
                                    summary: "Wants to run Bash.", updatedAt: F.now.addingTimeInterval(-60))
        s.engine.state = SessionState(sessions: s.engine.state.sessions + [restored])
        s.engine.settleRestoredWaits()
        s.at(30)
        #expect(s.glyph("restored") == nil && s.engine.state.session(id: "restored")?.phase == .completed)
        #expect(s.engine.needsYouCount == 0 && s.signals.isEmpty)
    }

    /// CL18: the app quits while a request is held: the broker stops, every held helper ends with no decision.
    @Test
    func cl18QuittingEndsEveryHeldHelper() throws {
        let s = S()
        s.begin()
        _ = try #require(askBash(s))
        s.engine.stopHookRequests()
        #expect(s.broker.stopped.current && s.broker.answers.current.isEmpty && s.engine.hookRequestBroker == nil)
    }

    /// CL19: a profile whose hook config has no `permission_prompt` for our helper: confirmed at 8 s with one sound,
    /// never released by the window.
    @Test
    func cl19AnUnarmedProfileConfirmsAtEightSeconds() throws {
        let s = S(armed: false)
        s.begin(transcript: S.transcript("s1"))
        let id = try #require(askBash(s))
        s.at(7.9)
        #expect(s.glyph() == nil)
        s.at(8)
        #expect(s.glyph() == "!" && s.state(id) == .confirmed && s.broker.released.current.isEmpty && s.needsYou.count == 1)
        s.at(30)
        s.hook(Self.post)
        #expect(s.glyph() == nil && s.broker.released.current == [id])
    }

    /// CL20: the old helper's request, through upstream's bridge: answerable once confirmed; gone when its hook
    /// disconnects. With v2 notes (a new helper that found no broker) its window hides it and a later notice brings
    /// the answerable card back; with v1 notes (no notice to wait for) it is confirmed at 8 s.
    @Test
    func cl20TheOldHelpersRequestStaysAnswerable() async {
        let s = S()
        s.begin()
        s.hook(Self.pre)
        s.bridge(F.permission("s1", toolUseID: nil, at: s.clock.current))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        #expect(s.glyph() == "!" && s.head()?.channel == .answer(.bridge))
        s.bridge(.actionableStateResolved(ActionableStateResolved(sessionID: "s1", summary: "Hook process disconnected.",
                                                                  timestamp: s.clock.current)))
        #expect(s.glyph() == nil && s.engine.openRequests.isEmpty)

        let hidden = S()
        hidden.begin()
        hidden.hook(Self.pre)
        hidden.bridge(F.permission("s1", toolUseID: nil, at: hidden.clock.current))
        hidden.at(8)
        #expect(hidden.glyph() == nil && hidden.engine.openRequests.first?.state == .dormant)
        hidden.at(40)
        hidden.hook(S.notification("permission_prompt"))
        #expect(hidden.glyph() == "!" && hidden.head()?.channel == .answer(.bridge))
        #expect(await hidden.engine.approve(sessionID: "s1", decision: .allowOnce) == .sent)
        #expect(hidden.sent.current == [.resolvePermission(sessionID: "s1", resolution: .allowOnce())])

        let old = S()
        old.begin()
        old.hook(Self.pre, version: 1)
        old.bridge(F.permission("s1", toolUseID: nil, at: old.clock.current))
        old.at(7.9)
        #expect(old.glyph() == nil)
        old.at(8)
        #expect(old.glyph() == "!" && old.needsYou.count == 1)
    }

    /// CL21 (P155, C8): a `<task-notification>` turn is not the owner's prompt and closes nothing.
    @Test
    func cl21AMachinePromptClosesNothing() throws {
        let s = S()
        s.begin(prompt: "refactor the parser")
        let id = try #require(askBash(s))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        let machine = "<task-notification><task-id>b1</task-id><status>completed</status></task-notification>"
        s.hook(S.claude("UserPromptSubmit", extra: ["prompt": machine]))
        s.bridge(F.prompt("s1", machine, at: s.clock.current))
        #expect(s.head()?.id == id && s.glyph() == "!")
        // A human prompt does end the main thread's wait.
        s.hook(S.claude("UserPromptSubmit", extra: ["prompt": "never mind"]))
        s.bridge(F.prompt("s1", "never mind", at: s.clock.current))
        #expect(!s.isOpen(id))
    }

    /// CL22 (C12, P169): after an island No the session runs on; after No and stop it waits for a prompt,
    /// interrupted. Never a Done, through the broker or through the bridge.
    @Test
    func cl22AnIslandNoIsNeverADone() async throws {
        for stop in [false, true] {
            let s = S()
            s.begin()
            let id = try #require(askBash(s))
            s.at(6)
            s.hook(S.notification("permission_prompt"))
            #expect(await s.engine.approve(requestID: id, decision: stop ? .denyAndStop : .deny) == .sent)
            #expect(allowResponse(s, id) == .deny(message: ApprovalChoices.denyMessage, interrupt: stop))
            let session = try #require(s.engine.state.session(id: "s1"))
            if stop {
                #expect(session.phase == .completed && s.engine.statusWord(for: session) == .interrupted)
            } else {
                #expect(session.phase == .running && s.engine.statusWord(for: session) == .denied(tool: "Bash"))
            }
            s.at(20)
            #expect(s.dones.isEmpty, "stop: \(stop)")

            let legacy = S()
            legacy.begin()
            legacy.bridge(F.permission("s1", at: legacy.clock.current))
            legacy.at(8)
            #expect(await legacy.engine.approve(sessionID: "s1", decision: stop ? .denyAndStop : .deny) == .sent)
            // The bridge's own echo: its "denied" completion.
            legacy.bridge(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "Claude Code permission was denied.",
                                                             timestamp: legacy.clock.current)))
            let after = try #require(legacy.engine.state.session(id: "s1"))
            #expect(stop ? legacy.engine.statusWord(for: after) == .interrupted : after.phase == .running, "legacy stop: \(stop)")
            legacy.at(20)
            #expect(legacy.dones.isEmpty, "legacy stop: \(stop)")
        }
    }

    /// CL23 (P165): A answered at the keyboard, B left: each window runs from its own opening, and B's late notice
    /// revives B read-only with one sound.
    @Test
    func cl23ALateNoticeRevivesTheNewestDormantRequest() throws {
        let s = S()
        s.begin()
        let a = try #require(s.hook(Self.ask))
        s.at(1)
        let b = try #require(s.hook(S.claude("PermissionRequest", tool: "Edit", input: S.edit)))
        s.at(8)
        #expect(s.state(a) == .dormant && s.state(b) == .pending)
        s.at(9)
        #expect(s.state(b) == .dormant && s.broker.released.current == [a, b])
        s.at(9.2)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.id == b && s.head()?.isAnswerable == false && s.state(a) == .dormant)
        #expect(s.needsYou.count == 1)
    }

    /// CL24: two requests queued with the owner away: confirmed first in, first out; after A is answered B shows,
    /// and each sounded once.
    @Test
    func cl24QueuedRequestsAreConfirmedInOrder() async throws {
        let s = S()
        s.begin()
        let a = try #require(s.hook(Self.ask))
        s.at(1)
        let b = try #require(s.hook(S.claude("PermissionRequest", tool: "Edit", input: S.edit)))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        #expect(s.state(a) == .confirmed && s.state(b) == .pending && s.head()?.id == a)
        s.at(7)
        s.hook(S.notification("permission_prompt"))
        #expect(s.state(b) == .confirmed && s.needsYou.count == 2)
        #expect(await s.engine.approve(requestID: a, decision: .allowOnce) == .sent)
        #expect(s.head()?.id == b && s.glyph() == "!" && s.needsYou.count == 2)
        s.at(20)
        #expect(s.needsYou.count == 2 && s.state(b) == .confirmed)
    }

    /// CL25 (C3): a question typed into past the window, then left: "?" (never "!") at the notice, read-only.
    @Test
    func cl25AQuestionComesBackAsAQuestion() throws {
        let s = S()
        s.begin()
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "AskUserQuestion", input: S.questions)))
        s.at(12)
        #expect(s.state(id) == .dormant && s.glyph() == nil)
        s.at(18)
        s.hook(S.notification("permission_prompt"))
        #expect(s.glyph() == "?" && s.head()?.id == id && s.head()?.isAnswerable == false && s.needsYou.count == 1)
    }

    /// CL26 (C8, C9): a background subagent's prompt outlives the owner's next main prompt; its own transcript's
    /// result ends it.
    @Test
    func cl26ASubagentsPromptOutlivesTheMainPrompt() async throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UW", agent: "w1"))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "w1")))
        s.at(6)
        s.hook(S.notification("permission_prompt", agent: "w1"))
        #expect(s.head()?.id == id)
        s.hook(S.claude("UserPromptSubmit", extra: ["prompt": "and update the docs"]))
        s.bridge(F.prompt("s1", "and update the docs", at: s.clock.current))
        s.hook(S.claude("Stop"))
        s.bridge(F.completed("s1", at: s.clock.current))
        #expect(s.head()?.id == id && s.glyph() == "!")
        let path = "/Users/test/.claude-lab/projects/-tmp-project/s1/subagents/agent-w1.jsonl"
        #expect(s.watches.all.current.map(\.path) == [path])
        await s.transcriptResult("UW")
        #expect(s.engine.openRequests.isEmpty)
    }

    /// CL27 (C10): only the four interactive surfaces are held; `local-agent`, an unknown value and a missing one
    /// with no terminal are released and shown read-only; a missing one with a terminal is the terminal.
    @Test
    func cl27OnlyInteractiveSurfacesAreHeld() throws {
        for (entrypoint, terminal, held) in [("local-agent", false, false), ("new-surface", true, false), (nil, false, false),
                                             (nil, true, true)] as [(String?, Bool, Bool)] {
            let s = S()
            s.begin()
            let id = try #require(s.hook(Self.ask, entrypoint: entrypoint, terminal: terminal))
            #expect(s.broker.held.current.contains(id) == held, "\(String(describing: entrypoint))")
            s.at(6)
            s.hook(S.notification("permission_prompt"), entrypoint: entrypoint, terminal: terminal)
            #expect(s.head()?.id == id && s.head()?.isAnswerable == held, "\(String(describing: entrypoint))")
        }
    }

    /// CL28 (C11): the agent's pid gone (a crash, no SessionEnd): closed and released on the liveness pass.
    @Test
    func cl28AGoneAgentClosesItsRequest() throws {
        let s = S()
        s.begin()
        let id = try #require(askBash(s))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        s.livenessPass()
        #expect(s.isOpen(id))
        s.gone.update { _ = $0.insert(900) }
        s.livenessPass()
        #expect(!s.isOpen(id) && s.broker.released.current == [id])
        #expect(s.engine.attentionTally.closes["pidGone"] == 1)
    }
}
