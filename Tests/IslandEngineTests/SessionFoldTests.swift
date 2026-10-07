import Foundation
import IslandHookNotes
import Observation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Sending a session to the island (wave 6, P1300 to P1312): the Terminal reply route, the tuck, the held reply, the
/// two routes of a reply and Open in terminal. Headless engines: every reply goes to a recording stand-in, every tuck to
/// a fake, every jump to a fake runner, every resume to a fake; no terminal, no osascript and no process is touched.
@MainActor
struct SessionFoldTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box

    /// The resume lane's stand-in: what the card asked of it, and what it answers.
    @MainActor
    @Observable
    final class FakeResume: ConversationResuming {
        var offer: ResumeAvailability = .resume(note: nil)
        var running: Set<String> = []
        var continued: [(String, String)] = []
        var opened: [String] = []
        /// Each Open in terminal, with the words it was to carry the turn on with (nil: the conversation alone).
        var openedWith: [(String, String?)] = []
        var stopped: [String] = []
        var opens = true
        var outcome: SendOutcome = .sent
        /// What Codex's shared background service last said of each thread (P1487); none by default.
        var service: [String: CodexDaemonStatus] = [:]

        func availability(for sessionID: String) -> ResumeAvailability { offer }
        func isRunning(_ sessionID: String) -> Bool { running.contains(sessionID) }
        func continueConversation(_ sessionID: String, text: String) async -> SendOutcome {
            continued.append((sessionID, text))
            return outcome
        }
        func stop(_ sessionID: String) { stopped.append(sessionID) }
        func openInTerminal(_ sessionID: String, continuing prompt: String?) async -> Bool {
            opened.append(sessionID)
            openedWith.append((sessionID, prompt))
            return opens
        }
        func problem(_ sessionID: String) -> String? { nil }
        func answer(_ sessionID: String) -> String? { nil }
        func keep(_ sessionID: String) {}
        func serviceStatus(_ sessionID: String) -> CodexDaemonStatus? { service[sessionID] }
    }

    /// One engine and every seam it was given.
    @MainActor
    struct Rig {
        let engine: SessionEngine
        let typed: Box<[(ReplyRoute, String)]>
        let tucks: Box<[(TerminalTuck.Move, ReplyRoute)]>
        let scheduled: Box<[F.ScheduledCheck]>
        let clock: Box<Date>
        let atPrompt: Box<Bool>
        let calls: ExactJumpTests.Calls

        func runChecks(_ seconds: TimeInterval = 2) { F.runScheduledChecks(scheduled, clock: clock, for: seconds) }
    }

    nonisolated static let tty = "/dev/ttys004"

    /// `tuck`: what the window's script answers (nil: no tucker, as a headless engine has none).
    static func rig(tuck: TuckOutcome? = .tucked(TuckBounds(left: 100, top: 80, right: 900, bottom: 600)), sends: Bool = true) -> Rig {
        let typed = Box<[(ReplyRoute, String)]>([]), tucks = Box<[(TerminalTuck.Move, ReplyRoute)]>([])
        let scheduled = Box<[F.ScheduledCheck]>([]), clock = Box(F.now), atPrompt = Box(true)
        let calls = ExactJumpTests.Calls()
        let runner = ExactJumpTests.runner(calls: calls, running: [ExactJumpTests.terminal], frontmost: ExactJumpTests.terminal,
                                           script: { _ in "matched\u{1f}\(SessionFoldTests.tty)" })
        let engine = F.engine(clock: clock, scheduled: scheduled, replies: { route, text in
            typed.update { $0.append((route, text)) }
            return sends
        }, atPrompt: { _ in atPrompt.current }) { dependencies in
            // A tab that closed took its agent and its tty with it (`atPrompt` false stands for that here): no route
            // is left, so Open in terminal brings no window back (P1421).
            dependencies.ttyForPID = { $0 == 900 && atPrompt.current ? SessionFoldTests.tty : nil }
            dependencies.jumpRunner = runner
            if let tuck {
                dependencies.tuckWindow = { move, route in
                    tucks.update { $0.append((move, route)) }
                    return move == .untuck ? .restored : tuck
                }
            }
            dependencies.scheduleFoldCheck = { delay, check in
                scheduled.update { $0.append(F.ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
            }
        }
        return Rig(engine: engine, typed: typed, tucks: tucks, scheduled: scheduled, clock: clock, atPrompt: atPrompt, calls: calls)
    }

    static func note(_ id: String, agent: Int32? = 900) -> HookContextNote {
        HookContextNote(event: "UserPromptSubmit", sessionID: id, agentPID: agent)
    }

    /// A session in `terminal` whose agent a note names; its turn finished unless `running`.
    static func session(_ engine: SessionEngine, _ id: String, terminal: String = "Terminal", running: Bool = false,
                        agent: Int32? = 900, tool: AgentTool = .claudeCode) {
        engine.ingest(F.started(id, tool: tool, terminal: terminal), ingress: .bridge)
        engine.ingest(F.prompt(id), ingress: .bridge)
        if let agent { engine.ingest(note: note(id, agent: agent)) }
        if !running { engine.ingest(F.completed(id), ingress: .bridge) }
    }

    // MARK: Terminal's route (P1300, P1301)

    @Test
    func aTerminalTabIsKnownByItsAgentsOwnTTYAlone() {
        let rig = Self.rig()
        Self.session(rig.engine, "term")
        #expect(rig.engine.state.session(id: "term").flatMap { rig.engine.replyRoute(for: $0) } == .terminal(tty: Self.tty))
        #expect(rig.engine.canReply(sessionID: "term"))
        // No pid, or a pid whose tty is not found (the agent is gone): never upstream's tty, which a new tab can carry.
        Self.session(rig.engine, "nopid", agent: nil)
        Self.session(rig.engine, "gone", agent: 901)
        for id in ["nopid", "gone"] {
            #expect(rig.engine.state.session(id: id).flatMap { rig.engine.replyRoute(for: $0) } == nil, "\(id)")
            #expect(!rig.engine.canReply(sessionID: id), "\(id)")
        }
        // Warp and the editors still have no route.
        Self.session(rig.engine, "warp", terminal: "Warp")
        #expect(rig.engine.state.session(id: "warp").flatMap { rig.engine.replyRoute(for: $0) } == nil)
    }

    @Test
    func theTerminalScriptTypesIntoTheOneTabWithTheAgentsTTY() {
        let script = ReplySender.terminalScript(#"say "hi" \ now"#, tty: Self.tty, submit: .thenReturn)
        #expect(script.contains(#"tell application id "com.apple.Terminal""#))
        #expect(script.contains(#"if not (it is running) then return """#))
        #expect(script.contains(#"if (tty of aTab as text) is "/dev/ttys004" then set end of found to tab k of window id (id of aWindow)"#))
        #expect(script.contains(#"if (count of found) is not 1 then return """#))
        #expect(script.contains(#"do script "say \"hi\" \\ now" in targetTab"#))
        // Never a new window or tab, never brought forward.
        #expect(!script.contains("activate") && !script.contains("selected") && !script.contains("frontmost"))
    }

    /// The submit is one small piece with two candidates: the line end with the text, or on its own after a pause
    /// (the standard, P1301). The owner's live test of `do script` decides between them.
    @Test
    func theSubmitIsOneSwapBetweenTwoCandidates() {
        let inOne = ReplySender.terminalScript("ship it", tty: Self.tty, submit: .inOne)
        let thenReturn = ReplySender.terminalScript("ship it", tty: Self.tty, submit: .thenReturn)
        #expect(inOne.components(separatedBy: "do script").count - 1 == 1)
        #expect(!inOne.contains("delay"))
        #expect(thenReturn.components(separatedBy: "do script").count - 1 == 2)
        #expect(thenReturn.contains("delay 0.3\n") && thenReturn.contains(#"do script "" in targetTab"#))
        let typed = thenReturn.range(of: #"do script "ship it" in targetTab"#)!, alone = thenReturn.range(of: #"do script "" in targetTab"#)!
        #expect(typed.upperBound < alone.lowerBound)
        #expect(ReplySender.TerminalSubmit.standard == .thenReturn)
        // Either way the text goes the same way: the same tab, found the same way.
        func upToTheText(_ script: String) -> String { String(script[..<script.range(of: #"do script "ship it""#)!.upperBound]) }
        #expect(upToTheText(inOne) == upToTheText(thenReturn))
    }

    /// W6-R3: the line end alone goes into the agent's own tab only: found again by its tty after the pause, as
    /// Terminal's windows may have moved meanwhile.
    @Test
    func theLineEndAloneFindsTheTabAgainByItsTTY() throws {
        let script = ReplySender.terminalScript("ship it", tty: Self.tty, submit: .thenReturn)
        let pause = try #require(script.range(of: "delay 0.3"))
        let after = String(script[pause.upperBound...])
        let check = try #require(after.range(of: #"(tty of aTab as text) is "/dev/ttys004""#))
        let alone = try #require(after.range(of: #"do script """#))
        #expect(check.upperBound < alone.lowerBound)
    }

    @Test
    func aReplyLineHasNoControlCharacter() {
        #expect(ReplySender.line("fix\u{1b}[A it\tnow\r\nplease") == "fix [A it now please")
        #expect(ReplySender.line("\u{1b}\u{7}") == nil)
    }

    @Test
    func aReplyToATerminalTabIsTypedThere() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term")
        #expect(await rig.engine.reply(sessionID: "term", text: "/compact") == .sent)
        #expect(rig.typed.current.map(\.0) == [.terminal(tty: Self.tty)])
        #expect(rig.typed.current.map(\.1) == ["/compact"])
    }

    // MARK: Folding (P1300, P1302)

    @Test
    func aSessionFoldsOnlyWithAKnownTab() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term")
        Self.session(rig.engine, "warp", terminal: "Warp")
        Self.session(rig.engine, "running", running: true)
        rig.engine.ingest(F.started("ended"), ingress: .bridge)
        rig.engine.ingest(note: Self.note("ended"))
        rig.engine.ingest(F.sessionEnd("ended"), ingress: .bridge)
        #expect(rig.engine.canFold(sessionID: "term"))
        // A turn that runs folds too: its reply waits for the turn's end.
        #expect(rig.engine.canFold(sessionID: "running"))
        #expect(!rig.engine.canFold(sessionID: "warp") && !rig.engine.canFold(sessionID: "ended") && !rig.engine.canFold(sessionID: "none"))
        #expect(await rig.engine.fold(sessionID: "warp") == .refused)
        #expect(await rig.engine.fold(sessionID: "term") == .folded(bounds: TuckBounds(left: 100, top: 80, right: 900, bottom: 600)))
        #expect(rig.engine.folds["term"]?.tucked == true && rig.engine.isFolded("term"))
        #expect(rig.tucks.current.map(\.0) == [.tuck] && rig.tucks.current.map(\.1) == [.terminal(tty: Self.tty)])
        // Once folded, never twice.
        #expect(!rig.engine.canFold(sessionID: "term"))
        #expect(await rig.engine.fold(sessionID: "term") == .refused)
        #expect(rig.tucks.current.count == 1)
    }

    /// A window that holds other tabs stays where it is, and the card says nothing of it; so does one whose script
    /// failed.
    @Test
    func aWindowThatHoldsMoreThanThisTabStays() async {
        for answer in [TuckOutcome.kept, .failed, .stayed(nil)] {
            let rig = Self.rig(tuck: answer)
            Self.session(rig.engine, "term")
            #expect(await rig.engine.fold(sessionID: "term") == .folded(bounds: nil))
            #expect(rig.engine.folds["term"]?.tucked == false)
        }
        // P1360: one that stayed for its other tabs gives its bounds, so the motion plays from it; it is not tucked.
        let bounds = TuckBounds(left: 10, top: 40, right: 810, bottom: 640)
        let rig = Self.rig(tuck: .stayed(bounds))
        Self.session(rig.engine, "term")
        #expect(await rig.engine.fold(sessionID: "term") == .folded(bounds: bounds))
        #expect(rig.engine.folds["term"]?.tucked == false)
        // P1421: Open in terminal still asks its window back, which the script leaves as it is unless it is in the Dock
        // now (the owner may have put it there since).
        _ = await rig.engine.openFolded(sessionID: "term")
        #expect(rig.tucks.current.map(\.0) == [.tuck, .untuck])
    }

    @Test
    func aHeadlessEngineTucksNothing() async {
        let rig = Self.rig(tuck: nil)
        Self.session(rig.engine, "term")
        #expect(await rig.engine.fold(sessionID: "term") == .folded(bounds: nil))
        #expect(rig.engine.folds["term"]?.tucked == false && rig.tucks.current.isEmpty)
    }

    @Test
    func theWindowsBoundsBecomeAppKitsFrame() {
        let bounds = TuckBounds(left: 100, top: 80, right: 900, bottom: 600)
        #expect(bounds.frame(mainDisplayHeight: 1117) == CGRect(x: 100, y: 517, width: 800, height: 520))
        #expect(TuckBounds(left: 5, top: 5, right: 5, bottom: 9).frame(mainDisplayHeight: 900) == nil)
    }

    // MARK: The held reply (P1306)

    @Test
    func aReplyWhileTheTurnRunsIsHeldAndTypedOnceAtItsEnd() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term", running: true)
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "then run the tests")
        #expect(rig.engine.folds["term"]?.held == "then run the tests")
        // Mid-turn: nothing is typed, whatever the clock does, and an approval keeps it waiting too.
        rig.runChecks(5)
        rig.engine.ingest(F.permission("term"), ingress: .bridge)
        rig.runChecks(5)
        #expect(rig.typed.current.isEmpty)
        rig.engine.ingest(F.running("term"), ingress: .bridge)
        rig.engine.ingest(F.completed("term"), ingress: .bridge)
        #expect(rig.typed.current.isEmpty)
        rig.runChecks(2)
        await Self.settle()
        #expect(rig.typed.current.map(\.1) == ["then run the tests"])
        #expect(rig.engine.folds["term"]?.held == nil && rig.engine.folds["term"]?.send == .sent)
        // The next events and checks never type it again.
        rig.engine.ingest(F.completed("term"), ingress: .bridge)
        rig.runChecks(5)
        await Self.settle()
        #expect(rig.typed.current.count == 1)
    }

    @Test
    func aHeldReplyCanBeCancelledOrReplaced() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term", running: true)
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "run the tests")
        await rig.engine.replyFolded(sessionID: "term", text: "and push if green")
        // W6-R4: the second joins the first; neither is dropped.
        #expect(rig.engine.folds["term"]?.held == "run the tests and push if green")
        rig.engine.cancelHeldReply(sessionID: "term")
        rig.engine.ingest(F.completed("term"), ingress: .bridge)
        rig.runChecks(3)
        await Self.settle()
        #expect(rig.typed.current.isEmpty && rig.engine.folds["term"]?.held == nil)
    }

    @Test
    func aReplyAtThePromptIsTypedAtOnceAndSentGivesWayToWorking() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "ship it")
        #expect(rig.typed.current.map(\.1) == ["ship it"])
        #expect(rig.engine.folds["term"]?.send == .sent && rig.engine.folds["term"]?.lastReply == "ship it")
        // Its turn begins: the card reads Working, not Sent.
        rig.engine.ingest(F.prompt("term", "ship it"), ingress: .bridge)
        #expect(rig.engine.folds["term"]?.send == nil)
        #expect(rig.engine.foldTurnRuns("term"))
    }

    @Test
    func aReplyThatCouldNotBeTypedSaysNotSentAndRetries() async {
        let rig = Self.rig(sends: false)
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "ship it")
        #expect(rig.engine.folds["term"]?.send == .notSent)
        await rig.engine.retryFolded(sessionID: "term")
        #expect(rig.typed.current.map(\.1) == ["ship it", "ship it"])
    }

    // MARK: The tab gone (P1303, P1304)

    @Test
    func whenTheTabIsGoneTheReplyGoesOnThroughTheResume() async {
        let rig = Self.rig()
        let resume = FakeResume()
        resume.offer = .resume(note: "Codex runs this without asking.")
        rig.engine.conversationResume = resume
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        #expect(rig.engine.foldReach("term") == .tab)
        // The tab closed: its agent no longer holds a terminal.
        rig.atPrompt.update { $0 = false }
        #expect(rig.engine.foldReach("term") == .resume(note: "Codex runs this without asking."))
        await rig.engine.replyFolded(sessionID: "term", text: "go on")
        #expect(rig.typed.current.isEmpty)
        #expect(resume.continued.map(\.1) == ["go on"] && resume.continued.map(\.0) == ["term"])
        #expect(rig.engine.folds["term"]?.send == .sent)
        // Its note is said before the first resumed reply only.
        #expect(rig.engine.foldReach("term") == .resume(note: nil))
    }

    @Test
    func withNoResumeTheCardOnlyOpens() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        rig.atPrompt.update { $0 = false }
        #expect(rig.engine.foldReach("term") == .openOnly)
        await rig.engine.replyFolded(sessionID: "term", text: "go on")
        #expect(rig.typed.current.isEmpty && rig.engine.folds["term"]?.send == .notSent)
        let resume = FakeResume()
        resume.offer = .openOnly
        rig.engine.conversationResume = resume
        #expect(rig.engine.foldReach("term") == .openOnly)
    }

    @Test
    func aResumedRunHoldsTheReplyUntilItsProcessEnds() async {
        let rig = Self.rig()
        let resume = FakeResume()
        rig.engine.conversationResume = resume
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        rig.atPrompt.update { $0 = false }
        resume.running = ["term"]
        await rig.engine.replyFolded(sessionID: "term", text: "and the docs")
        #expect(rig.engine.folds["term"]?.held == "and the docs" && resume.continued.isEmpty)
        rig.runChecks(3)
        await Self.settle()
        #expect(resume.continued.isEmpty)
        resume.running = []
        rig.runChecks(2)
        await Self.settle()
        #expect(resume.continued.map(\.1) == ["and the docs"])
    }

    @Test
    func stopEndsTheRunAndDropsTheHeldReply() async {
        let rig = Self.rig()
        let resume = FakeResume()
        rig.engine.conversationResume = resume
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        rig.atPrompt.update { $0 = false }
        resume.running = ["term"]
        await rig.engine.replyFolded(sessionID: "term", text: "and the docs")
        rig.engine.stopFolded(sessionID: "term")
        #expect(resume.stopped == ["term"] && rig.engine.folds["term"]?.held == nil)
        resume.running = []
        rig.runChecks(5)
        await Self.settle()
        #expect(resume.continued.isEmpty)
    }

    // MARK: Open in terminal and ✕ (P1305)

    @Test
    func openInTerminalBringsTheWindowBackAndJumpsToTheTab() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        let outcome = await rig.engine.openFolded(sessionID: "term")
        #expect(rig.tucks.current.map(\.0) == [.tuck, .untuck])
        #expect(outcome?.sessionID == "term" && rig.calls.all.contains("osascript"))
        #expect(rig.calls.allScripts.first?.contains(#"(tty of aTab as text) is "/dev/ttys004""#) == true)
        #expect(!rig.engine.isFolded("term"))
    }

    @Test
    func openInTerminalWithTheTabGoneOpensTheConversationAgain() async {
        let rig = Self.rig()
        let resume = FakeResume()
        rig.engine.conversationResume = resume
        Self.session(rig.engine, "term")
        _ = await rig.engine.fold(sessionID: "term")
        rig.atPrompt.update { $0 = false }
        resume.opens = false
        #expect(await rig.engine.openFolded(sessionID: "term") == nil)
        #expect(rig.engine.folds["term"]?.notOpened == true)
        resume.opens = true
        _ = await rig.engine.openFolded(sessionID: "term")
        #expect(resume.opened == ["term", "term"] && !rig.engine.isFolded("term"))
        // No window was brought back and no tab jumped to: the tab is gone.
        #expect(rig.tucks.current.map(\.0) == [.tuck] && rig.calls.all.isEmpty)
    }

    @Test
    func dismissUnfoldsWithoutOpening() async {
        let rig = Self.rig()
        Self.session(rig.engine, "term", running: true)
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "later")
        rig.engine.unfold(sessionID: "term")
        rig.engine.ingest(F.completed("term"), ingress: .bridge)
        rig.runChecks(3)
        await Self.settle()
        #expect(!rig.engine.isFolded("term") && rig.typed.current.isEmpty)
        #expect(rig.tucks.current.map(\.0) == [.tuck] && rig.calls.all.isEmpty)
        #expect(rig.engine.canFold(sessionID: "term"))
    }

    @Test
    func theFrontTabIsTheOneTheKeySends() async {
        let front = Box<String?>("b")
        let engine = F.engine(isFrontmost: { session in session.id == front.current }, configure: { dependencies in
            dependencies.ttyForPID = { _ in SessionFoldTests.tty }
        })
        for id in ["a", "b"] { Self.session(engine, id) }
        #expect(await engine.frontmostFoldable() == "b")
        front.update { $0 = "warp" }
        #expect(await engine.frontmostFoldable() == nil)
    }

    /// Lets the tasks the checks started run.
    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// The tuck's scripts and their answers (P1302): a window that holds the tab alone goes into the Dock, its bounds read
/// and nothing else of it; any other window stays.
struct TerminalTuckTests {
    static let tty = "/dev/ttys004"

    @Test
    func aWindowIsTuckedOnlyWhenItHoldsTheTabAlone() throws {
        let terminal = try #require(TerminalTuck.script(.tuck, .terminal(tty: Self.tty)))
        #expect(terminal.contains(#"tell application id "com.apple.Terminal""#))
        #expect(terminal.contains(#"if (tty of aTab as text) is "/dev/ttys004" then"#))
        #expect(terminal.contains(#"if not ((count of tabs of aWindow) is 1) then return "stayed" & placed"#))
        #expect(terminal.contains("set b to bounds of aWindow") && terminal.contains("set miniaturized of aWindow to true"))
        let iterm = try #require(TerminalTuck.script(.tuck, .iterm(sessionID: "UUID-A", tty: Self.tty)))
        #expect(iterm.contains(#"if (id of aSession as text) is "UUID-A" then"#))
        #expect(iterm.contains(#"(tty of aSession as text) is not "/dev/ttys004" then return """#))
        #expect(iterm.contains("(count of tabs of aWindow) is 1 and (count of sessions of aTab) is 1"))
        let ghostty = try #require(TerminalTuck.script(.tuck, .ghostty(terminalID: "TERM-1")))
        #expect(ghostty.contains(#"tell application id "com.mitchellh.ghostty""#))
        #expect(ghostty.contains("(count of tabs of aWindow) is 1 and (count of terminals of aTab) is 1"))
        // A tmux pane's outer window is not known exactly: it stays.
        #expect(TerminalTuck.script(.tuck, .tmux(pane: "%1", socket: "/tmp/tmux")) == nil)
        for script in [terminal, iterm, ghostty] {
            // Nothing is brought forward, selected or read of what the window shows.
            for word in ["activate", "select", "contents", "history", "do script", "write text"] {
                #expect(!script.contains(word), "\(word)")
            }
            #expect(script.contains(#"if not (it is running) then return """#))
        }
    }

    /// W6-R6: a window that holds other tabs stays, but its bounds are read first, so the fold's motion plays from it.
    @Test
    func aWindowThatStaysStillGivesItsBounds() throws {
        let terminal = try #require(TerminalTuck.script(.tuck, .terminal(tty: Self.tty)))
        let bounds = try #require(terminal.range(of: "set b to bounds of aWindow"))
        let alone = try #require(terminal.range(of: "if not ((count of tabs of aWindow) is 1)"))
        #expect(bounds.upperBound < alone.lowerBound)
    }

    @Test
    func aWindowComesBackOutOfTheDock() throws {
        let script = try #require(TerminalTuck.script(.untuck, .terminal(tty: Self.tty)))
        #expect(script.contains("if miniaturized of aWindow then set miniaturized of aWindow to false"))
        #expect(!script.contains("to true") && !script.contains("activate"))
    }

    @Test
    func theScriptsAnswerIsRead() {
        #expect(TerminalTuck.parse("tucked\u{1f}100\u{1f}80\u{1f}900\u{1f}600\n")
            == .tucked(TuckBounds(left: 100, top: 80, right: 900, bottom: 600)))
        #expect(TerminalTuck.parse("tucked") == .tucked(nil))
        #expect(TerminalTuck.parse("tucked\u{1f}x") == .tucked(nil))
        #expect(TerminalTuck.parse("kept") == .kept && TerminalTuck.parse("restored") == .restored)
        #expect(TerminalTuck.parse("stayed\u{1f}0\u{1f}25\u{1f}700\u{1f}500") == .stayed(TuckBounds(left: 0, top: 25, right: 700, bottom: 500)))
        #expect(TerminalTuck.parse("stayed") == .stayed(nil))
        #expect(TerminalTuck.parse("") == .failed && TerminalTuck.parse("matched") == .failed)
    }
}
