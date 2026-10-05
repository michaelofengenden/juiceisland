import AppKit
import Foundation
import IslandEngine
import JuiceCore
import Observation

/// The sessions the app shows, behind the "Live sessions" switch (spec §5.3, §8 decision 11). On: the app's own
/// engine, with its bridge on Open Island's hook socket, tagging sessions in every profile (§3.6). Off: the demo feed
/// in a development build, nothing in the production app. The switch is on by default in the production app and off
/// in development builds (`AppIdentity`). The engine's guard refuses while Open Island runs or a hook socket has a
/// live owner, and `refusal` says why: a development build turns the switch back off; the production app keeps it
/// on and tries again when an app quits or the Mac wakes. It is the app's `SessionsModel` and forwards to whichever
/// feed is showing. The live engine's signals play the owner's sounds (`SignalSounds`) and its Dones reach the island
/// (`finishSource`); No alerts for focused sessions, Show Codex app threads and Show scripted runs apply to it as they
/// change.
@MainActor
@Observable
final class LiveSessions: SessionsModel {
    enum Mode: Equatable, Sendable { case demo, live }

    /// The toolbar and island badge: live only while the bridge runs.
    private(set) var mode: Mode = .demo
    /// Why the last switch-on was refused, as one plain line; cleared by the next try.
    private(set) var refusal: String?
    /// The last Done the live engine let out, for the island (`finishSource`).
    private(set) var releasedFinish: ReleasedFinish?
    /// The demo feed, only while the switch is off.
    private(set) var demo: (any SessionsModel)?
    private var live: (any SessionsModel)?
    /// Made-up sessions shown in place of every other for a while: the welcome's Hello demo (P963) or Diagnostics' Demo
    /// sessions (P967). The live engine runs on underneath and keeps every real request; they show again as this goes.
    private(set) var showcase: (any SessionsModel)?
    private(set) var showcaseKind: ShowcaseKind?

    enum ShowcaseKind: Equatable, Sendable { case hello, demoSessions }

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let identity: AppIdentity
    @ObservationIgnored private var retryObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private let makeDemo: @MainActor () -> any SessionsModel
    @ObservationIgnored private let makeEngine: @MainActor () -> SessionEngine
    @ObservationIgnored private let loadProfiles: @MainActor () -> LiveProfiles
    @ObservationIgnored private let sounds: any SoundPlaying
    /// The screen is locked or the owner's session switched out (`ScreenLockWatch.isAway`): Quiet while locked holds the
    /// sounds back (P422). Never, but in the app.
    @ObservationIgnored private let away: @MainActor () -> Bool
    /// The screen mirrored or a Focus that quiets (`QuietScenes`, P1005, P1006): holds the sounds back as Quiet hours do.
    /// None, but in the app.
    @ObservationIgnored private let scene: @MainActor () -> QuietScene
    /// Made on the first switch-on and kept: upstream's process monitor has no stop, so a new engine would add another.
    @ObservationIgnored private(set) var engine: SessionEngine?
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var observing = false
    /// Every signal the live engine let out, after its sound: Window mode's banners (P412).
    @ObservationIgnored var onReleased: (@MainActor (EngineSignal) -> Void)?

    /// `sounds` plays the signals: the app passes the system's player, and everything else plays nothing. `away`: the
    /// app's lock watch; `scene`: its quiet scenes.
    init(settings: AppSettings, demo: @escaping @MainActor () -> any SessionsModel,
         engine: @escaping @MainActor () -> SessionEngine = { SessionEngine() },
         profiles: @escaping @MainActor () -> LiveProfiles = { LiveProfiles.load() },
         identity: AppIdentity = .development, sounds: any SoundPlaying = SilentSoundPlayer(),
         away: @escaping @MainActor () -> Bool = { false }, scene: @escaping @MainActor () -> QuietScene = { .none }) {
        self.settings = settings
        self.identity = identity
        makeDemo = demo
        makeEngine = engine
        loadProfiles = profiles
        self.sounds = sounds
        self.away = away
        self.scene = scene
        self.demo = identity.showsDemoSessions ? demo() : nil
    }

    /// Applies the switch now and again whenever it changes. The app calls this once, at launch. The production app
    /// also tries a refused start again when any app quits (Open Island, or whatever held the socket) or the Mac wakes,
    /// and then looks at a live bridge's socket too (`SessionEngine.checkBridgeSockets`): an app that quit may have
    /// left the socket it took, and one that ran while the Mac slept may have taken it.
    func activate() {
        apply()
        guard !observing else { return }
        observing = true
        observe()
        observeFocusSwitch()
        observeScriptedRunsSwitch()
        observeSubagentSwitch()
        observeModeChoicesSwitch()
        guard identity == .production else { return }
        let center = NSWorkspace.shared.notificationCenter
        retryObservers = [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.retry()
                    self?.checkSocket()
                }
            }
        }
    }

    /// A live bridge looks at its hook socket again (P112).
    func checkSocket() {
        guard mode == .live else { return }
        engine?.checkBridgeSockets()
    }

    /// The hooks reach this app: live, and no other app took the hook socket since (`BridgeHealth.taken`).
    var hooksReachApp: Bool { mode == .live && engine?.bridgeHealth != .taken }

    /// Quitting: the bridge stops; the switch keeps its setting.
    func shutdown() {
        engine?.stop()
        for observer in retryObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        retryObservers = []
    }

    /// Brings the sessions in line with the switch.
    func apply() {
        if settings.liveSessions {
            if mode == .demo { goLive() }
        } else {
            guard mode == .live else { return }
            engine?.stop()
            mode = .demo
            demo = identity.showsDemoSessions ? makeDemo() : nil
        }
    }

    /// A refused start, again (production: an app quit or the Mac woke). Nothing while the switch is off or live.
    func retry() {
        guard settings.liveSessions, mode != .live, refusal != nil else { return }
        goLive()
    }

    /// The profile list changed: the running engine tags sessions against the new list.
    func profilesChanged() {
        guard let engine else { return }
        let profiles = loadProfiles()
        aliases = Dictionary(profiles.accounts.map { ($0.id, $0.alias) }, uniquingKeysWith: { first, _ in first })
        engine.setProfiles(accounts: profiles.accounts, discovered: profiles.discovered)
    }

    /// The production app's badge while it waits: a word or two for why the hooks are not live, a socket another app
    /// took included.
    var shortRefusal: String? {
        guard settings.liveSessions else { return nil }
        if mode == .live { return hooksReachApp ? nil : Self.hooksBusy }
        guard let refusal else { return nil }
        return refusal == Self.refusalText(for: SessionEngineError.otherIslandRunning) ? "Open Island running" : Self.hooksBusy
    }

    static let hooksBusy = "Hooks busy"
    static let takenText = "Another app took the hook connection — its hooks go there until it quits"

    /// Why the hooks do not reach this app, as one plain line: the refusal, or the socket another app took.
    var hooksProblem: String? {
        guard settings.liveSessions else { return nil }
        if mode == .live { return hooksReachApp ? nil : Self.takenText }
        return refusal
    }

    /// The toolbar's and island header's badge. A development build says "Live" or "Demo" (or why its hooks wait,
    /// once live); the production app, which is live as a rule, says only why its hooks wait, and nothing otherwise.
    var badge: String? {
        guard identity != .production else { return shortRefusal }
        if mode == .live { return hooksReachApp ? "Live" : Self.hooksBusy }
        return "Demo"
    }

    private func observe() {
        withObservationTracking { _ = settings.liveSessions } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
    }

    /// No alerts for focused sessions, applied to the engine as it changes.
    private func observeFocusSwitch() {
        engine?.suppressWhenFrontmost = settings.suppressForFocusedSessions
        withObservationTracking { _ = settings.suppressForFocusedSessions } onChange: { [weak self] in
            Task { @MainActor in self?.observeFocusSwitch() }
        }
    }

    /// Show scripted runs, applied to the engine as it changes: its lists, and so every row, count and card, follow.
    private func observeScriptedRunsSwitch() {
        engine?.showsScriptedRuns = settings.showScriptedRuns
        withObservationTracking { _ = settings.showScriptedRuns } onChange: { [weak self] in
            Task { @MainActor in self?.observeScriptedRunsSwitch() }
        }
    }

    /// Answer subagents on the island and Answer Codex on the island, applied to the engine as they or Show as change. A
    /// subagent's hold is the island's alone, so in Window mode every subagent request is handed back at once (P350); a
    /// Codex hold waits on the window's Needs you card there as it waits on the island's card in Island mode (P470, P1050).
    private func observeSubagentSwitch() {
        engine?.answersSubagents = Self.answersSubagents(settings)
        engine?.answersCodex = Self.answersCodex(settings)
        withObservationTracking {
            _ = settings.answerSubagentsOnIsland
            _ = settings.answerCodexOnIsland
            _ = settings.showAs
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSubagentSwitch() }
        }
    }

    static func answersSubagents(_ settings: AppSettings) -> Bool { settings.answerSubagentsOnIsland && settings.showAs == .island }
    static func answersCodex(_ settings: AppSettings) -> Bool { settings.answerCodexOnIsland }

    /// Permission modes on cards, applied to the engine as it changes: off, no card offers a mode and none is sent (P450).
    private func observeModeChoicesSwitch() {
        engine?.offersModeChoices = settings.modeChoicesOnCards
        withObservationTracking { _ = settings.modeChoicesOnCards } onChange: { [weak self] in
            Task { @MainActor in self?.observeModeChoicesSwitch() }
        }
    }

    /// A signal the live engine let out: its sound, and a Done for the island. A question is the head request's kind
    /// (P425); a mute rule matches the session's row as it lists (P421).
    private func released(_ signal: EngineSignal) {
        guard mode == .live else { return }
        let session = engine?.state.session(id: signal.sessionID)
        let stillNeedsYou = session.map { engine?.needsAttention($0) == true } ?? false
        let isQuestion = engine?.attentionHead(for: signal.sessionID)?.kind.isQuestion == true
        let muted = !settings.muteRules.isEmpty && row(id: signal.sessionID).map { settings.muteRules.mutes($0) } == true
        let isCodexAppThread = session.map { engine?.isCodexAppThread($0) == true } ?? false
        if let name = SignalSounds.sound(for: signal, isCodexAppThread: isCodexAppThread, stillNeedsYou: stillNeedsYou,
                                         isQuestion: isQuestion, muted: muted, away: away(), scene: scene(), settings: settings) {
            sounds.play(name, volume: SignalSounds.volume(settings))
        }
        if case let .done(sessionID) = signal {
            releasedFinish = ReleasedFinish(sessionID: sessionID, serial: (releasedFinish?.serial ?? 0) + 1)
        }
        onReleased?(signal)
    }

    private func goLive() {
        refusal = nil
        let engine = self.engine ?? makeEngine()
        if self.engine == nil {
            engine.onSignal = { [weak self] signal in self?.released(signal) }
        }
        engine.suppressWhenFrontmost = settings.suppressForFocusedSessions
        engine.showsScriptedRuns = settings.showScriptedRuns
        engine.answersSubagents = Self.answersSubagents(settings)
        engine.offersModeChoices = settings.modeChoicesOnCards
        engine.answersCodex = Self.answersCodex(settings)
        self.engine = engine
        let profiles = loadProfiles()
        aliases = Dictionary(profiles.accounts.map { ($0.id, $0.alias) }, uniquingKeysWith: { first, _ in first })
        engine.setProfiles(accounts: profiles.accounts, discovered: profiles.discovered)
        do {
            try engine.start()
        } catch {
            refusal = Self.refusalText(for: error)
            // A development build turns the switch back off; the production app waits and tries again (`retry`).
            if identity != .production { settings.liveSessions = false }
            return
        }
        if live == nil {
            live = EngineSessionsModel(engine: engine, aliasForAccountID: { [weak self] id in self?.aliases[id] }, jumps: .live,
                                       showsCodexAppThreads: { [settings] in settings.showCodexAppThreads },
                                       stalledAfter: { [settings] in settings.stalledAfter.seconds },
                                       uptime: { ProcessInfo.processInfo.systemUptime }, branches: .live())
        }
        demo = nil
        mode = .live
    }

    static func refusalText(for error: any Error) -> String {
        switch error as? SessionEngineError {
        case .otherIslandRunning: "Open Island is running — quit it to see live sessions"
        case .hookSocketInUse: "Another app is using the hook connection"
        case nil: "Could not start the hook connection: \(error.localizedDescription)"
        }
    }

    /// Shows `model` in place of the sessions (nil: the sessions again). Never written to the settings: a relaunch shows
    /// the real sessions.
    func show(_ model: (any SessionsModel)?, as kind: ShowcaseKind?) {
        showcase = model
        showcaseKind = model == nil ? nil : kind
    }

    /// Real sessions show (no showcase): banners, reminders and the tidy act only then.
    var showsRealSessions: Bool { showcase == nil }

    // MARK: SessionsModel

    private var current: (any SessionsModel)? { showcase ?? (mode == .live ? live : demo) }

    var rows: [SessionRow] { current?.rows ?? [] }
    var now: Date { current?.now ?? Date() }
    func card(for sessionID: String) -> SessionCard? { current?.card(for: sessionID) }
    var waiting: [SessionRow] { current?.waiting ?? [] }
    func waitingSince(_ sessionID: String) -> TimeInterval? { current?.waitingSince(sessionID) }
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) {
        current?.approve(sessionID, decision, request: request)
    }
    @discardableResult func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool {
        current?.answerQuestion(sessionID, input, request: request) ?? false
    }
    func reply(_ sessionID: String, text: String) { current?.reply(sessionID, text: text) }
    func retry(_ sessionID: String) { current?.retry(sessionID) }
    func jump(_ sessionID: String) { current?.jump(sessionID) }
    func jumpToNextNeedsYou() { current?.jumpToNextNeedsYou() }
    func dismiss(_ sessionID: String) { current?.dismiss(sessionID) }
    // A read-only card's two buttons reach the engine's request, never the protocol's plain jump (P171).
    func openRequest(_ sessionID: String, request: String?) { current?.openRequest(sessionID, request: request) }
    func dismissRequest(_ sessionID: String, request: String?) { current?.dismissRequest(sessionID, request: request) }
    func islandShows(requestID: String?) { current?.islandShows(requestID: requestID) }
    func windowShows(requestIDs: Set<String>) { current?.windowShows(requestIDs: requestIDs) }
    func openFresh(_ sessionID: String, in alternative: LimitAlternative) { current?.openFresh(sessionID, in: alternative) }
    var jumpNote: JumpNote? { current?.jumpNote }
    var finishSource: FinishSource {
        if let showcase { return showcase.finishSource }
        return mode == .live ? .engine(last: releasedFinish) : current?.finishSource ?? .rows
    }
    func peek(_ sessionID: String, clean: Bool) async -> SessionPeek? { await current?.peek(sessionID, clean: clean) }
    func work(_ sessionID: String) -> SessionWork? { current?.work(sessionID) }
}

/// The profiles the live engine tags sessions with and Setup hooks: standalone Juice's accounts file, only ever read
/// (spec §5.3, §8 decision 10), plus the default ~/.claude and ~/.codex, which count even when that file is missing,
/// plus every other profile folder in the home folder, found by which files exist (`ProfileFolderDiscovery`, which
/// opens none of them), so all six Claude and five Codex profiles count whatever the accounts file lists (§8 decision 6).
struct LiveProfiles: Equatable, Sendable {
    var accounts: [Account]
    var discovered: [DiscoveredProfile]

    /// On any thread (`ProfileDirectory` reloads off the main one).
    static func load(accountsFile: URL = AccountsStore.defaultFileURL, home: String = NSHomeDirectory()) -> LiveProfiles {
        let accounts = (try? Data(contentsOf: accountsFile)).map(AccountsStore.accounts(in:)) ?? []
        return LiveProfiles(accounts: accounts, discovered: discovered(home: home))
    }

    /// The default ~/.claude and ~/.codex, then every other profile folder in `home`; the accounts file is not read.
    static func discovered(home: String) -> [DiscoveredProfile] {
        let defaults = Provider.allCases.map {
            DiscoveredProfile(provider: $0, folder: home + "/" + $0.defaultFolderName, suggestedAlias: $0.displayName)
        }
        let folders = Set(defaults.map(\.folder))
        return defaults + ProfileFolderDiscovery.discover(home: home).filter { !folders.contains($0.folder) }
    }
}
