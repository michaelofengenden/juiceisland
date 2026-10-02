import AppKit

/// Where the owner is, as the island hears it (P270): an app became active, or the island's panel lost the keys to a
/// click outside it. Notifications only: `NSWorkspace`'s and the panel's own, never an event monitor or tap.
enum IslandFocusChange: Equatable, Sendable {
    /// An app became active (its process id; nil when the notice named none), Juice Island itself included.
    case appActivated(pid_t?)
    /// The island's panel stopped being key: a click outside it, or another window took the keys.
    case panelResignedKey
}

enum IslandFocus {
    /// Whether `change` means the owner went elsewhere, so an open island folds back into the pill (P270): any app
    /// becoming active but the one that was in front when the island opened, whose notice can come just after an open
    /// that came after the switch (the island opened over it, and stays); and the panel losing its keys.
    static func ownerLeft(_ change: IslandFocusChange, frontAtOpen: pid_t?) -> Bool {
        switch change {
        case let .appActivated(pid): pid == nil || pid != frontAtOpen
        case .panelResignedKey: true
        }
    }
}

/// Reports `IslandFocusChange`s for the island's panel: `NSWorkspace.didActivateApplicationNotification` from the
/// workspace's center, and the panel's own `NSWindow.didResignKeyNotification`. Tests hand it centers of their own
/// and post fake notices. Nothing polls; `stop()` removes both observers.
@MainActor
final class IslandFocusWatch {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(window: NSWindow, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         local: NotificationCenter = .default, changed: @escaping @MainActor (IslandFocusChange) -> Void) {
        let activated = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                              queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { changed(.appActivated(pid)) }
        }
        observers.append((workspace, activated))
        let resigned = local.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { changed(.panelResignedKey) }
        }
        observers.append((local, resigned))
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    isolated deinit { stop() }
}

/// Whether the pointer on the island is the owner's (P271): it moved there. A still pointer the island opened under (a
/// finish's Done card or a request that opens under a pointer parked on the menu bar) is not, and holds nothing against
/// the owner going elsewhere. Moves are told from the pointer's place, so an entry AppKit makes up from the tracking
/// area as the panel grows under a still pointer never counts.
struct PointerEngagement: Equatable, Sendable {
    /// Moves shorter than this (points) are the same place.
    static let slop: CGFloat = 1

    private(set) var engaged = false
    private var last: CGPoint?

    /// A sample of the pointer (a tracking-area event, the poll, a read after a change), inside the island or not.
    mutating func sample(_ location: CGPoint, inside: Bool) {
        if !inside {
            engaged = false
        } else if let last {
            if hypot(location.x - last.x, location.y - last.y) >= Self.slop { engaged = true }
        } else {
            engaged = true
        }
        last = location
    }

    /// The island's shape moved under a still pointer (`IslandHoverMachine.Event.pointerRelocated`): the pointer is
    /// where it was, and not the owner's doing.
    mutating func relocated(to location: CGPoint) {
        engaged = false
        last = location
    }

    /// The island opened. By itself from the closed pill (`.attention`: a request, a finish's Done card), under a pointer
    /// that was already there: it is not the owner's until it moves, whatever it did before the open (a click on the
    /// pill and an Esc, the pointer left where it was). A rest or a click, or anything that came while the pointer
    /// rested on the pill (`fromClosed` false), keeps what the pointer did.
    mutating func opened(_ reason: IslandHoverMachine.OpenReason, fromClosed: Bool, at location: CGPoint) {
        guard reason == .attention, fromClosed else { return }
        relocated(to: location)
    }
}

/// The requests the island folded away from (P272): each stays on the pill ("!", "?") and opens the island again only
/// on hover or click, never by itself; a new request (another id) opens it as before. Kept per session, and forgotten
/// only once its session is in a batch and no longer waits on it: a batch the row is missing from (a Live model's
/// restart, a batch without it) forgets nothing. A close puts away what the island last heard, never a request the
/// engine has that no batch has brought yet (its first needs-you signal is still to come).
struct IslandPutAway: Equatable, Sendable {
    /// Session → the request put away (`IslandAttention.requestKey`).
    private(set) var keys: [String: String] = [:]
    /// Session → the request it waits on, in the last batch the island heard.
    private(set) var heard: [String: String] = [:]

    /// The island folded: what waited in the last batch it heard is put away.
    mutating func folded() { keys.merge(heard) { _, new in new } }

    /// What `sessions` waited on in the last batch the island heard is put away, the rest left as it is: a question held
    /// on the pill (Questions open the island off, P411).
    mutating func putAway(_ sessions: Set<String>) {
        keys.merge(heard.filter { sessions.contains($0.key) }) { _, new in new }
    }

    /// A batch the island heard (or the rows it found as it showed, with no signals): `pending`, its needs-you rows'
    /// request keys (`IslandAttention.pendingKeys`). A request put away is forgotten once its session is in `rows` and
    /// no longer waits on it. Returns `signals` without the needs-you signals of requests put away.
    mutating func hear(_ signals: [IslandSignal], rows: [SessionRow], pending: [String: String]) -> [IslandSignal] {
        heard = pending
        guard !keys.isEmpty else { return signals }
        let present = Set(rows.map(\.id))
        keys = keys.filter { session, key in !present.contains(session) || pending[session] == key }
        guard !keys.isEmpty else { return signals }
        return signals.filter { signal in
            guard case let .needsYou(id) = signal, let key = keys[id] else { return true }
            return pending[id] != key
        }
    }
}

extension IslandAttention {
    /// What a needs-you row waits on, as the island remembers it (P272): the engine request its card shows, else (a
    /// failed turn, a card with no engine behind it) the session and its status.
    static func requestKey(_ row: SessionRow, card: SessionCard?) -> String {
        if let id = card?.request?.id { return "request:\(id)" }
        return "row:\(row.id):\(row.status)"
    }

    /// The request keys of the rows that need you now.
    static func pendingKeys(_ rows: [SessionRow], card: (String) -> SessionCard?) -> [String: String] {
        var keys: [String: String] = [:]
        for row in rows where row.bucket == .needsYou { keys[row.id] = requestKey(row, card: card(row.id)) }
        return keys
    }
}
