import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Diagnostics › Accounts and Copy Report by login (P361) and a Claude login with no plan (P360), on `LiveUsageModel`'s
/// fakes: one row per login exactly as the batteries are, named by its folders' aliases, its state its battery's and its
/// next read the scheduler's. Fictional folders and emails only.
@MainActor
@Suite(.serialized)
struct LoginDiagnosticsTests {
    typealias F = LiveFakes

    static func folder(_ provider: Provider, _ suffix: String, _ alias: String) -> Account {
        Account(provider: provider, folder: F.home + "/." + provider.rawValue + suffix, alias: alias)
    }

    static let codexHome = folder(.codex, "", "Home")
    static let a = "a@example.com", b = "b@example.com", c = "c@example.com", d = "d@example.com"

    func entries(_ model: LiveUsageModel) -> [DiagnosticsText.AccountEntry] {
        DiagnosticsText.accounts(model.logins, records: model.records, schedule: { model.schedule(of: $0) },
                                 question: { model.question(forFolder: $0) }, now: model.now)
    }

    /// Two folders holding one login are one row, named by both aliases, with the login's own state and next read. The
    /// report says the same, with no email and no folder.
    @Test func twoFoldersOfOneLoginAreOneRow() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side, Self.codexHome])
        fakes.codex(F.side, Self.a, stamp: AuthFileStamp(inode: 1, modifiedSeconds: 100))
        fakes.codex(Self.codexHome, Self.a, stamp: AuthFileStamp(inode: 2, modifiedSeconds: 200))
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let rows = entries(model)
        let id = LoginsStore.id(provider: .codex, email: Self.a)
        #expect(rows.map(\.id) == [id] && rows.map(\.label) == ["Home + Side"])
        #expect(rows[0].line == .init(lastRead: "0s ago", next: "in 1m", status: "OK", tone: .normal))
        #expect(model.schedule(of: id) == ReadSchedule(next: DemoClock.now + 60))
        let report = DiagnosticsText.report(lines: rows.map { ($0.label, $0.provider, $0.line) }, money: [])
        #expect(report.contains("  Codex Home + Side: OK (read 0s ago, next in 1m)"))
        #expect(!report.contains("@") && !report.contains("/.codex"))
    }

    /// A login switched off says so, whatever its folders' own switches: "Not monitored", nothing next.
    @Test func aSwitchedOffLoginIsNotMonitored() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side, Self.codexHome])
        fakes.codex(F.side, Self.a, stamp: nil)
        fakes.codex(Self.codexHome, Self.b, stamp: nil)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let idA = LoginsStore.id(provider: .codex, email: Self.a)
        model.setMonitored(login: idA, false)
        let rows = entries(model)
        #expect(rows.map(\.label) == ["Side", "Home"])
        let side = try #require(rows.first { $0.id == idA })
        #expect(side.line.status == "Not monitored" && side.line.next == "off" && side.line.tone == .normal)
        #expect(rows.first { $0.label == "Home" }?.line.status == "OK")
        #expect(model.accounts.allSatisfy { $0.monitored })
    }

    /// Thirteen folders holding five logins: five rows, in the lists' order and the batteries', each named by the folders
    /// that hold it.
    @Test func fiveLoginsOfThirteenFoldersAreFiveRows() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let claude = [Self.folder(.claude, "", "Main"), Self.folder(.claude, "-work", "Work"), Self.folder(.claude, "-lab", "Lab"),
                      Self.folder(.claude, "-studio", "Studio"), Self.folder(.claude, "-research", "Research"),
                      Self.folder(.claude, "-demo", "Demo"), Self.folder(.claude, "-edge", "Edge")]
        let codex = [Self.codexHome, Self.folder(.codex, "-side", "Side"), Self.folder(.codex, "-fresh", "Fresh"),
                     Self.folder(.codex, "-preset", "Preset"), Self.folder(.codex, "-night", "Night"), Self.folder(.codex, "-spare", "Spare")]
        try fakes.writeStore(accounts: claude + codex)
        for (folder, email) in zip(claude, [Self.a, Self.a, Self.b, Self.b, Self.c, Self.c, Self.a]) { fakes.claude(folder, email, stamp: nil) }
        for (folder, email) in zip(codex, [Self.a, Self.a, Self.d, Self.d, Self.a, Self.d]) { fakes.codex(folder, email, stamp: nil) }
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        // Three reads at a time: the Claude logins first, then the Codex ones.
        #expect(entries(model).map(\.line.next) == ["in 5m", "in 5m", "in 5m", "now", "now"])
        await model.settle()
        let rows = entries(model)
        #expect(model.accounts.count == 13)
        #expect(rows.map(\.label) == ["Main + Work + Edge", "Lab + Studio", "Research + Demo", "Home + Side + Night", "Fresh + Preset + Spare"])
        #expect(rows.map(\.id) == model.panel.rows.flatMap(\.batteries).map(\.id))
        #expect(rows.map(\.line.status) == ["OK", "OK", "OK", "OK", "OK"])
        #expect(rows.map(\.line.next) == ["in 5m", "in 5m", "in 5m", "in 1m", "in 1m"])
        #expect(fakes.reads.count == 5)
    }

    /// A folder signed out and one being asked who is signed in are rows of their own, after the provider's logins, named
    /// by their own alias.
    @Test func looseFoldersAreRowsOfTheirOwn() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work, F.lab])
        fakes.claude(F.work, Self.a, stamp: nil)
        fakes.claude(F.lab, nil, stamp: nil)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        fakes.holdQuestions.withValue { $0 = true }
        defer { fakes.holdQuestions.withValue { $0 = false } }
        let north = DiscoveredProfile(provider: .claude, folder: F.home + "/.claude-north", suggestedAlias: "North")
        model.add(north)
        #expect(model.asking == [north.id])
        let rows = entries(model)
        #expect(rows.map(\.label) == ["Work", "Lab", "North"])
        #expect(rows[1].line == .init(lastRead: "0s ago", next: "paused", status: "Sign-in required", tone: .red))
        #expect(rows[2].line == .init(lastRead: "never", next: "now", status: "New · first read due", tone: .normal))
        model.loginCheck?.cancel()
    }

    /// P360 through the readers: a Claude login whose CLI answers "no plan limits" is stale-retrying on its backoff, then
    /// No plan at its fourth answer 35 minutes on: never Next, no attention, read every 6 hours (Refresh all too), and
    /// its row says so. A relaunch keeps it; a good read ends it.
    @Test func aLoginWithNoPlanIsNoPlanAfterAStreakAndStaysSoAcrossARelaunch() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let main = Self.folder(.claude, "", "Main")
        try fakes.writeStore(accounts: [F.work, main])
        fakes.claude(F.work, Self.a, stamp: nil)
        fakes.claude(main, Self.b, stamp: nil)
        let answers = LockedBox<[String: Result<AccountReading, ReadError>]>([:])
        let base = fakes.claudeResult
        fakes.claudeResult = { account, now in answers.withValue { $0[account.folder] } ?? base(account, now) }
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        let t0 = DemoClock.now
        let ended = LoginsStore.id(provider: .claude, email: Self.a), kept = LoginsStore.id(provider: .claude, email: Self.b)
        answers.withValue { $0[F.work.folder] = .failure(.noPlanLimits) }

        // Read at 5, 10, 20 and 40 minutes: the first answer, then the backoff (5, 10 and 20 minutes).
        var readsAt: [TimeInterval] = []
        for minute in stride(from: 1.0, through: 45, by: 1) {
            fakes.clock.now = t0 + minute * 60
            let before = fakes.reads.count
            await model.settle()
            if fakes.reads.suffix(fakes.reads.count - before).contains("read \(F.work.id)") { readsAt.append(minute) }
        }
        #expect(readsAt == [5, 10, 20, 40])
        #expect(model.claudeRow?.batteries.first { $0.id == ended }?.state == .noPlan)
        #expect(model.claudeRow?.batteries.first { $0.id == ended }?.isNext == false && !model.panel.attentionNeeded)
        #expect(model.claudeRow?.nextAlias == "b")
        let row = try #require(entries(model).first { $0.id == ended })
        #expect(row.line.status == "No plan" && row.line.next == "in 6h" && row.line.tone == .normal)
        #expect(model.scheduler.nextDue(for: ended) == t0 + 40 * 60 + NoPlanStreak.interval)

        // Refresh all reads the other login only.
        fakes.clock.now = t0 + 50 * 60
        let before = fakes.reads.count
        model.refreshAll()
        await model.settle()
        #expect(Array(fakes.reads.dropFirst(before)) == ["read \(main.id)"])

        // A relaunch keeps it, with its wait.
        model.stop()
        let again = fakes.model()
        defer { again.stop() }
        again.start()
        await again.look()
        await again.settle()
        #expect(again.claudeRow?.batteries.first { $0.id == ended }?.state == .noPlan)
        #expect(again.scheduler.isNoPlan(ended) && again.scheduler.nextDue(for: ended) == t0 + 40 * 60 + 1 + NoPlanStreak.interval)
        #expect(!fakes.reads.dropFirst(before + 1).contains("read \(F.work.id)"))

        // Resubscribed: its own Refresh reads it, and a good read ends it.
        answers.withValue { $0[F.work.folder] = nil }
        again.refreshAccount(ended)
        await again.settle()
        #expect(again.claudeRow?.batteries.first { $0.id == ended }?.state == .available(percentLeft: 60, isLow: false))
        #expect(!again.scheduler.isNoPlan(ended) && again.records[ended]?.noPlan == nil)
        _ = kept
    }
}
