import Foundation

/// When drift checks run (spec §3.5, P26, P51): every profile at launch, on wake and when the profile list changes;
/// one profile 2 s after the last file event in its folder (`HookDriftSchedule`). It only decides when; `check` does
/// the reading (`ProfileHookManager.refresh(only:)` and `checkDrift`). Nothing here writes or repairs.
@MainActor
public final class HookDriftMonitor {
    public enum Reason: Equatable, Sendable {
        case launch
        case wake
        case profileChange
        case fileEvent
    }

    /// Starts watching one profile folder and calls back on any change; the returned token stops it when released
    /// or cancelled. The app passes `ConfigFolderWatcher`; tests pass a stand-in they fire by hand.
    public typealias Watch = @MainActor (ProfileHookTarget, @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)?
    /// Calls the closure after the delay (seconds). Tests run it on their own clock.
    public typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    public private(set) var targets: [ProfileHookTarget] = []
    /// Every check that ran, newest last (kept short), for Diagnostics and tests.
    public private(set) var recentChecks: [(reason: Reason, targetIDs: [String])] = []

    private let watch: Watch
    private let schedule: Schedule
    private let now: @Sendable () -> Date
    private let check: @MainActor ([ProfileHookTarget], Reason) async -> Void
    private var schedule2s = HookDriftSchedule()
    private var tokens: [String: any HookWatchToken] = [:]
    /// Due times that already have a wake-up waiting, so one quiet period never checks twice.
    private var pendingWakeUps: Set<Date> = []

    public init(watch: @escaping Watch, schedule: @escaping Schedule = HookDriftMonitor.sleepThenRun,
                now: @escaping @Sendable () -> Date = { Date() },
                check: @escaping @MainActor ([ProfileHookTarget], Reason) async -> Void) {
        self.watch = watch
        self.schedule = schedule
        self.now = now
        self.check = check
    }

    public nonisolated static func sleepThenRun(_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    /// At launch: watch every profile and check them all.
    public func launch(_ targets: [ProfileHookTarget]) async {
        rearm(targets)
        await run(targets, .launch)
    }

    /// After the Mac wakes: files may have changed while it slept.
    public func wake() async {
        await run(targets, .wake)
    }

    /// The profile list changed (an account added or removed, a folder found): watch the new list and check it all.
    public func profilesChanged(_ targets: [ProfileHookTarget]) async {
        rearm(targets)
        await run(targets, .profileChange)
    }

    /// A file event in one profile's folder. The check waits for 2 s without another event in that profile.
    public func fileChanged(_ targetID: String) {
        guard targets.contains(where: { $0.id == targetID }) else { return }
        let at = now()
        schedule2s.fileChanged(targetID, at: at)
        wakeUp(at: at.addingTimeInterval(HookDriftSchedule.quietPeriod), after: HookDriftSchedule.quietPeriod)
    }

    private func wakeUp(at dueAt: Date, after delay: TimeInterval) {
        guard pendingWakeUps.insert(dueAt).inserted else { return }
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.pendingWakeUps.remove(dueAt)
            Task { @MainActor in await self.runDue() }
        }
    }

    /// Checks the profiles whose files have been quiet for 2 s. A profile with a later event waits for its own wake-up.
    /// The sleep and `now` are different clocks, so a wake-up that finds its profile a hair short of 2 s by `now`
    /// wakes again shortly rather than leave the burst unchecked.
    func runDue() async {
        let due = Set(schedule2s.takeDue(now: now()))
        if let next = schedule2s.nextDue { wakeUp(at: next, after: max(0.05, next.timeIntervalSince(now()))) }
        let targets = self.targets.filter { due.contains($0.id) }
        guard !targets.isEmpty else { return }
        await run(targets, .fileEvent)
    }

    private func run(_ targets: [ProfileHookTarget], _ reason: Reason) async {
        guard !targets.isEmpty else { return }
        recentChecks.append((reason, targets.map(\.id)))
        if recentChecks.count > 20 { recentChecks.removeFirst(recentChecks.count - 20) }
        await check(targets, reason)
    }

    private func rearm(_ targets: [ProfileHookTarget]) {
        let old = Dictionary(self.targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.targets = targets
        let ids = Set(targets.map(\.id))
        for id in tokens.keys where !ids.contains(id) {
            tokens[id]?.cancel()
            tokens[id] = nil
        }
        for target in targets where tokens[target.id] == nil || old[target.id] != target {
            tokens[target.id]?.cancel()
            let id = target.id
            tokens[target.id] = watch(target) { [weak self] in self?.fileChanged(id) }
        }
    }

    /// Stops every watcher.
    public func stop() {
        for token in tokens.values { token.cancel() }
        tokens = [:]
    }
}

/// A running folder watch.
public protocol HookWatchToken: AnyObject {
    func cancel()
}
