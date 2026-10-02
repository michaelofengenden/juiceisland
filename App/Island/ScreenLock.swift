import AppKit
import CoreGraphics
import Observation

/// Whether the owner's session is in front of them now, as the window server's session dictionary says
/// (`CGSessionCopyCurrentDictionary`, public CoreGraphics since macOS 10.3). Its on-console key (`kCGSessionOnConsoleKey`,
/// public) is false while another user's session has the display (fast user switching); `CGSSessionScreenIsLocked`, which
/// loginwindow puts in the dictionary only while the screen is locked, is not in the header, so it is only ever read
/// together with the lock notice (`ScreenLockWatch`, P422). No permission is needed and nothing else is read.
struct SessionPresence: Equatable, Sendable {
    var screenLocked = false
    var onConsole = true

    /// The screen is locked, or another user's session is in front.
    var away: Bool { screenLocked || !onConsole }

    /// Present, with 1, only while the screen is locked (loginwindow on macOS 27.0 writes it beside its lock notices).
    static let lockedKey = "CGSSessionScreenIsLocked"
    /// `kCGSessionOnConsoleKey`'s value (CGSession.h), a `CFSTR` macro Swift does not import.
    static let onConsoleKey = "kCGSSessionOnConsoleKey"

    /// nil when there is no GUI session to ask (a test runner over SSH, the window server gone).
    static func make(_ dictionary: [String: Any]?) -> SessionPresence? {
        guard let dictionary else { return nil }
        return SessionPresence(screenLocked: (dictionary[lockedKey] as? NSNumber)?.boolValue ?? false,
                               onConsole: (dictionary[onConsoleKey] as? NSNumber)?.boolValue ?? true)
    }

    /// The window server's answer now: one call, made only while a lock or a switch-out was heard.
    static func now() -> SessionPresence? {
        make(CGSessionCopyCurrentDictionary() as? [String: Any])
    }
}

/// Hears when the owner leaves the Mac and comes back (P422, P423): the screen locked and unlocked
/// (`com.apple.screenIsLocked` and `com.apple.screenIsUnlocked`, which loginwindow posts to every app through the
/// distributed notification center; the names are not in a header, but macOS 27.0's loginwindow still sends both), and
/// the owner's session switched out and back in (`NSWorkspace.sessionDidResignActiveNotification` and
/// `sessionDidBecomeActiveNotification`, documented). Notifications only: no monitor, no tap, no timer, nothing polls.
///
/// Away needs both: a notice heard, and the window server confirming it at the moment it is asked (`isAway`). So a notice
/// macOS stopped sending, an unlock notice that never came or a key it no longer writes leaves the island and its sounds
/// as they were without the switch: it fails open, never into a quiet that does not end. Tests hand it centers and a
/// presence of their own.
@MainActor
@Observable
final class ScreenLockWatch {
    static let lockedNotice = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotice = Notification.Name("com.apple.screenIsUnlocked")

    /// A lock or a switch-out was heard, and nothing has brought the owner back since.
    private(set) var awayNoticed = false
    /// Counts each return after a lock or a switch-out: the island's catch-up follows it (P423).
    private(set) var returns = 0

    @ObservationIgnored private var locked = false
    @ObservationIgnored private var switchedOut = false
    @ObservationIgnored private let presence: @MainActor () -> SessionPresence?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    init(distributed: NotificationCenter = DistributedNotificationCenter.default(),
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         presence: @escaping @MainActor () -> SessionPresence? = { SessionPresence.now() }) {
        self.presence = presence
        let heard: [(NotificationCenter, Notification.Name, @MainActor (ScreenLockWatch) -> Void)] = [
            (distributed, Self.lockedNotice, { $0.locked = true }),
            (distributed, Self.unlockedNotice, { $0.locked = false }),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, { $0.switchedOut = true }),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, { $0.switchedOut = false }),
        ]
        for (center, name, apply) in heard {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.noticed()
                }
            }
            observers.append((center, observer))
        }
    }

    /// The owner is away now: a lock or a switch-out was heard, and the window server says so too. Read at the moment a
    /// sound or a card would come; asks the window server only while a notice says away.
    var isAway: Bool { awayNoticed && presence()?.away == true }

    private func noticed() {
        let away = locked || switchedOut
        guard away != awayNoticed else { return }
        awayNoticed = away
        if !away { returns += 1 }
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    isolated deinit { stop() }
}

/// What the island shows once the owner is back (P423): the card that has waited longest of those that came while the
/// screen was locked and still wait on the same request, none of them muted (they were never heard, P421). Nothing when
/// all were answered elsewhere; a finish that came meanwhile has lit Glance's dot already.
enum LockCatchUp {
    /// `arrivals`: session → the request key (`IslandAttention.requestKey`) of each needs-you heard while away;
    /// `waiting`: the rows that wait, the one that has waited longest first; `pending`: their request keys now.
    static func card(arrivals: [String: String], waiting: [SessionRow], pending: [String: String]) -> String? {
        guard !arrivals.isEmpty else { return nil }
        return waiting.first { row in arrivals[row.id].map { pending[row.id] == $0 } ?? false }?.id
    }

    /// The rows the catch-up may open on: none a mute rule matches (they were never heard, P421), and no question held
    /// on the pill while Questions open the island is off (it waits there after a lock too, P411).
    static func candidates(_ waiting: [SessionRow], rules: [MuteRule], questionsOpen: Bool) -> [SessionRow] {
        waiting.filter { !rules.mutes($0) && (questionsOpen || !QuestionsOpen.isQuestion($0)) }
    }

    /// How long after the unlock the island opens: the lock screen's own fade has ended by then, so the card is seen
    /// arriving rather than found open.
    static let delay: Duration = .milliseconds(600)
}
