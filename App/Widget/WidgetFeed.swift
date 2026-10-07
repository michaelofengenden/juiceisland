import Foundation
import Observation
import WidgetKit

/// When the app asks WidgetKit to draw one kind of widget again (P340, P1222). WidgetKit gives a widget some 40 to 70
/// reloads a day, and the rows change every few seconds while agents work, the batteries' percents every minute or two,
/// so reloading on each change would spend the day's budget within the hour and the widget would stop following. So:
/// at once for what the owner must see now (`WidgetKind.urgentKey`: for the sessions a request that comes or goes, for
/// the batteries one that changes its kind or the account in use, for both the app quitting), and at most once a floor
/// (`WidgetKind.floor`: five minutes for the sessions, fifteen for the batteries) for the rest, in one reload after the
/// last of them. Nothing waits while nothing changes. Each kind keeps its own: a session that starts reloads no battery.
struct WidgetReloadPolicy: Equatable, Sendable {
    let kind: WidgetKind

    enum Decision: Equatable, Sendable {
        case now
        /// A reload is due then (the floor since the last one), unless something urgent comes first.
        case at(Date)
    }

    private(set) var lastReload: Date?
    private(set) var reloadedKey: [String]?
    /// The routine reloads of the last day, for `WidgetKind.routinePerDay` (P1282).
    private(set) var routine: [Date] = []

    init(kind: WidgetKind = .sessions) { self.kind = kind }

    /// The sessions' floor (five minutes), which the policy kept before it had kinds.
    static var floor: TimeInterval { WidgetKind.sessions.floor }

    /// What to do about a snapshot whose content changed. Past the day's routine reloads, what is not urgent waits for the
    /// freshness reload (P1282).
    func decide(_ snapshot: WidgetSnapshot, at now: Date) -> Decision {
        guard let lastReload, kind.urgentKey(snapshot) == reloadedKey else { return .now }
        var due = lastReload.addingTimeInterval(kind.floor)
        if let cap = kind.routinePerDay, Self.within(routine, day: now).count >= cap {
            due = max(due, lastReload.addingTimeInterval(kind.freshAfter))
        }
        return now >= due ? .now : .at(due)
    }

    mutating func reloaded(_ snapshot: WidgetSnapshot, at date: Date) {
        let key = kind.urgentKey(snapshot)
        if kind.routinePerDay != nil, let lastReload, key == reloadedKey, date.timeIntervalSince(lastReload) < kind.freshAfter {
            routine = Self.within(routine, day: date) + [date]
        }
        lastReload = date
        reloadedKey = key
    }

    /// The dates less than a day before `day`.
    private static func within(_ dates: [Date], day: Date) -> [Date] {
        dates.filter { day.timeIntervalSince($0) < 86_400 }
    }
}

/// Keeps the widgets' snapshot current (spec §4.7): it follows the rows, the batteries, the money and the glyph settings
/// through Observation (no timer of its own: nothing runs while nothing changes), writes the snapshot when what either
/// widget draws changed, off the main thread, and asks WidgetKit to reload each kind by its own `WidgetReloadPolicy`.
/// While the app runs it writes the file again, with no reload, once it is `UsageFreshness.heartbeat` old, at the next
/// tick of the usage model's clock, so the Usage widget, which re-reads it within the hour, can tell a quiet app from a
/// gone one (P1223); and it reloads the Usage widget itself once its last reload is `UsageFreshness.appReloadAfter` old,
/// so a request of the widget's that WidgetKit put off never leaves it saying "Not updated" while the app runs (P1282).
/// At quit it writes the closed snapshot, so the widgets never show what nobody follows any more (P344). Only a build
/// signed by the App Group's team runs one (`WidgetFeed.app`, P342).
@MainActor
final class WidgetFeed {
    private let env: AppEnvironment
    private let store: WidgetStore
    private let reload: @Sendable (WidgetKind) -> Void
    private let clock: @MainActor () -> Date
    private let queue = DispatchQueue(label: "com.ofengenden.juice.widget-snapshot", qos: .utility)
    private var policies = Dictionary(uniqueKeysWithValues: WidgetKind.allCases.map { ($0, WidgetReloadPolicy(kind: $0)) })
    /// The last snapshot handed to the write queue.
    private(set) var last: WidgetSnapshot?
    private var deferred: [WidgetKind: Task<Void, Never>] = [:]
    private var running = false
    private var generation = 0

    init(env: AppEnvironment, store: WidgetStore, clock: @escaping @MainActor () -> Date = { Date() },
         reload: @escaping @Sendable (WidgetKind) -> Void) {
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
                    reload: @escaping @Sendable (WidgetKind) -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: $0.rawValue) })
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

    /// Quit: the closed snapshot, written before this returns, and a reload of both kinds.
    func stop() {
        guard running else { return }
        running = false
        generation &+= 1
        for task in deferred.values { task.cancel() }
        deferred.removeAll()
        let closed = WidgetSnapshot.closed(at: clock(), theme: env.settings.juiceTheme, appearance: env.settings.appearance,
                                           background: env.settings.widgetBackground)
        last = closed
        let store = store, reload = reload
        queue.sync {
            try? store.write(closed)
            for kind in WidgetKind.allCases { reload(kind) }
        }
    }

    private func observe() {
        let generation = generation
        withObservationTracking {
            _ = env.sessions.rows
            _ = env.usage.panel
            // The usage model's clock (every 5 s in the app): the heartbeat rides on it.
            _ = env.usage.now
            _ = env.settings.moneyShown
            _ = env.settings.glyphStyle
            _ = env.settings.glyphColour
            _ = env.settings.needsYouColour
            _ = env.settings.liquidRunning
            _ = env.settings.juiceTheme
            _ = env.settings.appearance
            _ = env.settings.widgetBackground
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == generation else { return }
                self.changed()
                self.observe()
            }
        }
    }

    /// The rows, the batteries, the money, a glyph setting, the theme or the widget background changed, or the clock
    /// ticked: a snapshot only when what a widget draws did, or when the last one is a heartbeat old.
    func changed() {
        let now = clock()
        let snapshot = WidgetSnapshot.make(env, at: now)
        let kinds = WidgetKind.allCases.filter { !$0.drawsSame(snapshot, last) }
        defer { freshen(at: now) }
        guard !kinds.isEmpty else {
            beat(snapshot, at: now)
            return
        }
        last = snapshot
        let store = store, reload = reload
        queue.async { try? store.write(snapshot) }
        for kind in kinds {
            switch policies[kind]!.decide(snapshot, at: now) {
            case .now:
                deferred[kind]?.cancel()
                deferred[kind] = nil
                policies[kind]!.reloaded(snapshot, at: now)
                // Behind the write on the same queue.
                queue.async { reload(kind) }
            case let .at(due):
                guard deferred[kind] == nil else { continue }
                let generation = generation
                deferred[kind] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSince(now))))
                    guard !Task.isCancelled, let self, self.running, self.generation == generation, let last = self.last else { return }
                    self.deferred[kind] = nil
                    self.policies[kind]!.reloaded(last, at: self.clock())
                    self.queue.async { reload(kind) }
                }
            }
        }
    }

    /// Nothing changed: the same snapshot again, newly dated, once the last write is a heartbeat old. No reload: the
    /// Usage widget reads it when WidgetKit next asks it for a timeline (P1223).
    private func beat(_ snapshot: WidgetSnapshot, at now: Date) {
        guard let written = last?.written, now.timeIntervalSince(written) >= UsageFreshness.heartbeat else { return }
        last = snapshot
        let store = store
        queue.async { try? store.write(snapshot) }
    }

    /// The Usage widget's freshness reload from the app's side (P1282): once its last reload is `appReloadAfter` old,
    /// whatever else changed meanwhile, the file it reads (never older than a heartbeat) is reloaded now, and a routine
    /// reload still waiting is no longer needed.
    private func freshen(at now: Date) {
        guard running, let last, let reloaded = policies[.usage]!.lastReload,
              now.timeIntervalSince(reloaded) >= UsageFreshness.appReloadAfter else { return }
        deferred[.usage]?.cancel()
        deferred[.usage] = nil
        policies[.usage]!.reloaded(last, at: now)
        let reload = reload
        queue.async { reload(.usage) }
    }

    /// Whether two snapshots draw the same in both widgets, whenever each was written.
    static func sameContent(_ a: WidgetSnapshot, _ b: WidgetSnapshot?) -> Bool {
        WidgetKind.allCases.allSatisfy { $0.drawsSame(a, b) }
    }

    /// Whether a reload of `kind` is waiting for its floor (tests).
    func reloadPending(_ kind: WidgetKind = .sessions) -> Bool { deferred[kind] != nil }

    /// Waits for the writes and reloads already handed to the queue (tests).
    func drain() { queue.sync {} }
}
