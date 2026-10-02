import Foundation
import Observation

/// Which rows Archive idle sessions after takes, and when (P727, P728): pure. Only a row Archive itself is offered on
/// (`SessionRow.canArchive`: done, nothing waiting) and that is done: never one that runs, delegates, stalls, waits on
/// the owner or failed (those are not done). Its age is its last event's (`updatedAt`), on the wall clock.
enum TidyRule {
    /// A timer fires a moment after its deadline (`WallClockTimer`'s leeway), never long before: this much early still
    /// counts as due.
    static let slack: TimeInterval = 1

    static func archivable(_ row: SessionRow) -> Bool { row.bucket == .done && row.canArchive }

    /// The rows due at `now` with `after` set, and the next moment another falls due (nil: none waits).
    static func plan(rows: [SessionRow], after: TimeInterval, now: Date) -> (due: [String], next: Date?) {
        var due: [String] = []
        var next: Date?
        for row in rows where archivable(row) {
            let lapse = row.updatedAt.addingTimeInterval(after)
            if lapse <= now.addingTimeInterval(slack) {
                due.append(row.id)
            } else if next.map({ lapse < $0 }) ?? true {
                next = lapse
            }
        }
        return (due, next)
    }
}

/// Settings › Island › Archive idle sessions after (Off, 2 days, 3 days, 1 week; 3 days, P727 to P729): a session done
/// or idle that long is archived as its Archive would (`SessionsModel.dismiss`, which takes only a finished session), so
/// it leaves the lists until its agent does something again, as an archived one does. Live sessions only: the demo's
/// are never archived. One timer, set for the next row's lapse only while one waits, on the wall clock (a Mac asleep
/// through it archives as it wakes); a batch of rows or a new choice plans again. Nothing ticks.
@MainActor
final class AutoTidy {
    /// The sessions are the live engine's (`LiveSessions.mode`); the demo's are left alone.
    var live: @MainActor () -> Bool = { true }

    private let sessions: any SessionsModel
    private let settings: AppSettings
    private let scheduler: any WallScheduling
    private let clock: @MainActor () -> Date
    private var timer: (any IslandTimerToken)?
    private var timerAt: Date?
    private var started = false

    init(sessions: any SessionsModel, settings: AppSettings, scheduler: any WallScheduling = WallClockScheduler(),
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.sessions = sessions
        self.settings = settings
        self.scheduler = scheduler
        self.clock = clock
    }

    /// Follows the rows and the choice from now on: the shell calls this once, at launch.
    func start() {
        guard !started else { return }
        started = true
        plan()
        observe()
    }

    /// A timer is set, and for when (tests: nothing waits with nothing to wait for).
    var isArmed: Bool { timer != nil }
    var armedFor: Date? { timerAt }

    private func observe() {
        withObservationTracking {
            _ = sessions.rows
            _ = settings.archiveIdleAfter
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.plan()
                self?.observe()
            }
        }
    }

    /// Archives what is due now and sets the one timer for the next lapse; Off, or the demo's sessions, sets none.
    func plan() {
        guard live(), let after = settings.archiveIdleAfter.seconds else { return cancel() }
        let plan = TidyRule.plan(rows: sessions.rows, after: after, now: clock())
        for id in plan.due { sessions.dismiss(id) }
        guard let next = plan.next else { return cancel() }
        guard next != timerAt || timer == nil else { return }
        cancel()
        timerAt = next
        timer = scheduler.schedule(at: next) { [weak self] in self?.fired() }
    }

    private func fired() {
        timer = nil
        timerAt = nil
        plan()
    }

    private func cancel() {
        timer?.cancel()
        timer = nil
        timerAt = nil
    }
}
