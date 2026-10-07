import Foundation
import JuiceCore
import Observation
import OpenIslandCore

/// Sessions the owner went on with from a folded card (`SessionResumer`), and those whose run is under way. Read on the
/// request broker's queue as well as the main thread, so it is a locked set (P1327, P1328). Memory only.
final class IslandResumeBook: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed: Set<String> = []
    private var running: Set<String> = []

    func start(_ sessionID: String) {
        lock.withLock {
            resumed.insert(sessionID)
            running.insert(sessionID)
        }
    }

    func end(_ sessionID: String) {
        _ = lock.withLock { running.remove(sessionID) }
    }

    func wasResumed(_ sessionID: String) -> Bool { lock.withLock { resumed.contains(sessionID) } }

    func isRunning(_ sessionID: String) -> Bool { lock.withLock { running.contains(sessionID) } }
}

/// Route (b) of a folded session (wave 6, P1325 to P1349): once its tab is gone, a reply the owner types in its card goes
/// on through the agent's own resume, and Open in terminal reopens the conversation in a new window. Claude Code and
/// Codex only; every other agent's card says "Open in terminal to reply".
///
/// Nothing starts by itself: a run begins only with `continueConversation`, which the card calls on the owner's Return
/// (or for a reply it held, which was a Return too), or on their click on Continue (P1419), and never while the
/// session's agent runs anywhere (P1420). One run per session; Stop sends SIGINT, then SIGTERM after
/// `stopGrace`; `endAll` ends every run when the app quits or Live sessions goes off. The run keeps hooks on and the
/// session's own id, so the island follows the turn as it follows any other: Working, the tool line, approvals as cards
/// (held for the island while the run lasts, P1328), the new last message. A headless engine (tests, renders, the demo)
/// has no live runner and no window opener: only injected ones run, so no test starts a CLI or opens a window.
@MainActor
@Observable
public final class SessionResumer: ConversationResuming {
    /// The line a Codex card shows above its field before the first send: `codex exec` never asks before a command and
    /// runs under its own sandbox (P1329).
    public static let codexNote = "Codex runs this without asking, within its sandbox."

    struct Dependencies: Sendable {
        /// Starts a run; nil: the live process for the app's own engine, none for a headless one.
        var start: (@Sendable (ResumeCommand) throws -> any ResumeProcess)?
        /// Opens Open in terminal's new window; nil: Open in's own (`FreshSessionLaunch.live`) for the app's engine, none
        /// for a headless one.
        var openWindow: (@Sendable (FreshSessionLaunch) -> Bool)?
        var isFolder: @Sendable (String) -> Bool = { FreshSessionLaunch.isFolder($0) }
        /// The owner's usual terminal, for a session whose own is not known (`FreshSessionLaunch.usualHost`).
        var usualHost: @Sendable () -> FreshSessionLaunch.Host = { FreshSessionLaunch.liveUsualHost() }
        /// The app's environment, from which only the ssh agent's socket and the shell are taken (`ResumeCommand.make`).
        var environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        /// From Stop's SIGINT to its SIGTERM.
        var stopGrace: Duration = .seconds(3)
        /// How long a quit waits for its SIGINTs before the SIGTERMs.
        var quitGrace: TimeInterval = 1
        /// This user's agent processes whose arguments name a session's id (`claude --resume <id>`, `codex resume <id>`),
        /// looked for off the main thread just before a run starts or a new window opens (P1420); nil: the live scan
        /// (`AgentProcessScan`) for the app's own engine, none for a headless one.
        var findAgents: (@Sendable (String) -> [Int32])?
        /// Codex's shared background service (P1487): asked whether it holds a Codex session's thread, and given the
        /// reply when it does. nil: none (every headless engine, and every test that gives none); the app's own engine
        /// gets the live link (`init(engine:)`).
        var daemon: (any CodexDaemonReaching)?
        /// A turn the island started on the service counts as ended only once it reads not running this long after it
        /// began: the service may not show a turn it just took yet.
        var serviceSettle: TimeInterval = 3
        /// How often a folded session's thread is asked about while a turn runs there (or the island's own does), and
        /// while the service holds it idle (its unload, or the service gone).
        var servicePollBusy: TimeInterval = 5
        var servicePollIdle: TimeInterval = 60
    }

    /// One run under way.
    public struct Run: Equatable, Sendable {
        public var startedAt: Date
        public var pid: Int32?
        /// Stop was asked for.
        public var stopping = false
    }

    /// What the session's resume would run, as known before the island's first run of it: the run's own notes name no
    /// terminal, so the host is kept from before (P1330).
    struct Conversation: Equatable, Sendable {
        var provider: Provider
        var folder: String
        var profile: String
        var host: FreshSessionLaunch.Host?
    }

    @ObservationIgnored private weak var engine: SessionEngine?
    @ObservationIgnored let dependencies: Dependencies
    /// Runs under way, by session: the card reads Working and offers Stop.
    public private(set) var runs: [String: Run] = [:]
    /// The line for a run that did not start or ended badly, by session, until its next send (P1331).
    public private(set) var problems: [String: String] = [:]
    /// The last run's own final text, by session, from the CLI's output: for a profile whose hooks did not report it.
    public private(set) var answers: [String: String] = [:]
    @ObservationIgnored private var processes: [String: any ResumeProcess] = [:]
    @ObservationIgnored private var conversations: [String: Conversation] = [:]
    /// The island's own runs' pids: their hook notes are not the agent's own process (P1326).
    @ObservationIgnored private var runPIDs: Set<Int32> = []
    /// What Codex's shared background service last said of each session's thread (P1487). Observed: a card follows it.
    public private(set) var serviceViews: [String: CodexDaemonStatus] = [:]
    /// The asks under way, one per session, and those asked for again meanwhile.
    @ObservationIgnored private var serviceAsks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var serviceAgain: Set<String> = []
    /// Sessions with a poll of the service waiting.
    @ObservationIgnored private var servicePolls: Set<String> = []
    /// The island's own turns on the service, by session: the turn's id, for Stop.
    @ObservationIgnored private var serviceTurns: [String: String] = [:]

    /// The app's own resumer: with the live link to Codex's shared background service when the engine is the app's own,
    /// never in a test process, whose engines may start their bridge but never reach the owner's daemon (P929, P1496).
    public convenience init(engine: SessionEngine) {
        var dependencies = Dependencies()
        if engine.configuration.startBridge, !CodexDaemonLink.runningUnderTests { dependencies.daemon = CodexDaemonLink() }
        self.init(engine: engine, dependencies: dependencies)
    }

    init(engine: SessionEngine, dependencies: Dependencies) {
        self.engine = engine
        self.dependencies = dependencies
    }

    // MARK: ConversationResuming

    /// `.resume` for a Claude Code or Codex session that can go on here (the note for Codex, P1329); `.openOnly` for any
    /// other agent, a Codex app thread, an SSH session, an id that is not a UUID, a folder or profile folder not on this
    /// Mac, and while the agent's own process still runs (P1332: resuming it then would write one transcript from two
    /// processes). Looks at no process but the pid its notes name, and at two folders; never asks for the CLI.
    ///
    /// `.daemon` while Codex's shared background service holds the thread (it is its one writer, so `codex exec resume`
    /// would only be refused, P1440): a reply goes there instead (P1487).
    public func availability(for sessionID: String) -> ResumeAvailability {
        guard let conversation = conversation(for: sessionID) else { return .openOnly }
        if conversation.provider == .codex, serviceHolds(sessionID) { return .daemon(note: Self.serviceNote) }
        guard !agentStillRuns(sessionID) else { return .openOnly }
        return .resume(note: conversation.provider == .codex ? Self.codexNote : nil)
    }

    public func isRunning(_ sessionID: String) -> Bool { runs[sessionID] != nil }

    /// Starts the session's resume with `text` (P1325): `.sent` once the process started, `.notSent` when it could not
    /// (the CLI not found, no runner; the card then has `problem`), `.nothingToSend` for empty text, a run already under
    /// way (the card holds the reply) or a session that cannot resume.
    public func continueConversation(_ sessionID: String, text: String) async -> SendOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let offered = availability(for: sessionID)
        guard !text.isEmpty, runs[sessionID] == nil, let engine, offered != .openOnly,
              let conversation = conversation(for: sessionID) else { return .nothingToSend }
        problems[sessionID] = nil
        answers[sessionID] = nil
        // Codex: its shared background service is asked first, every time (P1488). Holding the thread, it gets the
        // reply; running a turn there, nothing runs now ("Codex is still finishing this in the background").
        if conversation.provider == .codex, let daemon = dependencies.daemon {
            // Recorded before anything waits, so a second Return finds it under way (P1333).
            runs[sessionID] = Run(startedAt: engine.dependencies.now())
            let status = await ask(sessionID, home: conversation.profile, daemon: daemon)
            if status.turnRuns {
                runs[sessionID] = nil
                problems[sessionID] = Self.finishingWords
                engine.noteFold(sessionID, .serviceFinishing)
                return .notSent
            }
            if status.holds {
                return await startServiceTurn(sessionID, text: text, conversation: conversation, daemon: daemon)
            }
            runs[sessionID] = nil
            // Not there: the exec resume, as before; a session the service ran is offered it only once the service
            // said so (`agentStillRuns`).
            guard case .resume = availability(for: sessionID) else { return .nothingToSend }
        }
        guard let start = dependencies.start ?? (engine.configuration.startBridge ? LiveResumeProcess.start : nil) else {
            problems[sessionID] = "Not sent"
            engine.noteFold(sessionID, .resumeNotStarted(.noRunner))
            return .notSent
        }
        // Recorded before anything waits, so a second Return finds it under way (P1333).
        runs[sessionID] = Run(startedAt: engine.dependencies.now())
        // The agent's own process, wherever it runs, never shares the transcript with a run (P1332, P1420): looked for
        // by its pid and by its arguments, just before the run starts.
        if let pid = await agentRunningAnywhere(sessionID) {
            runs[sessionID] = nil
            problems[sessionID] = "Not sent · it still runs in a terminal"
            engine.noteFold(sessionID, .resumeRefused(agentPID: pid))
            return .notSent
        }
        // Kept as it is now: from here on, the session's notes are the run's, which name no terminal.
        conversations[sessionID] = conversation
        let command = ResumeCommand.make(provider: conversation.provider, sessionID: sessionID, text: text,
                                         folder: conversation.folder, profile: conversation.profile,
                                         inherited: dependencies.environment())
        // Before the process starts, so its first hook note already finds the session the owner's and its first
        // approval held (P1327, P1328).
        engine.islandRunStarted(sessionID)
        let process: any ResumeProcess
        do {
            process = try await Task.detached(priority: .userInitiated) { try start(command) }.value
        } catch {
            runs[sessionID] = nil
            engine.islandRunEnded(sessionID)
            problems[sessionID] = Self.notStartedWords(error, provider: conversation.provider)
            engine.noteFold(sessionID, .resumeNotStarted((error as? ResumeStartError).map {
                if case .toolMissing = $0 { return .toolMissing } else { return .couldNotStart }
            } ?? .couldNotStart))
            return .notSent
        }
        engine.noteFold(sessionID, .resumeStarted)
        processes[sessionID] = process
        runPIDs.insert(process.pid)
        runs[sessionID]?.pid = process.pid
        // Stop was pressed while it was starting.
        if runs[sessionID]?.stopping == true { interrupt(process, of: sessionID) }
        Task { @MainActor [weak self] in
            let exit = await process.exit()
            self?.finished(sessionID, process: process, exit: exit)
        }
        return .sent
    }

    /// SIGINT (Claude Code and Codex end the turn and exit), then SIGTERM after `stopGrace` if the run still lives. A run
    /// still starting is interrupted as soon as it has a process.
    ///
    /// A turn the island started on Codex's background service: `turn/interrupt` for that turn, on the owner's Stop only
    /// (P1490); the service then says it ended.
    public func stop(_ sessionID: String) {
        guard runs[sessionID] != nil, runs[sessionID]?.stopping == false else { return }
        runs[sessionID]?.stopping = true
        if serviceTurns[sessionID] != nil { return interruptServiceTurn(sessionID) }
        guard let process = processes[sessionID] else { return }
        interrupt(process, of: sessionID)
    }

    /// A new window of the session's own terminal (as it was before the island's first run, else the owner's usual
    /// one) typing the interactive resume in its folder and profile, through Open in's own path (P703, P1330); with
    /// `prompt` as its first prompt, for a stopped turn the card carries on (P1439). False while a run is under way.
    /// When the agent's own process still runs, or for an agent this does not resume, the plain jump, never a second
    /// copy of the conversation, and nothing typed.
    ///
    /// A thread Codex's shared background service holds: the new window's `codex resume '<id>'` joins it there as one more
    /// client of the one writer (P1489), whatever else shows it, so neither its agent's pid nor the scan holds it back;
    /// a turn the island runs there does not either.
    public func openInTerminal(_ sessionID: String, continuing prompt: String?) async -> Bool {
        guard let engine else { return false }
        if let conversation = conversation(for: sessionID), conversation.provider == .codex, serviceHolds(sessionID),
           runs[sessionID] == nil || serviceTurns[sessionID] != nil {
            return await openWindow(sessionID, conversation: conversation,
                                    prompt: serviceTurnRuns(sessionID) ? nil : prompt, engine: engine)
        }
        guard runs[sessionID] == nil else { return false }
        let elsewhere = conversation(for: sessionID) != nil && !agentStillRuns(sessionID) ? await agentRunningAnywhere(sessionID) : nil
        guard runs[sessionID] == nil, let conversation = conversation(for: sessionID), !agentStillRuns(sessionID), elsewhere == nil else {
            guard engine.state.session(id: sessionID) != nil else { return false }
            // The log says why it took the plain jump: its agent runs, or there is no conversation to open (P1441).
            engine.noteFold(sessionID, .opened(elsewhere != nil || agentStillRuns(sessionID) ? .agentRuns : .jump))
            let outcome = await engine.jump(sessionID: sessionID)
            return outcome.result == .matched || outcome.result == .activatedOnly
        }
        return await openWindow(sessionID, conversation: conversation, prompt: prompt, engine: engine)
    }

    /// The new window with the interactive resume (P703, P1330, P1439).
    private func openWindow(_ sessionID: String, conversation: Conversation, prompt: String?, engine: SessionEngine) async -> Bool {
        conversations[sessionID] = conversation
        let launch = FreshSessionLaunch(
            host: conversation.host ?? dependencies.usualHost(), folder: conversation.folder,
            line: ResumeCommand.terminalLine(provider: conversation.provider, sessionID: sessionID, folder: conversation.folder,
                                             profile: conversation.profile, prompt: prompt))
        guard let open = dependencies.openWindow ?? (engine.configuration.startBridge ? FreshSessionLaunch.live : nil) else {
            return false
        }
        let opened = await Task.detached(priority: .userInitiated) { open(launch) }.value
        let continuing = prompt.flatMap(ResumeOutput.nonEmpty) != nil
        if opened { engine.noteFold(sessionID, .opened(continuing ? .newWindowContinuing : .newWindow)) }
        return opened
    }

    /// Open in terminal with the conversation alone.
    public func openInTerminal(_ sessionID: String) async -> Bool {
        await openInTerminal(sessionID, continuing: nil)
    }

    // MARK: The card's line and answer (contract R3)

    /// One line for a run that did not start or ended badly ("Not sent · …", "Failed · …"), nil once the next send
    /// starts and for a run that ended well or was stopped.
    public func problem(_ sessionID: String) -> String? { problems[sessionID] }

    /// The last run's final text from the CLI's own output: for a profile whose hooks did not report it.
    public func answer(_ sessionID: String) -> String? { answers[sessionID] }

    /// What the session's resume would run, as it is now, kept for when its session has left the engine's state
    /// (P1355): upstream's monitor drops an ended session on its next pass, and `conversation(for:)` then has only what
    /// was kept. Looks at two folders; runs nothing.
    public func keep(_ sessionID: String) {
        guard let engine, engine.state.session(id: sessionID) != nil, let conversation = conversation(for: sessionID) else { return }
        conversations[sessionID] = conversation
    }

    /// Ends every run: SIGINT, at most `quitGrace` for them to exit, then SIGTERM (the app quits, or Live sessions went
    /// off). A run still starting is interrupted as soon as it has a process.
    ///
    /// A turn the island started on Codex's background service is the service's, not the app's: it goes on (P1490).
    public func endAll() {
        for sessionID in runs.keys { runs[sessionID]?.stopping = true }
        let all = Array(processes.values)
        for process in all { process.interrupt() }
        let deadline = Date().addingTimeInterval(dependencies.quitGrace)
        while all.contains(where: { !$0.hasExited }), Date() < deadline { usleep(20_000) }
        for process in all where !process.hasExited { process.terminate() }
    }

    // MARK: Codex's shared background service (P1487 to P1494)

    /// The line a card says before its first reply goes to the service.
    public static let serviceNote = "Goes to Codex's background service"
    /// What a card says while the service goes on with a turn of the thread, and what a resume that met it says instead
    /// of "active writer" (P1488).
    public static let finishingWords = "Codex is still finishing this in the background"

    /// What the service last said of the session's thread; nil with no link to it, or before it was asked.
    public func serviceStatus(_ sessionID: String) -> CodexDaemonStatus? {
        dependencies.daemon == nil ? nil : serviceViews[sessionID]
    }

    /// The service holds the thread, as it last said.
    func serviceHolds(_ sessionID: String) -> Bool { serviceStatus(sessionID)?.holds == true }

    /// Asks the service now, off the main thread, for a Codex session it may hold; one ask at a time per session.
    public func lookAgain(_ sessionID: String) async {
        guard let daemon = dependencies.daemon, let conversation = conversation(for: sessionID),
              conversation.provider == .codex else { return }
        _ = await ask(sessionID, home: conversation.profile, daemon: daemon)
    }

    /// For Open in Codex (lane APPS): whether the service holds `threadID` in the profile `home` now. nil: no service,
    /// or it could not be asked.
    public func codexDaemonHolds(threadID: String, profile home: String) async -> Bool? {
        guard let daemon = dependencies.daemon else { return nil }
        switch await daemon.status(of: threadID, home: home) {
        case .idle, .active: return true
        case .notHeld: return false
        case .noDaemon, .failed: return nil
        }
    }

    /// One ask, its answer taken. Asked again while one is under way, that one asks once more as it ends, so an answer
    /// always postdates the event that asked (a turn's end must not read an answer from before it).
    @discardableResult
    private func ask(_ sessionID: String, home: String, daemon: any CodexDaemonReaching) async -> CodexDaemonStatus {
        if let asking = serviceAsks[sessionID] {
            serviceAgain.insert(sessionID)
            await asking.value
            return serviceViews[sessionID] ?? .failed("not asked")
        }
        let task = Task { @MainActor [weak self] in
            while let self {
                let askedAt = self.engine?.dependencies.now() ?? Date()
                let status = await daemon.status(of: sessionID, home: home)
                self.take(status, for: sessionID, askedAt: askedAt)
                guard self.serviceAgain.remove(sessionID) != nil else { break }
            }
            self?.serviceAsks[sessionID] = nil
        }
        serviceAsks[sessionID] = task
        await task.value
        return serviceViews[sessionID] ?? .failed("not asked")
    }

    /// The service's answer: kept, the island's own turn there ended when it no longer runs, the card told, the next
    /// poll planned.
    private func take(_ status: CodexDaemonStatus, for sessionID: String, askedAt: Date) {
        guard let engine else { return }
        let before = serviceViews[sessionID]
        // An ask that failed says nothing new of a thread the service was seen to hold.
        if case .failed = status, before?.holds == true {} else { serviceViews[sessionID] = status }
        // The turn Continue or a reply met has ended there: its words are no longer true (P1488).
        if !status.turnRuns, !Self.isFailure(status), problems[sessionID] == Self.finishingWords { problems[sessionID] = nil }
        if serviceTurns[sessionID] != nil, let run = runs[sessionID], !status.turnRuns, !Self.isFailure(status),
           engine.dependencies.now().timeIntervalSince(run.startedAt) >= dependencies.serviceSettle {
            endServiceTurn(sessionID)
        }
        if serviceViews.count > 200 {
            serviceViews = serviceViews.filter { engine.state.session(id: $0.key) != nil || engine.folds[$0.key] != nil }
        }
        engine.serviceAnswered(sessionID, serviceViews[sessionID] ?? status, changed: before != serviceViews[sessionID], askedAt: askedAt)
        scheduleServicePoll(sessionID)
    }

    static func isFailure(_ status: CodexDaemonStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    /// A folded session's thread is asked about again a while on: soon while a turn runs there (or the island's own
    /// does, or its fold reads a turn), seldom while the service holds it idle; never once its card went or the service
    /// no longer holds it.
    private func scheduleServicePoll(_ sessionID: String) {
        guard let engine, engine.folds[sessionID] != nil, serviceHolds(sessionID) || serviceTurns[sessionID] != nil,
              servicePolls.insert(sessionID).inserted else { return }
        let busy = serviceTurnRuns(sessionID) || serviceTurns[sessionID] != nil || engine.folds[sessionID]?.turnOpen == true
        engine.dependencies.scheduleFoldCheck(busy ? dependencies.servicePollBusy : dependencies.servicePollIdle) { [weak self] in
            guard let self else { return }
            self.servicePolls.remove(sessionID)
            guard self.engine?.folds[sessionID] != nil else { return }
            Task { await self.lookAgain(sessionID) }
        }
    }

    /// The reply as a turn on the service (`turn/start`): the text inside the JSON-RPC message, never on a command line
    /// (P1325); on the owner's Return or Continue only. The run reads Working with Stop until the service says it ended.
    private func startServiceTurn(_ sessionID: String, text: String, conversation: Conversation,
                                  daemon: any CodexDaemonReaching) async -> SendOutcome {
        guard let engine else { return .notSent }
        conversations[sessionID] = conversation
        // Before the turn, so its notes find the session the owner's (P1327).
        engine.islandRunStarted(sessionID)
        let started = await daemon.startTurn(on: sessionID, home: conversation.profile, text: text)
        guard case let .started(turnID) = started else {
            runs[sessionID] = nil
            engine.islandRunEnded(sessionID)
            switch started {
            case .notHeld:
                serviceViews[sessionID] = .notHeld
                problems[sessionID] = "Not sent · Codex's background service let it go"
            case .noDaemon:
                serviceViews[sessionID] = .noDaemon
                problems[sessionID] = "Not sent · Codex's background service is not running"
            case let .failed(words):
                problems[sessionID] = "Not sent · " + words
            case .started:
                break
            }
            engine.noteFold(sessionID, .resumeNotStarted(.couldNotStart))
            return .notSent
        }
        serviceTurns[sessionID] = turnID
        serviceViews[sessionID] = .active(waitsOnYou: false)
        engine.noteFold(sessionID, .resumeStarted)
        // Stop was pressed while it was starting.
        if runs[sessionID]?.stopping == true { interruptServiceTurn(sessionID) }
        scheduleServicePoll(sessionID)
        return .sent
    }

    private func interruptServiceTurn(_ sessionID: String) {
        guard let daemon = dependencies.daemon, let turnID = serviceTurns[sessionID],
              let home = conversations[sessionID]?.profile ?? conversation(for: sessionID)?.profile else { return }
        Task { @MainActor [weak self] in
            _ = await daemon.interrupt(turn: turnID, on: sessionID, home: home)
            await self?.lookAgain(sessionID)
        }
    }

    /// The island's own turn on the service ended: the card reads its answer as its hooks gave it.
    private func endServiceTurn(_ sessionID: String) {
        let stopped = runs[sessionID]?.stopping == true
        serviceTurns[sessionID] = nil
        runs[sessionID] = nil
        engine?.noteFold(sessionID, .serviceTurnEnded(stopped: stopped))
        engine?.islandRunEnded(sessionID)
    }

    // MARK: Inside

    private func interrupt(_ process: any ResumeProcess, of sessionID: String) {
        process.interrupt()
        let grace = dependencies.stopGrace, sleep = dependencies.sleep
        Task { @MainActor [weak self, weak process] in
            await sleep(grace)
            guard let self, let process, !process.hasExited, self.processes[sessionID] === process else { return }
            process.terminate()
        }
    }

    private func finished(_ sessionID: String, process: any ResumeProcess, exit: ResumeExit) {
        guard processes[sessionID] === process else { return }
        let stopped = runs[sessionID]?.stopping == true
        processes[sessionID] = nil
        engine?.noteFold(sessionID, .resumeExited(status: exit.status, stopped: stopped))
        if let answer = exit.output.answer { answers[sessionID] = answer }
        let held = !stopped && exit.heldElsewhere
        // Codex refused it as another process writes the thread: its shared background service is asked who (P1488),
        // before the card learns the run ended, so it reads Working until then and never "Failed".
        if held, let daemon = dependencies.daemon, let home = conversations[sessionID]?.profile {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await self.ask(sessionID, home: home, daemon: daemon)
                self.runs[sessionID] = nil
                self.problems[sessionID] = status.holds ? (status.turnRuns ? Self.finishingWords : nil) : exit.problem
                self.engine?.islandRunEnded(sessionID, heldElsewhere: true)
            }
            return
        }
        runs[sessionID] = nil
        if !stopped { problems[sessionID] = exit.problem }
        engine?.islandRunEnded(sessionID, heldElsewhere: held)
    }

    /// The agent's own process still runs: its notes' pid (not one of the island's runs) is alive, or, with no pid
    /// known, a session that has not ended whose process discovery still finds it, or a hook-managed one (it may still
    /// run). A session that ended (SessionEnd) has no agent, whatever its old pid became.
    func agentStillRuns(_ sessionID: String) -> Bool {
        guard let engine else { return false }
        // The agent the fold kept from its tab, by its own process, whatever the state says of its session: ended,
        // dropped by the monitor, or marked gone while it runs (P1420).
        if let pid = engine.folds[sessionID]?.agentPID, !runPIDs.contains(pid), engine.foldAgentRuns(sessionID, pid: pid) {
            return true
        }
        guard let session = engine.state.session(id: sessionID), !session.isSessionEnded else { return false }
        if let pid = engine.hookNotes.contexts[sessionID]?.agentPID {
            guard !runPIDs.contains(pid), engine.dependencies.processExists(pid) else { return false }
            // Codex's shared daemon (or another app-server) runs the thread: it holds it, unless the service itself
            // says nobody does there (P1487).
            if engine.agentIsCodexServer(pid) { return serviceViews[sessionID] != .notHeld }
            return true
        }
        return session.isHookManaged || session.isProcessAlive
    }

    /// The session's agent wherever it runs, but the island's own runs: the cheap look (`agentStillRuns`: the pid its
    /// fold kept, its notes' pid) and then, off the main thread, any of this user's agents whose arguments name its id
    /// (`claude --resume <id>`, opened by hand or by Open in terminal before its hooks spoke). nil when none (P1420).
    func agentRunningAnywhere(_ sessionID: String) async -> Int32? {
        guard let engine else { return nil }
        if agentStillRuns(sessionID) {
            return engine.folds[sessionID]?.agentPID ?? engine.hookNotes.contexts[sessionID]?.agentPID ?? 0
        }
        guard let find = dependencies.findAgents ?? (engine.configuration.startBridge ? AgentProcessScan.live : nil) else { return nil }
        let own = runPIDs
        let found = await Task.detached(priority: .userInitiated) { find(sessionID).filter { !own.contains($0) } }.value
        return found.first
    }

    /// What the session's resume would run; nil when it cannot (the rules of `availability`, but the agent's process).
    func conversation(for sessionID: String) -> Conversation? {
        guard let engine else { return nil }
        guard let session = engine.state.session(id: sessionID) else { return conversations[sessionID] }
        guard let provider = Self.provider(for: session), UUID(uuidString: sessionID) != nil,
              engine.remoteSessions.entry(for: sessionID) == nil,
              let folder = ExactJump.nonEmpty(session.jumpTarget?.workingDirectory) ?? conversations[sessionID]?.folder,
              dependencies.isFolder(folder),
              let profile = engine.accountTags[sessionID]?.folder ?? Self.profile(of: session, provider: provider),
              dependencies.isFolder(profile) else { return nil }
        let known = conversations[sessionID]
        let context = engine.hookNotes.contexts[sessionID]
        // The island's own run names no terminal: the one from before it stays.
        let ownRun = context?.agentPID.map(runPIDs.contains) ?? false
        let bundleID = context?.hostBundleID ?? session.jumpTarget.flatMap { JumpHosts.bundleIdentifier(forTerminalApp: $0.terminalApp) }
        // A session Codex's shared daemon runs names the daemon's terminal, not its own: the owner's usual one (P1486).
        let serverRun = context?.agentPID.map(engine.agentIsCodexServer) ?? false
        let host = ownRun || serverRun ? known?.host : Self.host(bundleID: bundleID) ?? known?.host
        return Conversation(provider: provider, folder: folder, profile: profile, host: host)
    }

    static func provider(for session: AgentSession) -> Provider? {
        switch session.tool {
        case .claudeCode: .claude
        case .codex: session.isCodexAppSession ? nil : .codex
        default: nil
        }
    }

    /// The profile folder from the session's transcript path, when no account tag names it: the folder before the last
    /// `/projects/` (Claude) or `/sessions/` or `/archived_sessions/` (Codex).
    static func profile(of session: AgentSession, provider: Provider) -> String? {
        let path = provider == .claude ? session.claudeMetadata?.transcriptPath : session.codexMetadata?.transcriptPath
        guard let path = ExactJump.nonEmpty(path) else { return nil }
        let markers = provider == .claude ? ["/projects/"] : ["/archived_sessions/", "/sessions/"]
        for marker in markers {
            if let range = path.range(of: marker, options: .backwards), range.lowerBound > path.startIndex {
                return String(path[..<range.lowerBound])
            }
        }
        return nil
    }

    /// Terminal, iTerm or Ghostty; nil for any other host (the owner's usual terminal then).
    static func host(bundleID: String?) -> FreshSessionLaunch.Host? {
        switch bundleID {
        case ExactJump.terminalBundleID: .terminal
        case ExactJump.itermBundleID: .iterm
        case ExactJump.ghosttyBundleID: .ghostty
        default: nil
        }
    }

    static func notStartedWords(_ error: any Error, provider: Provider) -> String {
        switch error as? ResumeStartError {
        case .toolMissing: "Not sent · \(provider == .claude ? "Claude Code" : "Codex") not found"
        default: "Not sent · it could not start"
        }
    }
}
