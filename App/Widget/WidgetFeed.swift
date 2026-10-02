import Foundation
import Observation
import WidgetKit

/// When the app asks WidgetKit to draw the widget again (P340). WidgetKit gives an app that is not in front some 40 to
/// 70 reloads a day, and rows change every few seconds while agents work, so reloading on each change would spend the
/// day's budget within the hour and the widget would stop following what needs you. So: at once for what the owner
/// must see now (`WidgetSnapshot.urgentKey`: a request that comes or goes, the app quitting, a battery that changes its
/// kind), and at most once every five minutes for the rest (a title, a turn that starts or ends, a battery's percent),
/// in one reload after the last of them. Nothing waits while nothing changes.
struct WidgetReloadPolicy: Equatable, Sendable {
    static let floor: TimeInterval = 300

    enum Decision: Equatable, Sendable {
        case now
        /// A reload is due then (the floor since the last one), unless something urgent comes first.
        case at(Date)
    }

    private(set) var lastReload: Date?
    private(set) var reloadedKey: WidgetSnapshot.UrgentKey?

    /// What to do about a snapshot whose content changed.
    func decide(_ snapshot: WidgetSnapshot, at now: Date) -> Decision {
        guard let lastReload, snapshot.urgentKey == reloadedKey else { return .now }
        let due = lastReload.addingTimeInterval(Self.floor)
        return now >= due ? .now : .at(due)
    }

    mutating func reloaded(_ snapshot: WidgetSnapshot, at date: Date) {
        lastReload = date
        reloadedKey = snapshot.urgentKey
    }
}

/// Keeps the widget's snapshot current (spec §4.7): it follows the rows, the batteries and the glyph settings through
/// Observation (no timer: nothing runs while nothing changes), writes the snapshot when what the widget draws changed,
/// off the main thread, and asks WidgetKit to reload by `WidgetReloadPolicy`. At quit it writes the closed snapshot, so
/// the widget never shows rows nobody follows any more (P344). Only a build signed by the App Group's team runs one
/// (`WidgetFeed.app`, P342).
@MainActor
final class WidgetFeed {
    private let env: AppEnvironment
    private let store: WidgetStore
    private let reload: @Sendable () -> Void
    private let clock: @MainActor () -> Date
    private let queue = DispatchQueue(label: "com.ofengenden.juice.widget-snapshot", qos: .utility)
    private var policy = WidgetReloadPolicy()
    /// The last snapshot handed to the write queue.
    private(set) var last: WidgetSnapshot?
    private var deferred: Task<Void, Never>?
    private var running = false
    private var generation = 0

    init(env: AppEnvironment, store: WidgetStore, clock: @escaping @MainActor () -> Date = { Date() },
         reload: @escaping @Sendable () -> Void) {
        self.env = env
        self.store = store
        self.clock = clock
        self.reload = reload
    }

    /// The app's feed, or nil: in `swift test` and renders (no App Group in the bundle), and in a build its signature
    /// does not vouch for the group (ad hoc: every dev build), which macOS would stop with a prompt (P342).
    /// The container is asked for only once the signature allows it: on macOS asking may already create it.
    static func app(env: AppEnvironment, identity: WidgetIdentity? = .main, team: @autoclosure () -> String? = SigningTeam.current(),
                    store: (String) -> WidgetStore? = WidgetStore.appGroup,
                    reload: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: JuiceIslandWidget.kind) })
        -> WidgetFeed? {
        guard let identity, identity.allows(signingTeam: team()), let store = store(identity.appGroup) else { return nil }
        return WidgetFeed(env: env, store: store, reload: reload)
    }

    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        changed()
        observe()
    }

    /// Quit: the closed snapshot, written before this returns, and a reload.
    func stop() {
        guard running else { return }
        running = false
        generation &+= 1
        deferred?.cancel()
        deferred = nil
        let closed = WidgetSnapshot.closed(at: clock(), theme: env.settings.juiceTheme, appearance: env.settings.appearance)
        last = closed
        let store = store, reload = reload
        queue.sync {
            try? store.write(closed)
            reload()
        }
    }

    private func observe() {
        let generation = generation
        withObservationTracking {
            _ = env.sessions.rows
            _ = env.usage.panel
            _ = env.settings.glyphStyle
            _ = env.settings.glyphColour
            _ = env.settings.needsYouColour
            _ = env.settings.liquidRunning
            _ = env.settings.juiceTheme
            _ = env.settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == generation else { return }
                self.changed()
                self.observe()
            }
        }
    }

    /// The rows, the batteries, a glyph setting or the theme changed: a snapshot only when what the widget draws did.
    func changed() {
        let now = clock()
        let snapshot = WidgetSnapshot.make(env, at: now)
        guard !Self.sameContent(snapshot, last) else { return }
        last = snapshot
        let store = store, reload = reload
        switch policy.decide(snapshot, at: now) {
        case .now:
            deferred?.cancel()
            deferred = nil
            policy.reloaded(snapshot, at: now)
            queue.async {
                try? store.write(snapshot)
                reload()
            }
        case let .at(due):
            queue.async { try? store.write(snapshot) }
            guard deferred == nil else { return }
            let generation = generation
            deferred = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSince(now))))
                guard !Task.isCancelled, let self, self.running, self.generation == generation, let last = self.last else { return }
                self.deferred = nil
                self.policy.reloaded(last, at: self.clock())
                // Behind the write of `last` on the same queue.
                self.queue.async { reload() }
            }
        }
    }

    /// Whether two snapshots draw the same, whenever each was written.
    static func sameContent(_ a: WidgetSnapshot, _ b: WidgetSnapshot?) -> Bool {
        guard var b else { return false }
        b.written = a.written
        return a == b
    }

    /// Whether a reload is waiting for the floor (tests).
    var reloadPending: Bool { deferred != nil }

    /// Waits for the writes and reloads already handed to the queue (tests).
    func drain() { queue.sync {} }
}
