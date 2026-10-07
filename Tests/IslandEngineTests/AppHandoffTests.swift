import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Open in Claude, Open in Codex and Open in <App>, and back (wave 8, P1510 to P1529). Every CLI run is an injected
/// stand-in that records its command, every app and link an injected opener, every tab a recorder: no test starts a CLI,
/// lists or stops a real session, opens an app or types into a terminal. The `claude agents --json` fixtures follow the
/// shape the owner's own listing had (cwd, id, kind, name, pid, sessionId, startedAt, state, status). Folders are
/// fictional.
@MainActor
struct AppHandoffTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box

    static let claudeID = "6a1f0c2e-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
    static let codexID = "019a7c3d-4e5f-7a60-8b9c-0d1e2f3a4b5c"
    static let home = "/tmp/ji-handoff"
    static let folder = "/tmp/ji-handoff/project"
    static let lab = "/tmp/ji-handoff/.claude-lab"
    static let side = "/tmp/ji-handoff/.codex-side"
    nonisolated static let agent: Int32 = 5100
    nonisolated static let tty = "/dev/ttys007"
    static let short = "0ca371e5"
    nonisolated static let apps: [HandoffApp: URL] = [
        .claude: URL(fileURLWithPath: "/Applications/Claude.app"), .codex: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        .vscode: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), .kimi: URL(fileURLWithPath: "/Applications/Kimi Code.app"),
        .opencode: URL(fileURLWithPath: "/Applications/OpenCode.app"),
    ]

    /// One engine, its hand-over, and every seam either was given.
    @MainActor
    final class Rig {
        let engine: SessionEngine
        let handoff: SessionHandoff
        let resume = SessionFoldTests.FakeResume()
        /// What was typed into the session's tab.
        let typed: Box<[String]>
        /// The agent exits when its tab command is typed, as Claude Code's `/desktop` and Codex's `/quit` do.
        let quits: Box<Bool>
        let alive: Box<Set<Int32>>
        let commands: Box<[HandoffCommand]>
        /// Each `claude agents --json` read takes the next answer; the last one stays.
        let lists: Box<[String]>
        let version: Box<String>
        let answers: Box<[String: HandoffResult]>
        let opened: Box<[(URL, String?)]>
        let links: Box<[String]>
        let running: Box<Set<HandoffApp>>
        let installed: Box<Set<HandoffApp>>
        let found: Box<[Int32]>
        let daemonHolds: Box<Bool?>
        /// Claude Code's supervisor has run in the default profile (its roster is there).
        let roster: Box<Bool>
        let frontmost: Box<Bool>
        let scheduled: Box<[F.ScheduledCheck]>
        let clock: Box<Date>

        /// `moved`: conversations that went on under another id (claudebg's `/bg`). `servers`: pids that are a shared
        /// server (Codex's daemon).
        init(daemon: Bool = false, moved: [String: String] = [:], servers: Set<Int32> = []) {
            let typed = Box<[String]>([]), quits = Box(true), alive = Box<Set<Int32>>([AppHandoffTests.agent])
            let commands = Box<[HandoffCommand]>([]), lists = Box<[String]>(["[]"]), version = Box("2.1.285 (Claude Code)")
            let answers = Box<[String: HandoffResult]>([:]), opened = Box<[(URL, String?)]>([]), links = Box<[String]>([])
            let running = Box<Set<HandoffApp>>([]), installed = Box<Set<HandoffApp>>(Set(HandoffApp.allCases))
            let found = Box<[Int32]>([]), daemonHolds = Box<Bool?>(nil), frontmost = Box(false), roster = Box(true)
            let scheduled = Box<[F.ScheduledCheck]>([]), clock = Box(F.now)
            self.typed = typed; self.quits = quits; self.alive = alive; self.commands = commands; self.lists = lists
            self.version = version; self.answers = answers; self.opened = opened; self.links = links; self.running = running
            self.installed = installed; self.found = found; self.daemonHolds = daemonHolds; self.frontmost = frontmost
            self.roster = roster
            self.scheduled = scheduled; self.clock = clock
            engine = F.engine(clock: clock, scheduled: scheduled, isFrontmost: { _ in frontmost.current }, replies: { _, text in
                typed.update { $0.append(text) }
                if quits.current, text.hasPrefix("/") { alive.update { $0.remove(AppHandoffTests.agent) } }
                return true
            }, atPrompt: { alive.current.contains($0) }) { dependencies in
                dependencies.ttyForPID = { alive.current.contains($0) ? AppHandoffTests.tty : nil }
                dependencies.processExists = { alive.current.contains($0) }
                dependencies.scheduleFoldCheck = { delay, check in
                    scheduled.update { $0.append(F.ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
                }
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
            }
            // Claude Code's background family (`claude agents --json --all`, `claude stop`) goes through the engine's
            // backgrounder, the family's one runner (P1531): a stand-in that records into the same list.
            var background = ClaudeBackgrounder.Dependencies()
            background.run = { command, timeout in
                commands.update {
                    $0.append(HandoffCommand(tool: command.tool, arguments: command.arguments, environment: command.environment,
                                             folder: command.folder, timeout: timeout))
                }
                let key = command.arguments.joined(separator: " ")
                if key == "agents --json --all" {
                    var next = "[]"
                    lists.update { list in
                        next = list.first ?? "[]"
                        if list.count > 1 { list.removeFirst() }
                    }
                    return ClaudeCommandResult(status: 0, output: next)
                }
                let answer = answers.current[key] ?? HandoffResult(status: 0)
                return ClaudeCommandResult(status: answer.status, output: answer.output, errorTail: answer.error)
            }
            background.findAttached = { _ in [] }
            background.sleep = { _ in }
            engine.claudeBackground = ClaudeBackgrounder(engine: engine, dependencies: background)
            var dependencies = SessionHandoff.Dependencies()
            dependencies.run = { command in
                commands.update { $0.append(command) }
                let key = command.arguments.joined(separator: " ")
                if key == "--version" { return HandoffResult(status: 0, output: version.current) }
                return answers.current[key] ?? HandoffResult(status: 0)
            }
            dependencies.appURL = { installed.current.contains($0) ? AppHandoffTests.apps[$0] : nil }
            dependencies.isAppRunning = { running.current.contains($0) }
            dependencies.appName = { $0 == .codex ? "ChatGPT" : $0.name }
            dependencies.openApp = { url, folder in
                opened.update { $0.append((url, folder)) }
                return true
            }
            dependencies.openLink = { link in
                links.update { $0.append(link) }
                return true
            }
            dependencies.findAgents = { _ in found.current }
            dependencies.hasRoster = { roster.current }
            if daemon { dependencies.codexDaemonHolds = { _ in daemonHolds.current } }
            if !moved.isEmpty { dependencies.conversation = { moved[$0] } }
            if !servers.isEmpty { dependencies.isServer = { servers.contains($0) } }
            dependencies.sleep = { _ in }
            dependencies.exitLooks = 4
            dependencies.stopLooks = 3
            dependencies.home = AppHandoffTests.home
            handoff = SessionHandoff(engine: engine, dependencies: dependencies)
            engine.appHandoff = handoff
            engine.conversationResume = resume
        }

        func runChecks(_ seconds: TimeInterval = 2) { F.runScheduledChecks(scheduled, clock: clock, for: seconds) }

        /// Lets the main actor run what a scheduled check handed to it.
        func settle(until condition: () -> Bool) async {
            for _ in 0..<400 where !condition() { await Task.yield() }
        }

        var arguments: [[String]] { commands.current.map(\.arguments) }

        /// A Claude Code session in a Terminal tab, its agent at its prompt unless `working`.
        func claude(_ id: String = AppHandoffTests.claudeID, profile: String = AppHandoffTests.home + "/.claude", working: Bool = false) {
            engine.ingest(F.started(id, transcript: "\(profile)/projects/-tmp-ji-handoff-project/\(id).jsonl", cwd: AppHandoffTests.folder),
                          ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: AppHandoffTests.agent,
                                                hostBundleID: ExactJump.terminalBundleID, entrypoint: "cli", source: "claude"))
            engine.ingest(F.prompt(id), ingress: .bridge)
            if working { engine.ingest(F.running(id), ingress: .bridge) } else { engine.ingest(F.completed(id), ingress: .bridge) }
        }

        /// A Codex CLI session in a Terminal tab, at its prompt.
        func codex(_ id: String = AppHandoffTests.codexID, home: String = AppHandoffTests.home + "/.codex") {
            engine.ingest(F.started(id, tool: .codex, transcript: "\(home)/sessions/2026/10/05/rollout-\(id).jsonl",
                                    cwd: AppHandoffTests.folder), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: AppHandoffTests.agent,
                                                hostBundleID: ExactJump.terminalBundleID, source: "codex"))
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(F.completed(id), ingress: .bridge)
        }

        /// Another agent's session in a Terminal tab, at its prompt, labelled by its notes as the helper labels it.
        func other(_ id: String, tool: AgentTool, source: String) {
            engine.ingest(F.started(id, tool: tool, cwd: AppHandoffTests.folder), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: AppHandoffTests.agent,
                                                hostBundleID: ExactJump.terminalBundleID, source: source))
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(F.completed(id), ingress: .bridge)
        }

        /// Its tab closed: the agent gone, its session ended.
        func closeTab(_ id: String = AppHandoffTests.claudeID) {
            alive.update { $0.remove(AppHandoffTests.agent) }
            engine.ingest(F.sessionEnd(id), ingress: .bridge)
        }
    }

    /// One `claude agents --json` entry in the owner's listing's shape.
    static func entry(kind: String = "background", id: String? = short, session: String = claudeID, pid: Int32? = 6200,
                      state: String? = "done", status: String? = "idle") -> [String: Any] {
        var object: [String: Any] = ["cwd": folder, "kind": kind, "name": "fix the tests", "sessionId": session,
                                     "startedAt": 1_800_000_000_000]
        if let id { object["id"] = id }
        if let pid { object["pid"] = Int(pid) }
        if let state { object["state"] = state }
        if let status { object["status"] = status }
        return object
    }

    static func list(_ entries: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
    }

    // MARK: P1510 what is offered

    @Test
    func eachAgentOffersItsOwnAppOnlyWhereThatAppCanOpenIt() {
        let rig = Rig()
        rig.claude()
        #expect(rig.handoff.offer(for: Self.claudeID)?.title == "Open in Claude")
        // Claude signs in on its own account and reads the default folder: a profile's session is never offered (P1512).
        rig.claude("1b2c3d4e-5f60-4718-9a2b-3c4d5e6f7a8b", profile: Self.lab)
        #expect(rig.handoff.offer(for: "1b2c3d4e-5f60-4718-9a2b-3c4d5e6f7a8b") == nil)
        rig.codex()
        #expect(rig.handoff.offer(for: Self.codexID)?.title == "Open in Codex")
        rig.codex("019a7c3d-0000-7a60-8b9c-0d1e2f3a4b5c", home: Self.side)
        #expect(rig.handoff.offer(for: "019a7c3d-0000-7a60-8b9c-0d1e2f3a4b5c") == nil)
        // The apps that list the CLI's sessions (P1514).
        rig.other("copilot-1", tool: .codebuddy, source: "copilot")
        rig.other("kimi-1", tool: .kimiCLI, source: "kimi")
        rig.other("opencode-1", tool: .openCode, source: "opencode")
        rig.other("gemini-1", tool: .geminiCLI, source: "gemini")
        #expect(rig.handoff.offer(for: "copilot-1")?.title == "Open in VS Code")
        #expect(rig.handoff.offer(for: "kimi-1")?.title == "Open in Kimi Code")
        #expect(rig.handoff.offer(for: "opencode-1")?.title == "Open in OpenCode")
        // Others get nothing new.
        #expect(rig.handoff.offer(for: "gemini-1") == nil)
    }

    @Test
    func nothingIsOfferedForAnAppThatIsNotInstalledOrAnIDTheCLICannotTake() {
        let rig = Rig()
        rig.installed.update { $0.remove(.claude) }
        rig.claude()
        #expect(rig.handoff.offer(for: Self.claudeID) == nil)
        rig.installed.update { $0.insert(.claude) }
        // The installed answer is kept a minute (mappings ask often).
        #expect(rig.handoff.offer(for: Self.claudeID) == nil)
        rig.clock.update { $0 += 61 }
        #expect(rig.handoff.offer(for: Self.claudeID) != nil)
        rig.claude("claude-process:4242")
        #expect(rig.handoff.offer(for: "claude-process:4242") == nil)
    }

    @Test
    func aRowOffersItAtItsPromptOnlyAndAFoldedCardWhileItsTurnRunsToo() async {
        let rig = Rig()
        rig.claude(working: true)
        #expect(rig.handoff.offer(for: Self.claudeID) == nil)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        #expect(rig.handoff.offer(for: Self.claudeID)?.app == .claude)
        // Not while a reply of the card's is held.
        rig.engine.folds[Self.claudeID]?.held = "then push"
        #expect(rig.handoff.offer(for: Self.claudeID) == nil)
    }

    // MARK: P1511 Claude Code

    @Test
    func claudesTabAtItsPromptTakesDesktopAndNoOtherCommandRuns() async {
        let rig = Rig()
        rig.claude()
        await rig.handoff.open(Self.claudeID)
        // Claude Code's own command: it saves, opens Claude and exits the CLI.
        #expect(rig.typed.current == ["/desktop"])
        #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil))
        // No CLI ran: nothing listed, started, stopped or opened.
        #expect(rig.arguments.isEmpty)
        #expect(rig.opened.current.isEmpty && rig.links.current.isEmpty)
    }

    @Test
    func aTabWhoseCLIStaysIsNotHandedOver() async {
        let rig = Rig()
        rig.quits.update { $0 = false }
        rig.claude()
        await rig.handoff.open(Self.claudeID)
        #expect(rig.typed.current == ["/desktop"])
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.stayedInTab))
        // Refused once, it can be clicked again.
        #expect(rig.handoff.offer(for: Self.claudeID) != nil)
    }

    @Test
    func aClosedTabNeedsClaudeCode2_1_285AndNeverRunsAnUpdate() async {
        let rig = Rig()
        rig.version.update { $0 = "2.1.280 (Claude Code)" }
        rig.claude()
        rig.closeTab()
        // Even an idle background copy is left alone: nothing is listed or stopped for a move that cannot happen.
        rig.lists.update { $0 = [Self.list([Self.entry()])] }
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.updateClaude))
        #expect(rig.arguments == [["--version"]])
        #expect(rig.typed.current.isEmpty)
    }

    @Test
    func aClosedTabOpensWithClaudesOwnDesktopResumeInItsFolder() async throws {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil))
        #expect(rig.arguments == [["--version"], ["agents", "--json", "--all"], ["--desktop", "--resume", Self.claudeID]])
        let desktop = try #require(rig.commands.current.last)
        #expect(desktop.tool == "claude" && desktop.folder == Self.folder)
        // The default profile, no folder variable; `--desktop` starts no session here: the island's skip switches on.
        #expect(desktop.environment["CLAUDE_CONFIG_DIR"] == nil && desktop.environment["PATH"] == nil)
        for key in CLIEnvironment.islandSkipKeys { #expect(desktop.environment[key] == "1") }
        // The list may start Claude Code's supervisor, which hosts every background session after it: never with the
        // island's skip switches, or those sessions would skip its hooks for good (P1520).
        // It is the background family's own command (P1531): its profile is the default folder of the rig's home, which
        // is not this Mac's, so the folder variable names it here (the app's home is its own: none goes there).
        let list = try #require(rig.commands.current.first { $0.arguments == ["agents", "--json", "--all"] })
        for key in CLIEnvironment.islandSkipKeys { #expect(list.environment[key] == nil) }
        #expect(list.environment["CLAUDE_CONFIG_DIR"] == Self.home + "/.claude" && list.environment["PATH"] == nil)
        #expect(list.environment["TERM"] == "xterm-256color" && list.environment["HOME"] == NSHomeDirectory())
        #expect(Set(list.environment.keys).isSubset(of: ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "TERM", "SHELL", "SSH_AUTH_SOCK",
                                                          "CLAUDE_CONFIG_DIR"]))
    }

    @Test
    func whereClaudesSupervisorNeverRanTheListIsNotAskedSoNoClickStartsIt() async {
        let rig = Rig()
        rig.roster.update { $0 = false }
        rig.claude()
        rig.closeTab()
        await rig.handoff.open(Self.claudeID)
        #expect(rig.arguments == [["--version"], ["--desktop", "--resume", Self.claudeID]])
        #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil))
    }

    @Test
    func aListThatCannotBeReadHandsNothingOver() async {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        rig.lists.update { $0 = ["error: the background service did not respond"] }
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.noList))
        #expect(rig.arguments == [["--version"], ["agents", "--json", "--all"]])
    }

    @Test
    func aClosedTabThatStillRunsSomewhereIsNotHandedOver() async {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        // `claude --resume <id>` in another window, found by its arguments (P1420).
        rig.found.update { $0 = [7777] }
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.stillRuns))
        #expect(!rig.arguments.contains(["--desktop", "--resume", Self.claudeID]))
    }

    @Test
    func anInteractiveCopyClaudeCodeListsIsNotHandedOver() async {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        rig.lists.update { $0 = [Self.list([Self.entry(kind: "interactive", id: nil, pid: 6300, state: nil, status: "idle")])] }
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.stillRuns))
        #expect(rig.arguments == [["--version"], ["agents", "--json", "--all"]])
    }

    @Test
    func aBackgroundCopyIsStoppedAndSeenStoppedBeforeClaudeOpensIt() async {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        rig.lists.update { $0 = [Self.list([Self.entry()]), Self.list([Self.entry()]), Self.list([Self.entry(pid: nil, state: "stopped", status: nil)])] }
        rig.answers.update { $0["stop \(Self.short)"] = HandoffResult(status: 0, output: "stopped \(Self.short)") }
        await rig.handoff.open(Self.claudeID)
        // `claude stop` is of the background family too: no skip switches (P1520).
        let stop = rig.commands.current.first { $0.arguments == ["stop", Self.short] }
        #expect(stop.map { cmd in CLIEnvironment.islandSkipKeys.allSatisfy { cmd.environment[$0] == nil } } == true)
        #expect(rig.arguments == [["--version"], ["agents", "--json", "--all"], ["stop", Self.short], ["agents", "--json", "--all"],
                                  ["agents", "--json", "--all"], ["--desktop", "--resume", Self.claudeID]])
        #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil))
    }

    @Test
    func aBackgroundCopyThatDoesNotStopIsNotHandedOver() async {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        rig.lists.update { $0 = [Self.list([Self.entry()])] }
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.backgroundStayed))
        #expect(!rig.arguments.contains(["--desktop", "--resume", Self.claudeID]))
        // Its first read, the one the stop reads after it, then three looks.
        #expect(rig.arguments.filter { $0 == ["agents", "--json", "--all"] }.count == 5)
    }

    @Test
    func aWorkingBackgroundCopyIsNeverStoppedForTheMove() async {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        rig.lists.update { $0 = [Self.list([Self.entry(state: "working", status: "busy")])] }
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.working))
        #expect(rig.arguments == [["--version"], ["agents", "--json", "--all"]])
    }

    @Test
    func aConversationThatWentOnUnderANewIDIsHandedOverUnderThatID() async {
        let moved = "7c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
        let rig = Rig(moved: [Self.claudeID: moved])
        rig.claude()
        rig.closeTab()
        rig.lists.update { $0 = [Self.list([Self.entry(session: moved)]), Self.list([])] }
        await rig.handoff.open(Self.claudeID)
        #expect(rig.arguments == [["--version"], ["agents", "--json", "--all"], ["stop", Self.short], ["agents", "--json", "--all"],
                                  ["agents", "--json", "--all"], ["--desktop", "--resume", moved]])
        #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil))
    }

    // MARK: P1513 a folded turn waits for its end

    @Test
    func aFoldedTurnWaitsForItsEndThenGoesAndCancelKeepsIt() async {
        let rig = Rig()
        rig.claude(working: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .pending(.claude))
        #expect(rig.typed.current.isEmpty && rig.commands.current.isEmpty)
        // A pending hand-over takes the field away, as nothing would reach the app.
        rig.handoff.cancelPending(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == nil)
        await rig.handoff.open(Self.claudeID)
        rig.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        #expect(rig.typed.current.isEmpty)
        rig.runChecks()
        await rig.settle { rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil) }
        #expect(rig.typed.current == ["/desktop"])
        #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil))
    }

    @Test
    func aPendingHandOverNeverTypesIntoATabInFront() async {
        let rig = Rig()
        rig.claude(working: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.handoff.open(Self.claudeID)
        rig.frontmost.update { $0 = true }
        rig.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        rig.runChecks()
        await rig.settle { rig.handoff.state(for: Self.claudeID) != .pending(.claude) }
        #expect(rig.typed.current.isEmpty)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.tabInFront))
    }

    @Test
    func aWindowClosedMidTurnDropsThePendingHandOverForContinue() async {
        let rig = Rig()
        rig.claude(working: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.handoff.open(Self.claudeID)
        rig.engine.folds[Self.claudeID]?.stopped = FoldStop(at: F.now, windowClosed: true, why: .processEnded)
        rig.engine.ingest(F.running(Self.claudeID), ingress: .bridge)
        #expect(rig.handoff.state(for: Self.claudeID) == nil)
        #expect(rig.typed.current.isEmpty)
    }

    // MARK: P1515 while the app holds it

    @Test
    func whileTheAppHoldsItTheCardSendsNoReplyAndItsCLIsExitIsNoStop() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: nil))
        // `/desktop` may come as a prompt of its own, late: the fold opens a turn whose agent has exited.
        rig.engine.ingest(F.prompt(Self.claudeID, "/desktop", at: F.now + 5), ingress: .bridge)
        #expect(rig.engine.folds[Self.claudeID]?.turnOpen == true)
        // The kernel's word that it exited, as the fold's exit watch hears it (P1416).
        rig.engine.foldAgentExited(Self.claudeID, pid: Self.agent)
        rig.runChecks()
        #expect(rig.engine.folds[Self.claudeID]?.stopped == nil)
        #expect(rig.engine.foldReach(Self.claudeID) == .openOnly)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "and push")
        #expect(rig.typed.current == ["/desktop"])
        #expect(rig.resume.continued.isEmpty)
    }

    // MARK: P1516 Codex

    @Test
    func codexQuitsItsTUIThenTheAppOpensTheThread() async {
        let rig = Rig()
        rig.codex()
        await rig.handoff.open(Self.codexID)
        #expect(rig.typed.current == ["/quit"])
        #expect(rig.links.current == ["codex://threads/\(Self.codexID)"])
        #expect(rig.handoff.state(for: Self.codexID) == .inApp(.codex, note: nil))
        #expect(rig.commands.current.isEmpty)
    }

    @Test
    func codexsDaemonHoldingTheThreadKeepsTheLinkShut() async {
        let rig = Rig(daemon: true)
        rig.daemonHolds.update { $0 = true }
        rig.codex()
        rig.closeTab(Self.codexID)
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == .blocked(.codex, ResumeExit.heldElsewhereWords))
        #expect(rig.links.current.isEmpty)
    }

    @Test
    func aTUIThatIsTheDaemonsClientIsNeverQuitForAMoveThatCannotHappen() async {
        // 0.158's default: the TUI at its prompt, the thread loaded in the daemon. Quitting it would not free the thread.
        let rig = Rig(daemon: true)
        rig.daemonHolds.update { $0 = true }
        rig.codex()
        await rig.handoff.open(Self.codexID)
        #expect(rig.typed.current.isEmpty)
        #expect(rig.alive.current.contains(Self.agent))
        #expect(rig.links.current.isEmpty)
        #expect(rig.handoff.state(for: Self.codexID) == .blocked(.codex, ResumeExit.heldElsewhereWords))
        // A TUI of its own (`--no-daemon`): the daemon does not hold the thread, so `/quit`, then the link.
        rig.daemonHolds.update { $0 = false }
        await rig.handoff.open(Self.codexID)
        #expect(rig.typed.current == ["/quit"])
        #expect(rig.links.current == ["codex://threads/\(Self.codexID)"])
    }

    @Test
    func codexsSharedServerIsNoHolderOnceItLetsTheThreadGo() async {
        // 0.158's hooks name the daemon's pid, which lives on: only the daemon's own answer decides.
        let rig = Rig(daemon: true, servers: [Self.agent])
        rig.codex()
        rig.daemonHolds.update { $0 = true }
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == .blocked(.codex, ResumeExit.heldElsewhereWords))
        rig.daemonHolds.update { $0 = false }
        await rig.handoff.open(Self.codexID)
        #expect(rig.links.current == ["codex://threads/\(Self.codexID)"])
        #expect(rig.handoff.state(for: Self.codexID) == .inApp(.codex, note: nil))
        // Nothing was typed: the daemon's pid has no tab of the session's.
        #expect(rig.typed.current.isEmpty)
    }

    @Test
    func aCodexTUIThatStaysOpenKeepsTheLinkShut() async {
        let rig = Rig()
        rig.quits.update { $0 = false }
        rig.codex()
        await rig.handoff.open(Self.codexID)
        #expect(rig.handoff.state(for: Self.codexID) == .blocked(.codex, HandoffWords.stayedInTab))
        #expect(rig.links.current.isEmpty)
    }

    // MARK: P1514 the apps that list the CLI's sessions

    @Test
    func copilotEndsItsCLIAndVSCodeOpensOnItsFolder() async {
        let rig = Rig()
        rig.other("copilot-1", tool: .codebuddy, source: "copilot")
        await rig.handoff.open("copilot-1")
        #expect(rig.typed.current == ["/exit"])
        #expect(rig.opened.current.map(\.0) == [Self.apps[.vscode]!] && rig.opened.current.map(\.1) == [Self.folder])
        #expect(rig.handoff.state(for: "copilot-1") == .pick(.vscode))
    }

    @Test
    func kimiAndOpenCodeOpenTheirAppAlone() async {
        let rig = Rig()
        rig.other("kimi-1", tool: .kimiCLI, source: "kimi")
        await rig.handoff.open("kimi-1")
        #expect(rig.opened.current.map(\.0) == [Self.apps[.kimi]!] && rig.opened.current.map(\.1) == [nil])
        #expect(rig.handoff.state(for: "kimi-1") == .pick(.kimi))
    }

    // MARK: P1517 the way back

    @Test
    func theWayBackFromClaudeWaitsUntilClaudeQuits() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.handoff.open(Self.claudeID)
        rig.running.update { $0 = [.claude] }
        let before = rig.commands.current.count
        // Claude runs, whatever names the session or not: no process, Claude Code's list empty, then unreadable. Claude
        // gives no sign when the owner leaves a session, so nothing frees it but its quit.
        for list in ["[]", "Unknown command: agents", Self.list([Self.entry(kind: "interactive", id: nil, pid: 6400, state: nil)])] {
            rig.lists.update { $0 = [list] }
            await rig.engine.openFolded(sessionID: Self.claudeID)
            #expect(rig.resume.opened.isEmpty)
            #expect(rig.handoff.state(for: Self.claudeID) == .inApp(.claude, note: "Quit Claude first"))
            #expect(rig.engine.foldReach(Self.claudeID) == .openOnly)
        }
        // The way back runs no command of its own: it asks only whether Claude runs.
        #expect(rig.commands.current.count == before)
        #expect(rig.engine.foldNotes.map(\.said).contains("back to a terminal · not yet · Quit Claude first"))
        // Claude quit: free, and the resume's own Open in terminal opens it (which scans for a process again, P1420).
        rig.running.update { $0 = [] }
        await rig.engine.openFolded(sessionID: Self.claudeID)
        #expect(rig.resume.opened == [Self.claudeID])
        #expect(rig.engine.folds[Self.claudeID] == nil)
    }

    @Test
    func theWayBackFromCodexWaitsUntilTheAppQuits() async {
        let rig = Rig()
        rig.codex()
        _ = await rig.engine.fold(sessionID: Self.codexID)
        await rig.handoff.open(Self.codexID)
        rig.running.update { $0 = [.codex] }
        await rig.engine.openFolded(sessionID: Self.codexID)
        #expect(rig.resume.opened.isEmpty)
        #expect(rig.handoff.state(for: Self.codexID) == .inApp(.codex, note: "Quit ChatGPT first"))
        rig.running.update { $0 = [] }
        await rig.engine.openFolded(sessionID: Self.codexID)
        #expect(rig.resume.opened == [Self.codexID])
    }

    @Test
    func aConversationTakenBackToATerminalByHandIsTheAppsNoLonger() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.handoff.open(Self.claudeID)
        #expect(rig.engine.foldReach(Self.claudeID) == .openOnly)
        // `claude --resume <id>` typed by hand in a tab: a new agent at its controls.
        rig.alive.update { $0.insert(5200) }
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.claudeID, agentPID: 5200,
                                                hostBundleID: ExactJump.terminalBundleID, entrypoint: "cli", source: "claude"))
        rig.engine.ingest(F.prompt(Self.claudeID), ingress: .bridge)
        #expect(rig.handoff.state(for: Self.claudeID) == nil)
        #expect(rig.engine.foldReach(Self.claudeID) == .tab)
    }

    // MARK: Safety

    @Test
    func aHeadlessEngineOffersAndRunsNothing() async {
        let engine = F.engine()
        let handoff = SessionHandoff(engine: engine)
        engine.appHandoff = handoff
        engine.ingest(F.started(Self.claudeID, transcript: "\(NSHomeDirectory())/.claude/projects/p/\(Self.claudeID).jsonl"), ingress: .bridge)
        engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        #expect(handoff.offer(for: Self.claudeID) == nil)
        await handoff.open(Self.claudeID)
        #expect(handoff.state(for: Self.claudeID) == nil)
        // An engine of the app's kind in a test process (a wiring rig's) is no live one either.
        #expect(HandoffRun.allowed == false)
    }

    @Test
    func noCommandEverCarriesTheOwnersText() async {
        let rig = Rig()
        rig.claude()
        rig.closeTab()
        rig.lists.update { $0 = [Self.list([Self.entry()]), Self.list([])] }
        await rig.handoff.open(Self.claudeID)
        let words = Set(rig.arguments.flatMap { $0 })
        #expect(words.isSubset(of: ["agents", "--json", "--all", "stop", Self.short, "--version", "--desktop", "--resume", Self.claudeID]))
    }

    @Test
    func theLogSaysEachStepWithIDsAndStatesOnly() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.handoff.open(Self.claudeID)
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said.contains("open in Claude · under way"))
        #expect(said.contains("open in Claude · typed /desktop"))
        #expect(said.contains("open in Claude · opened"))
    }

    // MARK: Claude Code's list and version

    @Test
    func claudesListParsesTheOwnersShapeAndSkipsWhatItCannotRead() throws {
        let output = """
        [{"cwd":"/tmp/ji-handoff/project","id":"0ca371e5","kind":"background","name":"fix the tests","pid":6200,\
        "sessionId":"\(Self.claudeID)","startedAt":1800000000000,"state":"working","status":"busy"},
        {"cwd":"/tmp/ji-handoff/other","kind":"interactive","pid":"not a pid","sessionId":"x"},
        {"cwd":"/tmp/ji-handoff/two","kind":"interactive","pid":6201,"sessionId":"\(Self.codexID)","startedAt":1800000000001,"status":"idle"}]
        """
        // The family's one parser (`ClaudeBackgroundList`, P1531): a field it cannot read is left out, not the row.
        let entries = try #require(ClaudeBackgroundList.parse(output: output))
        #expect(entries.count == 3)
        #expect(entries[0].id == "0ca371e5" && entries[0].sessionID == Self.claudeID && entries[0].pid == 6200)
        #expect(entries[0].isBackground && entries[0].isLive && entries[0].isWorking)
        #expect(entries[1].pid == nil && !entries[1].isLive)
        #expect(!entries[2].isBackground && entries[2].isLive && !entries[2].isWorking)
        #expect(ClaudeBackgroundEntry(id: "1", sessionID: "s", kind: .background, state: "stopped").isLive == false)
        #expect(ClaudeBackgroundEntry(id: "1", sessionID: "s", kind: .background, state: "working").isLive)
        #expect(ClaudeBackgroundList.parse(output: "error: unknown command") == nil)
        #expect(ClaudeBackgroundList.parse(output: "[]") == [])
    }

    @Test
    func claudesVersionDecidesTheDesktopFlag() {
        #expect(ClaudeVersion.parse("2.1.280 (Claude Code)") == ClaudeVersion(2, 1, 280))
        #expect(ClaudeVersion.parse("2.1.280 (Claude Code)")! < .desktopFlag)
        #expect(ClaudeVersion.parse("2.1.285")! >= .desktopFlag)
        #expect(ClaudeVersion.parse("2.2.0-beta.1 (Claude Code)")! >= .desktopFlag)
        #expect(ClaudeVersion.parse("Claude Code") == nil)
    }

    // MARK: P1544 nothing offered where it can only refuse

    /// In Codex 0.158's default the TUI is its shared daemon's client, so the daemon holds the thread while it is open and
    /// a while after: Open in Codex would only say so. It is not offered while the daemon last said it holds the thread.
    @Test
    func openInCodexIsNotOfferedWhileCodexsDaemonHoldsTheThread() async {
        // 0.158's hooks name the daemon's pid: its TUI is the daemon's client.
        let rig = Rig(servers: [Self.agent])
        rig.codex()
        #expect(rig.handoff.offer(for: Self.codexID)?.app == .codex)
        rig.resume.service[Self.codexID] = .idle
        #expect(rig.handoff.offer(for: Self.codexID) == nil)
        rig.resume.service[Self.codexID] = .active(waitsOnYou: false)
        #expect(rig.handoff.offer(for: Self.codexID) == nil)
        rig.resume.service[Self.codexID] = .notHeld
        #expect(rig.handoff.offer(for: Self.codexID)?.app == .codex)
        // Its card, whose polls keep the daemon's word fresh, likewise.
        _ = await rig.engine.fold(sessionID: Self.codexID)
        rig.resume.service[Self.codexID] = .idle
        #expect(rig.engine.folds[Self.codexID] != nil && rig.handoff.offer(for: Self.codexID) == nil)
        // Once its TUI quit and its card went, nothing keeps that word fresh: the click asks the daemon itself.
        rig.engine.unfold(sessionID: Self.codexID)
        rig.closeTab(Self.codexID)
        #expect(rig.handoff.offer(for: Self.codexID)?.app == .codex)
    }

    /// Below 2.1.285 only a tab's `/desktop` can open a conversation in Claude. Once a click read the version, Open in
    /// Claude is said once ("Update Claude Code…") and not offered again for a background copy or a closed tab; a tab at
    /// its prompt keeps it, and after `versionFor` it is offered again, so an update is seen.
    @Test
    func openInClaudeIsNotOfferedAgainWhereOnlyANewerClaudeCodeOpensIt() async {
        let rig = Rig()
        rig.version.update { $0 = "2.1.280 (Claude Code)" }
        rig.claude()
        rig.closeTab()
        #expect(rig.handoff.offer(for: Self.claudeID) != nil)
        await rig.handoff.open(Self.claudeID)
        #expect(rig.handoff.state(for: Self.claudeID) == .blocked(.claude, HandoffWords.updateClaude))
        #expect(rig.handoff.offer(for: Self.claudeID) == nil)
        // A tab at its prompt takes `/desktop`: still offered.
        let tab = "1b2c3d4e-5f60-4718-9a2b-3c4d5e6f7a8c"
        rig.alive.update { $0.insert(Self.agent) }
        rig.claude(tab)
        #expect(rig.handoff.offer(for: tab) != nil)
        // Its fold in Claude Code's background: only `--desktop` opens it there.
        _ = await rig.engine.fold(sessionID: tab)
        rig.engine.folds[tab]?.background = FoldBackground(stage: .moved, shortID: Self.short, profile: Self.home + "/.claude",
                                                           folder: Self.folder)
        #expect(rig.handoff.offer(for: tab) == nil)
        rig.clock.update { $0 += 3_601 }
        #expect(rig.handoff.offer(for: Self.claudeID) != nil && rig.handoff.offer(for: tab) != nil)
        #expect(rig.arguments == [["--version"]])
    }
}
