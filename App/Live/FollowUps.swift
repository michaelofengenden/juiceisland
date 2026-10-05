import Foundation
import IslandEngine
import Observation

/// Settings › General › Remind again: how long after a request began to wait on the owner, or a turn of the owner's
/// finished, the one reminder comes (P410). Off by default.
enum FollowUpDelay: String, CaseIterable, Sendable {
    case off, oneMinute, twoMinutes, threeMinutes, fiveMinutes

    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .oneMinute: 60
        case .twoMinutes: 2 * 60
        case .threeMinutes: 3 * 60
        case .fiveMinutes: 5 * 60
        }
    }
}

/// What a reminder may come for, and since when (P410): pure, on the Mac's awake clock (the uptime clock stands still in
/// sleep, so a night asleep never counts, as P313). One item per session and kind: its head request while it waits on
/// the owner, and its last finished turn while the row still shows it. An item goes once it is reminded of, once the
/// owner looks, or once what it is about is gone (the request answered or replaced, the session running again); a
/// request reminded of or looked at is spent, and never armed again while it waits.
struct FollowUpBook: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case request, finish }

    struct Item: Equatable, Sendable {
        var session: String
        var kind: Kind
        /// A request's key (`IslandAttention.requestKey`); a finish's is its session's id.
        var key: String
        /// When it was armed, on the awake clock.
        var since: TimeInterval
    }

    /// A timer fires a moment after its deadline, never before; this much early still counts as due.
    static let slack: TimeInterval = 0.05

    private(set) var items: [Item] = []
    /// Request keys reminded of or looked at, while they still wait.
    private(set) var spent: Set<String> = []

    /// One batch. `waiting`: session → the request key of each row that waits on the owner and may be reminded of;
    /// `finished`: the sessions whose turn finished in this batch; `done`: the sessions whose row still shows a finished
    /// turn; `looking`: the owner looks at the island or the window now, so what arrives is seen at once.
    mutating func hear(waiting: [String: String], finished: [String], done: Set<String>, looking: Bool, now: TimeInterval) {
        spent.formIntersection(Set(waiting.values))
        let restarted = Set(finished)
        items.removeAll { item in
            switch item.kind {
            case .request: waiting[item.session] != item.key
            case .finish: !done.contains(item.session) || restarted.contains(item.session)
            }
        }
        for (session, key) in waiting.sorted(by: { $0.key < $1.key }) where !spent.contains(key) {
            guard !items.contains(where: { $0.kind == .request && $0.session == session }) else { continue }
            if looking { spent.insert(key) } else { items.append(Item(session: session, kind: .request, key: key, since: now)) }
        }
        guard !looking else { return }
        for session in finished where done.contains(session) {
            items.append(Item(session: session, kind: .finish, key: session, since: now))
        }
    }

    /// The owner looked: nothing that shows now is reminded of.
    mutating func looked() {
        spent.formUnion(items.filter { $0.kind == .request }.map(\.key))
        items.removeAll()
    }

    /// The owner went to one session (a jump, a banner's click).
    mutating func looked(session: String) {
        spent.formUnion(items.filter { $0.kind == .request && $0.session == session }.map(\.key))
        items.removeAll { $0.session == session }
    }

    /// When the next reminder is due, `delay` after the oldest item; nil with nothing armed.
    func deadline(after delay: TimeInterval) -> TimeInterval? {
        items.map(\.since).min().map { $0 + delay }
    }

    /// The items due at `now`: they go, and their requests are spent.
    mutating func due(now: TimeInterval, delay: TimeInterval) -> [Item] {
        let isDue: (Item) -> Bool = { $0.since + delay <= now + Self.slack }
        let due = items.filter(isDue)
        items.removeAll(where: isDue)
        spent.formUnion(due.filter { $0.kind == .request }.map(\.key))
        return due
    }

    mutating func reset() {
        items = []
        spent = []
    }
}

/// The one timer a reminder needs: set for the next deadline only while something is armed, and never at rest. The
/// app's is a strict main-queue timer, whose clock (`DispatchTime`) stands still in sleep as the awake clock does; tests
/// fire theirs by hand.
@MainActor
protocol FollowUpScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken
}

@MainActor
final class StrictFollowUpScheduler: FollowUpScheduler {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken {
        StrictTimer(after: seconds, fire)
    }
}

/// Settings › General › Remind again (P410): once, `followUpAfter` after a request began to wait on the owner, or a turn
/// of the owner's finished, while it still waits (or still shows finished) and the owner has not looked, the closed
/// pill's lead pulses once (`pulse`, `NudgePulse`) and its sound plays once: the Needs you or Question sound for a
/// request, the Done sound for a finish (None, the default, only pulses; P493). Mute and Quiet hours silence it, as every
/// sound (`SignalSounds`), and so does a lock with Quiet while locked on. A snooze drops it whole: no pulse, no sound (P724). The live engine's requests count only once
/// their needs-you signal went out (`released`): one it kept quiet (its tab in front, No alerts for focused sessions)
/// was never told of and is never reminded of (P494). Never again for the same request,
/// never for a subagent's request or thread, a scripted run (`remindable`) or a session a mute rule matches (P421), and
/// never for what the owner looked at: the island opened by the pointer, a click or a
/// key, the pointer on it, the window made key, a jump or a banner's click (`looked`), or what arrived while they looked
/// (`looking`). Nothing runs while the setting is off; while it is on, one one-shot timer is set only while something is
/// armed.
@MainActor
@Observable
final class FollowUps {
    /// Bumped by each reminder: the closed pill's lead pulses once.
    private(set) var pulse = 0

    @ObservationIgnored private(set) var book = FollowUpBook()
    /// The sessions the last reminder was for.
    @ObservationIgnored private(set) var reminded: [String] = []
    /// The owner looks at the island or the window now (the shell's; nobody looks in tests unless they say so).
    @ObservationIgnored var looking: @MainActor () -> Bool = { false }
    /// The sessions are the live engine's: the demo feed pulses the pill but never plays a sound, as its signals play
    /// none (`LiveSessions.released`).
    @ObservationIgnored var live: @MainActor () -> Bool = { true }
    /// The screen is locked or the owner's session switched out (`ScreenLockWatch.isAway`): with Quiet while locked on,
    /// a reminder then plays nothing, as every sound (P422).
    @ObservationIgnored var away: @MainActor () -> Bool = { false }
    /// The screen mirrored or a Focus that quiets (`QuietScenes`): a reminder then plays nothing, as every sound (P1005).
    @ObservationIgnored var scene: @MainActor () -> QuietScene = { .none }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sessions: any SessionsModel
    @ObservationIgnored private let sounds: any SoundPlaying
    @ObservationIgnored private let scheduler: any FollowUpScheduler
    @ObservationIgnored private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var timer: (any IslandTimerToken)?
    @ObservationIgnored private var timerDeadline: TimeInterval?
    @ObservationIgnored private var running = false
    /// Bumped at each switch on or off, so an observer left from an earlier run never runs again.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastRows: [SessionRow] = []
    @ObservationIgnored private var lastFinish: ReleasedFinish?
    /// The live engine's requests (`IslandAttention.requestKey`) whose needs-you signal went out while they wait.
    @ObservationIgnored private var releasedKeys: Set<String> = []

    init(sessions: any SessionsModel, settings: AppSettings, sounds: any SoundPlaying,
         scheduler: any FollowUpScheduler = StrictFollowUpScheduler(),
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.sessions = sessions
        self.settings = settings
        self.sounds = sounds
        self.scheduler = scheduler
        self.uptime = uptime
        self.clock = clock
    }

    /// Follows the setting from now on: the shell calls this once, at launch.
    func start() {
        guard !started else { return }
        started = true
        apply()
        observeSetting()
    }

    /// A row a reminder may come for: the owner's own session (not a scripted run or a subagent's thread, P254), and
    /// not a subagent's request waiting on its parent's row.
    static func remindable(_ row: SessionRow) -> Bool { !row.isQuiet && row.asker == nil }

    /// The owner looked at the island or the window: nothing that shows now is reminded of.
    func looked() {
        guard running, !book.items.isEmpty else { return }
        book.looked()
        reschedule()
    }

    /// The owner went to one session.
    func looked(sessionID: String) {
        guard running, book.items.contains(where: { $0.session == sessionID }) else { return }
        book.looked(session: sessionID)
        reschedule()
    }

    private func observeSetting() {
        withObservationTracking { _ = settings.followUpAfter } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.apply()
                self?.observeSetting()
            }
        }
    }

    /// On: what waits now is armed from now (nothing that finished before counts); a new delay moves the deadline. Off:
    /// everything is forgotten and the timer goes.
    func apply() {
        let on = settings.followUpAfter.seconds != nil
        if on, !running {
            running = true
            generation &+= 1
            lastRows = sessions.rows
            if case let .engine(last) = sessions.finishSource { lastFinish = last } else { lastFinish = nil }
            hear(lastRows, finished: [])
            observeSessions()
        } else if !on, running {
            running = false
            generation &+= 1
            book.reset()
            releasedKeys = []
            cancelTimer()
        } else if on {
            reschedule()
        }
    }

    private func observeSessions() {
        let generation = generation
        withObservationTracking {
            _ = sessions.rows
            _ = sessions.finishSource
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == generation else { return }
                self.sessionsChanged()
                self.observeSessions()
            }
        }
    }

    /// A batch of rows: finishes as the island hears them (the live engine's Done, after its hold and the focused-tab
    /// check, or a row that turned done in the demo), and what waits.
    func sessionsChanged() {
        guard running else { return }
        let rows = sessions.rows
        let source = sessions.finishSource
        let signals = IslandAttention.signals(old: lastRows, new: rows, source: source, seen: lastFinish)
        if case let .engine(last) = source { lastFinish = last }
        lastRows = rows
        let finished = signals.compactMap { signal -> String? in if case let .finished(id) = signal { id } else { nil } }
        hear(rows, finished: finished)
    }

    /// A row a reminder may come for now: `remindable`, and no mute rule matches it (P421).
    private func remindable(_ row: SessionRow) -> Bool {
        Self.remindable(row) && (settings.muteRules.isEmpty || !settings.muteRules.mutes(row))
    }

    /// A needs-you signal the live engine let out (`LiveSessions.onReleased`): the request its session waits on now may be
    /// reminded of.
    func released(_ signal: EngineSignal) {
        guard running, case let .needsYou(id) = signal else { return }
        let rows = sessions.rows
        guard let row = rows.first(where: { $0.id == id }), row.bucket == .needsYou else { return }
        releasedKeys.insert(IslandAttention.requestKey(row, card: sessions.card(for: id)))
        hear(rows, finished: [])
    }

    /// The live engine tells which requests it let out; the demo's rows are all told of.
    private var gatesOnRelease: Bool {
        if case .engine = sessions.finishSource { return true }
        return false
    }

    private func hear(_ rows: [SessionRow], finished: [String]) {
        let eligible = rows.filter(remindable)
        var waiting = IslandAttention.pendingKeys(eligible) { sessions.card(for: $0) }
        if gatesOnRelease {
            releasedKeys.formIntersection(Set(waiting.values))
            let armed = Set(book.items.filter { $0.kind == .request }.map(\.key))
            waiting = waiting.filter { releasedKeys.contains($0.value) || armed.contains($0.value) }
        }
        let done = Set(eligible.filter { $0.bucket == .done && !$0.isInterrupted }.map(\.id))
        book.hear(waiting: waiting, finished: finished, done: done, looking: looking(), now: uptime())
        reschedule()
    }

    /// One timer, for the next deadline, only while something is armed; unchanged while the deadline is.
    private func reschedule() {
        guard running, let delay = settings.followUpAfter.seconds, let deadline = book.deadline(after: delay) else {
            cancelTimer()
            return
        }
        guard deadline != timerDeadline || timer == nil else { return }
        cancelTimer()
        timerDeadline = deadline
        timer = scheduler.schedule(after: max(0, deadline - uptime())) { [weak self] in self?.fire() }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerDeadline = nil
    }

    /// The deadline passed: what is due and still so is reminded of once, with one pulse and one sound however many are
    /// due together; the owner looking right now counts as having looked.
    func fire() {
        timer = nil
        timerDeadline = nil
        guard running, let delay = settings.followUpAfter.seconds else { return }
        if looking() { book.looked() }
        let due = book.due(now: uptime(), delay: delay)
        let rows = sessions.rows
        let still = due.filter { item in
            guard let row = rows.first(where: { $0.id == item.session }), remindable(row) else { return false }
            switch item.kind {
            case .request:
                return row.bucket == .needsYou && IslandAttention.requestKey(row, card: sessions.card(for: row.id)) == item.key
            case .finish:
                return row.bucket == .done && !row.isInterrupted
            }
        }
        // Snoozed: what was due is spent with no pulse and no sound, as if the owner had looked (P724).
        if QuietMode.snoozed(settings, now: clock()) {
            reschedule()
            return
        }
        if let first = still.first(where: { $0.kind == .request }) ?? still.first {
            reminded = still.map(\.session)
            pulse &+= 1
            // A request's reminder plays its first signal's sound (the Question sound for a question, P425), a finish's
            // the Done sound (P493); with both due, the request's.
            let signal: EngineSignal = first.kind == .request ? .needsYou(sessionID: first.session) : .done(sessionID: first.session)
            let isQuestion = first.kind == .request && rows.first { $0.id == first.session }.map(QuestionsOpen.isQuestion) == true
            if live(), let name = SignalSounds.sound(for: signal, isCodexAppThread: false, stillNeedsYou: true,
                                             isQuestion: isQuestion, away: away(), scene: scene(), settings: settings, now: clock()) {
                sounds.play(name, volume: SignalSounds.volume(settings))
            }
        }
        reschedule()
    }

    /// The timer is set (tests: nothing ticks at rest).
    var isArmed: Bool { timer != nil }
}
