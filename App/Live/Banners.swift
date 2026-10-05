import AppKit
import Foundation
import IslandEngine
import Observation
import UserNotifications

/// What macOS says of the app's notification banners.
enum BannerPermission: Equatable, Sendable {
    /// Not read yet (the switch is off, or the answer is on its way).
    case unknown
    /// The owner has not been asked yet.
    case notAsked
    case allowed
    /// Turned off in System Settings, or refused at the prompt.
    case denied
    /// macOS refused to ask at all: a build it will not let post (an unsigned copy, say).
    case unavailable
}

/// One banner. Notification Center keeps what it shows on disk, so a banner says only what the widget's file may
/// (P200, P412): the project folder (a chat's title only when the repo gave it) and the card's status line less any
/// words the session wrote ("Needs approval · Bash", "Question", "Plan ready · 4 steps", "API error · rate limited",
/// "Done"); never a command, a question, a message, a prompt or a path.
struct Banner: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case needsYou, done }

    /// Notification Center's id: one banner per request, or per finished turn.
    var id: String
    var sessionID: String
    var kind: Kind
    var title: String
    var body: String
    /// What it is about: a request's key (`IslandAttention.requestKey`), or the finished turn's (`BannerRule.finishKey`).
    var key: String
}

/// Where banners go: Notification Center in the app (`SystemBannerCenter`), a recorder in tests, which never post a
/// notification or ask for permission.
@MainActor
protocol BannerCenter: AnyObject {
    /// What macOS says now, without asking.
    func permission() async -> BannerPermission
    /// Asks the owner (macOS shows its prompt once; later calls answer at once).
    func requestPermission() async -> BannerPermission
    func post(_ banner: Banner)
    /// Takes delivered banners out of Notification Center.
    func remove(_ ids: [String])
    /// A banner's click, with its session's id.
    var clicked: (@MainActor (String) -> Void)? { get set }
}

/// Which signals get a banner, and what it says (P412).
enum BannerRule {
    /// A row a banner may tell of: the owner's own session (not a scripted run or a subagent's thread, P254), and not a
    /// subagent's request on its parent's row.
    static func tells(_ row: SessionRow) -> Bool { !row.isQuiet && row.asker == nil }

    /// Island mode: of one batch the island heard (after Quiet, what it put away and the questions it holds on the pill),
    /// the signals it does not show itself. None while it is open on its display, where the owner sees it; none for the
    /// card it opens by itself (`opened`); a stall's quiet notice never. `visible`: the island is on a display at all.
    static func fromIsland(_ signals: [IslandSignal], opened: String?, islandOpen: Bool, visible: Bool) -> [IslandSignal] {
        guard !(visible && islandOpen) else { return [] }
        return signals.filter { signal in
            switch signal {
            case let .needsYou(id), let .finished(id): !(visible && opened == id)
            case .stalled: false
            }
        }
    }

    /// The banner for `signal` of `row`, or nil when it tells of nothing: a row it may not tell of, or one no longer in
    /// the state the signal was about.
    static func banner(for signal: IslandSignal, row: SessionRow?, card: SessionCard?, finish: ReleasedFinish? = nil) -> Banner? {
        guard let row, tells(row) else { return nil }
        let title = WidgetSnapshot.title(row)
        switch signal {
        case .needsYou:
            guard row.bucket == .needsYou else { return nil }
            let key = IslandAttention.requestKey(row, card: card)
            return Banner(id: "needs:\(key)", sessionID: row.id, kind: .needsYou, title: title, body: status(row, card: card), key: key)
        case .finished:
            guard row.bucket == .done, !row.isInterrupted else { return nil }
            let key = finishKey(row, finish: finish)
            return Banner(id: "done:\(row.id):\(key)", sessionID: row.id, kind: .done, title: title, body: "Done", key: key)
        case .stalled:
            return nil
        }
    }

    /// The card's status line less the session's own words, as the widget writes it; with no card, the row's word alone.
    static func status(_ row: SessionRow, card: SessionCard?) -> String {
        if let card {
            let status = CardText.status(WidgetSnapshot.withoutSessionText(card), host: row.host)
            let line = [status.word, status.text].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty { return line }
        }
        return SessionRowText.cleanStatus(row).word ?? "Needs you"
    }

    /// The finished turn a Done banner tells of: the live engine's release of it (`ReleasedFinish`, one per turn), never
    /// the row's time, which later events of the same turn move (Claude's idle_prompt about a minute after an unanswered
    /// Stop, a late rollout line, a jump handle, P495). Without a release, the row's time when it was told.
    static func finishKey(_ row: SessionRow, finish: ReleasedFinish?) -> String {
        if let finish, finish.sessionID == row.id { return "turn:\(finish.serial)" }
        return "at:\(Int(row.updatedAt.timeIntervalSince1970.rounded(.down)))"
    }

    /// A delivered banner still says what is so: its request still waits; its turn still shows finished, and no newer
    /// turn of that session finished since (`finish`: the live engine's last release).
    static func stillHolds(_ banner: Banner, rows: [SessionRow], card: (String) -> SessionCard?, finish: ReleasedFinish? = nil) -> Bool {
        guard let row = rows.first(where: { $0.id == banner.sessionID }) else { return false }
        switch banner.kind {
        case .needsYou: return row.bucket == .needsYou && IslandAttention.requestKey(row, card: card(row.id)) == banner.key
        case .done:
            let newer = finish.map { $0.sessionID == row.id && finishKey(row, finish: $0) != banner.key } ?? false
            return row.bucket == .done && !row.isInterrupted && !newer
        }
    }
}

/// Settings › General › Notification banners (P412, off by default): a macOS banner for what needs you and for a
/// finished turn of the owner's, only where the island does not show it itself. Island mode: the island tells what it
/// heard and did (`islandHeard`); a card it opens by itself, or anything while it is open on its display, gets none.
/// Window mode: a signal the engine let out (after No alerts for focused sessions, as the sound) gets one unless the
/// window is in front (`released`). Quiet (Quiet hours, or full screen with Hide in full screen on) gets none, as it gets
/// no pop-up. One banner per request or finished turn; it is taken back once its request is answered, or once its
/// session runs again or finishes a newer turn (never because a later event of the same turn moved the row's time, P495). A click opens it where a widget's tap does (`clicked`). macOS is asked for permission only when the owner
/// turns the switch on (or clicks Allow in Settings); nothing touches Notification Center while the switch is off.
@MainActor
@Observable
final class Banners {
    /// What macOS says, for Settings' row.
    private(set) var permission: BannerPermission = .unknown

    /// A banner's click: the shell opens its session as a widget's tap does.
    @ObservationIgnored var clicked: @MainActor (String) -> Void = { _ in }
    /// Window mode: the window is in front, where the owner sees what a banner would say.
    @ObservationIgnored var windowFront: @MainActor () -> Bool = { false }
    /// The sessions are the live engine's: the demo feed's rows never post a banner.
    @ObservationIgnored var live: @MainActor () -> Bool = { true }
    /// The screen is locked or the owner's session switched out (`ScreenLockWatch.isAway`): with Quiet while locked on,
    /// nothing pops up (P422).
    @ObservationIgnored var away: @MainActor () -> Bool = { false }
    /// The screen mirrored or a Focus that quiets (`QuietScenes`): nothing pops up (P1005).
    @ObservationIgnored var scene: @MainActor () -> QuietScene = { .none }
    /// Opens System Settings' Notifications page for this app.
    @ObservationIgnored var openSystemSettings: @MainActor () -> Void = Banners.openNotificationSettings
    /// The banners Notification Center may still show.
    @ObservationIgnored private(set) var delivered: [Banner] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sessions: any SessionsModel
    @ObservationIgnored private let makeCenter: @MainActor () -> any BannerCenter
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private(set) var center: (any BannerCenter)?
    /// Banner ids told, by session: each request or finished turn gets one banner.
    @ObservationIgnored private var told: [String: String] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = 0

    init(settings: AppSettings, sessions: any SessionsModel, center: @escaping @MainActor () -> any BannerCenter,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.settings = settings
        self.sessions = sessions
        makeCenter = center
        self.clock = clock
    }

    /// Follows the switch from now on: the shell calls this once, at launch. With the switch on, macOS is read (never
    /// asked) so Settings can say where it stands.
    func start() {
        guard !started else { return }
        started = true
        if settings.notificationBanners { connect(asking: false) }
        observeSwitch()
    }

    /// Settings' Allow: asks macOS (its prompt shows once).
    func ask() {
        guard settings.notificationBanners else { return }
        connect(asking: true)
    }

    /// Reads what macOS says again (Settings shows, the app comes to the front): never asks.
    func refresh() {
        guard settings.notificationBanners, let center else { return }
        Task { @MainActor [weak self] in
            let permission = await center.permission()
            self?.permission = permission
        }
    }

    private func observeSwitch() {
        withObservationTracking { _ = settings.notificationBanners } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settings.notificationBanners { self.connect(asking: true) } else { self.disconnect() }
                self.observeSwitch()
            }
        }
    }

    private func connect(asking: Bool) {
        let center = self.center ?? makeCenter()
        if self.center == nil {
            center.clicked = { [weak self] id in self?.clicked(id) }
            self.center = center
        }
        generation &+= 1
        observeRows()
        Task { @MainActor [weak self] in
            let permission = asking ? await center.requestPermission() : await center.permission()
            self?.permission = permission
        }
    }

    /// Off: every banner still shown is taken back, and nothing more is posted.
    private func disconnect() {
        generation &+= 1
        if !delivered.isEmpty { center?.remove(delivered.map(\.id)) }
        delivered = []
        told = [:]
        permission = .unknown
    }

    // MARK: Signals

    /// Island mode: one batch as the island heard it and what it did (`BannerRule.fromIsland`). `quiet`: Quiet holds
    /// attention, so nothing pops up.
    func islandHeard(_ signals: [IslandSignal], opened: String?, islandOpen: Bool, visible: Bool, quiet: Bool) {
        guard settings.notificationBanners, center != nil, !quiet, settings.showAs == .island, live() else { return }
        for signal in BannerRule.fromIsland(signals, opened: opened, islandOpen: islandOpen, visible: visible) { post(signal) }
    }

    /// Window mode: a signal the live engine let out (once per request or turn, after its hold and the focused-tab
    /// check), unless the window is in front or Quiet hours hold.
    func released(_ signal: EngineSignal) {
        guard settings.notificationBanners, center != nil, settings.showAs == .window, !windowFront(),
              !QuietMode.holdsAttention(settings, fullScreen: false, away: away(), scene: scene(), now: clock()) else { return }
        switch signal {
        case let .needsYou(id): post(.needsYou(id))
        case let .done(id): post(.finished(id))
        }
    }

    private func post(_ signal: IslandSignal) {
        guard let center else { return }
        let id: String
        switch signal {
        case let .needsYou(session), let .finished(session), let .stalled(session): id = session
        }
        let row = sessions.row(id: id)
        // A session a mute rule matches never pops up (P421); the island's batches come without it already.
        if let row, !settings.muteRules.isEmpty, settings.muteRules.mutes(row) { return }
        guard let banner = BannerRule.banner(for: signal, row: row, card: sessions.card(for: id), finish: lastFinish),
              told[banner.id] == nil else { return }
        told[banner.id] = banner.sessionID
        delivered.append(banner)
        center.post(banner)
    }

    /// The live engine's last released finish, if the sessions are its.
    private var lastFinish: ReleasedFinish? {
        if case let .engine(last) = sessions.finishSource { return last }
        return nil
    }

    // MARK: Taking back

    private func observeRows() {
        let generation = generation
        withObservationTracking {
            _ = sessions.rows
            _ = sessions.finishSource
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.settings.notificationBanners else { return }
                self.rowsChanged()
                self.observeRows()
            }
        }
    }

    /// A banner whose request was answered (anywhere) or whose session runs again is taken back; what was told of a
    /// session no longer listed is forgotten.
    func rowsChanged() {
        let rows = sessions.rows
        let finish = lastFinish
        let gone = delivered.filter { !BannerRule.stillHolds($0, rows: rows, card: { sessions.card(for: $0) }, finish: finish) }
        if !gone.isEmpty {
            center?.remove(gone.map(\.id))
            let ids = Set(gone.map(\.id))
            delivered.removeAll { ids.contains($0.id) }
        }
        let listed = Set(rows.map(\.id))
        told = told.filter { listed.contains($0.value) }
    }

    /// System Settings › Notifications, at this app's own page when macOS knows it.
    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(id)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Notification Center, made only once the owner turns Notification banners on (or at launch with it on). Alerts only:
/// no sound (the app plays its own, Settings › Sound) and no badge. A banner shows even while the app is active: the
/// rule already kept those the island or the window shows.
@MainActor
final class SystemBannerCenter: NSObject, BannerCenter, UNUserNotificationCenterDelegate {
    var clicked: (@MainActor (String) -> Void)?
    private let center: UNUserNotificationCenter
    nonisolated static let sessionKey = "session"

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    func permission() async -> BannerPermission {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .notAsked
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestPermission() async -> BannerPermission {
        do {
            return try await center.requestAuthorization(options: [.alert]) ? .allowed : .denied
        } catch {
            return .unavailable
        }
    }

    func post(_ banner: Banner) {
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        content.threadIdentifier = banner.sessionID
        content.userInfo = [Self.sessionKey: banner.sessionID]
        center.add(UNNotificationRequest(identifier: banner.id, content: content, trigger: nil)) { _ in }
    }

    func remove(_ ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo[Self.sessionKey] as? String else { return }
        await MainActor.run { self.clicked?(id) }
    }
}
