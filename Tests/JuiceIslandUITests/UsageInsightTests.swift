import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// P125 in the app: the release build's readers keep a history and raise a quota notice once per window, the dev
/// build's mirror does the same from Juice's files in memory, the island resolves and gates the notice card, and a
/// battery's Refresh keeps to the floors (#12). Fakes and fictional folders only.
@MainActor
@Suite(.serialized)
struct UsageInsightTests {
    typealias F = LiveFakes

    /// Claude's readings: `used` percent of a 5-hour window whose reset stays put.
    static func claude(_ used: LockedBox<Double>, reset: Date) -> @Sendable (Account, Date) -> Result<AccountReading, ReadError> {
        { account, now in
            .success(AccountReading(accountID: account.id, readAt: now, plan: "max", windows: [
                UsageWindow(seconds: 18_000, usedPercent: used.withValue { $0 }, resetsAt: reset),
                UsageWindow(seconds: 604_800, usedPercent: 20, resetsAt: reset + 3 * 86_400),
            ]))
        }
    }

    @Test
    func theReadersRaiseANoticeOncePerWindow() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        let used = LockedBox<Double>(85)
        fakes.claudeResult = Self.claude(used, reset: DemoClock.now + 3 * 3_600)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let login = try #require(model.loginID(of: F.work))
        // The first reading of a run is only a sample: 85 % says nothing.
        #expect(model.quotaNotice == nil && model.history.samples(login, window: "5h").count == 1)

        used.withValue { $0 = 91 }
        fakes.clock.now += 300
        await model.settle()
        let notice = try #require(model.quotaNotice)
        #expect(notice.account == login && notice.provider == .claude)
        #expect(notice.kind == .low(window: "5h", percentLeft: 9, resetsAt: DemoClock.now + 3 * 3_600))

        // Higher in the same window, and a dip back under 90: the same notice, nothing new.
        for next in [93.0, 89, 92] {
            used.withValue { $0 = next }
            fakes.clock.now += 300
            await model.settle()
            #expect(model.quotaNotice == notice)
        }
        #expect(model.history.samples(login, window: "5h").count == 5)

        // The file keeps the history and what was said: a new run (a relaunch) that sees the window cross 90 again says
        // nothing, however it dipped.
        model.stop()
        let saved = try Data(contentsOf: UsageHistoryStore.file(in: fakes.directory))
        #expect(saved.count < 4_000)
        let again = fakes.model()
        defer { again.stop() }
        used.withValue { $0 = 89 }
        fakes.clock.now += 300
        again.start()
        await again.settle()
        used.withValue { $0 = 95 }
        fakes.clock.now += 300
        await again.settle()
        #expect(again.quotaNotice == nil && again.history.samples(login, window: "5h").count >= 5)
    }

    @Test
    func theMirrorRaisesNoticesFromJuicesFilesWithoutWritingAny() throws {
        let directory = try JuiceReadingsUsageModelTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = JuiceReadingsUsageModelTests.work
        func record(used: Double, at date: Date) -> AccountRecord {
            AccountRecord(lastGood: AccountReading(accountID: work.id, readAt: date, plan: "pro", email: work.knownEmail, windows: [
                UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: DemoClock.now + 3_600),
            ]), lastAttemptAt: date)
        }
        try JuiceReadingsUsageModelTests.write(directory, accounts: [work], records: [work.id: record(used: 80, at: DemoClock.now - 600)])
        let usage = JuiceReadingsUsageModelTests.model(directory)
        #expect(usage.quotaNotice == nil)
        try JuiceReadingsUsageModelTests.write(directory, accounts: [work], records: [work.id: record(used: 96, at: DemoClock.now - 300)])
        usage.poll()
        #expect(usage.quotaNotice?.kind == .low(window: "5h", percentLeft: 4, resetsAt: DemoClock.now + 3_600))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["accounts.json", "readings.json"])
    }

    // MARK: The island

    @Test
    func theIslandFindsTheNoticeCardByItsOwnID() throws {
        let env = AppEnvironment.demo()
        let notice = QuotaNotice(account: DStub.accountID("Team"), provider: .codex, kind: .back(percentLeft: 100), at: DemoClock.now)
        let id = QuotaNoticeCard(notice: notice).sessionID
        #expect(env.card(for: id) == nil)                               // nothing shows yet
        env.islandNotice = notice
        #expect(env.card(for: id) == .quota(QuotaNoticeCard(notice: notice)))
        #expect(env.card(for: id)?.isBrief(in: .islandClean) == true && env.card(for: id)?.isBrief(in: .islandDetailed) == true)
        let older = QuotaNotice(account: notice.account, provider: .codex, kind: .back(percentLeft: 100), at: DemoClock.now - 60)
        #expect(env.card(for: QuotaNoticeCard(notice: older).sessionID) == nil)
        // Sessions' cards are still the sessions' own, and no key acts on a notice.
        #expect(env.card(for: FixtureSessionFeed.ID.question) == env.sessions.card(for: FixtureSessionFeed.ID.question))
        let key = IslandKeyPress(characters: "a", control: true)
        #expect(IslandKeyRouter.command(for: key, card: .quota(QuotaNoticeCard(notice: notice))) == nil)
        #expect(QuotaNoticeCard(notice: notice).line(now: DemoClock.now) == ("back", nil, true))
    }

    @Test
    func aNoticeShowsOnlyWhenItShould() {
        let notice = QuotaNotice(account: "claude#a", provider: .claude, kind: .back(percentLeft: 100), at: DemoClock.now)
        #expect(QuotaNoticeGate.decide(notice, alertsOn: true, ownerAtCard: false, now: DemoClock.now + 5) == .show)
        #expect(QuotaNoticeGate.decide(notice, alertsOn: true, ownerAtCard: true, now: DemoClock.now + 5) == .wait)
        #expect(QuotaNoticeGate.decide(notice, alertsOn: false, ownerAtCard: false, now: DemoClock.now + 5) == .drop)
        #expect(QuotaNoticeGate.decide(notice, alertsOn: true, ownerAtCard: false, now: DemoClock.now + 11 * 60) == .drop)
        #expect(AppSettings.ephemeral().quotaAlerts)
    }

    // MARK: The demo

    @Test
    func theDemoShowsTwoRunOutsAndItsSparklines() throws {
        let usage = DemoUsageModel()
        let lab = try #require(usage.battery(id: DStub.accountID("Lab")))
        let team = try #require(usage.battery(id: DStub.accountID("Team")))
        #expect(lab.runOut?.window == "5h" && team.runOut?.window == "5h")
        #expect(lab.hoverLabel.contains(" · out in ~4") && lab.hoverLabel.hasSuffix("resets in 2h 5m · read 4m ago"))
        #expect(AccountListText.detail(team, usage: usage) == ("out in ~22m · resets in 1h 2m", .amber))
        #expect(HoverLabelText.short(.account(team.id), usage: usage)?.parts.first == "out in ~22m")
        // Everything else says what it said before.
        let main = try #require(usage.battery(id: DStub.accountID("Main")))
        #expect(main.runOut == nil && main.hoverLabel == "Main · 82% left, 5h · resets in 1h 40m · read 1m ago")
        #expect(usage.sparkline(lab.id)?.runsOut == true && usage.sparkline(main.id)?.runsOut == false)
        #expect(usage.sparkline(DStub.accountID("Work")) == nil && usage.sparkline(DStub.accountID("Studio")) == nil)
        #expect(AccountListView.width(.claude, usage: usage) == AccountListView.width + AccountListView.sparklineColumn)
    }

    // MARK: Refresh account (#12)

    @Test
    func refreshAccountKeepsToTheFloors() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let login = try #require(model.loginID(of: F.work))
        #expect(fakes.reads.count == 1)
        fakes.clock.now += 30
        #expect(model.manualRead(login) == .floor(until: DemoClock.now + 120))
        #expect(AccountRefreshMenu.item(login, usage: model, now: fakes.clock.now) == .init(title: "Refresh in 2m", isEnabled: true))
        model.refreshAccount(login)
        await model.settle()
        #expect(fakes.reads.count == 1)                                  // not before the floor
        #expect(model.scheduler.nextDue(for: login) == DemoClock.now + 120)
        fakes.clock.now += 90
        #expect(AccountRefreshMenu.item(login, usage: model, now: fakes.clock.now) == .init(title: "Refresh account", isEnabled: true))
        await model.settle()
        #expect(fakes.reads.count == 2)                                  // read at the floor the click moved it to
        // The demo and the mirror read nothing: the item is there, greyed.
        #expect(AccountRefreshMenu.item(DStub.accountID("Main"), usage: DemoUsageModel(), now: DemoClock.now).isEnabled == false)
        #expect(AccountRefreshMenu.item(.paused(until: DemoClock.now + 14 * 60), unavailable: false, now: DemoClock.now)
                == .init(title: "Rate limited · next read in 14m", isEnabled: false))
        #expect(AccountRefreshMenu.wait(DemoClock.now + 45, now: DemoClock.now) == "45s")
        #expect(AccountRefreshMenu.wait(DemoClock.now + 61, now: DemoClock.now) == "2m")
    }

    /// #12: an account whose sessions are at work is read at its boosted floor (Claude 120 s), never sooner, and only
    /// while it is: renewing the boost more than once a minute changes nothing.
    @Test
    func sessionsAtWorkReadTheirAccountAtTheBoostedFloor() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work, F.lab])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let work = try #require(model.loginID(of: F.work)), lab = try #require(model.loginID(of: F.lab))
        let t0 = DemoClock.now
        #expect(model.scheduler.nextDue(for: work) == t0 + 300)
        let labDue = model.scheduler.nextDue(for: lab)
        fakes.clock.now = t0 + 30
        model.sessionsAtWork(inFolders: [F.work.id, "claude:/nowhere"])
        #expect(model.scheduler.nextDue(for: work) == t0 + 150)          // now + 120, never before its floor
        #expect(model.scheduler.nextDue(for: lab) == labDue)             // no session of Lab's at work
        fakes.clock.now = t0 + 60
        model.sessionsAtWork(inFolders: [F.work.id])
        #expect(model.scheduler.nextDue(for: work) == t0 + 150)
        fakes.clock.now = t0 + 150
        await model.settle()
        #expect(fakes.reads.filter { $0 == "read \(F.work.id)" }.count == 2)
        #expect(model.scheduler.nextDue(for: work) == t0 + 270)          // boosted: 120 s after the read
        #expect(ActivityBoost.folders(["a", "b", "c"]) { $0 == "b" ? nil : "claude:/" + $0 } == ["claude:/a", "claude:/c"])
    }

    final class Minutes {
        var now = DemoClock.now
        var reports: [[String]] = []
    }

    /// Through a long build a session at work sends no hook event and its row stays as it is; the boost names its
    /// account again each minute all the same, so it never lapses while the session runs (P125).
    @Test func aRunningSessionIsNamedAgainEachMinute() async {
        let feed = FixtureSessionFeed(scenario: .prototype)
        let box = Minutes()
        let model = EngineSessionsModel(engine: feed.engine, clock: { box.now })
        let boost = ActivityBoost(sessions: { model }, atWork: { box.reports.append($0) })
        let running = model.running.map(\.id)
        #expect(!running.isEmpty)
        let rows = model.rows
        for minute in 1...3 {
            box.now += 60
            model.tick()
            for _ in 0..<200 where box.reports.count < minute { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(box.reports.count == minute)
            #expect(box.reports.last == running)
        }
        #expect(model.rows == rows)
        _ = boost
    }
}
