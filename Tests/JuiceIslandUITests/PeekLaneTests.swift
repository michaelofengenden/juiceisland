import Foundation
@testable import IslandEngine
import OpenIslandCore
import Observation
import Testing
@testable import JuiceIslandUI

// Lane PEEK (P720 to P729): live work in the peek, Snooze, and Archive idle sessions after. Clocks and timers are the
// tests' own fakes: nothing ticks, plays, opens or archives anything outside them.

/// A sessions model whose rows and work the test sets; Archive takes a finished row out, as the engine's does.
@MainActor
@Observable
final class LaneSessions: SessionsModel {
    var rows: [SessionRow] = []
    var works: [String: SessionWork] = [:]
    private(set) var dismissed: [String] = []
    var now: Date { DemoClock.now }

    func card(for sessionID: String) -> SessionCard? { nil }
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) {}
    func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool { false }
    func reply(_ sessionID: String, text: String) {}
    func jump(_ sessionID: String) {}
    func jumpToNextNeedsYou() {}
    func dismiss(_ sessionID: String) {
        guard let row = row(id: sessionID), row.canArchive else { return }
        dismissed.append(sessionID)
        rows.removeAll { $0.id == sessionID }
    }
    func work(_ sessionID: String) -> SessionWork? { works[sessionID] }
}

/// The wall-clock timers by hand: `advance(to:)` fires what is due; nothing runs by itself.
@MainActor
final class FakeWallScheduler: WallScheduling {
    final class Token: IslandTimerToken {
        let at: Date
        let fire: @MainActor @Sendable () -> Void
        var cancelled = false
        var fired = false
        init(at: Date, fire: @escaping @MainActor @Sendable () -> Void) {
            self.at = at
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    private(set) var tokens: [Token] = []

    func schedule(at date: Date, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken {
        let token = Token(at: date, fire: fire)
        tokens.append(token)
        return token
    }

    var pending: [Token] { tokens.filter { !$0.cancelled && !$0.fired } }

    func advance(to date: Date) {
        for token in pending where token.at <= date {
            token.fired = true
            token.fire()
        }
    }
}

/// A clock the test moves.
@MainActor
final class LaneClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Lets the observers' tasks run.
@MainActor
func laneSettle(_ done: @MainActor () -> Bool = { false }) async {
    for _ in 0..<50 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
}

// MARK: Snooze (P724 to P726)

@MainActor
@Suite(.serialized)
struct SnoozeTests {
    typealias Q = QuietModeTests

    /// An hour on; "until tomorrow" is the next 08:00, today's while it is not yet 08:00, across a clock change too.
    @Test func theEndsAreAnHourOnAndTheNextMorning() {
        let calendar = Q.berlin
        #expect(Snooze.end(.hour, now: Q.at(14, 32), calendar: calendar) == Q.at(15, 32))
        #expect(Snooze.end(.tomorrow, now: Q.at(14, 32), calendar: calendar) == Q.at(8, day: 28))
        #expect(Snooze.end(.tomorrow, now: Q.at(1, 30), calendar: calendar) == Q.at(8))
        #expect(Snooze.end(.tomorrow, now: Q.at(8), calendar: calendar) == Q.at(8, day: 28))
        // The night summer time ends in Berlin (25 October 2026): still 08:00 on the wall clock.
        #expect(Snooze.end(.tomorrow, now: Q.at(23, day: 24, month: 10), calendar: calendar) == Q.at(8, day: 25, month: 10))
        #expect(Snooze.isOn(Q.at(15), now: Q.at(14, 59)))
        #expect(!Snooze.isOn(Q.at(15), now: Q.at(15)))
        #expect(!Snooze.isOn(nil, now: Q.at(15)))
    }

    /// The menu: the two choices; while muted, when it ends and Unmute first. Every line in plain words, and the
    /// morning's choice says its end: before 08:00 it ends today, so a "tomorrow" could be minutes long.
    @Test func theMenuSaysWhereTheSnoozeStands() {
        let locale = Locale(identifier: "en_GB"), zone = Q.berlin.timeZone
        func titles(_ items: [Snooze.Item], _ locale: Locale = locale) -> [String] {
            items.map { $0.title(locale: locale, timeZone: zone) }
        }
        #expect(titles(Snooze.items(until: nil, now: Q.at(12), locale: locale, timeZone: zone)) == ["Mute for 1 hour", "Mute until 08:00"])
        #expect(titles(Snooze.items(until: Q.at(11), now: Q.at(12), locale: locale, timeZone: zone))
                == ["Mute for 1 hour", "Mute until 08:00"])
        #expect(titles([.mute(.tomorrow)], Locale(identifier: "en_US")) == ["Mute until 8:00\u{202F}AM"]
                || titles([.mute(.tomorrow)], Locale(identifier: "en_US")) == ["Mute until 8:00 AM"])
        let muted = Snooze.items(until: Q.at(14, 32), now: Q.at(12), locale: locale, timeZone: zone)
        #expect(titles(muted) == ["Muted until 14:32", "Unmute", "Mute for 1 hour", "Mute until 08:00"])
        #expect(muted.first == .header("Muted until 14:32"))
        let settings = AppSettings.ephemeral()
        Snooze.perform(.mute(.hour), settings: settings, now: Q.at(12), calendar: Q.berlin)
        #expect(settings.snoozedUntil == Q.at(13))
        Snooze.perform(.mute(.tomorrow), settings: settings, now: Q.at(12), calendar: Q.berlin)
        #expect(settings.snoozedUntil == Q.at(8, day: 28))
        Snooze.perform(.unmute, settings: settings, now: Q.at(12))
        #expect(settings.snoozedUntil == nil)
        #expect(titles(muted).allSatisfy { !$0.contains("\u{2014}") })
    }

    /// The gear's menu, the same in the island and the window, carries the snooze too: Window mode has no pill or header
    /// to right-click, so a snooze set on the island is seen and ended there.
    @Test func theGearCarriesTheSnooze() {
        let locale = Locale(identifier: "en_GB"), zone = Q.berlin.timeZone
        let snooze = Snooze.items(until: Q.at(14, 32), now: Q.at(12), locale: locale, timeZone: zone)
        for showing in [ShowAs.window, .island] {
            let items = GearMenu.items(showing: showing, updateTitle: nil, updateEnabled: false, soundsMuted: false, snooze: snooze,
                                       locale: locale, timeZone: zone)
            let titles = items.map { $0?.title }
            let start = titles.firstIndex(of: "Mute Sounds")!
            #expect(Array(titles[start...]) == ["Mute Sounds", nil, "Muted until 14:32", "Unmute", "Mute for 1 hour", "Mute until 08:00", nil,
                                                "Settings…", "Quit Juice Island"])
            #expect(items[start + 2]?.isEnabled == false && items[start + 3]?.action == .snooze(.unmute))
        }
        let env = AppEnvironment.demo()
        GearMenu.perform(.snooze(.mute(.hour)), env: env)
        #expect(env.settings.snoozedUntil != nil)
        let actions = GearMenu.items(env: env, showing: .window).compactMap { $0?.action }
        #expect(actions.contains(.snooze(.unmute)))
        GearMenu.perform(.snooze(.unmute), env: env)
        #expect(env.settings.snoozedUntil == nil)
    }

    /// While snoozed: no sound of any kind, attention held (nothing opens the island, no banner, no notice); at its end
    /// both come back, with no timer read.
    @Test func whileSnoozedNothingSoundsOrOpens() {
        let settings = AppSettings.ephemeral()
        settings.snoozedUntil = Q.at(13)
        for signal in [EngineSignal.needsYou(sessionID: "a"), .done(sessionID: "a")] {
            #expect(SignalSounds.sound(for: signal, isCodexAppThread: false, settings: settings, now: Q.at(12, 59)) == nil)
        }
        #expect(QuietMode.holdsAttention(settings, fullScreen: false, now: Q.at(12, 59)))
        #expect(QuietMode.snoozed(settings, now: Q.at(12, 59)))
        // A batch while quiet: nothing opens, a finish is Glance's dot, what waits is put away (it stays on the pill).
        let batch = QuietMode.quieted([.needsYou("a"), .finished("b"), .stalled("c")], finish: .card, quiet: true)
        #expect(batch.signals == [.finished("b")] && batch.finish == .glance && batch.putsAway)
        #expect(SignalSounds.sound(for: .needsYou(sessionID: "a"), isCodexAppThread: false, settings: settings, now: Q.at(13)) == "Glass")
        #expect(!QuietMode.holdsAttention(settings, fullScreen: false, now: Q.at(13)))
    }

    /// A reminder that falls due while snoozed neither pulses nor plays, and is spent.
    @Test func noNudgeWhileSnoozed() {
        let settings = NoticeFixtures.settings()
        settings.snoozedUntil = Q.at(13)
        let rig = FollowUpsTests.Rig(settings: settings, rows: [NoticeFixtures.waiting("a")],
                                     cards: ["a": NoticeFixtures.approval("a", request: "A1")], clock: Q.at(12))
        rig.followUps.start()
        rig.scheduler.advance(by: 60)
        #expect(rig.followUps.pulse == 0 && rig.player.played.isEmpty && rig.scheduler.pending.isEmpty)
    }

    /// One timer at the end, none without one; at the end the setting clears (the pill's moon goes); one already past at
    /// launch is cleared at once; a new end moves the timer.
    @Test func oneTimerClearsItAtItsEnd() async {
        let settings = AppSettings.ephemeral()
        let scheduler = FakeWallScheduler()
        let clock = LaneClock(Q.at(12))
        let end = SnoozeEnd(settings: settings, scheduler: scheduler, clock: { clock.now })
        end.start()
        #expect(!end.isArmed && scheduler.tokens.isEmpty)
        settings.snoozedUntil = Q.at(13)
        await laneSettle { end.isArmed }
        #expect(scheduler.pending.map(\.at) == [Q.at(13)])
        settings.snoozedUntil = Q.at(8, day: 28)
        await laneSettle { scheduler.pending.first?.at == Q.at(8, day: 28) }
        #expect(scheduler.pending.map(\.at) == [Q.at(8, day: 28)])
        clock.now = Q.at(8, day: 28)
        scheduler.advance(to: clock.now)
        #expect(settings.snoozedUntil == nil)
        await laneSettle()
        #expect(!end.isArmed && scheduler.pending.isEmpty)
        // Unmute: the timer goes.
        settings.snoozedUntil = Q.at(9, day: 28)
        await laneSettle { end.isArmed }
        settings.snoozedUntil = nil
        await laneSettle { !end.isArmed }
        #expect(scheduler.pending.isEmpty)
        // Past at launch.
        let stale = AppSettings.ephemeral()
        stale.snoozedUntil = Q.at(11)
        SnoozeEnd(settings: stale, scheduler: FakeWallScheduler(), clock: { clock.now }).start()
        #expect(stale.snoozedUntil == nil)
    }

    /// The end is kept in the defaults: a relaunch reads it back.
    @Test func aSnoozeSurvivesARelaunch() throws {
        let suite = "ji.tests.snooze.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(defaults: defaults, identity: .development)
        #expect(first.snoozedUntil == nil)
        first.snoozedUntil = Q.at(13)
        #expect(AppSettings(defaults: defaults, identity: .development).snoozedUntil == Q.at(13))
        first.snoozedUntil = nil
        #expect(AppSettings(defaults: defaults, identity: .development).snoozedUntil == nil)
    }

    /// The pill's moon joins a pill that shows something, after the count and the update dot, and widens its wing by
    /// the moon and a gap; an idle pill stays the notch.
    @Test func theMoonJoinsAPillThatShowsSomething() {
        let notch = IslandTheme.Metrics.referenceNotch
        let lead = PillLead(glyph: .eq, agent: .claude, state: .running)
        let plain = PillContent.make(lead: lead, count: 2, glance: false, style: .pixel, edgeLine: false, notch: notch, menuBar: 33)
        let muted = PillContent.make(lead: lead, count: 2, glance: false, snoozed: true, style: .pixel, edgeLine: false, notch: notch, menuBar: 33)
        #expect(muted.snoozed && !plain.snoozed)
        #expect(muted.countBlockWidth == plain.countBlockWidth + ClosedPillView.dotGap + ClosedPillView.snoozeMarkSize)
        #expect(muted.rightWing > plain.rightWing && muted.leftWing == plain.leftWing)
        let idle = PillContent.make(lead: nil, count: nil, glance: false, snoozed: true, style: .pixel, edgeLine: false, notch: notch, menuBar: 33)
        #expect(!idle.snoozed && idle.isEmpty && idle.extent == PillContent.make(lead: nil, count: nil, glance: false, style: .pixel,
                                                                                      edgeLine: false, notch: notch, menuBar: 33).extent)
        // From the settings: the moon while a snooze is set.
        let settings = AppSettings.ephemeral()
        settings.snoozedUntil = Q.at(13)
        let rows = [DStub.row("r", .claude, .running)]
        #expect(PillContent.make(rows: rows, settings: settings, glance: false, recentlyFinished: nil, now: DemoClock.now, notch: notch,
                                 menuBar: 33).snoozed)
        settings.snoozedUntil = nil
        #expect(!PillContent.make(rows: rows, settings: settings, glance: false, recentlyFinished: nil, now: DemoClock.now, notch: notch,
                                  menuBar: 33).snoozed)
    }
}

// MARK: Archive idle sessions after (P727 to P729)

@MainActor
@Suite(.serialized)
struct AutoTidyTests {
    static let day: TimeInterval = 86_400

    static func row(_ id: String, _ bucket: SessionBucket, idle: TimeInterval, now: Date, delegating: Bool = false,
                    failed: Bool = false) -> SessionRow {
        var row = DStub.row(id, .claude, bucket)
        row.updatedAt = now.addingTimeInterval(-idle)
        if delegating { row.glyph = .agents; row.glyphState = .delegating; row.status = .subagents(1) }
        if failed { row.glyph = .cross; row.hasCard = false }
        return row
    }

    /// More than a day, 3 days by default; Off sets nothing.
    @Test func theChoicesAndTheDefault() {
        #expect(AppSettings.ephemeral().archiveIdleAfter == .threeDays)
        #expect(ArchiveAfter.allCases.map(\.label) == ["Off", "2 days", "3 days", "1 week"])
        #expect(ArchiveAfter.allCases.compactMap(\.seconds).allSatisfy { $0 > Self.day })
        #expect(ArchiveAfter.off.seconds == nil)
    }

    /// Only a done row that long, never one that runs, delegates, stalls, waits or failed; the next lapse is the soonest.
    @Test func theRuleTakesOnlyDoneRows() {
        let now = DemoClock.now
        let rows = [
            Self.row("done-old", .done, idle: 4 * Self.day, now: now),
            Self.row("done-new", .done, idle: 2 * Self.day, now: now),
            Self.row("done-newer", .done, idle: 1 * Self.day, now: now),
            Self.row("running-old", .running, idle: 9 * Self.day, now: now),
            Self.row("delegating-old", .running, idle: 9 * Self.day, now: now, delegating: true),
            Self.row("waiting-old", .needsYou, idle: 9 * Self.day, now: now),
            Self.row("failed-old", .needsYou, idle: 9 * Self.day, now: now, failed: true),
        ]
        let plan = TidyRule.plan(rows: rows, after: 3 * Self.day, now: now)
        #expect(plan.due == ["done-old"])
        #expect(plan.next == now.addingTimeInterval(Self.day))
        #expect(TidyRule.plan(rows: rows, after: 7 * Self.day, now: now).due.isEmpty)
        // An interrupted turn (idle) is done too.
        var idle = Self.row("idle", .done, idle: 5 * Self.day, now: now)
        idle.glyphState = .idle
        #expect(TidyRule.plan(rows: [idle], after: 3 * Self.day, now: now).due == ["idle"])
    }

    @MainActor struct Rig {
        let sessions = LaneSessions()
        let settings = AppSettings.ephemeral()
        let scheduler = FakeWallScheduler()
        let clock: LaneClock
        let tidy: AutoTidy

        init(rows: [SessionRow], now: Date = DemoClock.now) {
            sessions.rows = rows
            let clock = LaneClock(now)
            self.clock = clock
            tidy = AutoTidy(sessions: sessions, settings: settings, scheduler: scheduler, clock: { clock.now })
        }
    }

    /// At launch what is due goes at once; one timer waits for the next lapse, and archives that row when it comes.
    @Test func oneCheckAtTheNextLapse() async {
        let now = DemoClock.now
        let rig = Rig(rows: [Self.row("old", .done, idle: 4 * Self.day, now: now), Self.row("new", .done, idle: 2 * Self.day, now: now),
                             Self.row("busy", .running, idle: 9 * Self.day, now: now)])
        rig.tidy.start()
        #expect(rig.sessions.dismissed == ["old"])
        #expect(rig.scheduler.pending.map(\.at) == [now.addingTimeInterval(Self.day)])
        await laneSettle()
        // The batch the archive made planned again: still one timer, for the same moment.
        #expect(rig.scheduler.pending.count == 1)
        rig.clock.now = now.addingTimeInterval(Self.day)
        rig.scheduler.advance(to: rig.clock.now)
        #expect(rig.sessions.dismissed == ["old", "new"])
        await laneSettle()
        #expect(!rig.tidy.isArmed && rig.scheduler.pending.isEmpty)
        #expect(rig.sessions.rows.map(\.id) == ["busy"])
    }

    /// A row that runs again is no longer waited for; Off forgets the timer; a longer choice moves it.
    @Test func batchesAndChoicesPlanAgain() async {
        let now = DemoClock.now
        let rig = Rig(rows: [Self.row("a", .done, idle: 2 * Self.day, now: now)])
        rig.tidy.start()
        #expect(rig.tidy.armedFor == now.addingTimeInterval(Self.day))
        rig.settings.archiveIdleAfter = .oneWeek
        await laneSettle { rig.tidy.armedFor == now.addingTimeInterval(5 * Self.day) }
        #expect(rig.scheduler.pending.map(\.at) == [now.addingTimeInterval(5 * Self.day)])
        rig.settings.archiveIdleAfter = .off
        await laneSettle { !rig.tidy.isArmed }
        #expect(rig.scheduler.pending.isEmpty)
        rig.settings.archiveIdleAfter = .threeDays
        await laneSettle { rig.tidy.isArmed }
        rig.sessions.rows = [Self.row("a", .running, idle: 0, now: now)]
        await laneSettle { !rig.tidy.isArmed }
        #expect(rig.scheduler.pending.isEmpty && rig.sessions.dismissed.isEmpty)
    }

    /// The demo's sessions are never archived.
    @Test func neverTheDemos() {
        let now = DemoClock.now
        let rig = Rig(rows: [Self.row("old", .done, idle: 30 * Self.day, now: now)])
        rig.tidy.live = { false }
        rig.tidy.start()
        #expect(rig.sessions.dismissed.isEmpty && !rig.tidy.isArmed)
    }

    /// What a relaunch restores: sessions that are not hook-managed. One finished 4 days ago whose terminal tab is still
    /// open (its process alive) leaves the rows on the real engine's Archive, keeps its age and is not active; a prompt
    /// brings it back. A hook-managed one leaves as well.
    @Test func aRestoredSessionLeavesTheEnginesRows() async throws {
        let now = DemoClock.now
        let finished = now.addingTimeInterval(-4 * Self.day)
        func restored(_ id: String, hooked: Bool) -> AgentSession {
            var session = AgentSession(id: id, title: "Claude · project", tool: .claudeCode, phase: .completed, summary: "Done.",
                                       updatedAt: finished, claudeMetadata: ClaudeSessionMetadata(lastUserPrompt: "fix the tests"))
            session.isProcessAlive = true
            session.isHookManaged = hooked
            return session
        }
        let engine = SessionEngine.preview(clock: { now })
        engine.state = SessionState(sessions: [restored("tab", hooked: false), restored("hooked", hooked: true)])
        let model = EngineSessionsModel(engine: engine, clock: { now })
        #expect(Set(model.rows.map(\.id)) == ["tab", "hooked"])
        let tidy = AutoTidy(sessions: model, settings: AppSettings.ephemeral(), scheduler: FakeWallScheduler(), clock: { now })
        tidy.start()
        #expect(model.rows.isEmpty)
        #expect(engine.rows.isEmpty)
        #expect(engine.state.session(id: "tab")?.updatedAt == finished)
        #expect(PillSummary.make(rows: model.rows, countMode: .active, now: now).count == nil)
        await laneSettle()
        #expect(!tidy.isArmed && model.rows.isEmpty)
        // Its agent does something again: back in the rows, as a new prompt brings back an archived one.
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "tab", summary: FixtureSessionFeed.promptPrefix + "go on",
                                                              phase: .running, timestamp: now)), ingress: .bridge)
        #expect(model.rows.map(\.id) == ["tab"])
    }
}

// MARK: Live work in the peek (P720 to P723)

@MainActor
@Suite(.serialized)
struct PeekWorkTests {
    typealias ID = FixtureSessionFeed.RowsID

    static let steps: [SessionWork.Step] = [.init("Find the reads", .done), .init("Add the store", .done),
                                            .init("Move the reads", .current), .init("Delete the shims", .pending)]

    /// The checklist takes the row's "2/5" out of the Clean peek's facts; the thought shows only while the row runs; a
    /// finished list says nothing.
    @Test func theChecklistReplacesTheProgressInThePeek() throws {
        var row = DStub.row("r", .codex, .running)
        row.facts = RowFacts(model: "GPT-6 Astra", progress: "2/4")
        let work = SessionWork(thinking: .init(title: "Weighing", text: "Two ways."), steps: Self.steps)
        let peek = try #require(SessionPeek.make(row: row, clean: true, prompt: nil, reply: nil, replyIsCurrent: true, read: nil, work: work))
        #expect(peek.steps == Self.steps && peek.thinking?.title == "Weighing")
        #expect(peek.facts.progress == nil && peek.facts.model == "GPT-6 Astra")
        var done = row
        done.bucket = .done
        let finished = try #require(SessionPeek.make(row: done, clean: true, prompt: nil, reply: nil, replyIsCurrent: true, read: nil, work: work))
        #expect(finished.thinking == nil && finished.steps == Self.steps)
        let allDone = SessionWork(steps: Self.steps.map { .init($0.text, .done) })
        let closed = try #require(SessionPeek.make(row: row, clean: true, prompt: nil, reply: nil, replyIsCurrent: true, read: nil, work: allDone))
        #expect(closed.steps.isEmpty && closed.facts.progress == "2/4")
        // Detailed rows say their own progress; their peek shows the list and no facts.
        let detailed = try #require(SessionPeek.make(row: row, clean: false, prompt: nil, reply: nil, replyIsCurrent: true, read: nil, work: work))
        #expect(detailed.steps == Self.steps && detailed.facts.isEmpty)
        // A peek with only its work to say still shows.
        var bare = DStub.row("b", .codex, .running)
        bare.lastPrompt = nil
        #expect(SessionPeek.make(row: bare, clean: false, prompt: nil, reply: nil, replyIsCurrent: true, read: nil, work: work) != nil)
        #expect(SessionPeek.make(row: bare, clean: false, prompt: nil, reply: nil, replyIsCurrent: true, read: nil, work: nil) == nil)
    }

    /// Claude's live task list wins over its transcript's todos; with none, the todos show.
    @Test func theTodosShowWhenNoLiveListDoes() throws {
        let row = DStub.row("c", .claude, .running)
        let read = SessionPeekRead(todos: [.init("Fix the guard", .current), .init("Add a test", .pending)])
        let fromTodos = try #require(SessionPeek.make(row: row, clean: false, prompt: nil, reply: nil, replyIsCurrent: false, read: read))
        #expect(fromTodos.steps.map(\.text) == ["Fix the guard", "Add a test"])
        let live = try #require(SessionPeek.make(row: row, clean: false, prompt: nil, reply: nil, replyIsCurrent: false, read: read,
                                                 work: SessionWork(steps: Self.steps)))
        #expect(live.steps == Self.steps)
        var peek = live
        peek.take(work: nil, running: true)
        #expect(peek.steps.map(\.text) == ["Fix the guard", "Add a test"])
    }

    /// At most six lines: a window around the current step, one before it, a line for what it leaves out each side.
    @Test func aLongListShowsAWindow() {
        func steps(_ count: Int, current: Int) -> [SessionWork.Step] {
            (0..<count).map { .init("s\($0)", $0 < current ? .done : $0 == current ? .current : .pending) }
        }
        let short = SessionPeek.window(steps(6, current: 3))
        #expect(short.above == 0 && short.shown.count == 6 && short.below == 0)
        let middle = SessionPeek.window(steps(12, current: 5))
        #expect(middle.above == 4 && middle.shown.map(\.text) == ["s4", "s5", "s6", "s7"] && middle.below == 4)
        let start = SessionPeek.window(steps(12, current: 0))
        #expect(start.above == 0 && start.shown.map(\.text) == ["s0", "s1", "s2", "s3", "s4"] && start.below == 7)
        let end = SessionPeek.window(steps(12, current: 11))
        #expect(end.above == 7 && end.shown.map(\.text) == ["s7", "s8", "s9", "s10", "s11"] && end.below == 0)
        for count in 7...20 {
            for current in 0..<count {
                let window = SessionPeek.window(steps(count, current: current))
                let lines = window.shown.count + (window.above > 0 ? 1 : 0) + (window.below > 0 ? 1 : 0)
                #expect(lines == SessionPeek.stepLines)
                #expect(window.above + window.shown.count + window.below == count)
                #expect(window.shown.contains { $0.state == .current })
            }
        }
    }

    /// The line above says "done" only when every step it hides is done: a skipped plan step or a task left behind by
    /// parallel work is not.
    @Test func theLineAboveSaysDoneOnlyWhenItIs() {
        let states: [SessionWork.Step.State] = [.done, .pending, .done, .done, .done, .current, .pending, .pending]
        let mixed = states.enumerated().map { SessionWork.Step("s\($0.offset)", $0.element) }
        let window = SessionPeek.window(mixed)
        #expect(window.above == 3)
        #expect(SessionPeek.aboveLine(mixed, above: window.above) == "3 earlier")
        let inOrder = mixed.map { $0.state == .pending && $0.text == "s1" ? SessionWork.Step($0.text, .done) : $0 }
        #expect(SessionPeek.aboveLine(inOrder, above: 3) == "3 done")
    }

    /// The peeker follows the shown peek's work: a new thought updates it in place, with no second read; once the
    /// peek goes, a change does nothing.
    @Test func thePeekFollowsTheWorkWhileItShows() async throws {
        let sessions = LaneSessions()
        var row = DStub.row("c", .codex, .running)
        row.lastPrompt = "move the settings"
        sessions.rows = [row]
        sessions.works["c"] = SessionWork(thinking: .init(title: "First", text: nil), steps: Self.steps)
        let ui = IslandUIState()
        ui.isOpen = true
        ui.presentation = .list
        let settings = AppSettings.ephemeral()
        let peeker = IslandPeeker(ui: ui, settings: settings, sessions: { sessions }, dwell: .zero, warmDwell: .zero)
        peeker.hovered(row, inside: true)
        await peeker.work?.value
        #expect(ui.peek?.thinking?.title == "First")
        sessions.works["c"] = SessionWork(thinking: .init(title: "Second", text: "Then this."), steps: Self.steps)
        await laneSettle { ui.peek?.thinking?.title == "Second" }
        #expect(ui.peek?.thinking == SessionWork.Thinking(title: "Second", text: "Then this."))
        // The turn's thought ends: the peek keeps its list.
        sessions.works["c"] = SessionWork(steps: Self.steps)
        await laneSettle { ui.peek?.thinking == nil }
        #expect(ui.peek?.steps == Self.steps)
        peeker.hovered(row, inside: false)
        #expect(ui.peek == nil)
        sessions.works["c"] = SessionWork(thinking: .init(title: "Third", text: nil), steps: Self.steps)
        await laneSettle()
        #expect(ui.peek == nil)
    }

    /// The rows fixture's Codex chat: its peek shows what it thinks and its plan, through the engine's own fold.
    @Test func theFixturesCodexPeekShowsItsWork() async throws {
        let settings = AppSettings.ephemeral()
        let env = AppEnvironment.demo(settings: settings, sessions: .rows)
        let peek = try #require(await env.sessions.peek(ID.codexRunning, clean: true))
        #expect(peek.thinking?.title == "Checking the old keys")
        #expect(peek.steps.count == 7 && peek.steps.filter { $0.state == .done }.count == 3)
        #expect(peek.facts.progress == nil)
        let claude = try #require(await env.sessions.peek(ID.claudePlan, clean: true))
        #expect(claude.steps.map(\.text) == ["Read the current index", "List the fields", "Pick the tokenizer", "Sketch the schema", "Write the plan"])
        #expect(claude.thinking == nil)
    }
}
