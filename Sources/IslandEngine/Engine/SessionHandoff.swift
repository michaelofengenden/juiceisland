import Foundation
import JuiceCore
import Observation
import OpenIslandCore

/// Open in Claude, Open in Codex and Open in <App> (wave 8, P1510 to P1529): a session goes on in its agent's own app,
/// and back to a terminal, with never two live copies of one conversation (Claude Code has no lock; two holders lose
/// turns). Before any hand-over the source is seen stopped: its process gone, or Claude Code's own list saying so. A
/// hand-over that cannot confirm that does not happen, and the card says why.
///
/// Nothing here starts by itself: `open` is the owner's click on the card or the row's menu, and a folded session whose
/// turn runs waits for that turn's end and goes then (one click, "Opens in Claude when this turn ends"). The ways:
/// - Claude Code, its tab at its prompt: `/desktop` typed into the tab (Claude Code's own command: it saves, opens the
///   session in Claude and exits the CLI). A background copy (`claude agents --json --all` names it, read through the
///   engine's `ClaudeBackgrounder`): once it is idle and no window is attached to it, `claude stop <id>`, the list read
///   until it says stopped, then `claude --desktop --resume <id>` (2.1.285 and later; below that the card says
///   "Update Claude Code to open this in Claude", and no update runs). Its tab gone: `claude --desktop --resume <id>`, once
///   nothing runs it. The default profile only: Claude signs in on its own account and reads `~/.claude`.
/// - Codex: its shared daemon asked first (through the engine's resume): while it holds the thread nothing is typed. Its tab
///   at its prompt: `/quit` typed, its process seen gone, then `codex://threads/<id>`. Its tab gone: the link, once
///   nothing runs it. Default home only.
/// - Copilot CLI and Kilo (VS Code), Kimi Code (Kimi Code Desktop), OpenCode (OpenCode Desktop): `/exit` typed, its
///   process seen gone, the app opened by its path; the card says "Pick this session in <App>".
/// The way back (Open in terminal on a card the app holds): Claude, only while Claude is not running ("Quit Claude
/// first": it gives no sign when the owner leaves a session, and no process or list is known to name one it has open);
/// Codex, only while the Codex app is not running (it keeps a thread's writer until it quits) and the daemon does not
/// hold it.
///
/// A headless engine (tests, renders, the demo) has no live runner, opener or app lookup: only injected ones run, so no
/// test starts a CLI, opens an app or types into a terminal.
@MainActor
@Observable
public final class SessionHandoff {
    struct Dependencies: Sendable {
        /// Runs a CLI command; nil: the live run for the app's own engine, none for a headless one.
        var run: (@Sendable (HandoffCommand) -> HandoffResult)?
        /// Where the app is installed; nil: Launch Services for the app's engine, none (nothing offered) for a headless one.
        var appURL: (@Sendable (HandoffApp) -> URL?)?
        /// Whether the app runs now; nil: `NSRunningApplication` for the app's engine, never for a headless one.
        var isAppRunning: (@Sendable (HandoffApp) -> Bool)?
        /// The installed app's own name ("ChatGPT"); nil: the installed bundle's for the app's engine, the app's own name
        /// for a headless one.
        var appName: (@Sendable (HandoffApp) -> String)?
        /// Opens the app by its path, with a folder (VS Code); nil: `open -a <path>` for the app's engine, none headless.
        var openApp: (@Sendable (URL, String?) -> Bool)?
        /// Opens a link with the app that owns its scheme; nil: `open <link>` for the app's engine, none headless.
        var openLink: (@Sendable (String) -> Bool)?
        /// This user's processes whose arguments name a session's id (P1420); nil: `AgentProcessScan` for the app's
        /// engine, none headless.
        var findAgents: (@Sendable (String) -> [Int32])?
        /// Claude Code's own list for the default profile; nil: the engine's `ClaudeBackgrounder` reads
        /// `claude agents --json --all` there (the one runner and parser of the family, P1531), once its supervisor has
        /// run there (`hasRoster`).
        var claudeAgents: (@Sendable () async -> [ClaudeBackgroundEntry]?)?
        /// Claude Code's supervisor has run in the default profile: its `daemon/roster.json` is there (a `stat`, never
        /// read). Without it no background copy can exist, and the list is not asked, so a click never starts the
        /// supervisor. nil: that file for the app's engine; true for a headless one, whose runs are injected.
        var hasRoster: (@Sendable () -> Bool)?
        /// Whether Codex's shared daemon has the thread loaded (its writer): true holds it, nil not known. nil: the
        /// engine's resume asks the daemon of the default Codex home (`ConversationResuming.codexDaemonHolds`, P1516, P1532).
        var codexDaemonHolds: (@Sendable (String) async -> Bool?)?
        /// The session's profile folder, for renders; nil: the account tag, else its transcript's path.
        var profile: (@MainActor @Sendable (String) -> String?)?
        /// The id the conversation goes on under now, when it moved to another (Claude Code's `/background` resumes a fork
        /// under a new id); nil: the engine's `movedConversation(from:)`, else its own (P1532).
        var conversation: (@MainActor @Sendable (String) -> String?)?
        /// A pid that is an agent's shared server rather than the session's own process (Codex's app-server daemon, told
        /// by its arguments): never taken for a holder here, as `codexDaemonHolds` answers for it. nil: the engine's own
        /// check (`agentIsCodexServer`, P1485, P1532).
        var isServer: (@Sendable (Int32) -> Bool)?
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        /// How often, and how many times, a CLI told to quit is looked at until its process is gone.
        var exitLook: Duration = .milliseconds(250)
        var exitLooks = 60
        /// How often, and how many times, Claude Code's list is read after `claude stop` until it says stopped.
        var stopLook: Duration = .milliseconds(500)
        var stopLooks = 20
        /// How long an app's installed or not is kept, so a card's mapping asks Launch Services at most this often.
        var installedFor: TimeInterval = 60
        /// How long Claude Code's version, read on a click, decides what is offered (P1544): an update is seen after it.
        var versionFor: TimeInterval = 3_600
        var home: String = NSHomeDirectory()
    }

    @ObservationIgnored private weak var engine: SessionEngine?
    @ObservationIgnored let dependencies: Dependencies
    /// Where each session's hand-over stands. Memory only.
    public private(set) var states: [String: HandoffState] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var installed: [HandoffApp: (yes: Bool, at: Date)] = [:]
    /// Whether each profile folder is its provider's default, as `CLIEnvironment` resolves it (links followed): asked
    /// once per folder, not at every mapping.
    @ObservationIgnored private var defaultFolders: [String: Bool] = [:]
    /// The CLI the hand-over saw quit in its tab: a later agent of the session's at a tab's controls is the owner taking
    /// it back by hand, and the app holds it no longer.
    @ObservationIgnored private var handedPIDs: [String: Int32] = [:]
    /// How often a pending hand-over found Claude's background copy still working at its turn's end.
    @ObservationIgnored private var pendingTries: [String: Int] = [:]
    /// Claude Code's version as the last click read it, and when (P1544).
    @ObservationIgnored private var claudeVersion: (version: ClaudeVersion?, at: Date)?

    public convenience init(engine: SessionEngine) {
        self.init(engine: engine, dependencies: Dependencies())
    }

    init(engine: SessionEngine, dependencies: Dependencies) {
        self.engine = engine
        self.dependencies = dependencies
    }

    /// The app's own engine, outside a test process: wiring rigs make an engine of the app's kind (`startBridge`) whose
    /// other seams are stand-ins, and none of them may reach a real CLI, app or link through a hand-over they did not
    /// give stand-ins (`HandoffRun.allowed`).
    private var live: Bool { engine?.configuration.startBridge == true && HandoffRun.allowed }

    // MARK: What the card and the menu ask

    public func state(for sessionID: String) -> HandoffState? { states[sessionID] }

    /// Renders and tests only: a hand-over's state as given.
    func set(_ state: HandoffState?, for sessionID: String) { states[sessionID] = state }

    /// The app that holds the session now or is about to (opening, in it, or picked there): the island sends it no reply,
    /// no Continue, and Open in terminal asks `wayBack` first.
    public func app(holding sessionID: String) -> HandoffApp? {
        guard let state = states[sessionID], state.holds else { return nil }
        return state.app
    }

    /// What the session offers now: its agent's app, installed, for a conversation that app can open (Claude and Codex:
    /// the default profile, an id the CLI takes; never a Codex app thread, which is the app's already, nor an SSH
    /// session). A folded session offers it while its turn runs too (it then waits for the turn's end); a row only while
    /// no turn of it runs. Nothing while a hand-over is under way or done, a reply of the card's is held or on its way, or
    /// the island's own run of it is under way. Looks at no process: cheap enough for every mapping.
    public func offer(for sessionID: String) -> HandoffOffer? {
        guard let engine, let session = engine.state.session(id: sessionID) ?? engine.folds[sessionID]?.session else { return nil }
        if let state = states[sessionID], state.holds || state == .pending(state.app) { return nil }
        guard engine.remoteSessions.entry(for: sessionID) == nil, let app = HandoffApp.of(engine.agent(of: session)) else { return nil }
        if app == .codex, engine.isCodexAppThread(session) { return nil }
        if let provider = app.provider {
            guard UUID(uuidString: sessionID) != nil, let profile = profile(of: session, provider: provider),
                  isDefault(profile, provider) else { return nil }
        }
        if let fold = engine.folds[sessionID] {
            if fold.held != nil || fold.send == .sending || engine.conversationResume?.isRunning(sessionID) == true { return nil }
            // A move into Claude Code's background under way or unsure (P1533).
            if engine.foldMoveUnsettled(sessionID) { return nil }
        } else if session.phase != .completed {
            return nil
        }
        // Where it could only refuse (P1544): Codex's shared daemon holds the thread, as it last said (its TUI is the
        // daemon's client in 0.158's default, and the daemon keeps the thread a while after it quits), while that word is
        // kept fresh: the card's polls, or its live TUI's events; or a Claude Code older than `--desktop`, as its version
        // read once said, for a conversation only `--desktop` can open.
        if app == .codex, engine.conversationResume?.serviceStatus(sessionID)?.holds == true,
           engine.folds[sessionID] != nil || !session.isSessionEnded && daemonsClient(sessionID) { return nil }
        if app == .claude, let known = knownClaudeVersion, known < .desktopFlag, needsDesktopFlag(sessionID, session) { return nil }
        return isInstalled(app) ? HandoffOffer(app: app) : nil
    }

    /// Its notes' agent is Codex's shared daemon: the session's TUI is that daemon's client (P1485).
    private func daemonsClient(_ sessionID: String) -> Bool {
        engine?.hookNotes.contexts[sessionID]?.agentPID.map(isServer) ?? false
    }

    /// Claude Code's version as `claude --version` last said it, kept `versionFor` (P1544): nil before the first click,
    /// and once that is past, so an updated Claude Code is offered again.
    private var knownClaudeVersion: ClaudeVersion? {
        guard let read = claudeVersion, let now = engine?.dependencies.now(),
              now.timeIntervalSince(read.at) < dependencies.versionFor else { return nil }
        return read.version
    }

    /// Open in Claude takes `claude --desktop --resume` for it: a background copy, or a session whose tab is gone. Its
    /// tab's `/desktop` needs no flag. Cheap: no process is looked at.
    private func needsDesktopFlag(_ sessionID: String, _ session: AgentSession) -> Bool {
        guard let engine else { return false }
        if engine.folds[sessionID]?.background?.holdsTheConversation == true { return true }
        if engine.claudeBackground?.isLiveBackground(liveID(sessionID)) == true { return true }
        return session.isSessionEnded || engine.state.session(id: sessionID) == nil
    }

    // MARK: The owner's click

    /// Open in <App>, on the owner's click only. A folded session whose turn runs waits for its end; any other goes now.
    public func open(_ sessionID: String) async {
        guard let engine, let offer = offer(for: sessionID), !inFlight.contains(sessionID) else { return }
        if engine.isFolded(sessionID), engine.foldTurnRuns(sessionID) {
            states[sessionID] = .pending(offer.app)
            pendingTries[sessionID] = 0
            engine.noteHandoff(sessionID, "open in \(offer.app.name) · waits for its turn's end")
            return
        }
        await go(sessionID, offer.app)
    }

    /// Cancel on "Opens in Claude when this turn ends".
    public func cancelPending(_ sessionID: String) {
        guard case .pending? = states[sessionID] else { return }
        states[sessionID] = nil
        engine?.noteHandoff(sessionID, "open in app · cancelled")
    }

    /// The card went (✕, Open in terminal): what it said goes with it.
    public func forget(_ sessionID: String) {
        states[sessionID] = nil
        handedPIDs[sessionID] = nil
        pendingTries[sessionID] = nil
    }

    /// Open in terminal on a card an app holds (the way back, P1517): true once the app no longer holds the conversation,
    /// and the card's resume may open it; false while it may (its line says why), or while the hand-over is under way.
    public func wayBack(_ sessionID: String) async -> Bool {
        guard let state = states[sessionID] else { return true }
        guard case let .inApp(app, _) = state else {
            if case .opening = state { return false }
            // Picked, pending or refused: no app holds a conversation the island follows by its id.
            states[sessionID] = nil
            return true
        }
        let held = await holder(sessionID, app)
        guard states[sessionID] != nil else { return false }
        if let held {
            states[sessionID] = .inApp(app, note: held)
            engine?.noteHandoff(sessionID, "back to a terminal · not yet · \(held)")
            return false
        }
        states[sessionID] = nil
        handedPIDs[sessionID] = nil
        engine?.noteHandoff(sessionID, "back to a terminal · \(app.name) no longer holds it")
        return true
    }

    // MARK: After every change of the engine's state (`SessionEngine.foldsFollowState`)

    /// A pending hand-over goes a moment after its turn ends, as a held reply does (P1306); one whose window closed
    /// mid-turn is dropped, and Continue's card shows. A conversation the owner took back to a terminal by hand (a new
    /// agent at a tab's controls) is the app's no longer.
    func followFold(_ sessionID: String) {
        guard let engine, let state = states[sessionID] else { return }
        switch state {
        case let .pending(app):
            if engine.folds[sessionID]?.stopped != nil {
                states[sessionID] = nil
                engine.noteHandoff(sessionID, "open in \(app.name) · dropped · its turn stopped")
                return
            }
            // Its session at its prompt, or ended or gone from the list with no turn running: a background copy under a
            // new id (claudebg's `/bg`) leaves the old id's session ended, and its turn is the copy's (`foldTurnRuns`).
            let settled = engine.state.session(id: sessionID).map { $0.phase == .completed || $0.isSessionEnded } ?? true
            guard !inFlight.contains(sessionID), !engine.foldTurnRuns(sessionID), settled else { return }
            inFlight.insert(sessionID)
            engine.dependencies.scheduleFoldCheck(SessionEngine.heldReplySettle) { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.goPending(sessionID, app) }
            }
        case .inApp, .pick:
            if let pid = engine.hookNotes.contexts[sessionID]?.agentPID, pid != handedPIDs[sessionID],
               engine.foldTabIsLive(sessionID) {
                states[sessionID] = nil
                handedPIDs[sessionID] = nil
                engine.noteHandoff(sessionID, "back in a terminal by hand")
            }
        case .opening, .blocked:
            break
        }
    }

    private func goPending(_ sessionID: String, _ app: HandoffApp) async {
        defer { inFlight.remove(sessionID) }
        guard let engine, states[sessionID] == .pending(app) else { return }
        // A turn began again in the second it waited.
        guard !engine.foldTurnRuns(sessionID) else { return }
        // Never typed into a tab in front, where the owner may be typing (P1359).
        if tabTakesTyping(sessionID), let session = engine.state.session(id: sessionID),
           await engine.dependencies.isSessionFrontmost(engine.withEffectiveJumpTarget(session)) {
            guard states[sessionID] == .pending(app) else { return }
            return finish(sessionID, .blocked(app, HandoffWords.tabInFront))
        }
        guard states[sessionID] == .pending(app) else { return }
        await run(sessionID, app)
    }

    // MARK: The hand-over

    private func go(_ sessionID: String, _ app: HandoffApp) async {
        guard inFlight.insert(sessionID).inserted else { return }
        defer { inFlight.remove(sessionID) }
        await run(sessionID, app)
    }

    private func run(_ sessionID: String, _ app: HandoffApp) async {
        guard let engine else { return }
        states[sessionID] = .opening(app)
        engine.noteHandoff(sessionID, "open in \(app.name) · under way")
        let outcome: HandoffState = switch app {
        case .claude: await openClaude(sessionID)
        case .codex: await openCodex(sessionID)
        case .vscode, .kimi, .opencode: await openPicking(sessionID, app)
        }
        finish(sessionID, outcome)
    }

    private func finish(_ sessionID: String, _ outcome: HandoffState) {
        // ✕ while it was on its way: the card went, and nothing is left to say.
        guard states[sessionID] != nil, let engine else { return }
        if case .pending = outcome {
            let tries = (pendingTries[sessionID] ?? 0) + 1
            pendingTries[sessionID] = tries
            if tries > 3 {
                states[sessionID] = .blocked(outcome.app, HandoffWords.working)
                return engine.noteHandoff(sessionID, "open in \(outcome.app.name) · not opened · still working")
            }
        }
        states[sessionID] = outcome
        if case .inApp = outcome { engine.appTookConversation(sessionID) }
        engine.noteHandoff(sessionID, Self.said(outcome))
    }

    static func said(_ state: HandoffState) -> String {
        switch state {
        case let .pending(app): "open in \(app.name) · waits for its turn's end"
        case let .opening(app): "open in \(app.name) · under way"
        case let .inApp(app, _): "open in \(app.name) · opened"
        case let .pick(app): "open in \(app.name) · opened, the owner picks it there"
        case let .blocked(app, why): "open in \(app.name) · \(why)"
        }
    }

    /// Claude Code: its tab's own `/desktop`; its background copy stopped first; or, its tab gone and nothing running
    /// it, `claude --desktop --resume <id>`.
    private func openClaude(_ sessionID: String) async -> HandoffState {
        guard let engine else { return .blocked(.claude, HandoffWords.didNotOpen(.claude)) }
        // Its own agent at its tab's prompt is the interactive copy, the only one: Claude Code's own command moves it.
        if tabTakesTyping(sessionID) {
            return await typeAndWait(sessionID, .claude) { .inApp(.claude, note: nil) }
        }
        // `claude --version` first: a CLI too old for `--desktop` lists, stops and opens nothing, so a background copy is
        // never stopped for a move that cannot happen.
        if let refused = await desktopFlagMissing() { return refused }
        let target = liveID(sessionID)
        // A list that cannot be read cannot say no background copy runs it: nothing more runs.
        guard let list = await claudeAgents() else { return .blocked(.claude, HandoffWords.noList) }
        let entry = list.first { Self.names($0, target) && $0.isLive }
        if let entry, entry.isBackground {
            // A turn under way is never ended for the move: it goes at that turn's end.
            if entry.isWorking { return engine.isFolded(sessionID) ? .pending(.claude) : .blocked(.claude, HandoffWords.working) }
            guard let short = entry.id else { return .blocked(.claude, HandoffWords.backgroundStayed) }
            // A window attached to it (`claude attach`) would wake the stopped copy beside Claude: it closes first (P1536).
            if let backgrounder = engine.claudeBackground, await backgrounder.lookForAttached(target, shortID: short) != nil {
                return .blocked(.claude, HandoffWords.attached)
            }
            guard await stopBackground(short, sessionID: sessionID, target: target) else {
                return .blocked(.claude, HandoffWords.backgroundStayed)
            }
            return await desktop(sessionID, target: target)
        }
        // An interactive copy Claude Code lists, or any process that runs it, is a holder the hand-over cannot stop.
        if entry != nil { return .blocked(.claude, HandoffWords.stillRuns) }
        if await sourceRuns(sessionID) { return .blocked(.claude, HandoffWords.stillRuns) }
        return await desktop(sessionID, target: target)
    }

    /// Why `claude --desktop` cannot run: Claude Code not found, or older than 2.1.285 (no update ever runs); nil when it
    /// can.
    private func desktopFlagMissing() async -> HandoffState? {
        guard let run = runner else { return .blocked(.claude, HandoffWords.didNotOpen(.claude)) }
        let version = await Self.off { run(HandoffCommand.claude(["--version"], timeout: 15)) }
        if version.missing { return .blocked(.claude, HandoffWords.claudeMissing) }
        let found = ClaudeVersion.parse(version.output)
        if let now = engine?.dependencies.now() { claudeVersion = (found, now) }
        guard let found, found >= .desktopFlag else {
            return .blocked(.claude, HandoffWords.updateClaude)
        }
        return nil
    }

    /// `claude --desktop --resume <id>` (its version read first, `desktopFlagMissing`). Claude Code itself refuses a
    /// session open in another terminal or running in the background: a second guard behind the island's own.
    private func desktop(_ sessionID: String, target: String) async -> HandoffState {
        guard let run = runner else { return .blocked(.claude, HandoffWords.didNotOpen(.claude)) }
        let command = HandoffCommand.claude(["--desktop", "--resume", target], folder: folder(of: sessionID), timeout: 60)
        let result = await Self.off { run(command) }
        guard result.succeeded else { return .blocked(.claude, "Not opened · " + (result.said ?? "Claude Code said no")) }
        return .inApp(.claude, note: nil)
    }

    /// Codex: the daemon not holding the thread; its TUI ended with its own `/quit`, or its tab gone and nothing running
    /// it; the daemon asked again; then `codex://threads/<id>`.
    private func openCodex(_ sessionID: String) async -> HandoffState {
        guard engine != nil else { return .blocked(.codex, HandoffWords.didNotOpen(.codex)) }
        // Asked before anything is typed: a TUI that is the daemon's client (0.158's default) leaves the thread loaded
        // there for the daemon's unload delay when it quits, and the Codex app is not the daemon's client by default
        // (openai/codex#47425), so it could not take the thread: the TUI is left as it is.
        if await daemonHolds(sessionID) { return .blocked(.codex, ResumeExit.heldElsewhereWords) }
        if tabTakesTyping(sessionID) {
            let quit = await typeAndWait(sessionID, .codex) { .opening(.codex) }
            guard case .opening = quit else { return quit }
        }
        if await sourceRuns(sessionID) { return .blocked(.codex, HandoffWords.stillRuns) }
        if await daemonHolds(sessionID) { return .blocked(.codex, ResumeExit.heldElsewhereWords) }
        guard let open = dependencies.openLink ?? (live ? HandoffApps.openLink : nil) else {
            return .blocked(.codex, HandoffWords.didNotOpen(.codex))
        }
        let link = ExactJump.codexThreadLink(sessionID)
        let opened = await Self.off { open(link) }
        return opened ? .inApp(.codex, note: nil) : .blocked(.codex, HandoffWords.didNotOpen(.codex))
    }

    /// An app that lists the CLI's sessions: the CLI ended with its own `/exit` (or its tab gone and nothing running it),
    /// then the app opened by its path (VS Code on the session's folder). The owner picks the session there.
    private func openPicking(_ sessionID: String, _ app: HandoffApp) async -> HandoffState {
        guard engine != nil else { return .blocked(app, HandoffWords.didNotOpen(app)) }
        guard let url = appURL(app) else { return .blocked(app, HandoffWords.appMissing(app)) }
        if tabTakesTyping(sessionID) {
            let quit = await typeAndWait(sessionID, app) { .opening(app) }
            guard case .opening = quit else { return quit }
        }
        if await sourceRuns(sessionID) { return .blocked(app, HandoffWords.stillRuns) }
        guard let open = dependencies.openApp ?? (live ? HandoffApps.open : nil) else { return .blocked(app, HandoffWords.didNotOpen(app)) }
        let folder = app == .vscode ? folder(of: sessionID) : nil
        let opened = await Self.off { open(url, folder) }
        return opened ? .pick(app) : .blocked(app, HandoffWords.didNotOpen(app))
    }

    /// Types the app's tab command at the CLI's prompt (the reply path: only a known tab, only while its agent holds it,
    /// P139), then waits until that agent's process is gone. `done`: the state once it is.
    private func typeAndWait(_ sessionID: String, _ app: HandoffApp, done: () -> HandoffState) async -> HandoffState {
        guard let engine, let pid = engine.hookNotes.contexts[sessionID]?.agentPID else { return .blocked(app, HandoffWords.notTyped) }
        guard await engine.reply(sessionID: sessionID, text: app.tabCommand) == .sent else { return .blocked(app, HandoffWords.notTyped) }
        engine.noteHandoff(sessionID, "open in \(app.name) · typed \(app.tabCommand)")
        for _ in 0..<dependencies.exitLooks {
            if !engine.dependencies.processExists(pid) {
                handedPIDs[sessionID] = pid
                return done()
            }
            await dependencies.sleep(dependencies.exitLook)
        }
        return .blocked(app, HandoffWords.stayedInTab)
    }

    /// `claude stop <id>` through the engine's `ClaudeBackgrounder` (the background family's one runner, P1531), then
    /// Claude Code's list until it no longer lists the session live.
    private func stopBackground(_ short: String, sessionID: String, target: String) async -> Bool {
        guard let backgrounder = engine?.claudeBackground, backgrounder.canRun else { return false }
        engine?.noteHandoff(sessionID, "open in Claude · claude stop \(short)")
        let stopped = await backgrounder.stop(sessionID: sessionID, shortID: short, profile: claudeHome)
        // The card says why on its own line: the background card's "Not stopped" is not shown beside it.
        guard stopped else {
            backgrounder.clearProblem(sessionID)
            return false
        }
        for _ in 0..<dependencies.stopLooks {
            if let list = await claudeAgents(),
               !list.contains(where: { Self.names($0, target) && $0.isLive }) { return true }
            await dependencies.sleep(dependencies.stopLook)
        }
        return false
    }

    /// Who holds a conversation the app had, for the way back; nil: nobody.
    private func holder(_ sessionID: String, _ app: HandoffApp) async -> String? {
        let running = dependencies.isAppRunning ?? (live ? HandoffApps.isRunning : nil)
        let name = dependencies.appName ?? (live ? { HandoffApps.displayName($0) } : { $0.name })
        switch app {
        case .claude:
            // Claude gives no sign when the owner leaves a session, and neither a process's arguments nor Claude Code's
            // own list is known to name one it has open: while Claude runs it may hold it, so only its quit frees it.
            return running?(.claude) ?? false ? HandoffWords.quitApp(name(.claude)) : nil
        case .codex:
            // The app keeps a thread's writer until it quits (openai/codex#37450).
            if running?(.codex) ?? false { return HandoffWords.quitApp(name(.codex)) }
            return await daemonHolds(sessionID) ? ResumeExit.heldElsewhereWords : nil
        case .vscode, .kimi, .opencode:
            return nil
        }
    }

    // MARK: Inside

    private var runner: (@Sendable (HandoffCommand) -> HandoffResult)? { dependencies.run ?? (live ? HandoffRun.live : nil) }

    /// Claude Code's own list for the default profile, read now (never a cache) by the engine's `ClaudeBackgrounder`;
    /// empty, unasked, where its supervisor has never run; nil when it cannot be read (no backgrounder, an older Claude
    /// Code, an error).
    private func claudeAgents() async -> [ClaudeBackgroundEntry]? {
        if let custom = dependencies.claudeAgents { return await custom() }
        guard let backgrounder = engine?.claudeBackground, backgrounder.canRun else { return nil }
        let home = dependencies.home
        let roster: @Sendable () -> Bool
        if let custom = dependencies.hasRoster {
            roster = custom
        } else if live {
            roster = { FileManager.default.fileExists(atPath: home + "/.claude/daemon/roster.json") }
        } else {
            roster = { true }
        }
        guard await Self.off(roster) else { return [] }
        return await backgrounder.list(profile: claudeHome)
    }

    /// The default profile's folder: the only one Claude's app opens (P1512).
    private var claudeHome: String { dependencies.home + "/" + Provider.claude.defaultFolderName }

    /// Something runs the conversation: the island's own run of it, the agent its fold or its notes name while alive, a
    /// session not ended with no pid known (it may still run), or any of this user's processes whose arguments name its id.
    private func sourceRuns(_ sessionID: String) async -> Bool {
        guard let engine else { return true }
        if engine.conversationResume?.isRunning(sessionID) == true { return true }
        let server = isServer
        if let pid = engine.folds[sessionID]?.agentPID, pid != handedPIDs[sessionID], !server(pid),
           engine.foldAgentRuns(sessionID, pid: pid) { return true }
        if let session = engine.state.session(id: sessionID), !session.isSessionEnded {
            if let pid = engine.hookNotes.contexts[sessionID]?.agentPID {
                if pid != handedPIDs[sessionID], !server(pid), engine.dependencies.processExists(pid) { return true }
            } else if session.isHookManaged || session.isProcessAlive {
                return true
            }
        }
        guard let find = dependencies.findAgents ?? (live ? AgentProcessScan.live : nil) else { return false }
        let ids = Array(Set([sessionID, liveID(sessionID)]))
        let found = await Self.off { ids.flatMap(find) }
        return !found.filter { !server($0) }.isEmpty
    }

    /// Its tab takes typing now: a known tab whose agent is at its prompt (P139), and that agent the session's own, never a
    /// shared server's (Codex's daemon has no tab of the session's).
    private func tabTakesTyping(_ sessionID: String) -> Bool {
        guard let engine, engine.canReply(sessionID: sessionID) else { return false }
        guard let pid = engine.hookNotes.contexts[sessionID]?.agentPID else { return true }
        return !isServer(pid)
    }

    /// A shared server's pid (`Dependencies.isServer`, else the engine's own check, P1485).
    private var isServer: (Int32) -> Bool {
        if let custom = dependencies.isServer { return custom }
        guard let engine else { return { _ in false } }
        return { engine.agentIsCodexServer($0) }
    }

    /// Codex's shared daemon says it has the thread loaded (its writer); false while it is not wired or does not know.
    private func daemonHolds(_ sessionID: String) async -> Bool {
        if let holds = dependencies.codexDaemonHolds { return await holds(sessionID) == true }
        guard let resume = engine?.conversationResume else { return false }
        let home = dependencies.home + "/" + Provider.codex.defaultFolderName
        return await resume.codexDaemonHolds(threadID: liveID(sessionID), profile: home) == true
    }

    /// The id the conversation goes on under now (`Dependencies.conversation`).
    private func liveID(_ sessionID: String) -> String {
        dependencies.conversation?(sessionID) ?? engine?.movedConversation(from: sessionID) ?? sessionID
    }

    /// The list's entry is that conversation's.
    nonisolated static func names(_ entry: ClaudeBackgroundEntry, _ id: String) -> Bool {
        entry.sessionID?.lowercased() == id.lowercased()
    }

    private func isDefault(_ profile: String, _ provider: Provider) -> Bool {
        let key = provider.rawValue + ":" + profile
        if let known = defaultFolders[key] { return known }
        let yes = CLIEnvironment.isDefaultFolder(profile, for: provider, home: dependencies.home)
        defaultFolders[key] = yes
        return yes
    }

    private func isInstalled(_ app: HandoffApp) -> Bool {
        guard let engine else { return false }
        let now = engine.dependencies.now()
        if let known = installed[app], now.timeIntervalSince(known.at) < dependencies.installedFor { return known.yes }
        let yes = appURL(app) != nil
        installed[app] = (yes, now)
        return yes
    }

    private func appURL(_ app: HandoffApp) -> URL? {
        guard let lookup = dependencies.appURL ?? (live ? { HandoffApps.url($0) } : nil) else { return nil }
        return lookup(app)
    }

    private func profile(of session: AgentSession, provider: Provider) -> String? {
        if let custom = dependencies.profile { return custom(session.id) }
        return engine?.accountTags[session.id]?.folder ?? SessionResumer.profile(of: session, provider: provider)
    }

    /// The session's folder, as its jump target or its fold's copy names it.
    private func folder(of sessionID: String) -> String? {
        guard let engine else { return nil }
        let session = engine.state.session(id: sessionID) ?? engine.folds[sessionID]?.session
        return ExactJump.nonEmpty(session?.jumpTarget?.workingDirectory)
    }

    nonisolated static func off<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { body() }.value
    }
}
