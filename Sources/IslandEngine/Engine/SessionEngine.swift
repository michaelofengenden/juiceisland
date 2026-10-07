import AppKit
import Foundation
import IslandHookNotes
import JuiceCore
import Observation
import OpenIslandCore

public enum SessionEngineError: Error, Equatable {
    case otherIslandRunning
    /// Another process listens on a socket path the bridge would take over (`BridgeServer` unlinks it first).
    case hookSocketInUse(path: String)
}

/// What the engine needs from its bridge server: `BridgeServer` in the app, a stand-in in tests.
protocol EngineBridge: AnyObject, Sendable {
    func updateStateSnapshot(_ snapshot: SessionState)
    func stop()
}

extension BridgeServer: EngineBridge {}

/// Replaces Open Island's AppModel for everything that is not UI: it owns the session state, the bridge, the
/// discovery and monitoring coordinators and the actions, and adds per-profile account tags, the interrupt flag,
/// the Juice-read filter, the surfaced list, the signal pipeline, session survival and jump outcomes. It never
/// installs hooks, never reads usage and draws nothing.
@MainActor
@Observable
public final class SessionEngine {
    public struct Configuration: Sendable {
        public var socketURL: URL
        public var startBridge: Bool
        /// Restore sessions from disk, discover transcripts and run process monitoring.
        public var loadRuntimeState: Bool
        /// No signal while the session's own terminal tab is frontmost: where the engine's `suppressWhenFrontmost`
        /// starts.
        public var suppressWhenFrontmost: Bool
        /// Sessions whose working directory is inside one of these are Juice's own usage reads and are dropped.
        public var excludedWorkingDirectories: [String]
        /// The second socket, for the superset helper's context notes (spec §3.8); received only while the bridge
        /// runs. nil receives none: only `.live`, the app's own engine, names the real one.
        public var hookNotesSocketURL: URL?
        /// Watch the hook socket's folder, so a socket another app unlinked or took is noticed (`checkBridgeSockets`).
        /// Only `.live` does: tests look by hand.
        public var watchesBridgeSockets: Bool
        /// The request broker's socket (the superset helper's PermissionRequests); received only while the bridge runs.
        /// nil receives none: only `.live` names the real one.
        public var hookRequestsSocketURL: URL?
        /// Where the rows' small labels (model, effort, mode) are kept across a relaunch (P445); nil keeps none. Only
        /// `.live`, the app's own engine, names the real file.
        public var sessionLabels: SessionLabelStore?
        /// Open Island's socket, which hooks installed before Juice's own helper still dial: relayed to the bridge while
        /// they exist and nobody else holds it (`LegacyBridgeRelay`, P911). nil relays nothing; only `.live` names it.
        public var legacyBridgeURL: URL?

        public init(socketURL: URL = BridgeSocketLocation.defaultURL, startBridge: Bool = true,
                    loadRuntimeState: Bool = true,
                    suppressWhenFrontmost: Bool = true,
                    excludedWorkingDirectories: [String] = [SessionEngine.juiceReadDirectory],
                    hookNotesSocketURL: URL? = nil, watchesBridgeSockets: Bool = false, hookRequestsSocketURL: URL? = nil,
                    sessionLabels: SessionLabelStore? = nil, legacyBridgeURL: URL? = nil) {
            self.socketURL = socketURL
            self.startBridge = startBridge
            self.loadRuntimeState = loadRuntimeState
            self.suppressWhenFrontmost = suppressWhenFrontmost
            self.excludedWorkingDirectories = excludedWorkingDirectories
            self.hookNotesSocketURL = hookNotesSocketURL
            self.watchesBridgeSockets = watchesBridgeSockets
            self.hookRequestsSocketURL = hookRequestsSocketURL
            self.sessionLabels = sessionLabels
            self.legacyBridgeURL = legacyBridgeURL
        }

        public static let headless = Configuration(startBridge: false, loadRuntimeState: false)
        /// The app's engine: the bridge, the context notes and the request broker on its own home's sockets (`HookHome`,
        /// P900), watched, and Open Island's socket relayed while older hooks dial it (P911).
        public static var live: Configuration {
            let home = HookHome.current
            return Configuration(socketURL: home.bridgeURL, hookNotesSocketURL: home.notesURL, watchesBridgeSockets: true,
                                 hookRequestsSocketURL: home.requestsURL, sessionLabels: .app,
                                 legacyBridgeURL: BridgeSocketLocation.defaultURL)
        }

        /// Open Island's own socket path; tests name a scratch path in its place.
        var openIslandSocketURL = BridgeSocketLocation.defaultURL

        /// The bridge is on a socket of the app's own, not Open Island's (P900).
        var ownsSocket: Bool { socketURL.standardizedFileURL != openIslandSocketURL.standardizedFileURL }
    }

    struct Dependencies: Sendable {
        /// nil sends through the bridge observer connection.
        var sendCommand: (@Sendable (BridgeCommand) async throws -> Void)?
        var jumpRunner = JumpRunner()
        var isSessionFrontmost: @Sendable (AgentSession) async -> Bool = { session in
            await ForegroundTerminalSessionProbe().matches(session: session)
        }
        /// The frontmost app's bundle id: the Codex app in front is its threads' tab, for their Done only (spec §3.4).
        var frontmostBundleID: @MainActor @Sendable () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        var updateProcessRoots: @Sendable ([ProfileHookTarget]) -> Void = { AgentProfileRoots.update(targets: $0) }
        var isOtherIslandRunning: @Sendable () -> Bool = { SingleIslandGuard.otherIslandIsRunning() }
        /// Whether anything of Juice's still dials Open Island's socket, given the profile folders (`LegacyBridgeUse`,
        /// P911, P932).
        var legacyRelayWanted: @Sendable ([ProfileHookTarget]) -> Bool = { LegacyBridgeUse.wanted(targets: $0) }
        /// nil probes the socket with connect(2) (`HookSocketProbe`): at the start, and a lost path's new file.
        var socketHasOwner: (@Sendable (URL) -> Bool)?
        /// Which file a socket path is (`lstat`), to notice one unlinked or bound again.
        var socketIdentity: @Sendable (URL) -> SocketIdentity? = { SocketIdentity.of($0) }
        /// nil watches the socket's folder with kqueue (`ConfigFolderWatcher`); only with `watchesBridgeSockets`.
        var watchSocketFolder: (@MainActor (String, @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)?)?
        /// nil starts a real `BridgeServer` on the URL.
        var startBridge: (@Sendable (URL) throws -> any EngineBridge)?
        /// nil runs `startRuntime()`: discovery and monitoring, with upstream's Codex.app upkeep.
        var startRuntime: (@MainActor @Sendable (SessionEngine) -> Void)?
        /// nil starts the process monitor's loop once startup discovery is applied.
        var startMonitoring: (@MainActor @Sendable (ProcessMonitoringCoordinator) -> Void)?
        /// nil binds a real `HookNoteListener` on `Configuration.hookNotesSocketURL`.
        var startHookNotes: (@Sendable (URL, @escaping @Sendable (HookContextNote) -> Void) throws -> any HookNoteReceiving)?
        /// An agent's terminal, from its pid (P18).
        var ttyForPID: @Sendable (Int32) -> String? = { ProcessTree.tty(forPID: $0, table: SystemProcessTable()) }
        /// The app an agent's process belongs to, from its pid: its own bundle id or its nearest ancestor's (P660).
        var appForPID: @Sendable (Int32) -> String? = { JumpRunner.owningApp(of: $0) }
        /// Whether the agent at a pid is still at its terminal's controls: running, and its terminal's foreground job
        /// (P139). A reply is offered, and typed, only then.
        var agentAtPrompt: @Sendable (Int32) -> Bool = { ProcessTree.holdsItsTerminal(pid: $0, table: SystemProcessTable()) }
        /// Whether a pid is a Codex app-server (its arguments: `codex … app-server`), the shared daemon among them: never a
        /// tab's agent, whatever terminal its parent holds (P1485).
        var isCodexServer: @Sendable (Int32) -> Bool = CodexServerProcess.live
        /// How a waiting approval's tool call is read: from its transcript, or the preview's fixtures.
        var toolCallReads = ToolCallReads.transcript
        /// Types a reply into a finished session's terminal (`reply`); nil: `ReplySender.live` in the app's own engine,
        /// none in a headless one.
        var sendReply: (@Sendable (ReplyRoute, String) -> Bool)?
        /// Opens a new terminal window for "Open in <account>" (`openFresh`, P703); nil: `FreshSessionLaunch.live` in the
        /// app's own engine, none in a headless one.
        var openFresh: (@Sendable (FreshSessionLaunch) -> Bool)?
        /// Tucks a folded session's window away, or brings it back, through its terminal's own script (`TerminalTuck`,
        /// P1302); nil: `TerminalTuck.live` in the app's own engine, none in a headless one, so no test touches a window.
        var tuckWindow: (@Sendable (TerminalTuck.Move, ReplyRoute) -> TuckOutcome)?
        /// Calls `check` after `delay` seconds: a held reply's look at whether its turn ended (P1306). Tests run them on
        /// their own clock.
        var scheduleFoldCheck: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, check in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                check()
            }
        }
        var now: @Sendable () -> Date = { Date() }
        /// Calls `check` after `delay` seconds; the engine asks for one per held Done. Tests record the checks and
        /// run them on their own clock, or call `flushHeldSignals()` themselves.
        var scheduleSignalCheck: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, check in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                check()
            }
        }
        /// Calls `check` after `delay` seconds: one per open request, its confirmation window (the only scheduled work
        /// of the needs-you book; nothing runs at rest).
        var scheduleAttentionCheck: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, check in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                check()
            }
        }
        /// nil binds a real `HookRequestBroker` on `Configuration.hookRequestsSocketURL`, replying as the engine's
        /// `HookRequestBroker.Holds` says (Answer subagents on the island read on the broker's queue, P350).
        var startHookRequests: (@Sendable (URL, @escaping HookRequestBroker.Holds, @escaping @Sendable (BrokeredRequest) -> Void,
                                           @escaping @Sendable (String) -> Void) throws -> any HookRequestReceiving)?
        /// When the broker ends a subagent's hold by itself, whatever the main thread does (P350): past the engine's
        /// own `SubagentHold.limit`.
        var subagentHoldBackstop: TimeInterval = SubagentHold.limit + SubagentHold.backstopMargin
        /// Whether an agent's pid still runs (C11: a crashed agent sends no SessionEnd).
        var processExists: @Sendable (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }
        /// A process's parent and its short name (`sysctl`): a folded session keeps its agent's, so it can tell a window
        /// that closed (its shell went too) from an agent that quit, and a pid given to another program since from its
        /// agent (P1415, P1420).
        var parentPID: @Sendable (Int32) -> Int32? = { SystemProcessTable().entry(pid: $0)?.parentPID }
        var processName: @Sendable (Int32) -> String? = { SystemProcessTable().entry(pid: $0)?.name }
        /// Calls `exited` once the process at a pid ends (`AgentExitWatch`): a folded session's agent, so its card learns
        /// at once that its window closed mid-turn (P1416). nil: the live watch in the app's own engine, none in a
        /// headless one.
        var watchProcessExit: (@MainActor @Sendable (Int32, @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)?)?
        /// The demo and renders: a request is shown at once, as one that already waited.
        var confirmsRequestsAtOnce = false
        /// A Codex rollout's reviewer, approval policy and strict review, read from its last 256 KB (C6).
        var readCodexSettings: @Sendable (String) -> CodexAttention? = { CodexSettingsReader.read(path: $0) }
        /// Watches a transcript for a call's `tool_result` (C9); nil when the file is not there.
        var watchTranscript: @Sendable (String, String, @escaping @Sendable () -> Void) -> (any TranscriptWatching)? = {
            TranscriptEvidenceWatch.start(path: $0, toolUseID: $1, onFound: $2)
        }
        /// Whether a Claude profile's hook config runs our helper on the `permission_prompt` notification (C19).
        var notificationArming: @Sendable (ProfileHookTarget) -> Bool = { NotificationArming.isArmed($0) }
        /// A Claude session's title lines, from its transcript's last 64 KB (`ClaudeTitleReader`); nil: not read.
        var readClaudeTitle: @Sendable (String) -> ClaudeTitleFold? = { ClaudeTitleReader.read(path: $0)?.fold }
        /// A session peek's read of a Claude transcript's last 128 KB (`SessionPeekReader`, P311); nil reads nothing
        /// (the preview's: no file is opened).
        var readPeek: (@Sendable (String) -> SessionPeekRead?)? = { SessionPeekReader.read(path: $0)?.peek }
        /// Running Codex subagents' rollouts are watched (P212); the preview reads no file.
        var watchesSubagentRollouts = true
        /// The parent a fork's transcript names (`ForkParentReader`, its first 64 KB, P441); the preview reads no file.
        var readForkParent: @Sendable (String) -> String? = { ForkParentReader.read(path: $0) }
        /// The local process list at a remote session's jump (`ps`, P748); the jump finds the ssh tab to its host in it.
        var remoteProcesses: @Sendable () -> String? = { RemoteJump.readProcesses() }
        /// A process's local TCP ports, to tell two ssh tabs to one host apart (P748).
        var localPorts: @Sendable (Int32) -> [Int] = { RemoteJump.localPorts(of: $0) }
        /// Calls `check` after `delay` seconds: when a watched Codex subagent goes quiet past the limit (P218).
        var scheduleSubagentCheck: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, check in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                check()
            }
        }
    }

    /// Where Juice's ClaudeCLIReader runs `claude` (JuiceCore ClaudeCLIReader, `$TMPDIR/juice-cli`).
    public nonisolated static let juiceReadDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("juice-cli", isDirectory: true).path
    static let syntheticClaudeSessionPrefix = "claude-process:"
    static let recentJumpLimit = 20

    public internal(set) var state = SessionState() {
        didSet {
            bridgeServer?.updateStateSnapshot(state)
            retagSessions()
            foldsFollowState()
        }
    }
    public internal(set) var isBridgeReady = false
    /// The hook socket as the engine last found it: live, taken by another app, or off (`checkBridgeSockets`).
    public internal(set) var bridgeHealth: BridgeHealth = .off
    /// When the bridge last took a lost socket back.
    public internal(set) var bridgeTakenBackAt: Date?
    public internal(set) var lastStatusMessage = ""
    public private(set) var profileTargets: [ProfileHookTarget] = []
    public private(set) var accountTags: [String: SessionAccountTag] = [:]
    /// Sessions whose last turn ended with Esc or Ctrl-C (upstream drops the flag in its reducer).
    public internal(set) var interruptedSessionIDs: Set<String> = []
    /// Last hook event per profile (`ProfileHookTarget.id`): proof that profile's hooks reach the island.
    public private(set) var lastHookEventAt: [String: Date] = [:]
    public private(set) var filteredJuiceReadCount = 0
    public private(set) var recentJumps: [JumpOutcome] = []
    /// Sessions that have had a prompt, an approval or a question: the only ones the lists show (P11).
    public internal(set) var promptedSessionIDs: Set<String> = []
    /// Sessions whose turn ended in a StopFailure, by the turn that failed (M5's context note; `hasFailedTurn`).
    public internal(set) var failedTurns: [String: Int] = [:]
    /// The limit or API error a Claude turn failed on, read from its StopFailure when the failure was marked (P700); gone
    /// once the session works again (`limit(for:)`).
    public internal(set) var turnLimits: [String: SessionLimit] = [:]
    /// Why the context-note socket could not start; nil while it runs or was never asked for.
    public internal(set) var hookNotesProblem: String?
    /// The tool calls waiting approvals are about, read from their transcripts, by session (`toolCallInput(for:)`).
    public internal(set) var toolCalls: [String: ToolCallRecord] = [:]
    @ObservationIgnored var toolCallTasks: [String: Task<Void, Never>] = [:]
    /// Sessions whose answer, decision or reply is on its way: a second click sends nothing until it has gone.
    @ObservationIgnored var sendingSessionIDs: Set<String> = []
    @ObservationIgnored var hookNotes = HookNoteBook()
    /// The tool calls each session has started and not finished, from the context notes (P440).
    @ObservationIgnored var toolFlights = ToolFlightBook()
    /// Forks whose SessionStart note came before their bridge event, by session, with the process they started in (P441).
    @ObservationIgnored var pendingForks: [String: Int32] = [:]
    /// Parents a fork of theirs ended (P441): Diagnostics and tests.
    public internal(set) var forkEndedCount = 0
    @ObservationIgnored var hookNoteListener: (any HookNoteReceiving)?
    @ObservationIgnored public var onSignal: ((EngineSignal) -> Void)?
    /// No signal while the session's own tab is frontmost (Settings › General › No alerts for focused sessions). The
    /// app sets it from the setting at start and on every change; it starts as the configuration's.
    @ObservationIgnored public var suppressWhenFrontmost: Bool
    @ObservationIgnored var signals = SignalPipeline()
    /// Due times that already have a check waiting, so a time is never checked twice over.
    @ObservationIgnored var pendingSignalChecks: Set<Date> = []
    @ObservationIgnored var lifecycle = SessionLifecycle()
    /// When each session's current turn and tool began (`activeSince(for:)`); set with the state it describes.
    @ObservationIgnored var activityClocks: [String: ActivityClock] = [:]
    /// The open requests (the needs-you design §3.1): the only source of "!" and "?", observed by the model.
    var attention = AttentionBook()
    /// What the book did, in counts (Diagnostics › Attention; no text).
    public internal(set) var attentionTally = AttentionTally()
    /// Why the request broker's socket could not start; nil while it runs or was never asked for.
    public internal(set) var hookRequestsProblem: String?
    @ObservationIgnored var hookRequestBroker: (any HookRequestReceiving)?
    /// What an answerable request's hook sent, for its answer (the input an Allow echoes, a question's items).
    @ObservationIgnored var attentionPayloads: [String: ClaudeHookPayload] = [:]
    /// Requests whose confirmation window already has its check.
    @ObservationIgnored var attentionWindows: Set<String> = []
    /// Answer subagents on the island (`answersSubagents`), read by the broker on its own queue (P350).
    @ObservationIgnored let subagentHoldSwitch = SubagentHoldSwitch()
    /// Answer Codex in Juice (`answersCodex`), read by the broker on its own queue (P470), and the Codex requests it
    /// held that are not entered yet: true while the helper waits, false once it ended.
    @ObservationIgnored let codexHoldSwitch = SubagentHoldSwitch()
    @ObservationIgnored var pendingCodexHolds: [String: Bool] = [:]
    /// The request whose card the island shows now (`islandShows(requestID:)`), and the held subagents' requests it has
    /// shown (P350).
    @ObservationIgnored var islandShownRequest: String?
    @ObservationIgnored var subagentHoldsSeen: Set<String> = []
    /// The requests whose cards the window shows now (`windowShows(requestIDs:)`, P1050).
    @ObservationIgnored var windowShownRequests: Set<String> = []
    /// Prompts Claude built as a subagent's hold ended, by request id, until their notice comes or can no longer come
    /// (P352).
    @ObservationIgnored var releasedHoldPrompts: [String: ReleasedHoldPrompt] = [:]
    /// The bridge's echo of an island answer to a request it held, by session (C12, P169).
    @ObservationIgnored var islandAnswers: [String: IslandAnswer] = [:]
    /// The note version each session's helper speaks (P163).
    @ObservationIgnored var noteVersions: [String: Int] = [:]
    /// The phase upstream's own events last left each session in, under any head the book applies: what it goes back
    /// to when the book has nothing left to show (P182).
    @ObservationIgnored var restingPhases: [String: SessionPhase] = [:]
    /// Claude profiles whose hook config runs our helper on `permission_prompt` (C19), by target id.
    @ObservationIgnored var armedProfiles: [String: Bool] = [:]
    /// Each watched Codex thread's attention state, as the rollout last said (C6, C7).
    @ObservationIgnored var codexAttention: [String: CodexAttention] = [:]
    /// Transcript watches for open Claude requests, by request id (C9).
    @ObservationIgnored var transcriptWatches: [String: any TranscriptWatching] = [:]
    /// Codex subagents' own rollouts, watched while one of their requests is open (C5); keyed by request id.
    @ObservationIgnored var childRollouts: CodexRolloutTracker?
    /// The Codex threads that are never rows, and each chat's subagents (P212).
    var codexThreads = CodexThreadBook()
    /// Running Codex subagents' rollouts, watched for their turn ends and questions (P212); keyed by thread id.
    @ObservationIgnored var subagentRollouts: CodexRolloutTracker?
    /// When the checks asked for a watched subagent's lapse fall due (P218).
    @ObservationIgnored var pendingSubagentChecks: Set<Date> = []
    /// Codex chats whose turn is a review (P217): "Reviewing" until the turn ends, whatever the review does meanwhile.
    var reviewingSessionIDs: Set<String> = []
    /// Each Claude session's subagents as the context notes tell of them (P370), read through `waitingSubagents(for:)`.
    @ObservationIgnored var claudeSubagents = ClaudeSubagentBook()
    /// How many of each Claude session's subagents run now: written only when a count changes, so the lists observe it
    /// and not every note a subagent's tools send.
    var claudeSubagentCounts: [String: Int] = [:]
    /// What each Claude session's main agent waits on once its turn has ended (P370, P510): by Claude's own word when
    /// its helper counts `background_tasks` by kind, else the book's agents. Written only when one changes.
    var claudeWaits: [String: SubagentWait] = [:]
    /// When the checks asked for a Claude subagent's lapse fall due.
    @ObservationIgnored var pendingClaudeSubagentChecks: Set<Date> = []
    /// Codex chats a subagent's result is to wake, from when that subagent's turn ended while the chat's had (P513).
    @ObservationIgnored var codexWakes: [String: Date] = [:]
    /// Island decisions by call id (true: denied), to count answers the agent did not follow (C18).
    @ObservationIgnored var islandDecisions: [String: Bool] = [:]
    /// The agents' own chat titles, by session (`chatTitle(for:)`): memory only (P200).
    public internal(set) var agentTitles: [String: String] = [:]
    /// Each Claude session's title lines as read so far, which a later window's lines update (P202).
    @ObservationIgnored var claudeTitleFolds: [String: ClaudeTitleFold] = [:]
    /// Each session's first prompt that can title it, as first seen (`ChatTitleText.firstPrompt`).
    @ObservationIgnored var firstPrompts: [String: String] = [:]
    /// The model a peek's read of a Claude transcript named last, by session (`facts(for:)`), until the session's next
    /// start: memory only (P310).
    var peekModels: [String: String] = [:]
    /// The reasoning effort a peek's read of a Claude transcript named last, by session, as `peekModels`: memory only
    /// (P443; the labels, P445, keep their own copy).
    var peekEfforts: [String: String] = [:]
    /// What each watched Codex chat is at (`SessionWork`): its reasoning summary and its plan's steps, for the peek only
    /// (P720). Observed, so a peek that shows it follows it; no row reads it, so a thought moves no row. Memory only.
    var codexWork: [String: SessionWork] = [:]
    /// Sessions the owner archived (Archive, or Archive idle sessions after), by the time of their last event then:
    /// never rows until they do something again (`dismiss`, P729). Memory only.
    var archived: [String: Date] = [:]
    /// The model, effort and mode each session last reported, kept across a relaunch (P445); read once at the start.
    @ObservationIgnored var labelBook = SessionLabelBook(now: .distantPast)
    /// Each session's agent as its hooks' notes named it, where that is not its tool's (P913).
    var agentLabels: [String: AgentKind] = [:]
    @ObservationIgnored var labelsLoaded = false
    /// Claude title reads: the one in flight per session, whether another was asked for meanwhile, and when the last
    /// began.
    @ObservationIgnored var titleReads: [String: TitleRead] = [:]
    /// Who started each session, where a context note or a rollout said it was not the owner (`scope(of:)`, P250).
    /// Observed: a session found to be a scripted run leaves the lists at once.
    var scopes: [String: SessionScope] = [:]
    /// What each Codex thread's hooks showed of the process that runs it (P257); read only to weigh `scopes`.
    @ObservationIgnored var codexHands: [String: CodexHand] = [:]
    /// Sessions the owner went on with from a folded card through the agent's own resume (`SessionResumer`, P1327,
    /// P1328), and those whose run is under way: read on the request broker's queue too. Memory only.
    @ObservationIgnored let islandResumes = IslandResumeBook()
    /// Settings › Island › Show scripted runs: the lists show scripted runs too. They never notify either way.
    public var showsScriptedRuns = false
    /// Settings › General › Permission modes on cards: a Claude plan or approval offers its mode buttons
    /// (`modeChoices(for:)`). Off: none shows and none is sent.
    public var offersModeChoices = true
    /// Route (b) of a folded session whose tab is gone: the agent's own resume (`SessionResumer`, which the app's
    /// `LiveSessions` sets as it makes the engine). nil (every headless engine): a card whose tab is gone says "Open in
    /// terminal to reply".
    @ObservationIgnored public var conversationResume: (any ConversationResuming)?
    /// Claude Code's own background sessions (`ClaudeBackgrounder`, wave 8, P1450 on), which the app's `LiveSessions`
    /// sets as it makes the engine. nil (every headless engine): Send to island types nothing and no card is a
    /// background one.
    @ObservationIgnored public var claudeBackground: ClaudeBackgrounder?
    /// Settings › Agents › Keep Claude sessions running when their window closes: Send to island moves a Claude Code
    /// session into Claude Code's background (P1450). Off in a headless engine unless a test sets it.
    public var keepsClaudeRunning = false
    /// Interactive sessions whose conversation went on in the background under another id, to that id (P1455): their
    /// rows stay out of the island's list, as the card of the new id stands for them.
    public internal(set) var movedConversations: [String: String] = [:]
    @ObservationIgnored var backgroundReadScheduled = false
    /// Folded sessions whose `/background`, waiting for their turn's end, has a check waiting (P1452).
    @ObservationIgnored var backgroundMoveChecks: Set<String> = []
    /// The background move each fold started, so a test can wait for it.
    @ObservationIgnored var backgroundMoves: [String: Task<Void, Never>] = [:]
    /// Whether each pid the notes named is a Codex app-server, and when that was asked (P1485).
    @ObservationIgnored var codexServerAnswers: [Int32: (server: Bool, at: Date)] = [:]
    /// Open in Claude, Codex or another agent's app, and back (`SessionHandoff`, wave 8, P1510), which the app's
    /// `LiveSessions` sets as it makes the engine. nil (every headless engine but a test's): nothing is offered.
    @ObservationIgnored public var appHandoff: SessionHandoff?
    /// Sessions sent to the island, by id (`SessionEngine+Fold`, P1300 to P1324). Observed: their cards follow it.
    public internal(set) var folds: [String: FoldedSession] = [:]
    /// Folded sessions whose held reply has a check waiting (P1306).
    @ObservationIgnored var foldChecks: Set<String> = []
    /// Folded sessions whose agent was found gone mid-turn, with the verdict's check waiting (P1415).
    @ObservationIgnored var foldStopChecks: Set<String> = []
    /// Each folded session's watch on its agent's exit, and the pid it watches (P1416).
    @ObservationIgnored var foldExitWatches: [String: (pid: Int32, token: any HookWatchToken)] = [:]
    /// The fold's last decisions, newest last, for Diagnostics' Copy Report (P1430): ids and states only.
    @ObservationIgnored public internal(set) var foldNotes: [FoldNote] = []

    @ObservationIgnored let configuration: Configuration
    @ObservationIgnored let dependencies: Dependencies
    /// Which SSH host each remote session came from, written by the tunnels' relays (P745).
    @ObservationIgnored public let remoteSessions = RemoteSessionDirectory()
    /// After a remote session's jump: the app's tunnels select its tmux pane on the remote (best effort, P748).
    @ObservationIgnored public var onRemoteJump: (@MainActor (String, RemoteContext) -> Void)?
    /// Juice's own reads, by the time each last sent an event: every later event of theirs is dropped too (a read's
    /// Stop has no working directory to tell it by). Kept for `ignoredLifetime` after the last one.
    @ObservationIgnored var ignoredSessionIDs: [String: Date] = [:]
    /// When the per-session bookkeeping was last looked over, and the ids it held then for sessions gone from the state
    /// (`pruneBookkeepingIfDue`).
    @ObservationIgnored var lastUpkeepAt: Date?
    @ObservationIgnored var goneAtLastUpkeep: Set<String> = []
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var bridgeServer: (any EngineBridge)?
    @ObservationIgnored var bridgeClient: LocalBridgeClient
    @ObservationIgnored var observerTask: Task<Void, Never>?
    /// Events taken from the bridge's observer connection so far (the end-to-end tests wait on it).
    @ObservationIgnored var bridgeEventsTaken = 0
    @ObservationIgnored var reconnectTask: Task<Void, Never>?
    @ObservationIgnored var reconnectDelay: Duration = .seconds(2)
    @ObservationIgnored var discovery: SessionDiscoveryCoordinator?
    @ObservationIgnored var monitoring: ProcessMonitoringCoordinator?
    /// Each hook socket path's file right after the bridge bound it (nil: nothing there).
    @ObservationIgnored var boundSockets: [String: SocketIdentity?] = [:]
    @ObservationIgnored var socketWatch: (any HookWatchToken)?
    @ObservationIgnored var socketCheck: Task<Void, Never>?
    @ObservationIgnored var socketFolderSettle: Task<Void, Never>?
    @ObservationIgnored var socketRetryTask: Task<Void, Never>?
    @ObservationIgnored var legacySocketLossNoted = false
    /// Open Island's socket, relayed to the bridge while older hooks dial it (P911).
    @ObservationIgnored var legacyRelay: LegacyBridgeRelay?
    @ObservationIgnored var legacyRelayCheck: Task<Void, Never>?

    public convenience init(configuration: Configuration = .live) {
        self.init(configuration: configuration, dependencies: Dependencies())
    }

    init(configuration: Configuration, dependencies: Dependencies) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.bridgeClient = LocalBridgeClient(socketURL: configuration.socketURL)
        suppressWhenFrontmost = configuration.suppressWhenFrontmost
    }

    // MARK: Profiles

    /// Called at launch, before `start()`, and whenever accounts or discovered profiles change. Startup discovery
    /// scans the profiles known when `start()` runs. A profile added later is matched at once by process discovery
    /// and by its hooks; its older transcripts are found at the next launch.
    public func setProfiles(accounts: [Account], discovered: [DiscoveredProfile]) {
        profileTargets = ProfileHookTargets.make(accounts: accounts, discovered: discovered)
        dependencies.updateProcessRoots(profileTargets)
        accountTags = [:]
        retagSessions()
        refreshAttentionArming()
    }

    public func accountTag(for sessionID: String) -> SessionAccountTag? { accountTags[sessionID] }

    func retagSessions() {
        guard !profileTargets.isEmpty else { return }
        for session in state.sessions where accountTags[session.id] == nil {
            if let tag = AccountResolver.tag(transcriptPath: session.trackingTranscriptPath, tool: session.tool,
                                             targets: profileTargets) {
                accountTags[session.id] = tag
            }
        }
    }

    // MARK: Lists

    /// Every list reads this one list (P14): tracked sessions that have had a prompt, an approval or a question, or
    /// were restored or discovered with a recorded prompt. A session that only started (and perhaps ended) is
    /// tracked but never shown (P11).
    public var surfacedSessions: [AgentSession] { state.sessions.filter(isSurfaced) }

    /// Rows in display order: upstream's ranking over the surfaced list, hidden and subagent sessions left out.
    public var rows: [AgentSession] { buckets.primary }
    /// Surfaced sessions that are not shown as rows (ended, hidden or duplicates of a live terminal).
    public var overflow: [AgentSession] { buckets.overflow }
    public var needsYouCount: Int { rows.filter(needsAttention).count }
    /// Running rows, and rows whose main agent waits on its subagents (P370).
    public var runningCount: Int { rows.filter { $0.phase == .running || waitingSubagents(for: $0) > 0 }.count }
    /// What "jump to what needs you" targets: the first row that needs an answer or an approval, or whose turn failed.
    public var nextNeedsYou: AgentSession? { rows.first(where: needsAttention) }

    /// A scripted run is left out unless Show scripted runs is on, or it waits on the owner: a request surfaces from
    /// any session (P251).
    func isSurfaced(_ session: AgentSession) -> Bool {
        let waits = attention.head(of: session.id) != nil
        if !waits, !showsScriptedRuns, scope(of: session) == .scripted { return false }
        return promptedSessionIDs.contains(session.id) || waits || Self.recordedPrompt(of: session) != nil
    }

    /// A bridge prompt's text is the owner's (P155); a rollout's new turn carries no text here and counts.
    static func promptIsHuman(_ event: AgentEvent) -> Bool {
        guard case let .activityUpdated(payload) = event, payload.summary.hasPrefix(SignalPipeline.promptPrefix) else { return true }
        return PromptText.human(String(payload.summary.dropFirst(SignalPipeline.promptPrefix.count))) != nil
    }

    static func recordedPrompt(of session: AgentSession) -> String? {
        let prompts = [session.claudeMetadata?.lastUserPrompt, session.claudeMetadata?.initialUserPrompt,
                       session.codexMetadata?.lastUserPrompt, session.codexMetadata?.initialUserPrompt,
                       session.geminiMetadata?.lastUserPrompt, session.openCodeMetadata?.lastUserPrompt,
                       session.cursorMetadata?.lastUserPrompt, session.piMetadata?.lastUserPrompt]
        return prompts.lazy.compactMap { PromptText.human($0) }.first
    }

    public func statusWord(for session: AgentSession) -> StatusWord {
        if hasFailedTurn(session) { return .failed }
        // A Claude session whose main turn ended while its background agents or workflows run waits on them (P370,
        // P510), as a Codex chat whose turn ended while its subagents run does (P513), and one whose main agent is
        // blocked on its Agent calls (P377).
        if let wait = waitingOn(session) { return .subagents(wait.agents, workflows: wait.workflows) }
        let blocked = blockedOnSubagents(for: session)
        if blocked > 0 { return .subagents(blocked) }
        let word = StatusWord.of(session, interrupted: interruptedSessionIDs.contains(session.id))
        // A Codex chat whose review runs says so (P217), one whose main agent waits on its running subagents says how
        // many (P212); its own tool (other than a wait on them), compaction or denial is its own work (P378), and a
        // request of its own still says itself.
        guard session.tool == .codex, session.phase == .running else { return word }
        switch word {
        case .needsApproval, .question: return word
        default:
            if reviewingSessionIDs.contains(session.id) { return .reviewing }
            switch word {
            case .compacting, .denied: return word
            case let .tool(name, _) where !Self.codexWaitTools.contains(name): return word
            default:
                let running = runningSubagents(for: session.id)
                return running > 0 ? .subagents(running) : word
            }
        }
    }

    /// A Codex main agent's calls that wait on its subagents (collab's `wait`, `wait_agent`).
    static let codexWaitTools: Set<String> = ["wait", "wait_agent"]

    /// When a running session's current tool started (while its status is a tool), else when its current turn
    /// started: "Running tool · 93m" for a long run, however recently the tool last reported. nil when the session
    /// is not running or the engine has not seen its turn begin (restored sessions); callers fall back to `updatedAt`.
    public func activeSince(for session: AgentSession) -> Date? {
        guard session.phase == .running, let clock = activityClocks[session.id] else { return nil }
        if case .tool = statusWord(for: session) { return clock.toolStartedAt ?? clock.turnStartedAt }
        return clock.turnStartedAt
    }

    /// When a compacting session's compaction began (its PreCompact), for the row's "Compacting 0:42" (P433); nil when it
    /// is not compacting or the engine has not seen the compaction begin (a session restored mid-compaction).
    public func compactingSince(for session: AgentSession) -> Date? {
        guard statusWord(for: session) == .compacting else { return nil }
        return activityClocks[session.id]?.compactingSince
    }

    /// The modes a request's card offers to switch to with its Allow (`ApprovalChoices.modes`): only on a Claude request
    /// on the main thread that the island answers, never on a subagent's held for the island, and none while Permission
    /// modes on cards is off. `approve` sends a mode only when this still offers it (P450, P453).
    public func modeChoices(for request: AttentionRequest) -> [ClaudePermissionMode] {
        guard offersModeChoices, request.isAnswerable, !request.isHeldForIsland else { return [] }
        return ApprovalChoices.modes(for: request, bypassAvailable: hookNotes.contexts[request.sessionID]?.bypassSeen == true)
    }

    public func alwaysAllowLabel(for sessionID: String) -> String? {
        ApprovalChoices.alwaysAllowLabel(for: state.session(id: sessionID)?.permissionRequest)
    }

    private var buckets: (primary: [AgentSession], overflow: [AgentSession]) {
        let monitoring = self.monitoring
        let archived = self.archived
        return SessionRanking.buckets(sessions: surfacedSessions, now: dependencies.now(), needsAttention: needsAttention,
                                      runs: { self.waitingSubagents(for: $0) > 0 },
                                      archived: { archived[$0.id] != nil && !self.needsAttention($0) }) { session in
            monitoring?.liveAttachmentKey(for: session)
        }
    }

    // MARK: Events

    /// The one funnel for every event: bridge (hooks, Codex.app) and rollout (transcript watchers).
    func ingest(_ incoming: AgentEvent, ingress: TrackedEventIngress) {
        var event = incoming
        guard let sessionID = Self.sessionID(of: event) else { return }
        if ignoredSessionIDs[sessionID] != nil {
            ignoredSessionIDs[sessionID] = dependencies.now()
            return
        }
        // Codex's reviewer, its helpers and a chat's subagents are never rows (P212).
        if codexThreads.isHidden(sessionID) {
            let now = dependencies.now()
            updateCodexThreads { $0.hide(sessionID, at: now) }
            return
        }
        if case let .sessionStarted(payload) = event, isJuiceRead(payload.jumpTarget?.workingDirectory) {
            ignoredSessionIDs[sessionID] = dependencies.now()
            filteredJuiceReadCount += 1
            return
        }
        if case .sessionHeartbeat = event {
            state.apply(event)
            return
        }

        let now = dependencies.now()
        for expired in lifecycle.expire(now: now) {
            signals.forget(expired)
            forgetHookNotes(expired)
            forgetToolCall(expired)
            forgetAttention(expired)
        }
        pruneBookkeepingIfDue(now: now)
        let before = state.session(id: sessionID)
        // The bridge's echo of an island answer is never a finished turn (C12, P169); first, as a No's echo reads like
        // a PermissionDenied.
        event = normalizedIslandAnswer(event, sessionID: sessionID, ingress: ingress, current: before, now: now)
        // A PermissionDenied arrives as the same completion as Stop; it is activity (P2).
        event = SignalPipeline.normalized(event, ingress: ingress, current: before)
        // A rollout's waiting phase is never a request: "!" and "?" come from the book alone (P161).
        event = Self.withoutRolloutWait(event, ingress: ingress)
        // Machine text is never kept as the owner's prompt (P155).
        event = PromptText.sanitized(event, current: before)
        // A subagent's start is never its finished parent's own activity (P371).
        if isSubagentLifecycleEcho(event, sessionID: sessionID, ingress: ingress, current: before, now: now) {
            if let tag = accountTags[sessionID] { lastHookEventAt[tag.targetID] = now }
            return
        }
        let gate = lifecycle.gate(event, sessionID: sessionID, ingress: ingress, current: before, now: now)
        if case .drop = gate { return }
        // A request event read from a rollout (Codex never writes one: `rollout/src/policy.rs`) is nothing (P161).
        if ingress != .bridge, Self.isRequest(event) { return }
        // A request from the bridge is the book's, never applied to the state directly (invariant 3).
        if ingress == .bridge, Self.isRequest(event) {
            lifecycle.noteApplied(event, sessionID: sessionID, ingress: ingress, before: before, now: now)
            signals.noteLive(sessionID)
            monitoring?.markSessionAttached(for: event)
            monitoring?.markSessionProcessAlive(for: event)
            if let tag = accountTags[sessionID] { lastHookEventAt[tag.targetID] = now }
            if archived[sessionID] != nil { archived[sessionID] = nil }
            takeBridgeRequest(event, now: now)
            schedulePersistence()
            return
        }
        switch gate {
        case .drop:
            return
        case .apply:
            state.apply(event)
        case let .merge(session):
            replace(session)
        case let .revive(prefix):
            for start in prefix { state.apply(start) }
            if var session = state.session(id: sessionID), session.isSessionEnded {
                session.isSessionEnded = false
                replace(session)
            }
            state.apply(event)
        }
        lifecycle.noteApplied(event, sessionID: sessionID, ingress: ingress, before: before, now: now)
        markRemoteIfKnown(sessionID)
        noteArchivedActivity(sessionID)
        if let phase = state.session(id: sessionID)?.phase, !phase.requiresAttention { restingPhases[sessionID] = phase }
        // What the event says about the session's requests, then their head over upstream's own clears (C14).
        attentionEvidence(for: event, sessionID: sessionID, ingress: ingress, tool: state.session(id: sessionID)?.tool ?? before?.tool)
        syncAttentionHead(sessionID)
        activityClocks[sessionID] = ActivityClock.next(activityClocks[sessionID], event: event, ingress: ingress,
                                                       before: before, after: state.session(id: sessionID))

        switch event {
        case let .sessionCompleted(payload):
            if payload.isInterrupt == true { interruptedSessionIDs.insert(sessionID) } else { interruptedSessionIDs.remove(sessionID) }
            if reviewingSessionIDs.contains(sessionID) { reviewingSessionIDs.remove(sessionID) }
        case let .activityUpdated(payload):
            interruptedSessionIDs.remove(sessionID)
            // A review's start (`RolloutFolder.applyReviewStart`) is its chat's turn until that turn ends; a prompt of
            // the owner's starts another (P217). Written only when it changes: the lists observe it.
            if payload.summary == StatusWord.reviewingSummary, payload.phase == .running {
                if !reviewingSessionIDs.contains(sessionID) { reviewingSessionIDs.insert(sessionID) }
            } else if reviewingSessionIDs.contains(sessionID), SignalPipeline.isNewPrompt(event, ingress: ingress, before: before) {
                reviewingSessionIDs.remove(sessionID)
            }
        case .sessionStarted:
            interruptedSessionIDs.remove(sessionID)
            if ingress == .bridge { noteForkSessionStarted(sessionID) }
            // A start (a resume, a new model) names its own model again.
            if peekModels[sessionID] != nil { peekModels[sessionID] = nil }
            if peekEfforts[sessionID] != nil { peekEfforts[sessionID] = nil }
        default:
            break
        }
        // A turn machine text started (a background task's notification) counts as a turn, but does not surface a
        // session that never had a prompt of the owner's (P155).
        if SignalPipeline.isNewPrompt(event, ingress: ingress, before: before), Self.promptIsHuman(event) {
            promptedSessionIDs.insert(sessionID)
        }
        forgetToolCallIfResolved(sessionID)
        keepLabels(sessionID)
        noteClaudeSubagents(event, sessionID: sessionID, ingress: ingress, before: before, now: now)

        if ingress == .bridge {
            monitoring?.markSessionAttached(for: event)
            monitoring?.markSessionProcessAlive(for: event)
            if let tag = accountTags[sessionID] { lastHookEventAt[tag.targetID] = now }
        }
        discovery?.refreshCodexRolloutTracking()
        schedulePersistence()

        let heldBefore = signals.dueAt(for: sessionID)
        let ready = signals.process(event, sessionID: sessionID, ingress: ingress, before: before,
                                    after: state.session(id: sessionID), now: now,
                                    resolvingInitialSessions: monitoring?.isResolvingInitialLiveSessions ?? false)
        for alert in ready { deliver(alert) }
        // A main turn that ends while its subagents run is no Done (P372): that turn's Done is never held. A Codex chat's
        // is held its 1.5 s all the same: its subagents' ends are read from their rollouts, which a Stop hook outruns, so
        // a `wait` that returned with the last result looks like a wait for a moment; `deliver` drops the Done if the
        // chat still waits when the hold passes (P514).
        if let after = state.session(id: sessionID), after.tool != .codex, waitingSubagents(for: after) > 0 {
            signals.dropHeld(sessionID)
        }
        noteAppliedForHookNotes(event, sessionID: sessionID, ingress: ingress, before: before, now: now)
        if folds[sessionID] != nil { noteFoldTurn(event, sessionID: sessionID, ingress: ingress, before: before) }
        // A session Codex's background service runs: whether it holds the thread, as it starts and as a turn begins or
        // ends there (P1487).
        if ingress == .bridge, Self.asksCodexService(event, ingress: ingress, before: before) { lookAtCodexService(sessionID) }
        noteForTitle(event, sessionID: sessionID, ingress: ingress, before: before, now: now)
        // Every new hold gets its own check, whether or not another session's Done is held earlier.
        if let dueAt = signals.dueAt(for: sessionID), dueAt != heldBefore { scheduleSignalCheck(at: dueAt, now: now) }
    }

    /// An archived session that did something again is a row again: an event the gate let through that moved its last
    /// event's time past the one it was archived at. A read of an old line again (a rollout's bootstrap) does not
    /// (P729).
    func noteArchivedActivity(_ sessionID: String) {
        guard let stamp = archived[sessionID] else { return }
        guard let session = state.session(id: sessionID) else { return archived[sessionID] = nil }
        if session.updatedAt > stamp { archived[sessionID] = nil }
    }

    /// An approval or a question, as upstream's bridge or reducer sends it.
    static func isRequest(_ event: AgentEvent) -> Bool {
        switch event {
        case .permissionRequested, .questionAsked: true
        default: false
        }
    }

    /// A rollout activity in a waiting phase (upstream's reducer reads `exec_approval_request`,
    /// `request_user_input` and the like, which Codex never writes) is running activity: no phase alone draws "!" or
    /// "?" (P161).
    static func withoutRolloutWait(_ event: AgentEvent, ingress: TrackedEventIngress) -> AgentEvent {
        guard ingress == .rollout else { return event }
        switch event {
        case var .activityUpdated(payload) where payload.phase.requiresAttention:
            payload.phase = .running
            return .activityUpdated(payload)
        default:
            return event
        }
    }

    /// Delivers the held Done signals whose 1.5 s hold has passed and whose session still shows the finished turn,
    /// then makes sure the next hold still waiting has a check of its own.
    func flushHeldSignals() {
        let now = dependencies.now()
        let current = state
        for alert in signals.due(now: now, session: { current.session(id: $0) }) { deliver(alert) }
        if let next = signals.nextDueAt { scheduleSignalCheck(at: next, now: now) }
    }

    private func scheduleSignalCheck(at dueAt: Date, now: Date) {
        guard pendingSignalChecks.insert(dueAt).inserted else { return }
        dependencies.scheduleSignalCheck(max(0, dueAt.timeIntervalSince(now))) { [weak self] in
            self?.pendingSignalChecks.remove(dueAt)
            self?.flushHeldSignals()
        }
    }

    /// Every state the process monitor writes comes through here, so a pass cannot end a session that waits on
    /// you or had a hook in the last 10 minutes, and ending takes 3 missed polls (P7).
    func applyMonitoredState(_ newState: SessionState) {
        let prefix = Self.syntheticClaudeSessionPrefix
        let now = dependencies.now()
        state = lifecycle.review(old: state, new: newState, now: now, waitsOnYou: needsAttention) { session in
            (session.tool == .claudeCode || session.tool == .codex) && !session.isCodexAppSession && !session.id.hasPrefix(prefix)
                // Amp's threads and Kilo's sessions too: the monitor finds only `opencode` processes, never `amp` or
                // `kilo`, so OpenCode's rule would end one a minute or two after its last event and drop what came next
                // (P1168, P1175).
                || (session.tool == .openCode && AgentKind.fromSessionID(session.id).map { $0 == .amp || $0 == .kilo } == true)
        }
        // A session the pass ended or dropped waits on nothing; an agent that crashed sends no SessionEnd (C11).
        for sessionID in attention.sessionIDs where state.session(id: sessionID).map(\.isSessionEnded) ?? true {
            forgetAttention(sessionID)
        }
        closeRequestsOfGoneAgents()
        endWaitsOfGoneAgents()
        for sessionID in attention.sessionIDs { syncAttentionHead(sessionID) }
        pruneBookkeepingIfDue(now: now)
    }

    // MARK: Upkeep

    /// How often the per-session bookkeeping is looked over (on an event or a process-monitor pass, never on a timer of
    /// its own), and so how long an id must have been gone from the state, at two looks in a row, before it is
    /// forgotten.
    static let upkeepInterval: TimeInterval = 600
    /// How long a Juice read's id stays ignored after its last event.
    static let ignoredLifetime: TimeInterval = 3_600

    /// P114: what the engine keeps per session (the prompted list, account tags, interrupt flags, activity clocks,
    /// failed turns, the signal pipeline's turns and keys, the lifecycle's hook times, reprieves and completions, the
    /// context notes, the tool call read for an approval) went only with an expired tombstone, so every session
    /// upstream's monitor dropped without a SessionEnd (a Codex app thread, a process that vanished, another tool's)
    /// stayed for the app's life. An id gone from the state at two looks in a row, `upkeepInterval` apart, and not
    /// closed by a tombstone is forgotten everywhere.
    func pruneBookkeepingIfDue(now: Date) {
        if let lastUpkeepAt, now.timeIntervalSince(lastUpkeepAt) < Self.upkeepInterval, now >= lastUpkeepAt { return }
        lastUpkeepAt = now
        for expired in lifecycle.expire(now: now) {
            signals.forget(expired)
            forgetHookNotes(expired)
            forgetToolCall(expired)
            forgetAttention(expired)
        }
        ignoredSessionIDs = ignoredSessionIDs.filter { now.timeIntervalSince($0.value) < Self.ignoredLifetime }
        updateCodexThreads { $0.prune(now: now) }
        syncSubagentRollouts()
        syncClaudeSubagents(now: now)
        let gone = bookkeptSessionIDs.subtracting(state.sessions.map(\.id)).subtracting(lifecycle.closedIDs)
        for id in gone.intersection(goneAtLastUpkeep) { forgetSession(id) }
        goneAtLastUpkeep = gone.subtracting(goneAtLastUpkeep)
    }

    /// Every session id the engine keeps anything for.
    var bookkeptSessionIDs: Set<String> {
        promptedSessionIDs.union(accountTags.keys).union(interruptedSessionIDs).union(reviewingSessionIDs).union(activityClocks.keys)
            .union(failedTurns.keys).union(turnLimits.keys)
            .union(signals.sessionIDs).union(lifecycle.sessionIDs).union(hookNotes.sessionIDs).union(toolFlights.sessionIDs)
            .union(toolCalls.keys).union(toolCallTasks.keys)
            .union(attention.sessionIDs).union(noteVersions.keys).union(codexAttention.keys).union(islandAnswers.keys)
            .union(restingPhases.keys).union(agentTitles.keys).union(claudeTitleFolds.keys).union(firstPrompts.keys)
            .union(titleReads.keys).union(scopes.keys).union(codexHands.keys).union(peekModels.keys)
            .union(peekEfforts.keys).union(codexWork.keys).union(archived.keys)
            .union(claudeSubagents.sessionIDs).union(claudeSubagentCounts.keys).union(claudeWaits.keys).union(codexWakes.keys)
    }

    /// Forgets a session everywhere but in the state.
    func forgetSession(_ id: String) {
        promptedSessionIDs.remove(id)
        accountTags[id] = nil
        interruptedSessionIDs.remove(id)
        if reviewingSessionIDs.contains(id) { reviewingSessionIDs.remove(id) }
        activityClocks[id] = nil
        signals.forget(id)
        lifecycle.forget(id)
        forgetHookNotes(id)
        forgetToolCall(id)
        forgetAttention(id)
        forgetTitle(id)
        if scopes[id] != nil { scopes[id] = nil }
        codexHands[id] = nil
        if peekModels[id] != nil { peekModels[id] = nil }
        if peekEfforts[id] != nil { peekEfforts[id] = nil }
        if archived[id] != nil { archived[id] = nil }
        pendingForks[id] = nil
        forgetClaudeSubagents(id)
        codexWakes[id] = nil
    }

    func replace(_ session: AgentSession) {
        state = SessionState(sessions: state.sessions.filter { $0.id != session.id } + [session])
    }

    func isJuiceRead(_ workingDirectory: String?) -> Bool {
        guard let workingDirectory else { return false }
        let path = ProfileHookTargets.normalized(workingDirectory)
        return configuration.excludedWorkingDirectories.contains { excluded in
            let root = ProfileHookTargets.normalized(excluded)
            return path == root || path.hasPrefix(root + "/")
        }
    }

    func schedulePersistence() {
        guard let discovery else { return }
        discovery.scheduleCodexSessionPersistence()
        discovery.scheduleClaudeSessionPersistence()
        discovery.scheduleOpenCodeSessionPersistence()
        discovery.scheduleCursorSessionPersistence()
        discovery.schedulePiSessionPersistence()
    }

    /// Sends a signal unless its session's own tab is frontmost (when that setting is on). After that check, which
    /// waits, the alert goes out only if the session still shows its key: the same request, or turn (P5).
    ///
    /// A Codex question, and a Codex approval the old helper holds, always go out: Codex shows nothing of its own for
    /// them (the TUI counts a collapsed async question down, and a held approval waits on the island alone; C4, C15).
    /// So does an approval Copilot CLI, Devin or Qwen Code waits on through the bridge (`waitsOnIslandAlone`, P931).
    /// A Codex app thread has no tab: the Codex app in front is its tab for its Done and for an approval the broker
    /// handed back to Codex, which shows its own prompt.
    ///
    /// Only the owner's own sessions tell of a finished or failed turn: a subagent's thread and a scripted run never
    /// do, whatever they are known as by the time the hold passes (P250, P252). A request that waits goes out from any.
    func deliver(_ alert: SignalPipeline.Alert) {
        if alert.kind != .needsYou, !notifiesOfTurnEnd(alert.sessionID) { return }
        // Only the main agent's own turn end notifies: never one that left it waiting on its subagents (P372).
        if alert.kind == .done, let session = state.session(id: alert.sessionID), waitingSubagents(for: session) > 0 { return }
        let request = Self.requestID(fromKey: alert.key).flatMap { attention.request($0) }
        guard suppressWhenFrontmost, let found = state.session(id: alert.sessionID) else {
            onSignal?(alert.signal)
            return
        }
        if let request, request.waitsOnIslandAlone || (request.tool == .codex && (request.source == .rollout || request.isHeldCodexLegacy)) {
            onSignal?(alert.signal)
            return
        }
        if isCodexAppThread(found) {
            if alert.kind == .done || request != nil, dependencies.frontmostBundleID() == ExactJump.codexBundleID { return }
            onSignal?(alert.signal)
            return
        }
        let session = withEffectiveJumpTarget(found)
        let isFrontmost = dependencies.isSessionFrontmost
        Task { [weak self] in
            let frontmost = await isFrontmost(session)
            guard let self, !frontmost, self.stillShows(alert) else { return }
            self.onSignal?(alert.signal)
        }
    }

    private func stillShows(_ alert: SignalPipeline.Alert) -> Bool {
        if let id = Self.requestID(fromKey: alert.key) { return attention.request(id)?.isConfirmed == true }
        let session = state.session(id: alert.sessionID)
        if alert.kind == .turnFailed, !(session.map(hasFailedTurn) ?? false) { return false }
        return SignalPipeline.currentKey(alert.kind, session: session, turn: signals.turn(for: alert.sessionID)) == alert.key
    }

    static func sessionID(of event: AgentEvent) -> String? {
        switch event {
        case let .sessionStarted(payload): payload.sessionID
        case let .activityUpdated(payload): payload.sessionID
        case let .permissionRequested(payload): payload.sessionID
        case let .questionAsked(payload): payload.sessionID
        case let .sessionCompleted(payload): payload.sessionID
        case let .jumpTargetUpdated(payload): payload.sessionID
        case let .sessionMetadataUpdated(payload): payload.sessionID
        case let .claudeSessionMetadataUpdated(payload): payload.sessionID
        case let .geminiSessionMetadataUpdated(payload): payload.sessionID
        case let .openCodeSessionMetadataUpdated(payload): payload.sessionID
        case let .cursorSessionMetadataUpdated(payload): payload.sessionID
        case let .piSessionMetadataUpdated(payload): payload.sessionID
        case let .sessionHeartbeat(payload): payload.sessionID
        case let .actionableStateResolved(payload): payload.sessionID
        }
    }

    // MARK: Actions

    /// The session's card: its head request (`approve(requestID:decision:)`). Sends nothing unless the session still
    /// shows an answerable approval.
    @discardableResult
    public func approve(sessionID: String, decision: ApprovalDecision) async -> SendOutcome {
        guard let head = attention.head(of: sessionID), head.permissionRequest != nil else { return .nothingToSend }
        return await approve(requestID: head.id, decision: decision)
    }

    /// As `approve`: the session's head question.
    @discardableResult
    public func answer(sessionID: String, response: QuestionPromptResponse) async -> SendOutcome {
        guard let head = attention.head(of: sessionID), head.questionPrompt != nil else { return .nothingToSend }
        return await answer(requestID: head.id, response: response)
    }

    /// Archive. Upstream's `dismissSession` ends the session and stamps it now, which hides only a hook-managed one:
    /// its visibility rule keeps a session that is not hook-managed (every one a relaunch restores) while its process
    /// lives, and the stamp made it look brand new. So the session keeps its last event's time, and the engine keeps
    /// it out of the rows itself until it does something again (`noteArchivedActivity`, P729).
    public func dismiss(sessionID: String) {
        clearTurnFailure(sessionID)
        forgetAttention(sessionID)
        var next = state
        next.dismissSession(id: sessionID)
        if var session = next.session(id: sessionID), let before = state.session(id: sessionID) {
            session.updatedAt = before.updatedAt
            archived[sessionID] = before.updatedAt
            next = SessionState(sessions: next.sessions.filter { $0.id != sessionID } + [session])
        }
        state = next
        forgetToolCall(sessionID)
        interruptedSessionIDs.remove(sessionID)
        activityClocks[sessionID] = nil
        forgetClaudeSubagents(sessionID)
        lifecycle.noteEnded(sessionID, at: dependencies.now())
    }

    @discardableResult
    public func jump(sessionID: String) async -> JumpOutcome {
        // A Codex app thread goes to the app, never upstream's folder in Finder (P660).
        var target = state.session(id: sessionID).flatMap(jumpTarget(for:))
        var context = jumpContext(for: sessionID)
        let remote = remoteSessions.entry(for: sessionID)
        if let remote {
            // A remote session's terminal is the local tab that runs ssh to its host (P748).
            guard let found = await remoteJumpTarget(remote, workspace: target?.workspaceName ?? remote.hostName) else {
                let outcome = JumpOutcome(id: UUID(), sessionID: sessionID, host: remote.hostName, startedAt: dependencies.now(),
                                          duration: 0, result: .noTarget, failure: nil,
                                          message: "No ssh tab to \(remote.hostName) on this Mac.", steps: [])
                clearTurnFailure(sessionID)
                endSubagentHolds(in: sessionID, .opened)
                noteJump(outcome)
                return outcome
            }
            (target, context) = found
        }
        let runner = dependencies.jumpRunner
        // The owner opens the session: a failed turn no longer needs them, and a subagent's hold ends, so Claude's own
        // prompt is there when they arrive (P350).
        clearTurnFailure(sessionID)
        endSubagentHolds(in: sessionID, .opened)
        let jumpTarget = target, jumpContext = context
        let outcome = await Task.detached(priority: .userInitiated) {
            runner.run(sessionID: sessionID, target: jumpTarget, context: jumpContext)
        }.value
        if let remote, outcome.result != .failed { onRemoteJump?(remote.hostID, remote.context) }
        noteJump(outcome)
        return outcome
    }

    func noteJump(_ outcome: JumpOutcome) {
        recentJumps.insert(outcome, at: 0)
        if recentJumps.count > Self.recentJumpLimit { recentJumps.removeLast(recentJumps.count - Self.recentJumpLimit) }
    }

    /// "Jump to what needs you": the first session that needs you, unless its tab is already in front.
    public func jumpToNextNeedsYou() async -> JumpOutcome? {
        guard let session = nextNeedsYou else { return nil }
        if await dependencies.isSessionFrontmost(withEffectiveJumpTarget(session)) {
            // Its tab is already in front: the owner sees it, so a failed turn no longer needs them.
            clearTurnFailure(session.id)
            return nil
        }
        return await jump(sessionID: session.id)
    }

    /// True once the command reached the bridge.
    func send(_ command: BridgeCommand) async -> Bool {
        do {
            if let sendCommand = dependencies.sendCommand {
                try await sendCommand(command)
            } else {
                try await bridgeClient.send(command)
            }
            return true
        } catch {
            lastStatusMessage = "Could not reach the bridge: \(error.localizedDescription)"
            return false
        }
    }
}
