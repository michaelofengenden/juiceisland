import Foundation
import IslandEngine
import Observation
import Testing
@testable import JuiceIslandUI

// Remind again (P410), Questions open the island (P411) and Notification banners (P412). Clocks, timers and the
// notification center are fakes of the tests' own: nothing ticks, plays, asks macOS for permission or posts a
// notification.

/// A sessions model whose rows, cards and finish source the test sets.
@MainActor
@Observable
final class NoticeSessions: SessionsModel {
    var rows: [SessionRow] = []
    var cards: [String: SessionCard] = [:]
    var finishSource: FinishSource = .rows
    var now: Date { DemoClock.now }

    func card(for sessionID: String) -> SessionCard? { cards[sessionID] }
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) {}
    func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool { false }
    func reply(_ sessionID: String, text: String) {}
    func jump(_ sessionID: String) {}
    func jumpToNextNeedsYou() {}
    func dismiss(_ sessionID: String) {}
}

/// The reminder's timer by hand: `advance` fires what is due; nothing runs by itself.
@MainActor
final class FakeFollowUpScheduler: FollowUpScheduler {
    final class Token: IslandTimerToken {
        let at: TimeInterval
        let fire: @MainActor @Sendable () -> Void
        var cancelled = false
        var fired = false
        init(at: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) {
            self.at = at
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    var now: TimeInterval = 5_000
    private(set) var tokens: [Token] = []

    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken {
        let token = Token(at: now + seconds, fire: fire)
        tokens.append(token)
        return token
    }

    var pending: [Token] { tokens.filter { !$0.cancelled && !$0.fired } }

    func advance(by seconds: TimeInterval) {
        now += seconds
        for token in pending where token.at <= now {
            token.fired = true
            token.fire()
        }
    }
}

@MainActor
enum NoticeFixtures {
    static func approval(_ session: String, request: String, agentType: String? = nil) -> SessionCard {
        .approval(ApprovalCardModel(sessionID: session, agent: .claude, tool: "Bash", body: .command("rm -rf build"),
                                    reason: "Clean the build folder",
                                    request: CardRequest(id: request, answerable: true, place: .terminal, agentType: agentType, more: 0,
                                                         isNotice: false, dismissable: false)))
    }

    static func question(_ session: String, request: String) -> SessionCard {
        .question(QuestionCardModel(sessionID: session, agent: .claude, topic: "Secret topic", question: "Which name?",
                                    options: [.init(label: "Juice", description: "")],
                                    request: CardRequest(id: request, answerable: true, place: .terminal, agentType: nil, more: 0,
                                                         isNotice: false, dismissable: false)))
    }

    static func waiting(_ id: String, question: Bool = false) -> SessionRow {
        DStub.row(id, .claude, .needsYou, glyph: question ? .ques : nil)
    }

    static func running(_ id: String) -> SessionRow { DStub.row(id, .claude, .running) }

    static func done(_ id: String) -> SessionRow { DStub.row(id, .claude, .done) }

    static func settings(remind: FollowUpDelay = .oneMinute) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.followUpAfter = remind
        return settings
    }

    /// Lets the tests' own tasks (a permission's answer) run.
    static func settle(until done: @MainActor () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

// MARK: Remind again (P410)

@MainActor
@Suite(.serialized)
struct FollowUpsTests {
    typealias F = NoticeFixtures

    @MainActor struct Rig {
        let sessions = NoticeSessions()
        let scheduler = FakeFollowUpScheduler()
        let player = RecordingSoundPlayer()
        let settings: AppSettings
        let followUps: FollowUps
        var looking = false

        init(settings: AppSettings = F.settings(), rows: [SessionRow] = [], cards: [String: SessionCard] = [:],
             clock: Date = QuietModeTests.at(12)) {
            self.settings = settings
            sessions.rows = rows
            sessions.cards = cards
            let scheduler = self.scheduler
            followUps = FollowUps(sessions: sessions, settings: settings, sounds: player, scheduler: scheduler,
                                  uptime: { scheduler.now }, clock: { clock })
        }

        /// A batch, as the model's observer hands it on.
        func batch(_ rows: [SessionRow], cards: [String: SessionCard]? = nil, finish: FinishSource? = nil) {
            sessions.rows = rows
            if let cards { sessions.cards = cards }
            if let finish { sessions.finishSource = finish }
            followUps.sessionsChanged()
        }
    }

    // The book, pure.

    @Test func theBookRemindsOnceAfterTheDelayAndNeverAgainForTheSameRequest() {
        var book = FollowUpBook()
        book.hear(waiting: ["a": "request:A1"], finished: [], done: [], looking: false, now: 0)
        #expect(book.deadline(after: 60) == 60)
        #expect(book.due(now: 59, delay: 60).isEmpty)
        #expect(book.due(now: 60, delay: 60).map(\.session) == ["a"])
        #expect(book.items.isEmpty && book.deadline(after: 60) == nil)
        // Still waiting on the same request: never again.
        book.hear(waiting: ["a": "request:A1"], finished: [], done: [], looking: false, now: 70)
        #expect(book.items.isEmpty)
        // The session's next request is a new one.
        book.hear(waiting: ["a": "request:A2"], finished: [], done: [], looking: false, now: 80)
        #expect(book.items.map(\.key) == ["request:A2"] && book.deadline(after: 60) == 140)
        // Answered: gone, and its spent key forgotten.
        book.hear(waiting: [:], finished: [], done: [], looking: false, now: 90)
        #expect(book.items.isEmpty && book.spent.isEmpty)
    }

    @Test func theBookForgetsWhatTheOwnerLookedAt() {
        var book = FollowUpBook()
        book.hear(waiting: ["a": "request:A1", "b": "request:B1"], finished: ["d"], done: ["d"], looking: false, now: 0)
        #expect(book.items.count == 3)
        book.looked(session: "a")
        #expect(Set(book.items.map(\.session)) == ["b", "d"])
        book.looked()
        #expect(book.items.isEmpty)
        book.hear(waiting: ["a": "request:A1", "b": "request:B1"], finished: [], done: ["d"], looking: false, now: 10)
        #expect(book.items.isEmpty)
        // What arrives while the owner looks is seen at once.
        book.hear(waiting: ["a": "request:A1", "c": "request:C1"], finished: ["e"], done: ["d", "e"], looking: true, now: 20)
        #expect(book.items.isEmpty && book.spent.contains("request:C1"))
    }

    @Test func theBookKeepsAFinishOnlyWhileItStillShowsFinished() {
        var book = FollowUpBook()
        book.hear(waiting: [:], finished: ["d"], done: ["d"], looking: false, now: 0)
        #expect(book.items == [FollowUpBook.Item(session: "d", kind: .finish, key: "d", since: 0)])
        // A later finish of the same session starts its time again.
        book.hear(waiting: [:], finished: ["d"], done: ["d"], looking: false, now: 30)
        #expect(book.items.map(\.since) == [30])
        // Running again: nothing to remind of.
        book.hear(waiting: [:], finished: [], done: [], looking: false, now: 40)
        #expect(book.items.isEmpty)
    }

    // The runtime.

    @Test func aRequestStillWaitingGetsOnePulseAndOneSoundThenNothingTicks() {
        let rig = Rig(rows: [F.waiting("a"), F.running("r")], cards: ["a": F.approval("a", request: "A1")])
        rig.followUps.start()
        #expect(rig.scheduler.pending.map(\.at) == [rig.scheduler.now + 60])
        rig.scheduler.advance(by: 59)
        #expect(rig.followUps.pulse == 0 && rig.player.played.isEmpty)
        rig.scheduler.advance(by: 1)
        #expect(rig.followUps.pulse == 1 && rig.player.played == ["Glass"] && rig.followUps.reminded == ["a"])
        #expect(!rig.followUps.isArmed && rig.scheduler.pending.isEmpty)
        // Batches that change nothing arm nothing: the request is spent.
        rig.batch([F.waiting("a"), F.running("r")])
        rig.scheduler.advance(by: 600)
        #expect(rig.followUps.pulse == 1 && rig.player.played.count == 1 && rig.scheduler.pending.isEmpty)
    }

    @Test func offByDefaultNothingRunsAndTurningItOffForgets() {
        let settings = AppSettings.ephemeral()
        #expect(settings.followUpAfter == .off)
        let rig = Rig(settings: settings, rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        rig.followUps.start()
        rig.batch([F.waiting("a")])
        #expect(rig.scheduler.tokens.isEmpty && rig.followUps.book.items.isEmpty)
        settings.followUpAfter = .twoMinutes
        rig.followUps.apply()
        #expect(rig.scheduler.pending.map(\.at) == [rig.scheduler.now + 120])
        settings.followUpAfter = .off
        rig.followUps.apply()
        #expect(rig.scheduler.pending.isEmpty && rig.followUps.book.items.isEmpty)
        rig.scheduler.advance(by: 600)
        #expect(rig.followUps.pulse == 0)
    }

    @Test func aNewDelayMovesTheDeadline() {
        let rig = Rig(rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        rig.followUps.start()
        rig.scheduler.advance(by: 30)
        rig.settings.followUpAfter = .fiveMinutes
        rig.followUps.apply()
        #expect(rig.scheduler.pending.map(\.at) == [rig.scheduler.now - 30 + 300])
        rig.scheduler.advance(by: 240)
        #expect(rig.followUps.pulse == 0)
        rig.scheduler.advance(by: 30)
        #expect(rig.followUps.pulse == 1)
    }

    @Test func neverForASubagentsRequestAScriptedRunOrWhatTheOwnerLookedAt() {
        var asking = F.waiting("s")
        asking.asker = "worker"
        var scripted = F.waiting("q")
        scripted.isQuiet = true
        let rig = Rig(rows: [asking, scripted], cards: ["s": F.approval("s", request: "S1", agentType: "worker"),
                                                        "q": F.approval("q", request: "Q1")])
        rig.followUps.start()
        #expect(rig.scheduler.pending.isEmpty)
        // An owner's request, looked at before its time.
        rig.batch([asking, scripted, F.waiting("a")], cards: ["a": F.approval("a", request: "A1"), "s": F.approval("s", request: "S1"),
                                                              "q": F.approval("q", request: "Q1")])
        #expect(rig.scheduler.pending.count == 1)
        rig.scheduler.advance(by: 30)
        rig.followUps.looked()
        #expect(rig.scheduler.pending.isEmpty)
        rig.scheduler.advance(by: 600)
        #expect(rig.followUps.pulse == 0 && rig.player.played.isEmpty)
    }

    @Test func whatArrivesWhileTheOwnerLooksIsNeverReminded() {
        let rig = Rig()
        rig.followUps.looking = { true }
        rig.followUps.start()
        rig.batch([F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        #expect(rig.scheduler.pending.isEmpty)
        // The owner looking when the deadline comes counts too.
        rig.followUps.looking = { false }
        rig.batch([F.waiting("a"), F.waiting("b")], cards: ["a": F.approval("a", request: "A1"), "b": F.approval("b", request: "B1")])
        #expect(rig.scheduler.pending.count == 1)
        rig.followUps.looking = { true }
        rig.scheduler.advance(by: 60)
        #expect(rig.followUps.pulse == 0 && rig.player.played.isEmpty)
    }

    @Test func aJumpOrABannersClickClearsThatSessionOnly() {
        let rig = Rig(rows: [F.waiting("a"), F.waiting("b")], cards: ["a": F.approval("a", request: "A1"), "b": F.approval("b", request: "B1")])
        rig.followUps.start()
        rig.followUps.looked(sessionID: "a")
        rig.scheduler.advance(by: 60)
        #expect(rig.followUps.reminded == ["b"] && rig.followUps.pulse == 1)
    }

    /// A finished turn of the owner's (the live engine's Done) that nobody looked at is reminded of once; one whose
    /// session runs again before its time is not.
    @Test func anUnseenFinishIsRemindedOnceAndARestartedOneIsNot() {
        let rig = Rig(rows: [F.running("d"), F.running("e")])
        rig.sessions.finishSource = .engine(last: nil)
        rig.followUps.start()
        rig.batch([F.done("d"), F.running("e")], finish: .engine(last: ReleasedFinish(sessionID: "d", serial: 1)))
        #expect(rig.scheduler.pending.count == 1)
        rig.scheduler.advance(by: 60)
        // Done's sound is None by default: the finish's reminder pulses and plays nothing (P493).
        #expect(rig.followUps.reminded == ["d"] && rig.followUps.pulse == 1 && rig.player.played.isEmpty)

        rig.batch([F.done("d"), F.done("e")], finish: .engine(last: ReleasedFinish(sessionID: "e", serial: 2)))
        #expect(rig.scheduler.pending.count == 1)
        rig.scheduler.advance(by: 20)
        rig.batch([F.done("d"), F.running("e")])
        #expect(rig.scheduler.pending.isEmpty)
        rig.scheduler.advance(by: 600)
        #expect(rig.followUps.pulse == 1)
    }

    /// Several due together: one pulse and one sound. Mute, Quiet hours and the demo feed play no sound; the pill still
    /// pulses.
    @Test func oneReminderForManyAndMuteOrQuietHoursSilenceIt() {
        let rig = Rig(rows: [F.waiting("a"), F.waiting("b")], cards: ["a": F.approval("a", request: "A1"), "b": F.approval("b", request: "B1")])
        rig.followUps.start()
        rig.scheduler.advance(by: 60)
        #expect(rig.followUps.pulse == 1 && rig.player.played == ["Glass"] && Set(rig.followUps.reminded) == ["a", "b"])

        let muted = F.settings()
        muted.soundsMuted = true
        let quietRig = Rig(settings: muted, rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        quietRig.followUps.start()
        quietRig.scheduler.advance(by: 60)
        #expect(quietRig.followUps.pulse == 1 && quietRig.player.played.isEmpty)

        let demo = Rig(rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        demo.followUps.live = { false }
        demo.followUps.start()
        demo.scheduler.advance(by: 60)
        #expect(demo.followUps.pulse == 1 && demo.player.played.isEmpty)

        let night = F.settings()
        night.quietHours = true
        let nightRig = Rig(settings: night, rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")],
                           clock: QuietModeTests.at(23))
        nightRig.followUps.start()
        nightRig.scheduler.advance(by: 60)
        #expect(nightRig.followUps.pulse == 1 && nightRig.player.played.isEmpty)
    }

    /// The quiet lane's rules reach the reminder: a session a mute rule matches is never reminded of (P421); a lock with
    /// Quiet while locked on silences it as every sound, the pill still pulsing (P422); a question's reminder plays the
    /// Question sound, at Volume (P425, P426).
    @Test func muteRulesTheLockAndTheQuestionSoundReachTheReminder() {
        var a = F.waiting("a")
        a.task = "deploy staging"
        let muting = F.settings()
        muting.muteRules = [MuteRule(field: .title, text: "staging")]
        let muted = Rig(settings: muting, rows: [a], cards: ["a": F.approval("a", request: "A1")])
        muted.followUps.start()
        muted.scheduler.advance(by: 60)
        #expect(muted.followUps.pulse == 0 && muted.player.played.isEmpty && !muted.followUps.isArmed)

        let locked = Rig(rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        locked.followUps.away = { true }
        locked.followUps.start()
        locked.scheduler.advance(by: 60)
        #expect(locked.followUps.pulse == 1 && locked.player.played.isEmpty)

        let asking = F.settings()
        asking.questionSound = .system("Submarine")
        asking.soundVolume = 0.4
        let question = Rig(settings: asking, rows: [F.waiting("q", question: true)], cards: ["q": F.question("q", request: "Q1")])
        question.followUps.start()
        question.scheduler.advance(by: 60)
        #expect(question.player.played == ["Submarine"] && question.player.volumes == [Float(0.4)])
    }

    /// A finished turn's reminder plays the Done sound, a request's the Needs you (or Question) sound; with both due, the
    /// request's (P493).
    @Test func aFinishIsRemindedWithTheDoneSound() {
        let settings = F.settings()
        settings.doneSound = .system("Hero")
        let rig = Rig(settings: settings, rows: [F.running("d")])
        rig.sessions.finishSource = .engine(last: nil)
        rig.followUps.start()
        rig.batch([F.done("d")], finish: .engine(last: ReleasedFinish(sessionID: "d", serial: 1)))
        rig.scheduler.advance(by: 60)
        #expect(rig.followUps.pulse == 1 && rig.player.played == ["Hero"])

        let both = Rig(settings: settings, rows: [F.running("d"), F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        both.followUps.start()
        both.batch([F.done("d"), F.waiting("a")], finish: .rows)
        both.scheduler.advance(by: 60)
        #expect(both.followUps.pulse == 1 && both.player.played == ["Glass"])
    }

    /// The live engine's requests: one is reminded of only once its needs-you signal was let out. A request whose tab
    /// was in front (No alerts for focused sessions) was never told of, so it is never reminded of either (P494).
    @Test func aRequestTheEngineKeptQuietIsNeverReminded() {
        let rig = Rig(rows: [F.running("a"), F.running("b")])
        rig.sessions.finishSource = .engine(last: nil)
        rig.followUps.start()
        rig.batch([F.waiting("a"), F.waiting("b")], cards: ["a": F.approval("a", request: "A1"), "b": F.approval("b", request: "B1")])
        // Only b's signal went out: a's tab was in front.
        rig.followUps.released(.needsYou(sessionID: "b"))
        rig.scheduler.advance(by: 60)
        #expect(rig.followUps.reminded == ["b"] && rig.followUps.pulse == 1)
        rig.scheduler.advance(by: 600)
        #expect(rig.followUps.pulse == 1 && !rig.followUps.isArmed)
        // a's next request, let out this time, is reminded of.
        rig.batch([F.waiting("a"), F.waiting("b")], cards: ["a": F.approval("a", request: "A2"), "b": F.approval("b", request: "B1")])
        rig.followUps.released(.needsYou(sessionID: "a"))
        rig.scheduler.advance(by: 60)
        #expect(rig.followUps.reminded == ["a"] && rig.followUps.pulse == 2)
    }

    /// Answered before its time, or replaced by the session's next request: the old one gets nothing, the new one its own.
    @Test func anAnsweredOrReplacedRequestIsNotReminded() {
        let rig = Rig(rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        rig.followUps.start()
        rig.scheduler.advance(by: 40)
        rig.batch([F.waiting("a")], cards: ["a": F.approval("a", request: "A2")])
        rig.scheduler.advance(by: 20)
        #expect(rig.followUps.pulse == 0)
        rig.scheduler.advance(by: 40)
        #expect(rig.followUps.pulse == 1)
        rig.batch([F.running("a")], cards: [:])
        #expect(rig.scheduler.pending.isEmpty)
    }

    @Test func theSettingsStartAsTodayAndKeepTheirValues() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.followUpAfter == .off && fresh.questionsOpenIsland && !fresh.notificationBanners)
        fresh.followUpAfter = .threeMinutes
        fresh.questionsOpenIsland = false
        fresh.notificationBanners = true
        let again = AppSettings(defaults: defaults)
        #expect(again.followUpAfter == .threeMinutes && !again.questionsOpenIsland && again.notificationBanners)
        #expect(FollowUpDelay.allCases.map(\.seconds) == [nil, 60, 120, 180, 300])
    }
}

// MARK: Questions open the island (P411)

@MainActor
@Suite(.serialized)
struct QuestionsOpenTests {
    typealias F = NoticeFixtures

    /// The island's side of a batch as the panel runs it (`IslandPanelController.sessionsChanged`): heard, quieted,
    /// questions held, and the card it opens.
    struct Island {
        var putAway = IslandPutAway()
        var last: [SessionRow] = []
        var cards: [String: SessionCard] = [:]
        var opens = true

        mutating func hear(_ rows: [SessionRow]) -> String? {
            let heard = putAway.hear(IslandAttention.signals(old: last, new: rows), rows: rows,
                                     pending: IslandAttention.pendingKeys(rows) { cards[$0] })
            last = rows
            let batch = QuietMode.quieted(heard, finish: .card, quiet: false)
            let held = QuestionsOpen.held(batch.signals, rows: rows, opens: opens)
            if !held.sessions.isEmpty { putAway.putAway(held.sessions) }
            return IslandAttention.respond(to: held.signals, rows: rows, finish: batch.finish, cardInUse: false).card
        }
    }

    @Test func onAQuestionOpensItsCardAsToday() {
        var island = Island(cards: ["q": F.question("q", request: "Q1")])
        #expect(island.hear([F.waiting("q", question: true)]) == "q")
        #expect(QuestionsOpen.held([.needsYou("q")], rows: [F.waiting("q", question: true)], opens: true)
            == QuestionsOpen.Held(signals: [.needsYou("q")], sessions: []))
    }

    /// Off: the question stays on the pill as "?", and never opens the island by itself, now or when its row comes back
    /// after a restart; an approval, and a finish's Done card, open as ever.
    @Test func offAQuestionStaysOnThePillAndNeverOpensTheIslandByItself() {
        let q = F.waiting("q", question: true), a = F.waiting("a"), d = F.done("d")
        var island = Island(cards: ["q": F.question("q", request: "Q1"), "a": F.approval("a", request: "A1")], opens: false)
        #expect(island.hear([F.running("d")]) == nil)
        #expect(island.hear([q, F.running("d")]) == nil)
        #expect(island.putAway.keys == ["q": "request:Q1"])
        let pill = HideWhenIdleTests.pill([q], hide: false)
        #expect(pill.lead?.glyph == .ques && pill.lead?.state == .waiting)
        // A restart: its row drops out and comes back; nothing opens.
        #expect(island.hear([]) == nil)
        #expect(island.hear([q]) == nil)
        // An approval opens; a finish opens its Done card.
        #expect(island.hear([q, a]) == "a")
        #expect(island.hear([q, a, F.running("d")]) == nil)
        #expect(island.hear([q, a, d]) == "d")
        // The session's next question is held too; with the switch back on, a new one opens.
        island.cards["q"] = F.question("q", request: "Q2")
        var q2 = q
        q2.status = .question
        #expect(island.hear([a, d]) == nil)
        #expect(island.hear([q2, a, d]) == nil)
        island.opens = true
        island.cards["q"] = F.question("q", request: "Q3")
        #expect(island.hear([a, d]) == nil)
        #expect(island.hear([q2, a, d]) == "q")
    }

    @Test func theRowSaysWhereTheQuestionIsWhenOff() {
        #expect(IslandPaneText.questions(true) == nil)
        #expect(IslandPaneText.questions(false) == "A ? on the pill until you hover.")
    }
}

// MARK: Notification banners (P412)

@MainActor
final class FakeBannerCenter: BannerCenter {
    var status: BannerPermission = .notAsked
    /// What the owner answers at macOS's prompt.
    var answer: BannerPermission = .allowed
    private(set) var asked = 0
    private(set) var read = 0
    private(set) var posted: [Banner] = []
    private(set) var removed: [String] = []
    var clicked: (@MainActor (String) -> Void)?

    func permission() async -> BannerPermission {
        read += 1
        return status
    }

    func requestPermission() async -> BannerPermission {
        asked += 1
        if status == .notAsked { status = answer }
        return status
    }

    func post(_ banner: Banner) { posted.append(banner) }
    func remove(_ ids: [String]) { removed += ids }
}

@MainActor
@Suite(.serialized)
struct BannersTests {
    typealias F = NoticeFixtures

    @MainActor struct Rig {
        let sessions = NoticeSessions()
        let center = FakeBannerCenter()
        let settings: AppSettings
        let banners: Banners
        let made: Counter

        final class Counter { var count = 0 }

        init(on: Bool = true, showAs: ShowAs = .island, clock: Date = QuietModeTests.at(12)) {
            let settings = AppSettings.ephemeral()
            settings.notificationBanners = on
            settings.showAs = showAs
            self.settings = settings
            let center = self.center, made = Counter()
            self.made = made
            banners = Banners(settings: settings, sessions: sessions, center: {
                made.count += 1
                return center
            }, clock: { clock })
        }
    }

    @Test func nothingTouchesNotificationCenterWhileOff() async {
        let rig = Rig(on: false)
        rig.banners.start()
        rig.sessions.rows = [F.waiting("a")]
        rig.banners.islandHeard([.needsYou("a")], opened: nil, islandOpen: false, visible: true, quiet: false)
        rig.banners.released(.needsYou(sessionID: "a"))
        await F.settle { false }
        #expect(rig.made.count == 0 && rig.center.posted.isEmpty && rig.center.asked == 0 && rig.center.read == 0)
    }

    /// macOS is asked only when the owner turns the switch on (or clicks Allow); a launch with it on only reads.
    @Test func macOSIsAskedOnlyWhenTheOwnerTurnsItOn() async {
        let launch = Rig(on: true)
        launch.banners.start()
        await F.settle { launch.banners.permission != .unknown }
        #expect(launch.center.asked == 0 && launch.center.read == 1 && launch.banners.permission == .notAsked)
        launch.banners.ask()
        await F.settle { launch.banners.permission == .allowed }
        #expect(launch.center.asked == 1)

        let rig = Rig(on: false)
        rig.center.answer = .denied
        rig.banners.start()
        rig.settings.notificationBanners = true
        await F.settle { rig.banners.permission != .unknown }
        #expect(rig.made.count == 1 && rig.center.asked == 1 && rig.banners.permission == .denied)
        #expect(GeneralPaneText.banners(on: true, .denied) == "Off in System Settings." && GeneralPaneText.bannerAction(.denied) == .open)
        #expect(GeneralPaneText.bannerAction(.notAsked) == .allow && GeneralPaneText.bannerAction(.allowed) == nil)
        #expect(GeneralPaneText.banners(on: false, .denied) == nil && GeneralPaneText.bannerAction(.unavailable) == nil)
    }

    /// Island mode: none for the card the island opens by itself, none while it is open, none for a stall; a Glance
    /// finish (the island stays closed) or a card it could not show (no display) gets one.
    @Test func islandModeBannersOnlyWhatTheIslandDoesNotShow() {
        let signals: [IslandSignal] = [.needsYou("a"), .finished("d"), .stalled("s")]
        #expect(BannerRule.fromIsland(signals, opened: "a", islandOpen: false, visible: true) == [.finished("d")])
        #expect(BannerRule.fromIsland(signals, opened: "d", islandOpen: false, visible: true) == [.needsYou("a")])
        #expect(BannerRule.fromIsland(signals, opened: nil, islandOpen: true, visible: true).isEmpty)
        #expect(BannerRule.fromIsland(signals, opened: "a", islandOpen: false, visible: false) == [.needsYou("a"), .finished("d")])
    }

    /// What Notification Center keeps is what the widget's file may say (P200): the project folder and the status line,
    /// never the chat's title, the command, the question's topic or the finished message.
    @Test func aBannerSaysOnlyTheFolderAndTheStatus() {
        var row = F.waiting("a")
        row.task = "Rename the secret project"
        row.titleSource = .prompt
        row.project = "juice-island"
        let approval = BannerRule.banner(for: .needsYou("a"), row: row, card: F.approval("a", request: "A1"))
        #expect(approval == Banner(id: "needs:request:A1", sessionID: "a", kind: .needsYou, title: "juice-island",
                                   body: "Needs approval · Bash", key: "request:A1"))
        var question = F.waiting("q", question: true)
        question.project = "juice-island"
        let asked = BannerRule.banner(for: .needsYou("q"), row: question, card: F.question("q", request: "Q1"))
        #expect(asked?.body == "Question" && asked?.title == "juice-island")
        var done = F.done("d")
        done.detail = "I deleted the secret file"
        let finished = BannerRule.banner(for: .finished("d"), row: done, card: nil)
        #expect(finished?.body == "Done" && finished?.kind == .done)
        for banner in [approval, asked, finished].compactMap({ $0 }) {
            for secret in ["secret", "rm -rf", "Clean the build", "Which name", "Secret topic"] {
                #expect(!banner.title.contains(secret) && !banner.body.contains(secret))
            }
        }
        // A repo's own title stays, as on the widget.
        var repo = F.done("r")
        repo.titleSource = .repo
        #expect(BannerRule.banner(for: .finished("r"), row: repo, card: nil)?.title == WidgetSnapshot.title(repo))
    }

    /// One banner per request; none for a subagent's request, a scripted run or a row no longer in that state; none
    /// while quiet or from the demo feed.
    @Test func oneBannerPerRequestAndNoneForSubagentsOrQuietRows() async {
        let rig = Rig()
        rig.banners.start()
        await F.settle { rig.banners.permission != .unknown }
        var asking = F.waiting("s")
        asking.asker = "worker"
        var scripted = F.done("x")
        scripted.isQuiet = true
        rig.sessions.rows = [F.waiting("a"), asking, scripted, F.running("r")]
        rig.sessions.cards = ["a": F.approval("a", request: "A1"), "s": F.approval("s", request: "S1", agentType: "worker")]
        let all: [IslandSignal] = [.needsYou("a"), .needsYou("s"), .finished("x"), .finished("r")]
        rig.banners.islandHeard(all, opened: nil, islandOpen: false, visible: true, quiet: true)
        #expect(rig.center.posted.isEmpty)
        // The demo feed's rows never post.
        rig.banners.live = { false }
        rig.banners.islandHeard(all, opened: nil, islandOpen: false, visible: true, quiet: false)
        #expect(rig.center.posted.isEmpty)
        rig.banners.live = { true }
        rig.banners.islandHeard(all, opened: nil, islandOpen: false, visible: true, quiet: false)
        rig.banners.islandHeard([.needsYou("a")], opened: nil, islandOpen: false, visible: true, quiet: false)
        #expect(rig.center.posted.map(\.id) == ["needs:request:A1"])
    }

    /// Window mode: a signal the engine let out gets a banner unless the window is in front; Quiet hours hold it.
    @Test func windowModeBannersWhenTheWindowIsNotInFront() async {
        let rig = Rig(showAs: .window)
        rig.banners.start()
        await F.settle { rig.banners.permission != .unknown }
        rig.sessions.rows = [F.waiting("a"), F.done("d")]
        rig.sessions.cards = ["a": F.approval("a", request: "A1")]
        rig.banners.windowFront = { true }
        rig.banners.released(.needsYou(sessionID: "a"))
        #expect(rig.center.posted.isEmpty)
        rig.banners.windowFront = { false }
        rig.banners.released(.needsYou(sessionID: "a"))
        rig.banners.released(.done(sessionID: "d"))
        #expect(rig.center.posted.map(\.kind) == [.needsYou, .done])
        // The island's report is not Window mode's.
        rig.banners.islandHeard([.needsYou("a")], opened: nil, islandOpen: false, visible: true, quiet: false)
        #expect(rig.center.posted.count == 2)

        let night = Rig(showAs: .window, clock: QuietModeTests.at(23))
        night.settings.quietHours = true
        night.banners.start()
        await F.settle { night.banners.permission != .unknown }
        night.sessions.rows = [F.waiting("a")]
        night.banners.released(.needsYou(sessionID: "a"))
        #expect(night.center.posted.isEmpty)
    }

    /// The quiet lane's rules hold banners: a session a mute rule matches gets none, in either mode (P421); Window mode's
    /// wait while the screen is locked with Quiet while locked on (P422), as the island's batches do.
    @Test func muteRulesAndTheLockHoldBanners() async {
        var a = F.waiting("a")
        a.task = "deploy staging"
        let rules = [MuteRule(field: .title, text: "staging")]
        let rig = Rig(showAs: .window)
        rig.settings.muteRules = rules
        rig.banners.start()
        await F.settle { rig.banners.permission != .unknown }
        rig.sessions.rows = [a, F.waiting("b")]
        rig.sessions.cards = ["a": F.approval("a", request: "A1"), "b": F.approval("b", request: "B1")]
        rig.banners.released(.needsYou(sessionID: "a"))
        #expect(rig.center.posted.isEmpty)
        rig.banners.away = { true }
        rig.banners.released(.needsYou(sessionID: "b"))
        #expect(rig.center.posted.isEmpty)
        rig.banners.away = { false }
        rig.banners.released(.needsYou(sessionID: "b"))
        #expect(rig.center.posted.map(\.id) == ["needs:request:B1"])

        let island = Rig()
        island.settings.muteRules = rules
        island.banners.start()
        await F.settle { island.banners.permission != .unknown }
        island.sessions.rows = [a]
        island.sessions.cards = ["a": F.approval("a", request: "A1")]
        island.banners.islandHeard([.needsYou("a")], opened: nil, islandOpen: false, visible: true, quiet: false)
        #expect(island.center.posted.isEmpty)
    }

    /// Answered anywhere, or running again: its banner is taken back; turning the switch off takes back the rest.
    @Test func aBannerIsTakenBackOnceItNoLongerHolds() async {
        let rig = Rig()
        rig.banners.start()
        await F.settle { rig.banners.permission != .unknown }
        rig.sessions.rows = [F.waiting("a"), F.done("d")]
        rig.sessions.cards = ["a": F.approval("a", request: "A1")]
        rig.banners.islandHeard([.needsYou("a"), .finished("d")], opened: nil, islandOpen: false, visible: false, quiet: false)
        #expect(rig.center.posted.count == 2)
        rig.sessions.rows = [F.running("a"), F.done("d")]
        rig.sessions.cards = [:]
        rig.banners.rowsChanged()
        #expect(rig.center.removed == ["needs:request:A1"] && rig.banners.delivered.map(\.sessionID) == ["d"])
        rig.settings.notificationBanners = false
        await F.settle { rig.banners.delivered.isEmpty }
        #expect(rig.center.removed.count == 2)
    }

    /// A Done banner stays while its turn still shows finished, however often the row's time moves (Claude's idle_prompt
    /// about a minute after an unanswered Stop, a late rollout line, a jump handle); it goes when the session runs again or
    /// finishes a newer turn (P495).
    @Test func aDoneBannerOutlastsLaterEventsOfTheSameTurn() async {
        for showAs in [ShowAs.island, .window] {
            let rig = Rig(showAs: showAs)
            rig.banners.start()
            await F.settle { rig.banners.permission != .unknown }
            var done = F.done("d")
            rig.sessions.rows = [done]
            rig.sessions.finishSource = .engine(last: ReleasedFinish(sessionID: "d", serial: 4))
            if showAs == .island {
                rig.banners.islandHeard([.finished("d")], opened: nil, islandOpen: false, visible: false, quiet: false)
            } else {
                rig.banners.released(.done(sessionID: "d"))
            }
            #expect(rig.center.posted.count == 1)
            done.updatedAt = done.updatedAt.addingTimeInterval(61)
            rig.sessions.rows = [done]
            rig.banners.rowsChanged()
            #expect(rig.center.removed.isEmpty && rig.banners.delivered.count == 1, "\(showAs)")
            // A newer turn of the same session finished: the old banner goes.
            rig.sessions.finishSource = .engine(last: ReleasedFinish(sessionID: "d", serial: 5))
            rig.banners.rowsChanged()
            #expect(rig.center.removed.count == 1 && rig.banners.delivered.isEmpty, "\(showAs)")
        }
    }

    @Test func aClickOpensItsSession() async {
        let rig = Rig()
        var opened: [String] = []
        rig.banners.clicked = { opened.append($0) }
        rig.banners.start()
        rig.center.clicked?("a")
        #expect(opened == ["a"])
    }
}
