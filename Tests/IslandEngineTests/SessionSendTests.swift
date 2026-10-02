import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Answers, decisions and replies as the engine sends them: sent first and resolved only once sent (P129), No with a
/// reason or a stop, and replies only to a terminal known exactly (P128). Headless engines; no bridge, no socket, and
/// every reply goes to a recording stand-in, never a terminal.
@MainActor
struct SessionSendTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box

    // MARK: Sent first (P129)

    @Test
    func aDecisionThatCouldNotBeSentLeavesTheSessionWaiting() async throws {
        let sent = Box<[BridgeCommand]>([]), failing = Box(true)
        let engine = F.engine(sent: sent, failing: failing)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        let request = try #require(engine.state.session(id: "s1")?.permissionRequest)

        #expect(await engine.approve(sessionID: "s1", decision: .allowOnce) == .notSent)
        let waiting = try #require(engine.state.session(id: "s1"))
        #expect(waiting.phase == .waitingForApproval && waiting.permissionRequest?.id == request.id)
        #expect(engine.needsYouCount == 1 && sent.current.isEmpty)
        #expect(engine.lastStatusMessage.hasPrefix("Could not reach the bridge"))

        // Once the bridge is back, the same click goes through and resolves the approval here.
        failing.update { $0 = false }
        #expect(await engine.approve(sessionID: "s1", decision: .allowOnce) == .sent)
        #expect(sent.current == [.resolvePermission(sessionID: "s1", resolution: .allowOnce())])
        #expect(engine.state.session(id: "s1")?.phase == .running)
        #expect(await engine.approve(sessionID: "s1", decision: .deny) == .nothingToSend)
    }

    @Test
    func answersThatCouldNotBeSentLeaveTheQuestionWaiting() async {
        let sent = Box<[BridgeCommand]>([]), failing = Box(true)
        let engine = F.engine(sent: sent, failing: failing)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.question("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        let response = QuestionPromptResponse(answer: "main")

        #expect(await engine.answer(sessionID: "s1", response: response) == .notSent)
        #expect(engine.state.session(id: "s1")?.phase == .waitingForAnswer)
        #expect(engine.state.session(id: "s1")?.questionPrompt != nil)

        failing.update { $0 = false }
        #expect(await engine.answer(sessionID: "s1", response: response) == .sent)
        #expect(sent.current == [.answerQuestion(sessionID: "s1", response: response)])
        #expect(engine.state.session(id: "s1")?.phase != .waitingForAnswer)
    }

    /// A second click while the first is on its way sends nothing: the send is first now, so the session still waits
    /// until it went.
    @Test
    func aSecondClickWhileTheFirstIsOnItsWaySendsNothing() async {
        let engine = F.engine()
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        engine.sendingSessionIDs.insert("s1")
        #expect(await engine.approve(sessionID: "s1", decision: .deny) == .nothingToSend)
        engine.sendingSessionIDs.remove("s1")
        #expect(await engine.approve(sessionID: "s1", decision: .deny) == .sent)
    }

    /// The bridge's own event can move the session on while the send is out (here, a new request arrives during it);
    /// a request that is no longer the one answered is left alone.
    @Test
    func onlyTheRequestThatWasAnsweredIsResolvedHere() async throws {
        let holder = Box<SessionEngine?>(nil)
        var configuration = SessionEngine.Configuration.headless
        configuration.excludedWorkingDirectories = []
        var dependencies = SessionEngine.Dependencies()
        dependencies.updateProcessRoots = { _ in }
        dependencies.sendCommand = { _ in
            await MainActor.run { holder.current?.ingest(F.permission("s1", toolUseID: "toolu_2"), ingress: .bridge) }
        }
        let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
        holder.update { $0 = engine }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        let first = try #require(engine.state.session(id: "s1")?.permissionRequest?.id)
        #expect(await engine.approve(sessionID: "s1", decision: .allowOnce) == .sent)
        // The newer request waits for its own window, then is shown.
        engine.passAttentionWindows()
        let now = try #require(engine.state.session(id: "s1"))
        #expect(now.phase == .waitingForApproval)
        #expect(now.permissionRequest?.id != first && now.permissionRequest?.toolUseID == "toolu_2")
    }

    // MARK: No, with a reason or a stop

    @Test
    func noWithAReasonSendsTheOwnersWords() async {
        let sent = Box<[BridgeCommand]>([])
        let engine = F.engine(sent: sent)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(await engine.approve(sessionID: "s1", decision: .denyWithReason("  use rg, not grep \n")) == .sent)
        #expect(sent.current == [.resolvePermission(sessionID: "s1", resolution: .deny(message: "use rg, not grep", interrupt: false))])
    }

    @Test
    func anEmptyReasonIsAPlainNo() {
        #expect(ApprovalChoices.resolution(for: .denyWithReason("  \n "), request: nil)
            == .deny(message: ApprovalChoices.denyMessage, interrupt: false))
        #expect(ApprovalChoices.reason(String(repeating: "a", count: 5_000))?.count == ApprovalChoices.reasonLimit)
    }

    @Test
    func noAndStopEndsClaudesTurnOnly() async {
        let sent = Box<[BridgeCommand]>([])
        let engine = F.engine(sent: sent)
        engine.ingest(F.started("claude"), ingress: .bridge)
        engine.ingest(F.permission("claude"), ingress: .bridge)
        engine.ingest(F.started("codex", tool: .codex), ingress: .bridge)
        engine.ingest(F.permission("codex", toolUseID: nil), ingress: .bridge)
        engine.passAttentionWindows()

        #expect(await engine.approve(sessionID: "codex", decision: .denyAndStop) == .nothingToSend)
        #expect(engine.state.session(id: "codex")?.phase == .waitingForApproval)
        #expect(await engine.approve(sessionID: "claude", decision: .denyAndStop) == .sent)
        // Codex takes a reason all the same: its hooks carry a deny's message.
        #expect(await engine.approve(sessionID: "codex", decision: .denyWithReason("not in main")) == .sent)
        #expect(sent.current == [
            .resolvePermission(sessionID: "claude", resolution: .deny(message: ApprovalChoices.denyMessage, interrupt: true)),
            .resolvePermission(sessionID: "codex", resolution: .deny(message: "not in main", interrupt: false)),
        ])
        #expect(ApprovalChoices.canStop(.claudeCode) && !ApprovalChoices.canStop(.codex))
    }

    // MARK: Replies (P128)

    private func note(_ id: String, iterm: String? = nil, tmux: String? = nil, pane: String? = nil, host: String? = nil,
                      agent: Int32? = 900) -> HookContextNote {
        HookContextNote(event: "UserPromptSubmit", sessionID: id, itermSessionID: iterm, tmux: tmux, tmuxPane: pane, agentPID: agent,
                        hostBundleID: host)
    }

    /// A finished turn; its agent named by a context note (`agent`), as the hook prelude names it, unless nil.
    private func finished(_ engine: SessionEngine, _ id: String, tool: AgentTool = .claudeCode, terminal: String = "Terminal",
                          terminalID: String? = nil, agent: Int32? = 900) {
        engine.ingest(F.started(id, tool: tool, terminal: terminal, terminalID: terminalID), ingress: .bridge)
        engine.ingest(F.prompt(id), ingress: .bridge)
        if let agent { engine.ingest(note: note(id, agent: agent)) }
        engine.ingest(F.completed(id), ingress: .bridge)
    }

    private func route(_ engine: SessionEngine, _ id: String) -> ReplyRoute? {
        engine.state.session(id: id).flatMap { engine.replyRoute(for: $0) }
    }

    @Test
    func aReplyGoesOnlyWhereTheTerminalIsKnownExactly() {
        let engine = F.engine()
        // tmux: the agent's own pane on the agent's own server, whatever terminal shows it.
        finished(engine, "tmux", terminal: "iTerm")
        engine.ingest(note: note("tmux", tmux: "/private/tmp/tmux-501/default,4242,0", pane: "%7", host: ExactJump.itermBundleID))
        #expect(route(engine, "tmux") == .tmux(pane: "%7", socket: "/private/tmp/tmux-501/default"))
        // iTerm: the session of ITERM_SESSION_ID, checked against the agent's tty (P17).
        finished(engine, "iterm", terminal: "iTerm")
        engine.ingest(note: note("iterm", iterm: "w0t1p2:UUID-A", host: ExactJump.itermBundleID))
        #expect(route(engine, "iterm") == .iterm(sessionID: "UUID-A", tty: "/dev/ttys003"))
        // Ghostty: its terminal id.
        finished(engine, "ghostty", terminal: "Ghostty", terminalID: "TERM-1")
        #expect(route(engine, "ghostty") == .ghostty(terminalID: "TERM-1"))
        #expect(engine.canReply(sessionID: "ghostty"))

        // Never a guess: Ghostty with no id (its title or folder could match another tab), iTerm with no
        // ITERM_SESSION_ID, a pane with no server, Terminal, the Codex app.
        finished(engine, "ghostty-noid", terminal: "Ghostty")
        finished(engine, "iterm-noid", terminal: "iTerm")
        finished(engine, "pane-only", terminal: "iTerm")
        engine.ingest(note: note("pane-only", pane: "%9"))
        finished(engine, "terminal")
        for id in ["ghostty-noid", "iterm-noid", "pane-only", "terminal"] {
            #expect(route(engine, id) == nil, "\(id)")
            #expect(!engine.canReply(sessionID: id), "\(id)")
        }
    }

    @Test
    func onlyAFinishedTurnTakesAReply() {
        let engine = F.engine()
        engine.ingest(F.started("s1", terminal: "Ghostty", terminalID: "TERM-1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        engine.ingest(note: note("s1"))
        #expect(!engine.canReply(sessionID: "s1"))
        engine.ingest(F.completed("s1"), ingress: .bridge)
        #expect(engine.canReply(sessionID: "s1"))
        #expect(!engine.canReply(sessionID: "gone"))
    }

    @Test
    func aReplyIsTypedAlongItsRouteOnOneLine() async {
        let typed = Box<[(ReplyRoute, String)]>([]), works = Box(true)
        let engine = F.engine(replies: { route, text in
            typed.update { $0.append((route, text)) }
            return works.current
        })
        finished(engine, "s1", terminal: "Ghostty", terminalID: "TERM-1")
        #expect(await engine.reply(sessionID: "s1", text: " ship it\nand tag it ") == .sent)
        works.update { $0 = false }
        #expect(await engine.reply(sessionID: "s1", text: "again") == .notSent)
        #expect(typed.current.map(\.1) == ["ship it and tag it", "again"])
        #expect(typed.current.allSatisfy { $0.0 == .ghostty(terminalID: "TERM-1") })
        // Nothing to type, or nowhere to type it: nothing is sent.
        #expect(await engine.reply(sessionID: "s1", text: " \n ") == .nothingToSend)
        finished(engine, "terminal")
        #expect(await engine.reply(sessionID: "terminal", text: "hi") == .nothingToSend)
        #expect(typed.current.count == 2)
    }

    /// A headless engine with no sender of its own never types anywhere: the live sender belongs to the app's engine.
    @Test
    func aHeadlessEngineHasNoLiveSender() async {
        var configuration = SessionEngine.Configuration.headless
        configuration.excludedWorkingDirectories = []
        var dependencies = SessionEngine.Dependencies()
        dependencies.sendCommand = { _ in }
        dependencies.updateProcessRoots = { _ in }
        dependencies.agentAtPrompt = { _ in true }
        let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
        finished(engine, "s1", terminal: "Ghostty", terminalID: "TERM-1")
        #expect(engine.canReply(sessionID: "s1"))
        #expect(await engine.reply(sessionID: "s1", text: "hi") == .notSent)
    }

    /// P139: a pane or a tab holds a bare shell again once its agent was stopped (Ctrl-Z), crashed or quit, and a reply
    /// typed there would run as a command. A reply is offered only while the session has not ended and its agent (the
    /// context note's pid) holds its terminal; with no pid known, none is.
    @Test
    func aReplyNeedsItsAgentAtItsPrompt() async {
        let typed = Box<[String]>([]), atPrompt = Box(true)
        let engine = F.engine(replies: { _, text in
            typed.update { $0.append(text) }
            return true
        }, atPrompt: { pid in pid == 900 && atPrompt.current })
        finished(engine, "s1", terminal: "Ghostty", terminalID: "TERM-1")
        #expect(engine.canReply(sessionID: "s1"))
        // Stopped, or a shell's prompt in front: no field, and nothing typed.
        atPrompt.update { $0 = false }
        #expect(!engine.canReply(sessionID: "s1"))
        #expect(await engine.reply(sessionID: "s1", text: "rm -rf build") == .notSent)
        atPrompt.update { $0 = true }
        #expect(await engine.reply(sessionID: "s1", text: "go on") == .sent)
        // An agent that is not at its prompt, whatever its route.
        finished(engine, "s2", terminal: "Ghostty", terminalID: "TERM-2", agent: 901)
        #expect(!engine.canReply(sessionID: "s2"))
        // No pid known: no reply.
        finished(engine, "s3", terminal: "Ghostty", terminalID: "TERM-3", agent: nil)
        #expect(engine.replyRoute(for: engine.state.session(id: "s3")!) == .ghostty(terminalID: "TERM-3"))
        #expect(!engine.canReply(sessionID: "s3"))
        #expect(await engine.reply(sessionID: "s3", text: "ls") == .nothingToSend)
        // The session ended (SessionEnd): no reply, whatever its process.
        engine.ingest(F.sessionEnd("s1"), ingress: .bridge)
        #expect(!engine.canReply(sessionID: "s1"))
        #expect(await engine.reply(sessionID: "s1", text: "ls") == .nothingToSend)
        #expect(typed.current == ["go on"])
    }

    /// The agent is looked at again on the reply queue, just before the text is typed: one that left its prompt after
    /// the card offered the field is sent nothing.
    @Test
    func aReplyLooksAtTheAgentAgainJustBeforeTyping() async {
        let typed = Box<[String]>([]), looks = Box(0)
        let engine = F.engine(replies: { _, text in
            typed.update { $0.append(text) }
            return true
        }, atPrompt: { _ in
            looks.update { $0 += 1 }
            return looks.current <= 2
        })
        finished(engine, "s1", terminal: "Ghostty", terminalID: "TERM-1")
        #expect(engine.canReply(sessionID: "s1"))
        #expect(await engine.reply(sessionID: "s1", text: "rm -rf build") == .notSent)
        #expect(looks.current == 3)
        #expect(typed.current.isEmpty)
    }

    @Test
    func theITermScriptTypesIntoTheMatchedSessionOnly() {
        let script = ReplySender.itermScript("say \"hi\" \\ now", sessionID: "UUID-A", tty: "/dev/ttys004")
        #expect(script.contains(#"write text "say \"hi\" \\ now" newline no"#))
        #expect(script.contains(#"(id of aSession as text) is "UUID-A""#))
        #expect(script.contains(#"(tty of targetSession as text) is not "/dev/ttys004""#))
        #expect(script.contains("(count of found) is not 1"))
        #expect(script.contains("tell application id \"com.googlecode.iterm2\""))
        #expect(!script.contains("activate") && !script.contains("select"))
        #expect(ReplySender.line("a\r\nb") == "a b")
        #expect(ReplySender.line("   ") == nil)
    }

    /// Upstream's sender is given only the exact handle, so its Ghostty script can match by nothing else.
    @Test
    func upstreamsSenderGetsTheHandleAndNothingElse() {
        let carrier = ReplySender.carrier(JumpTarget(terminalApp: "Ghostty", workspaceName: "", paneTitle: "", terminalSessionID: "TERM-1"))
        #expect(carrier.jumpTarget?.workingDirectory == nil)
        #expect(carrier.jumpTarget?.paneTitle == "")
        #expect(carrier.jumpTarget?.tmuxTarget == nil)
    }

    /// A reply that takes long (Ghostty's Apple Event waiting on an Automation prompt the owner answers late) counts as
    /// what it did when it is done: it went, so it is Sent, never "Not sent" first (P128).
    @Test
    func aLateReplyIsWhatItDid() async {
        let started = Date()
        let sent = await ReplySender.run(on: DispatchQueue(label: "reply-late")) {
            usleep(300_000)
            return true
        }
        #expect(sent)
        #expect(Date().timeIntervalSince(started) >= 0.3)
    }

    /// While a reply is on its way, its session stays held: a second reply or a Retry finds nothing to send, so the
    /// text is never typed twice; once it went, the session takes the next reply.
    @Test
    func aReplyOnItsWayHoldsItsSession() async {
        let release = DispatchSemaphore(value: 0), typed = Box<[String]>([])
        let engine = F.engine(replies: { _, text in
            if text == "ship it" { release.wait() }
            typed.update { $0.append(text) }
            return true
        })
        finished(engine, "s1", terminal: "Ghostty", terminalID: "TERM-1")
        let first = Task { await engine.reply(sessionID: "s1", text: "ship it") }
        for _ in 0..<500 where !engine.sendingSessionIDs.contains("s1") { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await engine.reply(sessionID: "s1", text: "ship it") == .nothingToSend)
        release.signal()
        #expect(await first.value == .sent)
        #expect(await engine.reply(sessionID: "s1", text: "and tag it") == .sent)
        #expect(typed.current == ["ship it", "and tag it"])
    }
}
