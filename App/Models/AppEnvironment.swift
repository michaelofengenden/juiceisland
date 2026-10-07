import Foundation
import IslandEngine
import JuiceCore
import Observation

/// The Settings panes, in sidebar order. Watch is gone (it becomes Filters in M8, C9).
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, island, sound, shortcuts, agents, accounts, money, desktopPanel, diagnostics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .island: "Island"
        case .sound: "Sound"
        case .shortcuts: "Shortcuts"
        case .agents: "Agents"
        case .accounts: "Accounts"
        case .money: "Money"
        case .desktopPanel: "Desktop Panel"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }
}

/// The window list's filter; the toolbar's pill copy and the filter bar both drive it.
enum WindowFilter: Sendable { case all, needsYou }

/// What views may ask the app to do. The shell (AppDelegate) fills these in; renders keep the no-op defaults.
struct AppActions {
    var openSettings: @MainActor (SettingsPane) -> Void = { _ in }
    /// Show as Window ⇄ Island (⌘⇧I while focused, the toolbar segment, the island gear).
    var setShowAs: @MainActor (ShowAs) -> Void = { _ in }
    var quit: @MainActor () -> Void = {}
    /// Settings › Desktop Panel › Reset Position.
    var resetPanelPosition: @MainActor () -> Void = {}
    /// Settings › About › Show welcome (P951).
    var showWelcome: @MainActor () -> Void = {}
    /// A session was sent to the island and its terminal said where its window is (in the Dock now, or stayed for its
    /// other tabs): the fold's motion from there into the pill (`WindowFold.flyIn`, P1302, P1360). Renders and tests
    /// play nothing.
    var foldIn: @MainActor (TuckBounds) -> Void = { _ in }
}

/// Everything a view binds to, injected once at the root with `.environment(env)` and read with
/// `@Environment(AppEnvironment.self)`. Renders build one with `AppEnvironment.demo(...)`.
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    /// Replaced when Settings › Accounts › Usage source changes (`followUsageSource`).
    private(set) var usage: any UsageModel
    let sessions: any SessionsModel
    /// Settings › Agents, Diagnostics' Hooks section and the drift rows: fixture profiles unless the app sets
    /// `ProfileHooks` (`AppEnvironment.app`).
    var hooks: any HooksModel = DemoHooksModel()
    /// Settings › Agents (P935): Claude, Codex and OpenCode over `hooks` as it is now, then the agents table's sources
    /// (`AgentsPaneModel.sources`, set by the app). Renders find no command, so their agents are `hooks`' rows. Codex is
    /// Approve only while the app answers it (`LiveSessions.answersCodex`, either mode since P1050), Watch otherwise (P947).
    @ObservationIgnored lazy var agentsPane: AgentsPaneModel = {
        let model = AgentsPaneModel(hooks: { [unowned self] in self.hooks })
        model.answersCodex = { [unowned self] in LiveSessions.answersCodex(self.settings) }
        return model
    }()
    var agents: any AgentsModel { agentsPane }
    /// Settings › Agents › SSH hosts (P751): no host unless the app sets `RemoteHosts` (`AppEnvironment.app`).
    var remoteHosts: any RemoteHostsModel = DemoRemoteHostsModel()
    @ObservationIgnored var actions: AppActions
    /// Shared transient UI state (not persisted).
    var windowFilter: WindowFilter = .all
    /// The window's row the keys are on (↑ ↓, Return, P321): nil until an arrow is pressed, and again after Esc.
    var windowSelection: String?
    /// The window's Needs you cards scrolled out of the list's view, by session (`WindowAttention`, P1050).
    var windowCardsOutOfView: Set<String> = []
    /// Which app this is (P820): the public flavor hides the motion A/B knobs and offers Report a bug (P1060, P1065).
    /// Renders and tests pick either; the app's is its bundle's.
    var flavor: AppFlavor = .current
    /// The quota notice the island shows (P125): set by the island as it presents one, by renders to draw one.
    var islandNotice: QuotaNotice?
    /// Allow all's or Deny all's one line, until it clears itself (`BatchAnswer`, P1031).
    var answerAllNote: AnswerAllNote?
    /// The requests Allow all or Deny all just answered, until their cards went: the island never presents one of them
    /// as the next card (P1035).
    @ObservationIgnored var answeredByAll: Set<String> = []
    /// The keys macOS takes itself, for Settings › Shortcuts' line (P1029): none in renders and tests, the owner's own
    /// list in the app (`app`).
    @ObservationIgnored var systemShortcuts = SystemShortcuts.none
    /// Diagnostics › Motion's last motions: the island adds each one it records.
    let motionLog = MotionLog()
    /// In-app Update: newer commits on main, and the update run. Renders and tests get inert ones (an unknown build
    /// that never checks, a controller with no repository).
    let updateChecker: UpdateChecker
    let updateController: UpdateController
    /// Which build this is: the release build hides the development switches (Live sessions, Usage source). Renders
    /// and tests draw the development build's panes unless they say otherwise.
    let identity: AppIdentity

    init(settings: AppSettings, usage: any UsageModel, sessions: any SessionsModel, actions: AppActions = AppActions(),
         updateChecker: UpdateChecker? = nil, updateController: UpdateController? = nil, identity: AppIdentity = .development) {
        self.settings = settings
        self.usage = usage
        self.sessions = sessions
        self.actions = actions
        self.identity = identity
        self.updateChecker = updateChecker ?? UpdateChecker(stamp: BuildStamp(commit: nil, repoPath: nil), git: NoGitRunner())
        self.updateController = updateController ?? UpdateController(repoPath: nil)
    }

    /// Demo data only: fictional accounts, fixture sessions on a headless engine, in-memory settings unless given.
    /// `stalledAfter`: the fixtures' stall limit (off unless given, P312).
    static func demo(settings: AppSettings = .ephemeral(), sessions scenario: FixtureSessionFeed.Scenario = .allStates,
                     usage variant: DemoUsageModel.Variant = .standard, now: Date = DemoClock.now,
                     updateChecker: UpdateChecker? = nil, updateController: UpdateController? = nil,
                     identity: AppIdentity = .development, stalledAfter: TimeInterval? = nil) -> AppEnvironment {
        let feed = FixtureSessionFeed(scenario: scenario, now: now)
        let environment = AppEnvironment(settings: settings, usage: DemoUsageModel(now: now, variant: variant),
                                         sessions: feed.makeModel(stalledAfter: stalledAfter),
                                         updateChecker: updateChecker, updateController: updateController, identity: identity)
        environment.fixtureFeed = feed
        return environment
    }

    /// The app: usage per `settings.usageSource` and the build's identity (`UsageModelKind`): the release build reads
    /// the accounts itself (`live`, started here); a dev build mirrors Juice's readings from `juiceDirectory`, never
    /// written. Money is the same for both: `MoneyUsageModel` puts the money model's rows over either one (the release
    /// build reads money, a dev build mirrors the release build's records; `LiveMoneyModel.role`); demo data keeps its
    /// own. Sessions behind the Live sessions switch (the demo feed while it is off). Updates per the flavor
    /// (`updates`): the private app's from origin/main, the public flavor's from `feed`.
    static func app(settings: AppSettings, juiceDirectory: URL = JuiceReadingsUsageModel.defaultDirectory,
                    identity: AppIdentity = .current, feed: (any FeedUpdating)? = nil,
                    live: @escaping @MainActor () -> LiveUsageModel = { LiveUsageModel(readers: .app) },
                    money makeMoney: @MainActor (AppSettings, AppIdentity) -> LiveMoneyModel? = { LiveMoneyModel.app(settings: $0, identity: $1) })
        -> AppEnvironment {
        let now = DemoClock.now
        // Profiles and hooks start reading at `activate()` (launch); building them reads nothing.
        let directory = ProfileDirectory.app()
        let hooks = ProfileHooks.app(directory: directory)
        // Hears the screen lock and the session switching out for Quiet while locked: the sounds here, the island's
        // opens and its catch-up there (P422, P423).
        let lock = ScreenLockWatch()
        // Quiet while presenting and a Focus (P1005, P1006), read where each sound, card, reminder or banner would come.
        let scenes = QuietScenes(settings: settings)
        let sessions = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .allStates, now: now).makeModel() },
                                    profiles: { directory.current }, identity: .current, sounds: SystemSoundPlayer(),
                                    away: { lock.isAway }, scene: { scenes.now() })
        hooks.hookEvents = { [weak sessions] in sessions?.engine?.lastHookEventAt ?? [:] }
        hooks.onHooksChanged = { [weak sessions] in sessions?.engine?.hooksChanged() }
        directory.onChange.append { [weak sessions] _ in sessions?.profilesChanged() }
        let (checker, controller) = updates(stamp: .current, settings: settings, flavor: .current, feed: feed)
        let environment = AppEnvironment(settings: settings, usage: DemoUsageModel(now: now), sessions: sessions,
                                         updateChecker: checker, updateController: controller, identity: identity)
        environment.liveSessions = sessions
        environment.systemShortcuts = .live
        environment.screenLock = lock
        environment.quietScenes = scenes
        environment.launchAtLogin = .app(settings: settings)
        environment.hooks = hooks
        environment.agentsPane.live()
        // Every agent besides Claude, Codex and OpenCode comes from the engine's agents table (P915).
        environment.agentsPane.sources = [TableAgents.app()]
        // SSH hosts' tunnels follow the live engine (P747); nothing connects before the app's launch activates it.
        let remote = RemoteHosts()
        environment.remoteHosts = remote
        environment.liveRemoteHosts = remote
        environment.activityBoost = ActivityBoost(env: environment)
        // Reminders and banners follow their switches from launch (`AppDelegate`); off, neither runs, and Notification
        // Center is not touched until the owner turns banners on.
        let followUps = FollowUps(sessions: sessions, settings: settings, sounds: SystemSoundPlayer())
        // Made-up sessions on show (the Hello demo, Demo sessions) never remind or post a banner (P967).
        followUps.live = { [weak sessions] in sessions?.mode == .live && sessions?.showsRealSessions == true }
        followUps.away = { lock.isAway }
        followUps.scene = { scenes.now() }
        environment.followUps = followUps
        let banners = Banners(settings: settings, sessions: sessions, center: { SystemBannerCenter() })
        banners.live = { [weak sessions] in sessions?.mode == .live && sessions?.showsRealSessions == true }
        banners.away = { lock.isAway }
        banners.scene = { scenes.now() }
        environment.banners = banners
        // Snooze's end (P725) and Archive idle sessions after (P727): each one timer, set only while it has a moment to
        // wait for; the shell starts both at launch.
        environment.snoozeEnd = SnoozeEnd(settings: settings)
        let tidy = AutoTidy(sessions: sessions, settings: settings)
        tidy.live = { [weak sessions] in sessions?.mode == .live && sessions?.showsRealSessions == true }
        environment.autoTidy = tidy
        // Settings › About › Install automatically (P1070); the shell starts it at launch.
        environment.autoInstall = AutoInstall.app(env: environment)
        sessions.onReleased = { [weak banners, weak followUps] signal in
            banners?.released(signal)
            followUps?.released(signal)
        }
        // Money readers run only while the usage is real (never for demo data, in-memory settings or tests), and an
        // unconfigured source sends nothing.
        let money = makeMoney(settings, identity)
        environment.followUsageSource { source in
            switch UsageModelKind.choose(identity: identity, source: source) {
            case .live:
                let model = live()
                model.start()
                return MoneyUsageModel.wrap(model, money: money)
            case .juiceReadings:
                return MoneyUsageModel.wrap(JuiceReadingsUsageModel(directory: juiceDirectory), money: money)
            case .demo:
                money?.stop()
                return DemoUsageModel()
            }
        }
        return environment
    }

    /// The app's update checker and controller. The private app builds origin/main of the owner's repository, as ever.
    /// The public flavor never runs git or update-app.sh (P823, P824): its feed checks, downloads and installs, and with
    /// no feed (a build made without the feed's key) updates are off and About says so.
    static func updates(stamp: BuildStamp, settings: AppSettings, flavor: AppFlavor, feed: (any FeedUpdating)?,
                        version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                        memory: FeedMemory = .standard) -> (UpdateChecker, UpdateController) {
        guard flavor.isPublic else {
            let checker = UpdateChecker(stamp: stamp)
            return (checker, .app(stamp: stamp, checker: checker, settings: settings))
        }
        let checker = UpdateChecker(stamp: stamp, git: NoGitRunner(), off: feed == nil)
        let controller = UpdateController(repoPath: nil, build: stamp.shortCommit, commit: stamp.commit)
        if let feed {
            let updates = FeedUpdates(updater: feed, runningVersion: version, memory: memory)
            FeedUpdates.join(updates, checker: checker, controller: controller)
            // Install automatically: Sparkle's own, downloading in the background and installing at quit (P1074).
            updates.followAutomaticInstall(settings)
        }
        return (checker, controller)
    }

    @ObservationIgnored private var usageFactory: (@MainActor (UsageSource) -> any UsageModel)?

    /// Builds `usage` for the current source now, and again whenever `settings.usageSource` changes.
    func followUsageSource(_ factory: @escaping @MainActor (UsageSource) -> any UsageModel) {
        usageFactory = factory
        usage = factory(settings.usageSource)
        observeUsageSource()
    }

    private func observeUsageSource() {
        withObservationTracking { _ = settings.usageSource } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let factory = self.usageFactory else { return }
                self.liveUsage?.stop()
                self.usage = factory(self.settings.usageSource)
                self.observeUsageSource()
            }
        }
    }

    /// Send to island, on the owner's click or key (a row's menu or hover button, the island's S, the system-wide key):
    /// the session folds, and when its terminal said where its window is, its motion plays into the pill (P1300, P1302,
    /// P1360). Island mode only: in Window mode there is no island to send it to.
    func sendToIsland(_ sessionID: String) {
        guard settings.showAs == .island else { return }
        let sessions = sessions, foldIn = actions.foldIn
        Task { @MainActor in
            if let bounds = await sessions.sendToIsland(sessionID) { foldIn(bounds) }
        }
    }

    /// Whether `row` offers Send to island here: its tab is known, it is not folded yet, and the island is what shows.
    func offersSendToIsland(_ row: SessionRow) -> Bool {
        row.canFold && !row.isFolded && settings.showAs == .island
    }

    /// A card by its id: the island's quota notice (`QuotaNoticeCard.prefix`), else a session's (`SessionsModel.card`).
    func card(for id: String) -> SessionCard? {
        guard QuotaNoticeCard.isNotice(id) else { return sessions.card(for: id) }
        guard let notice = islandNotice.map(QuotaNoticeCard.init), notice.sessionID == id else { return nil }
        return .quota(notice)
    }

    /// Keeps the demo engine alive (the sessions model holds the engine; this holds the command recorder).
    @ObservationIgnored private(set) var fixtureFeed: FixtureSessionFeed?

    /// The app's SSH hosts (`AppEnvironment.app`), which the shell attaches to the live engine at launch; nil in renders
    /// and tests, which start no tunnel.
    var liveRemoteHosts: RemoteHosts?
    /// The app's Live sessions switch (`AppEnvironment.app`): the Demo or Live badge and a refused start's reason.
    /// nil in renders and tests, which show no badge.
    var liveSessions: LiveSessions?
    /// Settings › General › Launch at Login (`AppEnvironment.app`); nil in renders and tests, which show no row.
    var launchAtLogin: LaunchAtLogin?
    /// The screen lock and the session switching out (`AppEnvironment.app`); nil in renders and tests, which hear neither.
    var screenLock: ScreenLockWatch?
    /// Quiet while presenting and a Focus (`AppEnvironment.app`, P1005, P1006); nil in renders and tests, which have
    /// neither.
    var quietScenes: QuietScenes?
    /// The system-wide jump key (the shell makes it at launch); nil in renders and tests, which register nothing.
    var globalJump: GlobalJumpHotKey?
    /// Reads the accounts at work at their boosted floor (#12); the app's only.
    @ObservationIgnored private(set) var activityBoost: ActivityBoost?
    /// Settings › General › Remind again (P410); nil in renders and tests unless they make one.
    var followUps: FollowUps?
    /// Settings › General › Notification banners (P412); nil in renders and tests unless they make one with a fake
    /// center.
    var banners: Banners?
    /// Snooze's one timer, which clears it at its end (P725); nil in renders and tests unless they make one.
    @ObservationIgnored var snoozeEnd: SnoozeEnd?
    /// Settings › Island › Archive idle sessions after (P727); nil in renders and tests unless they make one.
    @ObservationIgnored var autoTidy: AutoTidy?
    /// Settings › About › Install automatically, the private app's (P1070); nil in the public flavor, renders and tests.
    @ObservationIgnored var autoInstall: AutoInstall?

    /// The accounts in use as the panel's watch last made them (P810, P814): the desktop panel's marks; none while the
    /// panel is off. The island takes its own at each open (`IslandUIState.inUse`), so nothing moves while it shows.
    var accountsInUse: AccountsInUse { inUseWatch.current }

    /// Starts or stops the panel's watch (`DesktopPanelController`, P814): never from a view's body or inside another
    /// observation's tracking.
    func watchAccountsInUse(_ on: Bool) {
        if on { inUseWatch.start { [weak self] in self?.accountsInUseNow ?? .none } } else { inUseWatch.stop() }
    }

    /// The accounts in use now, made again at once (the island's open, the widget's snapshot, the panel's watch). While
    /// no row names an account, nothing but the rows is looked at.
    var accountsInUseNow: AccountsInUse {
        let rows = sessions.rows
        guard rows.contains(where: { $0.account != nil }) else { return .none }
        return AccountsInUse.make(rows: rows, logins: usage.logins, panel: usage.panel)
    }

    /// The panel's (`accountsInUse`): made with the environment, started by the panel.
    let inUseWatch = AccountsInUseWatch()
}
