import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// `JuiceReadingsUsageModel` against temp copies of Juice's two files, written with JuiceCore's own types and encoder.
/// Fictional folders and emails only; the real Application Support folder is never touched.
@MainActor
struct JuiceReadingsUsageModelTests {
    static let now = DemoClock.now
    static let work = Account(provider: .claude, folder: "/Users/person1/.claude-work", alias: "Work", knownEmail: "person1@example.com")
    static let side = Account(provider: .codex, folder: "/Users/person1/.codex-side", alias: "Side", knownEmail: "person1@example.com")

    private struct AccountsFixture: Encodable { var version = 1; var accounts: [Account] }
    private struct ReadingsFixture: Encodable { var version = 1; var records: [String: AccountRecord] }

    /// A reading that names the folder's account, as Juice Island's readings do.
    static func record(_ account: Account, left: Double) -> AccountRecord {
        AccountRecord(lastGood: AccountReading(accountID: account.id, readAt: now - 120, plan: "pro", email: account.knownEmail, windows: [
            UsageWindow(seconds: 18_000, usedPercent: 100 - left, resetsAt: now + 3_600),
        ]), lastAttemptAt: now - 120)
    }

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ directory: URL, accounts: [Account]? = [work, side], records: [String: AccountRecord]? = nil) throws {
        if let accounts {
            try JSONEncoder.juice.encode(AccountsFixture(accounts: accounts)).write(to: directory.appendingPathComponent("accounts.json"), options: .atomic)
        }
        let records = records ?? [work.id: record(work, left: 64), side.id: record(side, left: 30)]
        try JSONEncoder.juice.encode(ReadingsFixture(records: records)).write(to: directory.appendingPathComponent("readings.json"), options: .atomic)
    }

    static func model(_ directory: URL) -> JuiceReadingsUsageModel {
        JuiceReadingsUsageModel(directory: directory, pollInterval: nil, clock: { now })
    }

    @Test
    func decodesJuiceFilesAndBuildsTheHeaderLikeTheDemo() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(directory)
        let usage = Self.model(directory)
        #expect(usage.accounts == [Self.work, Self.side])
        #expect(usage.records[Self.work.id] == Self.record(Self.work, left: 64))
        let built = FolderLogins.build(accounts: usage.accounts, records: [Self.work.id: Self.record(Self.work, left: 64),
                                                                           Self.side.id: Self.record(Self.side, left: 30)], now: Self.now)
        #expect(usage.panel == FolderLogins.panel(built, money: MoneyRowModel.notConnected, now: Self.now) && usage.logins == built.lists)
        #expect(usage.claudeRow?.batteries.map(\.state) == [.available(percentLeft: 64, isLow: false)])
        #expect(usage.codexRow?.batteries.map(\.alias) == ["person1"])
        #expect(usage.now == Self.now && usage.refreshUnavailableReason != nil)
        // Money: no readers yet, so every source is rails, never a demo figure.
        #expect(usage.panel.money.map(\.id) == MoneyRowModel.sourceNames && usage.panel.money.allSatisfy { $0.amount == nil })
        #expect(usage.moneyDetails.values.allSatisfy { !$0.isReadable && $0.parts == ["not connected"] })
    }

    /// P93 in the dev build: folders whose readings name one account share its row and its battery, named by the email's
    /// local part; a signed-out folder has none of its own and raises the sign-in badge; a folder whose reading names no
    /// email waits, whatever its known email says (that comes from discovery, not from a CLI).
    @Test
    func foldersOfOneAccountShareItsRowAndBattery() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = Account(provider: .codex, folder: "/Users/person1/.codex", alias: "default")
        let fresh = Account(provider: .codex, folder: "/Users/person1/.codex-fresh", alias: "fresh")
        let preset = Account(provider: .codex, folder: "/Users/person1/.codex-preset", alias: "preset", knownEmail: "person1@example.com")
        var homeRecord = Self.record(home, left: 30)
        homeRecord.lastGood?.email = "person1@example.com"
        homeRecord.lastGood?.readAt = Self.now - 60
        let signedOut = AccountRecord(lastError: .signInRequired, lastErrorAt: Self.now - 600, lastAttemptAt: Self.now - 600)
        try Self.write(directory, accounts: [Self.work, home, Self.side, fresh, preset],
                       records: [Self.work.id: Self.record(Self.work, left: 64), home.id: homeRecord,
                                 Self.side.id: Self.record(Self.side, left: 30), fresh.id: signedOut,
                                 preset.id: Self.record(Account(provider: .codex, folder: preset.folder, alias: "preset"), left: 90)])
        let usage = Self.model(directory)
        let codex = try #require(usage.logins.first { $0.provider == .codex })
        #expect(codex.logins.map(\.email) == ["person1@example.com"] && codex.logins.first?.folders == [home, Self.side].map { account in
            var listed = account
            listed.monitored = true
            return listed
        })
        #expect(codex.folders.map(\.folder.alias) == ["fresh", "preset"] && codex.folders.map(\.state) == [.signedOut, .unknown])
        #expect(usage.codexRow?.batteries.count == 1 && usage.panel.attentionNeeded)
        #expect(usage.codexRow?.batteries.first?.alias == "person1" && codex.logins.first?.plan == "Pro")
        // The newest reading of the two folders is the account's.
        #expect(usage.records[try #require(codex.logins.first?.id)]?.lastGood?.readAt == Self.now - 60)
    }

    @Test
    func picksUpAnAtomicReplaceOfEitherFile() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(directory)
        let usage = Self.model(directory)
        try Self.write(directory, records: [Self.work.id: Self.record(Self.work, left: 20), Self.side.id: Self.record(Self.side, left: 30)])
        usage.poll()
        #expect(usage.claudeRow?.batteries.first?.state == .available(percentLeft: 20, isLow: false))
        var off = Self.side
        off.monitored = false
        try Self.write(directory, accounts: [Self.work, off])
        usage.poll()
        #expect(usage.accounts.count == 2 && usage.codexRow == nil)
    }

    @Test
    func missingOrUnreadableFilesShowTheEmptyHeader() throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("juice-missing-\(UUID().uuidString)")
        let missing = Self.model(gone)
        #expect(missing.panel.rows.isEmpty && missing.accounts.isEmpty && missing.panel.money == MoneyRowModel.notConnected)

        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("accounts.json"))
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("readings.json"))
        let unreadable = Self.model(directory)
        #expect(unreadable.panel.rows.isEmpty && unreadable.records.isEmpty)

        // Accounts without readings: Juice's folders, listed, with no account named yet and so no battery.
        try Self.write(directory, records: [:])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("readings.json"))
        unreadable.poll()
        #expect(unreadable.allBatteries.isEmpty && unreadable.logins.flatMap(\.folders).map(\.state) == [.unknown, .unknown])
    }

    @Test
    func neverWritesJuiceFiles() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(directory)
        let files = ["accounts.json", "readings.json"].map { directory.appendingPathComponent($0) }
        func snapshot() throws -> [(Data, Date?)] {
            try files.map { (try Data(contentsOf: $0), try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) }
        }
        let before = try snapshot()
        let usage = Self.model(directory)
        usage.poll()
        usage.refreshAll()
        usage.poll(force: true)
        let after = try snapshot()
        #expect(zip(before, after).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["accounts.json", "readings.json"])
    }

    @Test
    func usageSourceDefaultsToJuiceInTheAppAndDemoWhenEphemeral() throws {
        #expect(AppSettings.ephemeral().usageSource == .demo)
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.usageSource == .juiceReadings)
        settings.usageSource = .demo
        #expect(AppSettings(defaults: defaults).usageSource == .demo)
    }

    @Test
    func environmentFollowsTheUsageSource() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(directory)
        let settings = AppSettings.ephemeral()
        let env = AppEnvironment.app(settings: settings, juiceDirectory: directory)
        #expect(env.usage is DemoUsageModel)
        settings.usageSource = .juiceReadings
        for _ in 0..<100 where !(env.usage is JuiceReadingsUsageModel) { try await Task.sleep(for: .milliseconds(10)) }
        let juice = try #require(env.usage as? JuiceReadingsUsageModel)
        #expect(juice.directory == directory && juice.accounts.count == 2)
        settings.usageSource = .demo
        for _ in 0..<100 where !(env.usage is DemoUsageModel) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(env.usage is DemoUsageModel)
    }

    @Test
    func accountsPaneShowsFixturesOnlyForDemoData() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(directory)
        let usage = Self.model(directory)
        #expect(!AccountsPane.showsFixtures(usage) && AccountsPane.showsFixtures(DemoUsageModel()))
        // The reading's own plan, never the demo's table, though the demo also has a "Work".
        #expect(usage.logins.first?.logins.first?.plan == "Pro")
        let demoWork = try #require(DemoUsageModel().logins.flatMap(\.logins).first { $0.folders.map(\.alias) == ["Work"] })
        #expect(demoWork.plan == DemoUsageData.plans["Work"] && demoWork.email == "work@example.com")
        // The demo's batteries are its folders': Copy email finds the account through the folder.
        #expect(DemoUsageModel().email(of: DemoUsageData.accounts[1].id) == "work@example.com")
        #expect(usage.email(of: try #require(usage.logins.first?.logins.first?.id)) == "person1@example.com")
    }
}
