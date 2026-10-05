import CoreGraphics
import Foundation
import Observation

/// When the private app may install a build by itself (P1070 to P1073, P1075): a quiet moment, with no session waiting
/// on the owner (an approval, a plan or a question on a card), no sound of the app's playing, and no key typed in the
/// last minute. Pure.
enum QuietMoment {
    /// How long the keyboard must have been still.
    static let typingQuiet: TimeInterval = 60

    enum Verdict: Equatable {
        /// Install now.
        case now
        /// A card waits on the owner: again when the sessions change.
        case sessionsWait
        /// A sound of the app's plays (a signal's, a reminder's or a Play button's): again once it ends (P1075).
        case sound(until: Date)
        /// A key went down less than a minute ago: again at this moment.
        case typing(until: Date)
    }

    /// `soundUntil`: when the last sound the app started ends (`SystemSoundPlayer.playingUntil`), nil before the first.
    static func verdict(waiting: Int, sinceKey: TimeInterval, soundUntil: Date? = nil, now: Date) -> Verdict {
        if waiting > 0 { return .sessionsWait }
        if let soundUntil, soundUntil > now { return .sound(until: soundUntil) }
        if sinceKey < typingQuiet { return .typing(until: now.addingTimeInterval(typingQuiet - sinceKey)) }
        return .now
    }

    /// Seconds since a key last went down anywhere in this login session: a number the system keeps, read with no event
    /// monitor or tap and no permission (guardrail 4).
    static func secondsSinceKey() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
}

/// Settings › About › Install automatically, the private app's (P1070 to P1073): once a build prepared in the background
/// waits (Restart to update), it is installed through that same path (`UpdateController.installPrepared`) at the first
/// quiet moment (`QuietMoment`), and the build it opens says so (`WhatsNewCard`'s "Updated automatically"). It watches the
/// setting, the prepared build, the check's tip and the update's phase, and the sessions only while a build waits; a
/// sound or a typing pause is one wall-clock timer for the moment it ends. Nothing polls. The public flavor's feed has its
/// own (Sparkle's automatic install, `FeedUpdates`), so this does nothing there.
@MainActor
final class AutoInstall {
    private let settings: AppSettings
    private let controller: UpdateController
    private let checker: UpdateChecker
    private let sessions: any SessionsModel
    private let scheduler: any WallScheduling
    private let clock: @MainActor () -> Date
    private let sinceKey: @MainActor () -> TimeInterval
    private let soundUntil: @MainActor () -> Date?
    private var timer: (any IslandTimerToken)?
    private var started = false
    /// The prepared commit it last tried to install: a run that failed is not tried again for the same build while the
    /// app runs (Restart to update still can be clicked), so a failure never loops.
    private var tried: String?
    /// How many installs it started (tests).
    private(set) var attempts = 0

    init(settings: AppSettings, controller: UpdateController, checker: UpdateChecker, sessions: any SessionsModel,
         scheduler: any WallScheduling = WallClockScheduler(), clock: @escaping @MainActor () -> Date = { Date() },
         sinceKey: @escaping @MainActor () -> TimeInterval = { QuietMoment.secondsSinceKey() },
         soundUntil: @escaping @MainActor () -> Date? = { SystemSoundPlayer.playingUntil }) {
        self.settings = settings
        self.controller = controller
        self.checker = checker
        self.sessions = sessions
        self.scheduler = scheduler
        self.clock = clock
        self.sinceKey = sinceKey
        self.soundUntil = soundUntil
    }

    /// The app's: the private flavor's controller holds an automatic run's quit while a card waits on the owner or a sound
    /// of the app's plays (P1071, P1075); the public flavor's feed installs by itself (Sparkle), so it gets none.
    static func app(env: AppEnvironment) -> AutoInstall? {
        guard !env.flavor.isPublic else { return nil }
        let sessions = env.sessions
        env.updateController.quitWaits = { !sessions.waiting.isEmpty || SystemSoundPlayer.isPlaying() }
        return AutoInstall(settings: env.settings, controller: env.updateController, checker: env.updateChecker, sessions: sessions)
    }

    /// Follows what it depends on from now on: the shell calls this once, at launch.
    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    /// The timer for the end of a typing pause or a sound is set (tests).
    var isWaitingForTyping: Bool { timer != nil }

    private func observe() {
        let verdict = withObservationTracking { decide() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        act(verdict)
    }

    /// A build waits, and what stands in its way; nil when none waits (or the setting is off). Reads only what decides
    /// it, so the observation follows the sessions only while a build waits.
    private func decide() -> QuietMoment.Verdict? {
        guard settings.installAutomatically, controller.feed == nil, !controller.phase.isRunning,
              controller.restartOffered(for: checker.available), controller.prepared != tried else { return nil }
        return QuietMoment.verdict(waiting: sessions.waiting.count, sinceKey: sinceKey(), soundUntil: soundUntil(), now: clock())
    }

    /// Installs now, or waits: for the sessions (the observation brings it back), or for the sound or the minute to end.
    private func act(_ verdict: QuietMoment.Verdict?) {
        cancel()
        switch verdict {
        case .now?:
            tried = controller.prepared
            attempts += 1
            controller.installPrepared(automatic: true)
        case let .sound(until)?, let .typing(until)?:
            timer = scheduler.schedule(at: until) { [weak self] in
                guard let self else { return }
                self.timer = nil
                self.act(self.decide())
            }
        case .sessionsWait?, nil:
            break
        }
    }

    private func cancel() {
        timer?.cancel()
        timer = nil
    }
}
