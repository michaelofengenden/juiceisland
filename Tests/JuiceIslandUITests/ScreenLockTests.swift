import AppKit
import Foundation
@testable import IslandEngine
@testable import JuiceIslandUI
import Testing

/// Settings › Island › Quiet › Quiet while locked (P422, P423): while the screen is locked or the owner's session
/// switched out, no sounds and nothing opens the island by itself; back, the island opens on what came meanwhile. The
/// notices come from centers of the tests' own and the window server's answer is a fake: nothing locks, plays or shows.
@MainActor
@Suite(.serialized)
struct ScreenLockTests {
    final class Server {
        var presence: SessionPresence? = SessionPresence()
        var asked = 0
    }

    static func watch(_ server: Server) -> (ScreenLockWatch, distributed: NotificationCenter, workspace: NotificationCenter) {
        let distributed = NotificationCenter(), workspace = NotificationCenter()
        let watch = ScreenLockWatch(distributed: distributed, workspace: workspace, presence: {
            server.asked += 1
            return server.presence
        })
        return (watch, distributed, workspace)
    }

    static func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    // MARK: The window server's session (P422)

    /// Locked only while loginwindow's key says so (it is present only then); away also while another user's session
    /// has the console; no session to ask is no answer.
    @Test func presenceReadsTheWindowServersSession() {
        #expect(SessionPresence.make(nil) == nil)
        let unlocked = SessionPresence.make(["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501])
        #expect(unlocked == SessionPresence(screenLocked: false, onConsole: true) && unlocked?.away == false)
        let locked = SessionPresence.make(["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": 1])
        #expect(locked?.screenLocked == true && locked?.away == true)
        #expect(SessionPresence.make(["kCGSSessionOnConsoleKey": false])?.away == true)
        // A session dictionary with neither key: in front and unlocked, as today.
        #expect(SessionPresence.make([:])?.away == false)
    }

    // MARK: The watch (P422)

    /// A lock notice makes the owner away while the window server agrees; the unlock brings them back and counts one
    /// return. Unlocked, the window server is never asked.
    @Test func theWatchHearsTheLockAndTheUnlock() async {
        _ = NSApplication.shared
        let server = Server()
        let (watch, distributed, _) = Self.watch(server)
        defer { watch.stop() }
        #expect(!watch.isAway && server.asked == 0)

        server.presence = SessionPresence(screenLocked: true)
        distributed.post(name: ScreenLockWatch.lockedNotice, object: nil)
        await Self.settle { watch.awayNoticed }
        #expect(watch.isAway && watch.returns == 0 && server.asked == 1)

        server.presence = SessionPresence()
        distributed.post(name: ScreenLockWatch.unlockedNotice, object: nil)
        await Self.settle { !watch.awayNoticed }
        #expect(!watch.isAway && watch.returns == 1 && server.asked == 1)
        // An unlock with no lock before it is no return.
        distributed.post(name: ScreenLockWatch.unlockedNotice, object: nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(watch.returns == 1)

        watch.stop()
        server.presence = SessionPresence(screenLocked: true)
        distributed.post(name: ScreenLockWatch.lockedNotice, object: nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!watch.awayNoticed && !watch.isAway)
    }

    /// Fails open: a lock notice the window server does not confirm (a key macOS no longer writes), or a lock whose
    /// unlock notice never came, is not away, so nothing is held back that would not be without the switch.
    @Test func aLockTheWindowServerDoesNotConfirmIsNoQuiet() async {
        _ = NSApplication.shared
        let server = Server()
        let (watch, distributed, _) = Self.watch(server)
        defer { watch.stop() }
        distributed.post(name: ScreenLockWatch.lockedNotice, object: nil)
        await Self.settle { watch.awayNoticed }
        #expect(watch.awayNoticed && !watch.isAway)
        server.presence = nil
        #expect(!watch.isAway)
        // Unlocked with no notice: back as far as anything is concerned.
        server.presence = SessionPresence(screenLocked: true)
        #expect(watch.isAway)
        server.presence = SessionPresence()
        #expect(!watch.isAway)
    }

    /// Fast user switching: the owner's session switching out is away (another user has the display) until it becomes
    /// active again, one return; a lock over a switch-out ends only when both have.
    @Test func aSessionThatSwitchedOutIsAway() async {
        _ = NSApplication.shared
        let server = Server()
        let (watch, distributed, workspace) = Self.watch(server)
        defer { watch.stop() }
        server.presence = SessionPresence(onConsole: false)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await Self.settle { watch.awayNoticed }
        #expect(watch.isAway)
        distributed.post(name: ScreenLockWatch.lockedNotice, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(watch.awayNoticed && watch.returns == 0)
        distributed.post(name: ScreenLockWatch.unlockedNotice, object: nil)
        await Self.settle { !watch.awayNoticed }
        #expect(watch.returns == 1)
    }

    // MARK: Quiet (P422)

    /// Away with the switch on: no sound (Mute and Quiet hours as ever); with the switch off, or back, the sounds play.
    @Test func whileLockedNoSoundPlays() {
        let settings = AppSettings.ephemeral()
        settings.doneSound = .system("Hero")
        func sounds(away: Bool) -> [String?] {
            [SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, away: away, settings: settings),
             SignalSounds.sound(for: .done(sessionID: "s"), isCodexAppThread: false, away: away, settings: settings)]
        }
        #expect(settings.quietWhileLocked)
        #expect(sounds(away: true) == [nil, nil])
        #expect(sounds(away: false) == ["Glass", "Hero"])
        settings.quietWhileLocked = false
        #expect(sounds(away: true) == ["Glass", "Hero"])
        #expect(!QuietMode.holdsAttention(settings, fullScreen: false, away: true, now: Date()))
        settings.quietWhileLocked = true
        #expect(QuietMode.holdsAttention(settings, fullScreen: false, away: true, now: Date()))
        #expect(!QuietMode.holdsAttention(settings, fullScreen: false, away: false, now: Date()))
    }

    /// With the live engine: an approval that comes while away plays nothing, one after the owner is back plays.
    @Test func theLiveSoundsHearTheLock() throws {
        let probe = QuietLaneRig.Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let live = QuietLaneRig.live(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        QuietLaneRig.start("s1", folder: "/tmp/project", engine, probe)
        QuietLaneRig.start("s2", folder: "/tmp/other", engine, probe)
        probe.away = true
        engine.ingest(QuietLaneRig.permission("s1", "toolu_1", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played.isEmpty && live.row(id: "s1")?.bucket == .needsYou)
        probe.away = false
        engine.ingest(QuietLaneRig.permission("s2", "toolu_2", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played == ["Glass"])
    }

    /// The switch starts on and keeps its value.
    @Test func theSwitchStartsOnAndKeepsItsValue() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.quietWhileLocked && AppSettings.ephemeral().quietWhileLocked)
        fresh.quietWhileLocked = false
        #expect(!AppSettings(defaults: defaults).quietWhileLocked)
        #expect(IslandPaneText.quietWhileLocked == "What waits shows on unlock.")
    }

    // MARK: What opens the island, and the catch-up (P423)

    /// Locked: an approval that comes opens nothing and is put away, a finish lights Glance's dot instead of its Done
    /// card. Back: the island opens on the one that came meanwhile and has waited longest, never on one answered
    /// elsewhere, a muted one or one that waited before the lock; nothing when all were answered.
    @Test func whileLockedNothingOpensAndWhatCameShowsOnUnlock() {
        let a = DStub.row("a", .claude, .needsYou), b = DStub.row("b", .codex, .needsYou), r = DStub.row("r", .claude, .running)
        var island = Island(cards: ["a": FocusYieldTests.approval("a", request: "A1"), "b": FocusYieldTests.approval("b", request: "B1"),
                                    "c": FocusYieldTests.approval("c", request: "C1")])
        // A waits before the lock (and opened the island then).
        #expect(island.hear([a, r], away: false).card == "a")
        // Locked: B comes, R finishes.
        let finished = DStub.row("r", .claude, .done)
        let locked = island.hear([a, b, finished], away: true)
        #expect(locked.card == nil && locked.glance == "r")
        #expect(island.arrivals == ["b": "request:B1"])
        // Back: B, not A.
        #expect(island.returned(waiting: [a, b]) == "b")
        #expect(island.arrivals.isEmpty)

        // Answered elsewhere while locked, or answered and asked again (another request): nothing to catch up on.
        var other = Island(cards: ["b": FocusYieldTests.approval("b", request: "B1")])
        _ = other.hear([b], away: true)
        other.cards["b"] = FocusYieldTests.approval("b", request: "B2")
        #expect(other.returned(waiting: [b]) == nil)
        #expect(LockCatchUp.card(arrivals: ["b": "request:B1"], waiting: [], pending: [:]) == nil)

        // Several came: the one that has waited longest (the order `waiting` gives).
        let c = DStub.row("c", .claude, .needsYou)
        var many = Island(cards: island.cards)
        _ = many.hear([b, c], away: true)
        #expect(many.returned(waiting: [c, b]) == "c")

        // A muted one never shows, locked or back.
        var muted = Island(cards: island.cards, rules: [MuteRule(field: .title, text: "task")])
        #expect(muted.hear([b], away: true) == .init() && muted.arrivals.isEmpty)
        #expect(muted.returned(waiting: [b]) == nil)
    }

    /// Questions open the island off (P411): a question that came during the lock stays on the pill once the owner is
    /// back, as it would have without the lock; an approval that came with it still shows. On, the question shows.
    @Test func aQuestionHeldOnThePillStaysThereAfterTheLock() {
        let q = NoticeFixtures.waiting("q", question: true), b = DStub.row("b", .codex, .needsYou)
        let cards = ["q": NoticeFixtures.question("q", request: "Q1"), "b": FocusYieldTests.approval("b", request: "B1")]
        var held = Island(cards: cards, questionsOpen: false)
        #expect(held.hear([q], away: true).card == nil)
        #expect(held.returned(waiting: [q]) == nil)
        var both = Island(cards: cards, questionsOpen: false)
        _ = both.hear([q, b], away: true)
        #expect(both.returned(waiting: [q, b]) == "b")
        var open = Island(cards: cards)
        _ = open.hear([q], away: true)
        #expect(open.returned(waiting: [q]) == "q")
    }

    /// The island's side of the rows as the panel runs it (`IslandPanelController.sessionsChanged` and `ownerReturned`):
    /// heard, muted, quieted while away (what needs you put away and noted), and the catch-up once back.
    struct Island {
        var cards: [String: SessionCard] = [:]
        var rules: [MuteRule] = []
        var questionsOpen = true
        var putAway = IslandPutAway()
        var last: [SessionRow] = []
        var arrivals: [String: String] = [:]

        mutating func hear(_ rows: [SessionRow], away: Bool) -> IslandAttention.Response {
            let cards = self.cards
            let pending = IslandAttention.pendingKeys(rows) { cards[$0] }
            let heard = MuteRules.unmuted(putAway.hear(IslandAttention.signals(old: last, new: rows), rows: rows, pending: pending),
                                          rows: rows, rules: rules)
            last = rows
            let batch = QuietMode.quieted(heard, finish: .card, quiet: away)
            if batch.putsAway { putAway.folded() }
            if away {
                for case let .needsYou(id) in heard { arrivals[id] = pending[id] }
            }
            let held = QuestionsOpen.held(batch.signals, rows: rows, opens: questionsOpen)
            if !held.sessions.isEmpty { putAway.putAway(held.sessions) }
            return IslandAttention.respond(to: held.signals, rows: rows, finish: batch.finish, cardInUse: false)
        }

        mutating func returned(waiting: [SessionRow]) -> String? {
            defer { arrivals = [:] }
            let cards = self.cards
            return LockCatchUp.card(arrivals: arrivals, waiting: LockCatchUp.candidates(waiting, rules: rules, questionsOpen: questionsOpen),
                                    pending: IslandAttention.pendingKeys(last) { cards[$0] })
        }
    }
}
