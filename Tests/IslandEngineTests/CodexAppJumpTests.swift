import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// P660: a Codex app thread jumps to its own thread in the app (now installed as ChatGPT.app, bundle id
/// `com.openai.codex`, URL scheme `codex`), never to its folder in Finder. The app runs its app-server with neither
/// `__CFBundleIdentifier` nor `TERM_PROGRAM`, so its hooks' target says "Unknown" and names no thread; the rollout's
/// `session_meta.originator` says whose thread it is. Fake runners only: nothing is opened, no app is activated.
@MainActor
struct CodexAppJumpTests {
    typealias F = EngineFixtures
    typealias R = RolloutFixtures
    typealias Calls = ExactJumpTests.Calls

    static let codex = "com.openai.codex"
    static let thread = "019d516f-71ee-7e40-bcff-502fedac0928"

    // MARK: Originators

    /// Each originator Codex writes, from openai/codex (`default_client.rs`, `thread_manager.rs`) and the installed app
    /// (`CODEX_INTERNAL_ORIGINATOR_OVERRIDE`, its `clientInfo.name`), names its host; Codex matches them in any case.
    @Test(arguments: [
        ("Codex Desktop", CodexOriginator.Host.codexApp), ("codex_desktop", .codexApp), ("codex_work_desktop", .codexApp),
        ("codex_work_web", .codexApp), ("codex_work_mobile", .codexApp), ("codex_work_cca", .codexApp), ("chatgpt_cca", .codexApp),
        ("codex_chatgpt_desktop", .codexApp), ("CODEX_WORK_WEB", .codexApp),
        ("codex_cli_rs", .terminal), ("codex-tui", .terminal), ("codex_exec", .terminal), ("Claude Code", .terminal),
        ("codex_sdk_ts", .terminal), ("codex_vscode", .ide),
    ])
    func everyKnownOriginatorNamesItsHost(originator: String, host: CodexOriginator.Host) {
        #expect(CodexOriginator.host(of: originator) == host)
    }

    @Test
    func anUnknownOriginatorNamesNoHost() {
        for name in ["codex_atlas", "Codex Browser", "codex_latex_preview", "", " "] { #expect(CodexOriginator.host(of: name) == nil) }
        #expect(CodexOriginator.host(of: nil) == nil)
        // The scanner's reading: a known app originator, or an unknown one naming the desktop, ChatGPT or Work.
        #expect(CodexOriginator.isAppThread("Codex Desktop") && CodexOriginator.isAppThread("codex_work_web"))
        #expect(CodexOriginator.isAppThread("codex_desktop_next") && CodexOriginator.isAppThread("codex_work_tablet"))
        #expect(!CodexOriginator.isAppThread("codex_cli_rs") && !CodexOriginator.isAppThread("codex_vscode"))
        #expect(!CodexOriginator.isAppThread("codex_atlas") && !CodexOriginator.isAppThread(nil))
    }

    // MARK: The link

    @Test
    func theThreadLinkIsBuiltExactly() {
        #expect(ExactJump.codexThreadLink(Self.thread) == "codex://threads/019d516f-71ee-7e40-bcff-502fedac0928")
        // An id can never add a path, a query or a second link.
        #expect(ExactJump.codexThreadLink("a/../b?x=1 c") == "codex://threads/a%2F..%2Fb%3Fx%3D1%20c")
    }

    @Test
    func theAppsHelperNamesTheApp() {
        #expect(JumpHosts.canonical(bundleID: "com.openai.codex.cli") == Self.codex)
        #expect(JumpHosts.canonical(bundleID: "com.mitchellh.ghostty") == "com.mitchellh.ghostty")
    }

    // MARK: The runner

    static func target(_ app: String = "Unknown", thread: String? = nil) -> JumpTarget {
        JumpTarget(terminalApp: app, workspaceName: "project", paneTitle: "Codex · project", workingDirectory: "/tmp",
                   codexThreadID: thread)
    }

    /// The owner's jump: a thread whose host no one named goes to the thread, checked (P43, P50), never to Finder.
    @Test
    func aThreadWithNoHostGoesToTheCodexAppNeverFinder() {
        for context in [nil, JumpContext(agentPID: 900)] {
            let calls = Calls()
            let outcome = ExactJumpTests.runner(calls: calls, running: [Self.codex], frontmost: Self.codex)
                .run(sessionID: "c1", target: Self.target(thread: "T-1"), context: context)
            #expect(outcome.result == .matched)
            #expect(calls.all == ["open codex://threads/T-1"])
        }
        // The link that did not bring the app forward is named, and the app comes forward by id: still no folder.
        let calls = Calls()
        let outcome = ExactJumpTests.runner(calls: calls, running: [Self.codex], frontmost: "com.apple.finder")
            .run(sessionID: "c1", target: Self.target(thread: "T-1"), context: JumpContext(agentPID: 900))
        #expect(outcome.result == .activatedOnly && outcome.failure == .threadLinkFailed)
        #expect(calls.all == ["open codex://threads/T-1", "open -b com.openai.codex"])
    }

    @Test
    func aNoteNamingTheAppsHelperGoesToTheThread() {
        let calls = Calls()
        let outcome = ExactJumpTests.runner(calls: calls, running: [Self.codex], frontmost: Self.codex)
            .run(sessionID: "c1", target: Self.target(thread: "T-1"), context: JumpContext(hostBundleID: "com.openai.codex.cli"))
        #expect(outcome.result == .matched && calls.all == ["open codex://threads/T-1"])
    }

    /// An app thread whose id is not known: the app comes forward, and the note says the thread is not known.
    @Test
    func aCodexAppTargetWithoutAThreadBringsTheAppForward() {
        let calls = Calls()
        let outcome = ExactJumpTests.runner(calls: calls, running: [Self.codex], frontmost: Self.codex)
            .run(sessionID: "c1", target: Self.target("Codex.app"), context: JumpContext(agentPID: 900))
        #expect(outcome.result == .activatedOnly && outcome.failure == .threadUnknown)
        #expect(calls.all == ["open -b com.openai.codex"])
        #expect(outcome.host == "Codex.app")
    }

    /// Only a session with no app and no terminal at all opens its folder, and its outcome says so.
    @Test
    func onlyASessionWithNoAppOrTerminalOpensItsFolderAndSaysSo() {
        let calls = Calls()
        let outcome = ExactJumpTests.runner(calls: calls, running: [], frontmost: nil)
            .run(sessionID: "x1", target: Self.target(), context: nil)
        #expect(outcome.result == .folderOpened && outcome.failure == nil)
        #expect(calls.all == ["open /tmp"])
        #expect(outcome.message.contains("no app or terminal is known"))
    }

    // MARK: The engine

    /// A Codex session as the bridge makes it from the app's hooks: host "Unknown", no tty, no thread.
    static func appStarted(_ id: String = "c1") -> AgentEvent {
        .sessionStarted(SessionStarted(
            sessionID: id, title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: F.now, jumpTarget: JumpTarget(terminalApp: "Unknown", workspaceName: "project", paneTitle: "Codex c1",
                                                     workingDirectory: "/tmp/project"),
            codexMetadata: CodexSessionMetadata(transcriptPath: "/tmp/juice-test-codex/\(id).jsonl")))
    }

    static func meta(_ id: String = "c1", originator: String) -> String {
        R.line("session_meta", ["id": id, "timestamp": R.stamp(0), "cwd": "/tmp/project", "originator": originator,
                                "cli_version": "0.159.0", "source": "vscode"], at: 0)
    }

    /// A Codex hook's note as the app's app-server runs it: no `__CFBundleIdentifier`, no `TERM_PROGRAM`.
    static func appNote(_ id: String = "c1", host: String? = nil, termProgram: String? = nil) -> HookContextNote {
        var environment: [String: String] = [:]
        if let host { environment["__CFBundleIdentifier"] = host }
        if let termProgram { environment["TERM_PROGRAM"] = termProgram }
        return HookContextNote.make(object: ["hook_event_name": "UserPromptSubmit", "session_id": id, "cwd": "/tmp/project"],
                                    environment: environment, agentPID: 900, source: "codex")!
    }

    static func engine(calls: Calls = Calls(), frontmost: String? = CodexAppJumpTests.codex,
                       appForPID: @escaping @Sendable (Int32) -> String? = { _ in nil }) -> SessionEngine {
        F.engine(configure: { dependencies in
            dependencies.jumpRunner = ExactJumpTests.runner(calls: calls, running: [CodexAppJumpTests.codex], frontmost: frontmost)
            dependencies.appForPID = appForPID
        })
    }

    static func read(_ engine: SessionEngine, _ lines: [String], _ id: String = "c1") {
        var attention = CodexAttention()
        for line in lines { attention.apply(line) }
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: id, events: attention.takeEvents(), state: attention))
    }

    /// The owner's screenshot: a Codex app thread asks a question; its hook's target said "Unknown". Open goes to the
    /// thread in the app, the card says "in Codex", and nothing opens a folder.
    @Test
    func aCodexAppThreadsQuestionOpensItsThread() async throws {
        let calls = Calls()
        let engine = Self.engine(calls: calls)
        engine.ingest(Self.appStarted(), ingress: .bridge)
        engine.ingest(F.prompt("c1", "Check the benchmark tasks"), ingress: .bridge)
        engine.ingest(note: Self.appNote())
        Self.read(engine, [Self.meta(originator: "Codex Desktop"),
                           CodexAttentionTests.call("request_user_input", "call_Q1", arguments: CodexAttentionTests.blockingArguments)])
        let head = try #require(engine.attentionHead(for: "c1"))
        #expect(head.place == .codexApp)
        let target = try #require(engine.state.session(id: "c1").flatMap(engine.jumpTarget(for:)))
        #expect(target.terminalApp == "Codex.app" && target.codexThreadID == "c1" && target.workingDirectory == "/tmp/project")
        let outcome = try #require(await engine.openRequest(requestID: head.id))
        #expect(outcome.result == .matched && outcome.host == "Codex.app")
        #expect(calls.all == ["open codex://threads/c1"])
    }

    /// Each app originator gives the thread; a terminal's or the IDE's leaves upstream's target; one the island does
    /// not know brings the Codex app forward, not a thread (and never the folder).
    @Test(arguments: ["Codex Desktop", "codex_desktop", "codex_work_desktop", "codex_work_web", "codex_work_mobile",
                      "codex_chatgpt_desktop"])
    func anAppOriginatorGivesTheThread(originator: String) async {
        let calls = Calls()
        let engine = Self.engine(calls: calls)
        engine.ingest(Self.appStarted(), ingress: .bridge)
        Self.read(engine, [Self.meta(originator: originator)])
        #expect(await engine.jump(sessionID: "c1").result == .matched)
        #expect(calls.all == ["open codex://threads/c1"])
    }

    @Test
    func aTerminalOrIDEOriginatorKeepsUpstreamsTarget() {
        for originator in ["codex_cli_rs", "codex_exec", "codex_vscode"] {
            let engine = Self.engine()
            engine.ingest(Self.appStarted(), ingress: .bridge)
            Self.read(engine, [Self.meta(originator: originator)])
            let target = engine.state.session(id: "c1").flatMap(engine.jumpTarget(for:))
            #expect(target?.terminalApp == "Unknown" && target?.codexThreadID == nil)
        }
    }

    @Test
    func anUnknownOriginatorBringsTheAppForward() async {
        let calls = Calls()
        let engine = Self.engine(calls: calls)
        engine.ingest(Self.appStarted(), ingress: .bridge)
        Self.read(engine, [Self.meta(originator: "codex_atlas")])
        let outcome = await engine.jump(sessionID: "c1")
        #expect(outcome.result == .activatedOnly && outcome.failure == .threadUnknown)
        #expect(calls.all == ["open -b com.openai.codex"])
    }

    /// The Codex app flag, with a hook's "Unknown" target laid over the rescan's (upstream never takes the flag back).
    @Test
    func theCodexAppFlagGivesTheThreadWhateverTheHookSaid() async {
        let calls = Calls()
        let engine = Self.engine(calls: calls)
        engine.ingest(Self.appStarted(), ingress: .bridge)
        var session = engine.state.session(id: "c1")!
        session.isCodexAppSession = true
        engine.replace(session)
        #expect(await engine.jump(sessionID: "c1").result == .matched)
        #expect(calls.all == ["open codex://threads/c1"])
    }

    /// Before the rollout is read: the agent's process belongs to the Codex app.
    @Test
    func theAgentsProcessInTheAppGivesTheThread() {
        let engine = Self.engine(appForPID: { $0 == 900 ? "com.openai.codex" : nil })
        engine.ingest(Self.appStarted(), ingress: .bridge)
        engine.ingest(note: Self.appNote())
        #expect(engine.state.session(id: "c1").flatMap(engine.jumpTarget(for:))?.codexThreadID == "c1")
    }

    /// The note's own host wins: a Codex CLI in Ghostty is Ghostty's, whatever else is known.
    @Test
    func aNoteNamingATerminalKeepsTheTerminal() {
        let engine = Self.engine(appForPID: { _ in "com.openai.codex" })
        engine.ingest(Self.appStarted(), ingress: .bridge)
        engine.ingest(note: Self.appNote(host: "com.mitchellh.ghostty"))
        Self.read(engine, [Self.meta(originator: "codex_cli_rs")])
        let session = engine.state.session(id: "c1")!
        #expect(engine.codexAppJump(for: session, base: engine.effectiveJumpTarget(for: session)) == nil)
        #expect(engine.jumpTarget(for: session)?.codexThreadID == nil)
    }

    /// An app thread taken up in a terminal (`codex resume`; Codex writes no new `session_meta`, P257) keeps the app's
    /// originator: its tty says the terminal, whatever the originator says (P666). A `TERM_PROGRAM` alone does not: the
    /// app's app-server may carry one it inherited, and it never has a tty.
    @Test
    func anAppThreadResumedInATerminalKeepsTheTerminal() {
        let engine = F.engine(configure: { dependencies in
            dependencies.ttyForPID = { $0 == 900 ? "/dev/ttys004" : nil }
        })
        engine.ingest(Self.appStarted(), ingress: .bridge)
        engine.ingest(note: Self.appNote(termProgram: "ghostty"))
        Self.read(engine, [Self.meta(originator: "Codex Desktop")])
        let session = engine.state.session(id: "c1")!
        #expect(engine.jumpTarget(for: session)?.codexThreadID == nil)
        #expect(!engine.isCodexAppThread(session))

        let leaked = Self.engine()
        leaked.ingest(Self.appStarted(), ingress: .bridge)
        leaked.ingest(note: Self.appNote(termProgram: "ghostty"))
        Self.read(leaked, [Self.meta(originator: "Codex Desktop")])
        #expect(leaked.state.session(id: "c1").flatMap(leaked.jumpTarget(for:))?.codexThreadID == "c1")
    }

    /// The owner's thread as its hooks make it: upstream never flags it (its hooks' target is "Unknown"), yet it is a
    /// Codex app thread, so its Done is quiet while the Codex app is in front and heard when it is not (P665).
    @Test
    func aHookMadeAppThreadsDoneIsQuietOnlyWhileTheAppIsInFront() {
        let clock = F.Box(F.now), front = F.Box<String?>(Self.codex)
        let engine = F.engine(frontmost: true, suppress: true, clock: clock, frontmostApp: front)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(Self.appStarted(), ingress: .bridge)
        engine.ingest(note: Self.appNote())
        Self.read(engine, [Self.meta(originator: "Codex Desktop")])
        let session = engine.state.session(id: "c1")!
        #expect(!session.isCodexAppSession && engine.isCodexAppThread(session))
        for (app, heard) in [(Self.codex, false), ("com.apple.Terminal", true)] {
            front.update { $0 = app }
            engine.ingest(F.prompt("c1"), ingress: .bridge)
            engine.ingest(F.completed("c1"), ingress: .bridge)
            clock.update { $0 = $0.addingTimeInterval(SignalPipeline.doneHold) }
            engine.flushHeldSignals()
            #expect(signals.contains(.done(sessionID: "c1")) == heard, "\(app)")
        }
    }

    /// A Claude session is never taken for the Codex app.
    @Test
    func aClaudeSessionIsNeverTheCodexApp() {
        let engine = Self.engine(appForPID: { _ in "com.openai.codex" })
        engine.ingest(F.started("s1"), ingress: .bridge)
        #expect(engine.state.session(id: "s1").flatMap(engine.jumpTarget(for:))?.terminalApp == "Terminal")
    }
}
