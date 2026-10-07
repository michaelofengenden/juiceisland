import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Wave 8 from end to end (P1537): one engine wired as the app wires it, with Claude Code's background
/// (`ClaudeBackgrounder`), the resume with Codex's shared daemon (`SessionResumer`) and the hand-over to an agent's app
/// (`SessionHandoff`) all on it, and the hand-over reaching the other two through the engine alone, as `LiveSessions`
/// leaves it (no wiring closure given). Every seam is a stand-in: each `claude` command is `ClaudeBackgroundTests.FakeClaude`,
/// the hidden attach a `FakeTerminal`, the daemon `CodexServiceTests.FakeDaemon`, each window, app, link and tab a
/// recorder. No CLI, pty, socket, terminal, app or link of this Mac's is touched; folders are fictional.
@MainActor
struct HandoverEndToEndTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box
    typealias B = ClaudeBackgroundTests
    typealias Daemon = CodexServiceTests.FakeDaemon

    nonisolated static let home = "/tmp/ji-handover"
    nonisolated static let folder = "/tmp/ji-handover/project"
    nonisolated static let claudeProfile = home + "/.claude"
    nonisolated static let codexHome = home + "/.codex"
    nonisolated static let tty = "/dev/ttys006"
    /// The tab's agent and its shell: `FoldStopTests`' own, as its approval hooks name them.
    nonisolated static let agent = FoldStopTests.agent
    nonisolated static let shell = FoldStopTests.shell
    nonisolated static let daemonPID: Int32 = 6060
    nonisolated static let backgroundPID = 6200
    nonisolated static let attachPID: Int32 = 7100
    /// The interactive Claude Code session in its Terminal tab, and the id Claude Code goes on under in its background.
    static let tabID = "8b2f6d1e-4c3a-4e5f-9a0b-1c2d3e4f5a6b"
    static let newID = B.newID
    static let short = B.short
    static let codexID = "019a8d4e-5f60-7a71-8b9c-0d1e2f3a4b5c"

    /// One engine with every lane's part on it, and every seam recorded.
    @MainActor
    final class Rig {
        let engine: SessionEngine
        let resumer: SessionResumer
        let handoff: SessionHandoff
        let claude: B.FakeClaude
        let terminal = B.FakeTerminal()
        let scheduled = Box<[F.ScheduledCheck]>([])
        let clock = Box(F.now)
        /// The pids that run: the tab's agent and its shell to start with.
        let alive = Box<Set<Int32>>([HandoverEndToEndTests.agent, HandoverEndToEndTests.shell])
        /// Codex app-servers (the shared daemon): alive, never at a prompt.
        let daemons = Box<Set<Int32>>([])
        let exits = Box<[(Int32, @MainActor @Sendable () -> Void)]>([])
        /// What was typed into a tab, and where.
        let typed = Box<[(ReplyRoute, String)]>([])
        /// A typed `/desktop`, `/quit` or `/exit` ends the tab's CLI, as those commands do.
        let quits = Box(true)
        /// Runs as a reply's keystrokes land, on the queue the terminal's script runs on (before the send returns).
        let whileTyping = Box<(@Sendable (String) -> Void)?>(nil)
        let front = Box(false)
        /// `claude attach <id>` processes a scan finds (a window attached to the background copy).
        let attached = Box<[Int32]>([])
        let attaches = Box<[ClaudeBackgroundCommand]>([])
        /// Open in terminal's windows: the background card's attach, and the resume's.
        let attachWindows = Box<[FreshSessionLaunch]>([])
        let resumeWindows = Box<[FreshSessionLaunch]>([])
        let runs = Box<[SessionResumeTests.FakeRun]>([])
        /// The hand-over's own CLI runs (`claude --version`, `claude --desktop --resume`), its links, apps and scan.
        let cli = Box<[[String]]>([])
        let version = Box("2.1.285 (Claude Code)")
        let links = Box<[String]>([])
        let opened = Box<[URL]>([])
        let appsRunning = Box<Set<HandoffApp>>([])
        let found = Box<[Int32]>([])

        init(lists: [String] = ["[]"], daemon: Daemon? = nil) {
            let scheduled = scheduled, clock = clock, alive = alive, daemons = daemons, exits = exits, typed = typed, quits = quits
            let whileTyping = whileTyping, front = front, attached = attached, attaches = attaches, attachWindows = attachWindows, resumeWindows = resumeWindows
            let runs = runs, cli = cli, version = version, links = links, opened = opened, appsRunning = appsRunning, found = found
            let terminal = terminal
            let calls = ExactJumpTests.Calls()
            let runner = ExactJumpTests.runner(calls: calls, running: [ExactJumpTests.terminal], frontmost: ExactJumpTests.terminal,
                                               script: { _ in "matched\u{1f}\(HandoverEndToEndTests.tty)" })
            engine = F.engine(clock: clock, scheduled: scheduled, isFrontmost: { _ in front.current }, replies: { route, text in
                typed.update { $0.append((route, text)) }
                whileTyping.current?(text)
                if quits.current, text.hasPrefix("/"), text != SessionEngine.backgroundCommand {
                    alive.update { $0.remove(HandoverEndToEndTests.agent) }
                }
                return true
            }, atPrompt: { alive.current.contains($0) }) { dependencies in
                dependencies.ttyForPID = { alive.current.contains($0) ? HandoverEndToEndTests.tty : nil }
                dependencies.processExists = { alive.current.contains($0) || daemons.current.contains($0) }
                dependencies.isCodexServer = { daemons.current.contains($0) }
                dependencies.parentPID = { $0 == HandoverEndToEndTests.agent ? HandoverEndToEndTests.shell : nil }
                dependencies.processName = { pid in
                    alive.current.contains(pid) ? (pid == HandoverEndToEndTests.shell ? "zsh" : "claude") : nil
                }
                dependencies.jumpRunner = runner
                dependencies.tuckWindow = { move, _ in
                    move == .untuck ? .restored : .tucked(TuckBounds(left: 100, top: 80, right: 900, bottom: 600))
                }
                dependencies.scheduleFoldCheck = { delay, check in
                    scheduled.update { $0.append(F.ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
                }
                dependencies.watchProcessExit = { pid, exited in
                    exits.update { $0.append((pid, exited)) }
                    return FoldStopTests.Token {}
                }
            }
            engine.keepsClaudeRunning = true

            // Claude Code's background, as `LiveSessions` makes it, with stand-ins for every command.
            let claude = B.FakeClaude(lists: lists)
            self.claude = claude
            var background = ClaudeBackgrounder.Dependencies()
            background.run = { claude.run($0, $1) }
            background.attach = { command in
                attaches.update { $0.append(command) }
                return terminal
            }
            background.openWindow = { launch in
                attachWindows.update { $0.append(launch) }
                return true
            }
            background.findAttached = { _ in attached.current }
            background.hasRoster = { _ in false }
            background.usualHost = { .terminal }
            background.environment = { ["SHELL": "/bin/zsh", "OPEN_ISLAND_SKIP_HOOKS": "1"] }
            background.sleep = { _ in await Task.yield() }
            engine.claudeBackground = ClaudeBackgrounder(engine: engine, dependencies: background)

            // The resume, with Codex's shared daemon behind it.
            var resume = SessionResumer.Dependencies()
            resume.start = { _ in
                var made: SessionResumeTests.FakeRun!
                runs.update {
                    made = SessionResumeTests.FakeRun(pid: Int32(7000 + $0.count))
                    $0.append(made)
                }
                return made
            }
            resume.openWindow = { launch in
                resumeWindows.update { $0.append(launch) }
                return true
            }
            resume.isFolder = { _ in true }
            resume.usualHost = { .terminal }
            resume.findAgents = { _ in [] }
            resume.environment = { ["SHELL": "/bin/zsh"] }
            resume.sleep = { _ in }
            resume.quitGrace = 0
            resume.daemon = daemon
            resumer = SessionResumer(engine: engine, dependencies: resume)
            engine.conversationResume = resumer

            // The hand-over: only its own CLI runs, apps, links and scan are stand-ins. The list, the stop, the moved id,
            // the daemon's answer and the server check come through the engine, as in the app (P1532).
            var apps = SessionHandoff.Dependencies()
            apps.run = { command in
                cli.update { $0.append(command.arguments) }
                return command.arguments == ["--version"] ? HandoffResult(status: 0, output: version.current) : HandoffResult(status: 0)
            }
            apps.appURL = { URL(fileURLWithPath: "/Applications/\($0.name).app") }
            apps.isAppRunning = { appsRunning.current.contains($0) }
            apps.appName = { $0 == .codex ? "ChatGPT" : $0.name }
            apps.openApp = { url, _ in
                opened.update { $0.append(url) }
                return true
            }
            apps.openLink = { link in
                links.update { $0.append(link) }
                return true
            }
            apps.findAgents = { _ in found.current }
            apps.hasRoster = { true }
            apps.sleep = { _ in await Task.yield() }
            apps.exitLooks = 4
            apps.stopLooks = 3
            apps.home = HandoverEndToEndTests.home
            handoff = SessionHandoff(engine: engine, dependencies: apps)
            engine.appHandoff = handoff
        }

        func runChecks(_ seconds: TimeInterval = 2) { F.runScheduledChecks(scheduled, clock: clock, for: seconds) }

        func settle(until condition: () -> Bool = { false }) async {
            for _ in 0..<400 where !condition() { await Task.yield() }
        }

        /// One look of a background move: its clock moves on, and the look it scheduled runs.
        func look(_ looks: Int = 1, id: String = HandoverEndToEndTests.tabID) async {
            for _ in 0..<looks {
                runChecks(2)
                await engine.backgroundMoveStarted(id)
            }
        }

        var typedText: [String] { typed.current.map(\.1) }
        /// Every `claude` command any part ran, with its arguments: the family's and the hand-over's.
        var claudeArguments: [[String]] { claude.commands.map(\.arguments) + cli.current }

        /// A Claude Code session of the default profile working in a Terminal tab.
        func claudeTab(_ id: String = HandoverEndToEndTests.tabID, working: Bool = true) {
            engine.ingest(F.started(id, transcript: "\(HandoverEndToEndTests.claudeProfile)/projects/-tmp-ji-handover-project/\(id).jsonl",
                                    cwd: HandoverEndToEndTests.folder), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: HandoverEndToEndTests.agent,
                                                hostBundleID: ExactJumpTests.terminal, entrypoint: "cli", source: "claude"))
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(working ? F.running(id) : F.completed(id), ingress: .bridge)
        }

        /// The background copy's own hooks (it is a Claude Code process with hooks on, under Claude Code's supervisor).
        func backgroundHooks(_ id: String = HandoverEndToEndTests.newID, working: Bool) {
            if engine.state.session(id: id) == nil {
                engine.ingest(F.started(id, transcript: "\(HandoverEndToEndTests.claudeProfile)/projects/-tmp-ji-handover-project/\(id).jsonl",
                                        cwd: HandoverEndToEndTests.folder), ingress: .bridge)
                engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: Int32(HandoverEndToEndTests.backgroundPID),
                                                    entrypoint: "cli", source: "claude"))
            }
            engine.ingest(working ? F.running(id, summary: "Running Bash: swift test") : F.completed(id), ingress: .bridge)
        }

        /// A Codex session of the default home that Codex's shared daemon runs (its hooks name the daemon), its turn running
        /// unless `running` is false.
        func codexInDaemon(running: Bool = true) {
            daemons.update { $0.insert(HandoverEndToEndTests.daemonPID) }
            engine.ingest(F.started(HandoverEndToEndTests.codexID, tool: .codex,
                                    transcript: "\(HandoverEndToEndTests.codexHome)/sessions/2026/10/06/rollout-\(HandoverEndToEndTests.codexID).jsonl",
                                    cwd: HandoverEndToEndTests.folder, terminal: "Terminal"), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: HandoverEndToEndTests.codexID,
                                                agentPID: HandoverEndToEndTests.daemonPID, hostBundleID: ExactJumpTests.terminal,
                                                entrypoint: "cli", source: "codex"))
            engine.ingest(F.prompt(HandoverEndToEndTests.codexID), ingress: .bridge)
            if !running { engine.ingest(F.completed(HandoverEndToEndTests.codexID), ingress: .bridge) }
        }

        /// A CLI session of another agent in a Terminal tab, at its prompt.
        func other(_ id: String, tool: AgentTool, source: String) {
            engine.ingest(F.started(id, tool: tool, cwd: HandoverEndToEndTests.folder), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: HandoverEndToEndTests.agent,
                                                hostBundleID: ExactJumpTests.terminal, source: source))
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(F.completed(id), ingress: .bridge)
        }
    }

    /// Claude Code's list before `/background`: the tab's interactive row, and another session's background row.
    static let before = B.json([B.row("interactive", session: tabID, pid: Int(agent), cwd: folder),
                                B.row("background", id: "a1b2c3d4", session: "11111111-2222-3333-4444-555555555555", name: "other work",
                                      state: "done", status: "idle", pid: nil)])

    /// The conversation's background row, under its new id: working, at its prompt, or stopped.
    static func moved(state: String, status: String?, pid: Int? = backgroundPID) -> String {
        B.json([B.row("background", id: short, session: newID, state: state, status: status, pid: pid, cwd: folder)])
    }

    // MARK: Claude Code: the tab, its background, the card, the terminal and Claude (P1537)

    /// The owner's whole sequence for Claude Code: a working session sent to the island moves into Claude Code's
    /// background once the tool it runs lets `/background` through (Claude Code holds it until then, P1451); its window
    /// closes and it is still Working, never "Stopped"; a reply from the card reaches it through the hidden attach; Open
    /// in terminal attaches a new window; Open in Claude waits for that window to close, then stops the background copy,
    /// sees it stopped and only then opens it in Claude; the way back waits for Claude to quit and reopens the
    /// conversation with its own resume, never `claude attach` on the stopped copy.
    @Test
    func aWorkingClaudeSessionGoesOnInTheBackgroundWithItsWindowClosedThenInClaude() async throws {
        let rig = Rig(lists: [Self.before, Self.moved(state: "working", status: "busy")])
        rig.claudeTab()
        #expect(await rig.engine.fold(sessionID: Self.tabID) == .folded(bounds: TuckBounds(left: 100, top: 80, right: 900, bottom: 600)))
        await rig.engine.backgroundMoveStarted(Self.tabID)
        #expect(rig.typedText == ["/background"])
        #expect(rig.engine.foldBackground(Self.tabID)?.stage == .moving)
        // No hand-over is offered while the move is under way (P1533).
        #expect(rig.handoff.offer(for: Self.tabID) == nil)
        // Its tool still runs: Claude Code holds the move, and the tab's agent stays.
        await rig.look(3)
        #expect(rig.engine.foldBackground(Self.tabID)?.stage == .moving && rig.engine.foldTurnRuns(Self.tabID))
        // At the tool's end Claude Code moves it: the tab's agent leaves, the conversation goes on under a new id.
        rig.alive.update { $0.remove(Self.agent) }
        for (pid, exited) in rig.exits.current where pid == Self.agent { exited() }
        await rig.look()
        let fold = try #require(rig.engine.folds[Self.newID])
        #expect(fold.background?.stage == .moved && fold.background?.shortID == Self.short && rig.engine.folds[Self.tabID] == nil)
        #expect(rig.engine.isFolded(Self.tabID) && rig.engine.movedConversation(from: Self.tabID) == Self.newID)

        // Its window closes from the Dock: the turn goes on there, still Working, no stop.
        rig.backgroundHooks(working: true)
        rig.alive.update { $0.remove(Self.shell) }
        for (_, exited) in rig.exits.current { exited() }
        rig.runChecks(5)
        await rig.settle()
        #expect(rig.engine.folds[Self.newID]?.stopped == nil && rig.engine.foldTurnRuns(Self.newID))
        #expect(rig.engine.foldReach(Self.newID) == .background)
        #expect(!rig.engine.foldNotes.map(\.said).contains { $0.hasPrefix("stopped mid-turn") })

        // The turn ends; a reply from the card goes through the hidden attach, never on a command line.
        rig.claude.answer([Self.moved(state: "done", status: "idle")])
        rig.backgroundHooks(working: false)
        #expect(!rig.engine.foldTurnRuns(Self.newID))
        await rig.engine.replyFolded(sessionID: Self.newID, text: "now run the tests")
        #expect(rig.engine.folds[Self.newID]?.send == .sent || rig.engine.folds[Self.newID]?.send == nil)
        #expect(rig.attaches.current.map(\.arguments) == [["attach", Self.short]])
        #expect(rig.terminal.typed == "now run the tests")
        #expect(rig.terminal.writes.contains([AttachReply.carriageReturn]) && rig.terminal.writes.contains([AttachReply.controlZ]))
        #expect(!rig.claudeArguments.flatMap { $0 }.contains { $0.contains("run the tests") })
        #expect(rig.typedText == ["/background"])
        rig.backgroundHooks(working: true)
        rig.backgroundHooks(working: false)

        // Open in terminal attaches a new window; the card stays.
        await rig.engine.openFolded(sessionID: Self.newID)
        let window = try #require(rig.attachWindows.current.last)
        #expect(window.line.hasSuffix("claude attach '\(Self.short)'") && window.line.hasPrefix("cd '\(Self.folder)'"))
        #expect(rig.engine.folds[Self.newID]?.background?.attachedIn == "Terminal" && rig.resumeWindows.current.isEmpty)

        // Open in Claude while that window is attached: nothing is stopped (its attach would wake the stopped copy beside
        // Claude, P1536).
        rig.attached.update { $0 = [Self.attachPID] }
        #expect(rig.handoff.offer(for: Self.newID)?.app == .claude)
        await rig.handoff.open(Self.newID)
        #expect(rig.handoff.state(for: Self.newID) == .blocked(.claude, HandoffWords.attached))
        #expect(!rig.claudeArguments.contains(["stop", Self.short]) && !rig.cli.current.contains { $0.contains("--desktop") })

        // The window closes; Open in Claude stops the background copy, sees it stopped, then opens it in Claude.
        rig.attached.update { $0 = [] }
        rig.claude.answer([Self.moved(state: "done", status: "idle"), Self.moved(state: "stopped", status: nil, pid: nil)])
        await rig.handoff.open(Self.newID)
        #expect(rig.handoff.state(for: Self.newID) == .inApp(.claude, note: nil))
        let family = rig.claude.commands.map(\.arguments)
        let stop = try #require(family.firstIndex(of: ["stop", Self.short]))
        #expect(family[(stop + 1)...].contains(["agents", "--json", "--all"]))
        #expect(rig.cli.current.last == ["--desktop", "--resume", Self.newID])
        // The card is the app's now: no reply, no Stop, no background card.
        #expect(rig.engine.foldReach(Self.newID) == .openOnly && rig.engine.folds[Self.newID]?.background == nil)
        #expect(rig.engine.isFolded(Self.tabID))

        // The way back waits for Claude to quit, then reopens the conversation with its own resume.
        rig.appsRunning.update { $0 = [.claude] }
        await rig.engine.openFolded(sessionID: Self.newID)
        #expect(rig.handoff.state(for: Self.newID) == .inApp(.claude, note: HandoffWords.quitApp("Claude")))
        #expect(rig.resumeWindows.current.isEmpty && rig.attachWindows.current.count == 1)
        rig.appsRunning.update { $0 = [] }
        await rig.engine.openFolded(sessionID: Self.newID)
        let back = try #require(rig.resumeWindows.current.last)
        #expect(back.line.contains("claude --resume '\(Self.newID)'") && !back.line.contains("attach"))
        #expect(rig.attachWindows.current.count == 1 && rig.engine.folds[Self.newID] == nil)
        // Nothing went on a command line but ids, and the tab took `/background` alone.
        #expect(rig.typedText == ["/background"])
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said.contains("background · moved, under a new id") && said.contains("open in Claude · opened"))
    }

    /// An approval waits in the tab as it is sent: nothing is typed and no hand-over is offered until its turn ends; then
    /// `/background` goes, and a second Send to island's work is Claude Code's (P1452, P1533).
    @Test
    func aMoveThatWaitsForItsTurnsEndGoesThenAndNoHandOverCrossesIt() async throws {
        let rig = Rig(lists: [Self.before, Self.moved(state: "done", status: "idle")])
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        rig.claudeTab()
        typealias S = AttentionScene
        // As `FoldStopTests.askBash` asks it: the tool, its approval, Claude's notice.
        FoldStopTests.hook(rig.engine, broker, S.claude("PreToolUse", session: Self.tabID, tool: "Bash", input: S.push, toolUseID: "U1"))
        rig.engine.ingest(F.running(Self.tabID, summary: "Running Bash: git push origin main", at: rig.clock.current), ingress: .bridge)
        let request = try #require(FoldStopTests.hook(rig.engine, broker, S.claude("PermissionRequest", session: Self.tabID, tool: "Bash", input: S.push)))
        FoldStopTests.hook(rig.engine, broker, S.notification("permission_prompt", session: Self.tabID))
        _ = await rig.engine.fold(sessionID: Self.tabID)
        await rig.engine.backgroundMoveStarted(Self.tabID)
        #expect(rig.typed.current.isEmpty && rig.engine.foldBackground(Self.tabID)?.stage == .waitsForTurnEnd)
        #expect(rig.handoff.offer(for: Self.tabID) == nil)
        await rig.handoff.open(Self.tabID)
        #expect(rig.handoff.state(for: Self.tabID) == nil && rig.cli.current.isEmpty)
        // The owner allows it on the island; the turn ends; `/background` goes a second later, alone.
        #expect(await rig.engine.approve(requestID: request, decision: .allowOnce) == .sent)
        rig.engine.ingest(F.completed(Self.tabID, at: rig.clock.current), ingress: .bridge)
        rig.runChecks(2)
        await rig.engine.backgroundMoveStarted(Self.tabID)
        #expect(rig.typedText == ["/background"])
        rig.alive.update { $0.remove(Self.agent) }
        await rig.look()
        #expect(rig.engine.folds[Self.newID]?.background?.stage == .moved)
        #expect(rig.handoff.offer(for: Self.newID)?.app == .claude)
    }

    /// A held reply goes first and its own turn ends while its keystrokes are still on their way (the turn's end comes
    /// before the send does): the move that waited looks again once the send is done, and goes (P1538).
    @Test
    func aTurnsEndWhileTheReplyIsOnItsWayStillLetsTheMoveGo() async throws {
        let rig = Rig(lists: [Self.before, Self.moved(state: "done", status: "idle")])
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        rig.claudeTab()
        typealias S = AttentionScene
        FoldStopTests.hook(rig.engine, broker, S.claude("PreToolUse", session: Self.tabID, tool: "Bash", input: S.push, toolUseID: "U1"))
        rig.engine.ingest(F.running(Self.tabID, summary: "Running Bash: git push origin main", at: rig.clock.current), ingress: .bridge)
        let request = try #require(FoldStopTests.hook(rig.engine, broker, S.claude("PermissionRequest", session: Self.tabID, tool: "Bash", input: S.push)))
        FoldStopTests.hook(rig.engine, broker, S.notification("permission_prompt", session: Self.tabID))
        _ = await rig.engine.fold(sessionID: Self.tabID)
        await rig.engine.backgroundMoveStarted(Self.tabID)
        #expect(rig.engine.foldBackground(Self.tabID)?.stage == .waitsForTurnEnd)
        await rig.engine.replyFolded(sessionID: Self.tabID, text: "then run the tests")
        #expect(rig.engine.folds[Self.tabID]?.held == "then run the tests")
        // The reply's turn begins and ends (its hooks come) while its keystrokes are still on their way.
        nonisolated(unsafe) let engine = rig.engine
        let at = rig.clock.current, sendingThen = Box<FoldSend?>(nil)
        rig.whileTyping.update {
            $0 = { text in
                guard text == "then run the tests" else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        sendingThen.update { $0 = engine.folds[HandoverEndToEndTests.tabID]?.send }
                        engine.ingest(F.prompt(HandoverEndToEndTests.tabID, at: at), ingress: .bridge)
                        engine.ingest(F.completed(HandoverEndToEndTests.tabID, at: at), ingress: .bridge)
                    }
                }
            }
        }
        #expect(await rig.engine.approve(requestID: request, decision: .denyAndStop) == .sent)
        rig.runChecks(2)
        try await B.until { rig.typedText == ["then run the tests"] && rig.engine.folds[Self.tabID]?.send != .sending }
        #expect(sendingThen.current == .sending)
        rig.runChecks(2)
        try await B.until { rig.typedText.count == 2 }
        #expect(rig.typedText == ["then run the tests", "/background"])
        #expect(rig.engine.foldBackground(Self.tabID)?.stage == .moving)
    }

    // MARK: Codex: its daemon, the card, the terminal and the Codex app (P1537)

    /// The owner's sequence for Codex: a Codex session its shared daemon runs is sent to the island (no tuck), its
    /// window closes and the daemon still runs the turn (Working, no stop); Open in Codex is not offered while the
    /// daemon holds the thread, mid-turn or after it, as it could only refuse, and a click types nothing (P1544); a reply
    /// goes to the daemon's thread; Open in terminal attaches `codex resume`; once the daemon let the thread go and its
    /// terminal is gone, Open in Codex opens the thread's link.
    @Test
    func aCodexSessionGoesOnInItsDaemonWithItsWindowClosedThenInCodex() async throws {
        let daemon = Daemon(.active(waitsOnYou: false))
        let rig = Rig(daemon: daemon)
        rig.codexInDaemon()
        await rig.settle { rig.resumer.serviceStatus(Self.codexID) != nil }
        #expect(await rig.engine.fold(sessionID: Self.codexID) == .folded(bounds: nil))
        #expect(rig.engine.foldReach(Self.codexID).way == .daemon && rig.engine.foldTurnRuns(Self.codexID))

        // Its window closes: the client goes, the daemon goes on with the turn.
        rig.runChecks(30)
        await rig.settle()
        #expect(rig.engine.folds[Self.codexID]?.stopped == nil && rig.engine.foldTurnRuns(Self.codexID))

        // Open in Codex is not offered while the daemon holds the thread, mid-turn or after it (P1544).
        #expect(rig.handoff.offer(for: Self.codexID) == nil)
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == nil)
        daemon.status.update { $0 = .idle }
        rig.engine.ingest(F.completed(Self.codexID), ingress: .bridge)
        await rig.settle { rig.resumer.serviceStatus(Self.codexID) == .idle }
        rig.runChecks(2)
        await rig.settle()
        #expect(rig.handoff.offer(for: Self.codexID) == nil && rig.handoff.state(for: Self.codexID) == nil)
        #expect(rig.typed.current.isEmpty && rig.links.current.isEmpty)

        // A reply goes to the daemon's thread, the text inside the message.
        #expect(rig.engine.foldReach(Self.codexID).way == .daemon)
        await rig.engine.replyFolded(sessionID: Self.codexID, text: "then run the linter")
        await rig.settle { !daemon.started.current.isEmpty }
        #expect(daemon.started.current == [Daemon.Turn(thread: Self.codexID, home: Self.codexHome, text: "then run the linter")])
        #expect(rig.typed.current.isEmpty && rig.runs.current.isEmpty)
        daemon.status.update { $0 = .idle }
        rig.runChecks(12)
        await rig.settle { !rig.resumer.isRunning(Self.codexID) }

        // Open in terminal attaches `codex resume` in a new window; the card goes.
        await rig.engine.openFolded(sessionID: Self.codexID)
        let window = try #require(rig.resumeWindows.current.last)
        #expect(window.line.contains("codex resume '\(Self.codexID)'"))
        #expect(rig.engine.folds[Self.codexID] == nil)

        // The owner quits that terminal; the daemon lets the thread go; Open in Codex opens it.
        daemon.status.update { $0 = .notHeld }
        rig.engine.ingest(F.sessionEnd(Self.codexID), ingress: .bridge)
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == .inApp(.codex, note: nil))
        #expect(rig.links.current == [ExactJump.codexThreadLink(Self.codexID)])
        #expect(rig.typed.current.isEmpty)
    }

    // MARK: Every hand-over refuses while its source is alive (P1537)

    /// Claude Code: a CLI that stays in its tab, a working background copy, one that does not stop, a closed tab whose
    /// conversation still runs elsewhere, an interactive copy Claude Code lists, a list that cannot be read. Nothing is
    /// opened in Claude, and nothing working is ever stopped.
    @Test
    func everyClaudeHandOverRefusesWhileItsSourceIsAlive() async {
        // Its CLI stays after `/desktop`.
        var rig = Rig()
        rig.engine.keepsClaudeRunning = false
        rig.quits.update { $0 = false }
        rig.claudeTab(working: false)
        await rig.handoff.open(Self.tabID)
        #expect(rig.handoff.state(for: Self.tabID) == .blocked(.claude, HandoffWords.stayedInTab))
        #expect(rig.typedText == ["/desktop"] && rig.cli.current.isEmpty)

        // A working background copy (folded): it waits for the turn's end and is never stopped.
        rig = Rig(lists: [Self.before, Self.moved(state: "working", status: "busy")])
        rig.claudeTab()
        _ = await rig.engine.fold(sessionID: Self.tabID)
        await rig.engine.backgroundMoveStarted(Self.tabID)
        rig.alive.update { $0.remove(Self.agent) }
        await rig.look()
        rig.backgroundHooks(working: true)
        await rig.handoff.open(Self.newID)
        #expect(rig.handoff.state(for: Self.newID) == .pending(.claude))
        #expect(!rig.claudeArguments.contains(["stop", Self.short]) && !rig.cli.current.contains { $0.contains("--desktop") })

        // A background copy that does not stop: it is not handed over.
        rig = Rig(lists: [Self.before, Self.moved(state: "done", status: "idle")])
        rig.claudeTab()
        _ = await rig.engine.fold(sessionID: Self.tabID)
        await rig.engine.backgroundMoveStarted(Self.tabID)
        rig.alive.update { $0.remove(Self.agent) }
        await rig.look()
        rig.backgroundHooks(working: false)
        await rig.handoff.open(Self.newID)
        #expect(rig.handoff.state(for: Self.newID) == .blocked(.claude, HandoffWords.backgroundStayed))
        #expect(!rig.cli.current.contains { $0.contains("--desktop") })

        // A closed tab whose conversation a process still runs (found by its arguments, P1420), and one Claude Code lists
        // as an interactive copy elsewhere.
        for (found, list) in [([Int32(7777)], "[]"),
                              ([], B.json([B.row("interactive", session: Self.tabID, pid: 6300, cwd: Self.folder)]))] {
            rig = Rig(lists: [list])
            rig.engine.keepsClaudeRunning = false
            rig.claudeTab(working: false)
            rig.alive.update { $0.remove(Self.agent) }
            rig.engine.ingest(F.sessionEnd(Self.tabID), ingress: .bridge)
            rig.found.update { $0 = found }
            await rig.handoff.open(Self.tabID)
            #expect(rig.handoff.state(for: Self.tabID) == .blocked(.claude, HandoffWords.stillRuns))
            #expect(!rig.cli.current.contains { $0.contains("--desktop") })
        }

        // A list that cannot be read cannot say no copy runs it.
        rig = Rig(lists: ["fail"])
        rig.engine.keepsClaudeRunning = false
        rig.claudeTab(working: false)
        rig.alive.update { $0.remove(Self.agent) }
        rig.engine.ingest(F.sessionEnd(Self.tabID), ingress: .bridge)
        await rig.handoff.open(Self.tabID)
        #expect(rig.handoff.state(for: Self.tabID) == .blocked(.claude, HandoffWords.noList))
        #expect(!rig.cli.current.contains { $0.contains("--desktop") })
    }

    /// Codex and the apps that list a CLI's sessions: the daemon holding the thread (nothing typed), a TUI that stays
    /// after `/quit`, an OpenCode CLI that stays after `/exit`. No link and no app opens.
    @Test
    func everyCodexAndAppHandOverRefusesWhileItsSourceIsAlive() async {
        // The daemon holds the thread: it is not offered (P1544), and a click types and opens nothing.
        let daemon = Daemon(.idle)
        var rig = Rig(daemon: daemon)
        rig.codexInDaemon(running: false)
        await rig.settle { rig.resumer.serviceStatus(Self.codexID) != nil }
        #expect(rig.handoff.offer(for: Self.codexID) == nil)
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == nil)
        #expect(rig.typed.current.isEmpty && rig.links.current.isEmpty)
        // Its TUI quit: the word is no longer kept fresh, so the click asks the daemon itself and says it holds it.
        rig.engine.ingest(F.sessionEnd(Self.codexID), ingress: .bridge)
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == .blocked(.codex, ResumeExit.heldElsewhereWords))
        #expect(rig.typed.current.isEmpty && rig.links.current.isEmpty)

        // A Codex TUI of its own (`--no-daemon`) that stays after `/quit`.
        rig = Rig()
        rig.quits.update { $0 = false }
        rig.engine.ingest(F.started(Self.codexID, tool: .codex,
                                    transcript: "\(Self.codexHome)/sessions/2026/10/06/rollout-\(Self.codexID).jsonl", cwd: Self.folder,
                                    terminal: "Terminal"), ingress: .bridge)
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.codexID, agentPID: Self.agent,
                                                hostBundleID: ExactJumpTests.terminal, source: "codex"))
        rig.engine.ingest(F.prompt(Self.codexID), ingress: .bridge)
        rig.engine.ingest(F.completed(Self.codexID), ingress: .bridge)
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == .blocked(.codex, HandoffWords.stayedInTab))
        #expect(rig.typedText == ["/quit"] && rig.links.current.isEmpty)

        // OpenCode's CLI that stays after `/exit`.
        rig = Rig()
        rig.quits.update { $0 = false }
        rig.other("opencode-1", tool: .openCode, source: "opencode")
        await rig.handoff.open("opencode-1")
        #expect(rig.handoff.state(for: "opencode-1") == .blocked(.opencode, HandoffWords.stayedInTab))
        #expect(rig.typedText == ["/exit"] && rig.opened.current.isEmpty)
    }

    /// The way back from an app refuses while the app may hold the conversation: Claude while it runs, the Codex app
    /// while it runs, and Codex's daemon while it has the thread loaded (P1517).
    @Test
    func theWayBackRefusesWhileTheAppHoldsIt() async {
        let rig = Rig()
        rig.engine.keepsClaudeRunning = false
        rig.claudeTab(working: false)
        _ = await rig.engine.fold(sessionID: Self.tabID)
        await rig.handoff.open(Self.tabID)
        #expect(rig.handoff.state(for: Self.tabID) == .inApp(.claude, note: nil) && rig.typedText == ["/desktop"])
        rig.appsRunning.update { $0 = [.claude] }
        await rig.engine.openFolded(sessionID: Self.tabID)
        #expect(rig.handoff.state(for: Self.tabID) == .inApp(.claude, note: HandoffWords.quitApp("Claude")))
        #expect(rig.resumeWindows.current.isEmpty && rig.engine.folds[Self.tabID] != nil)

        let daemon = Daemon(.notHeld)
        let codex = Rig(daemon: daemon)
        codex.engine.ingest(F.started(Self.codexID, tool: .codex,
                                      transcript: "\(Self.codexHome)/sessions/2026/10/06/rollout-\(Self.codexID).jsonl", cwd: Self.folder,
                                      terminal: "Terminal"), ingress: .bridge)
        codex.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.codexID, agentPID: Self.agent,
                                                  hostBundleID: ExactJumpTests.terminal, source: "codex"))
        codex.engine.ingest(F.prompt(Self.codexID), ingress: .bridge)
        codex.engine.ingest(F.completed(Self.codexID), ingress: .bridge)
        _ = await codex.engine.fold(sessionID: Self.codexID)
        await codex.handoff.open(Self.codexID)
        #expect(codex.handoff.state(for: Self.codexID) == .inApp(.codex, note: nil) && codex.typedText == ["/quit"])
        codex.appsRunning.update { $0 = [.codex] }
        await codex.engine.openFolded(sessionID: Self.codexID)
        #expect(codex.handoff.state(for: Self.codexID) == .inApp(.codex, note: HandoffWords.quitApp("ChatGPT")))
        codex.appsRunning.update { $0 = [] }
        daemon.status.update { $0 = .idle }
        await codex.engine.openFolded(sessionID: Self.codexID)
        #expect(codex.handoff.state(for: Self.codexID) == .inApp(.codex, note: ResumeExit.heldElsewhereWords))
        #expect(codex.resumeWindows.current.isEmpty && codex.engine.folds[Self.codexID] != nil)
    }
}
