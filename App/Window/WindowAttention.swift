import AppKit
import Observation

/// Which requests' cards the window shows the owner now (P1050), for the engine (`SessionsModel.windowShows`): a Codex
/// request held for its card (Answer Codex in Juice) is held while the island or the window shows it, so Window mode
/// answers Codex as Island mode does. Pure; `WindowAttentionWatch` fills it in from AppKit.
///
/// The window shows a request's card when the window is on screen and someone can see it (`SurfaceVisibility.glyphsMove`:
/// ordered in, not minimised, not covered, the displays awake, unlocked, no screen saver), the card is in its Needs you
/// grid and not scrolled out of the list's view, and the owner has not gone to another app since the cards came: the
/// island's own ends (P270, P353), so a hold never keeps Codex's prompt from the app the owner looks at.
enum WindowAttention {
    /// The requests the window shows: every Needs you card's request in view, or none.
    static func shown(visible: Bool, ownerAway: Bool, cards: [SessionCard], outOfView: Set<String>) -> Set<String> {
        guard visible, !ownerAway else { return [] }
        return Set(cards.filter { !outOfView.contains($0.sessionID) }.compactMap { $0.request?.id })
    }

    /// An app became active (`pid`): the owner went elsewhere unless it is this app (they came to the window) or the
    /// one in front when the cards came, whose notice can arrive just after (the island's rule, `IslandFocus.ownerLeft`).
    static func ownerLeft(activated pid: pid_t?, own: pid_t, frontAtShow: pid_t?) -> Bool {
        guard let pid else { return true }
        return pid != own && pid != frontAtShow
    }
}

/// Keeps the engine told which requests the window shows (`WindowAttention`): it follows the rows and their cards, the
/// cards scrolled out of view (`AppEnvironment.windowCardsOutOfView`), the window's visibility (`SurfaceMotion`) and
/// which app the owner is in (`NSWorkspace`'s activation notice). Observation and notifications only, nothing polls;
/// it tells the engine only when the set changes.
@MainActor
final class WindowAttentionWatch {
    private let env: AppEnvironment
    private let motion: SurfaceMotion
    private let own: pid_t
    private let frontmost: @MainActor () -> pid_t?
    private var observer: (NotificationCenter, NSObjectProtocol)?
    private var reported: Set<String> = []
    /// The cards the window has in view, before the owner's whereabouts: what `frontAtShow` was taken for.
    private var candidates: Set<String> = []
    private var frontAtShow: pid_t?
    private var away = false
    private var stopped = false

    init(env: AppEnvironment, motion: SurfaceMotion, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         own: pid_t = ProcessInfo.processInfo.processIdentifier,
         frontmost: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.env = env
        self.motion = motion
        self.own = own
        self.frontmost = frontmost
        let token = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.activated(pid) }
        }
        observer = (workspace, token)
        observe()
    }

    /// The requests last told to the engine (tests).
    var shown: Set<String> { reported }

    func stop() {
        stopped = true
        if let (center, token) = observer { center.removeObserver(token) }
        observer = nil
        report([])
    }

    /// An app became active.
    func activated(_ pid: pid_t?) {
        guard !stopped else { return }
        if pid == own {
            away = false
        } else if !candidates.isEmpty, WindowAttention.ownerLeft(activated: pid, own: own, frontAtShow: frontAtShow) {
            away = true
        }
        report(compute())
    }

    /// Reads what the set depends on under observation, then tells the engine outside it.
    private func observe() {
        guard !stopped else { return }
        let next = withObservationTracking { compute() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        report(next)
    }

    /// The set from what it reads: the Needs you cards, the ones scrolled away, the window's visibility, the owner's app.
    /// While nobody can see the window it reads nothing else, so the rows are followed only while it shows.
    private func compute() -> Set<String> {
        let visible = motion.visibility.glyphsMove
        let cards = visible ? env.sessions.needsYou.compactMap { env.sessions.card(for: $0.id) } : []
        let outOfView = visible ? env.windowCardsOutOfView : []
        let inView = WindowAttention.shown(visible: visible, ownerAway: false, cards: cards, outOfView: outOfView)
        if inView.isEmpty {
            frontAtShow = nil
            away = false
        } else if candidates.isEmpty {
            frontAtShow = frontmost()
        }
        candidates = inView
        return away ? [] : inView
    }

    private func report(_ ids: Set<String>) {
        guard ids != reported else { return }
        reported = ids
        env.sessions.windowShows(requestIDs: ids)
    }

    isolated deinit {
        if let (center, token) = observer { center.removeObserver(token) }
    }
}
