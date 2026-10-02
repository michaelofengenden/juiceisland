import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// P580 and P581 on `LiveUsageModel`'s fakes: one email signed in to a personal plan in one folder and to a Team
/// organization in another is two logins, two batteries, each read on its own floor; a login from before organizations
/// were named takes its organization's id with everything it had; "+" places a new folder in the organization its own
/// sign-in picked. Fictional folders, emails and organizations only; nothing real is asked or read.
@MainActor
@Suite(.serialized)
struct OrganizationLoginsTests {
    typealias F = LiveFakes

    static let sam = "sam@example.com"
    static let main = Account(provider: .claude, folder: F.home + "/.claude", alias: "Main")
    static let lab = Account(provider: .claude, folder: F.home + "/.claude-lab", alias: "Lab")
    static let personalOrg = LoginOrganization.key(for: "0b7e5c2a-1111-4c3d-9e8f-000000000001")
    static let labOrg = LoginOrganization.key(for: "0b7e5c2a-2222-4c3d-9e8f-000000000002")
    static let personal = SignInIdentity(email: sam, plan: "max", org: personalOrg)
    static let research = SignInIdentity(email: sam, plan: "team", org: labOrg, orgName: "Research Lab")
    static let personalID = LoginsStore.id(provider: .claude, email: sam, org: personalOrg)
    static let labID = LoginsStore.id(provider: .claude, email: sam, org: labOrg)

    static func answers(_ fakes: LiveFakes, _ folders: [(Account, SignInIdentity)]) {
        fakes.claudeFolders.withValue { all in
            for (folder, who) in folders { all[folder.folder] = LiveFakes.ClaudeFolder(who: .success(who), stamp: nil) }
        }
    }

    /// `~/.claude` 40 % used on Max, `~/.claude-lab` 25 % on the Team plan; `lab` may answer a 429 instead.
    static func readings(_ fakes: LiveFakes, labResult: LockedBox<ReadError?> = LockedBox(nil)) {
        let labFolder = lab.folder
        fakes.claudeResult = { account, now in
            if account.folder == labFolder, let error = labResult.withValue({ $0 }) { return .failure(error) }
            let team = account.folder == labFolder
            return .success(AccountReading(accountID: account.id, readAt: now, plan: team ? "team" : "max", windows: [
                UsageWindow(seconds: 18_000, usedPercent: team ? 25 : 40, resetsAt: now + 3_600),
                UsageWindow(seconds: 604_800, usedPercent: 10, resetsAt: now + 86_400),
            ]))
        }
    }

    func claudeReads(_ fakes: LiveFakes) -> [String] { fakes.reads.filter { $0.hasPrefix("read claude") } }

    /// Two folders of one email in two organizations: asked once each, two logins, two rows and two batteries, the
    /// organization's named; each read on its own floor, and a 429 on one holds only that one.
    @Test func oneEmailInTwoOrganizationsIsTwoBatteriesReadApart() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [Self.main, Self.lab])
        Self.answers(fakes, [(Self.main, Self.personal), (Self.lab, Self.research)])
        let labFailure = LockedBox<ReadError?>(nil)
        Self.readings(fakes, labResult: labFailure)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let t0 = DemoClock.now

        #expect(Set(claudeReads(fakes)) == ["read \(Self.main.id)", "read \(Self.lab.id)"] && claudeReads(fakes).count == 2)
        let list = try #require(model.list(.claude))
        #expect(list.logins.map(\.id) == [Self.personalID, Self.labID] && list.folders.isEmpty)
        #expect(list.logins.map(\.email) == [Self.sam, Self.sam] && list.logins.map(\.org) == [nil, "Research Lab"])
        #expect(list.logins.map(\.plan) == ["Max", "Team"] && list.logins.map { $0.folders.map(\.alias) } == [["Main"], ["Lab"]])
        #expect(model.claudeRow?.batteries.map(\.alias) == ["sam", "sam · Research Lab"])
        #expect(model.claudeRow?.batteries.map(\.state) == [.available(percentLeft: 60, isLow: false), .available(percentLeft: 75, isLow: false)])
        #expect(model.records[Self.labID]?.lastGood?.org == Self.labOrg && model.records[Self.personalID]?.lastGood?.org == Self.personalOrg)
        // The hover names the organization; Diagnostics too, by alias, never by email or id.
        #expect(HoverLabelText.full(.account(Self.labID), usage: model)?.name == "sam · Research Lab")
        let rows = DiagnosticsText.accounts(model.logins, records: model.records, now: model.now)
        #expect(rows.map(\.label) == ["Main", "Lab · Research Lab"])

        // Each on its own floor: nothing before 300 s, then one read each.
        #expect(model.scheduler.nextDue(for: Self.personalID) == t0 + 300 && model.scheduler.nextDue(for: Self.labID) == t0 + 300)
        fakes.clock.now = t0 + 299
        await model.settle()
        #expect(claudeReads(fakes).count == 2)
        // A 429 on the organization's login holds it alone.
        labFailure.withValue { $0 = .rateLimited(retryAfter: 60) }
        fakes.clock.now = t0 + 300
        await model.settle()
        #expect(claudeReads(fakes).count == 4)
        labFailure.withValue { $0 = nil }
        fakes.clock.now = t0 + 600
        await model.settle()
        #expect(claudeReads(fakes).suffix(1) == ["read \(Self.main.id)"] && claudeReads(fakes).count == 5)
        #expect(model.scheduler.nextDue(for: Self.labID) == t0 + 300 + 960)
        #expect(model.records[Self.labID]?.lastError == .rateLimited(retryAfter: 60) && model.records[Self.personalID]?.lastError == nil)
    }

    /// An existing user: logins.json holds the email's login from before organizations were named, with a reading, a
    /// 429 pause and history. The folder's first answer names its organization: the login takes that id with all of it,
    /// nothing is read before the pause ends, and then it is read under its new id.
    @Test func anExistingLoginTakesItsOrganizationWithItsRecordPauseAndHistory() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let t0 = DemoClock.now
        let plainID = LoginsStore.id(provider: .claude, email: Self.sam)
        let before = AccountRecord(lastGood: AccountReading(accountID: plainID, readAt: t0 - 600, plan: "max", email: Self.sam, windows: [
            UsageWindow(seconds: 18_000, usedPercent: 30, resetsAt: t0 + 3_600),
        ]), lastError: .rateLimited(retryAfter: 60), lastErrorAt: t0 - 120, lastAttemptAt: t0 - 120, consecutiveFailures: 1)
        try fakes.writeStore(accounts: [Self.main])
        let stored = LoginsStore(fileURL: fakes.directory.appendingPathComponent("logins.json"))
        stored.place(Self.sam, in: Self.main, now: t0 - 3_600)
        stored.apply(.success(try #require(before.lastGood)), to: plainID, at: t0 - 600)
        stored.apply(.failure(.rateLimited(retryAfter: 60)), to: plainID, at: t0 - 120)
        try stored.save()
        Self.answers(fakes, [(Self.main, Self.personal)])
        Self.readings(fakes)

        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.entries.contains("auth \(Self.main.folder)") && claudeReads(fakes).isEmpty)
        #expect(model.loginID(of: Self.main) == Self.personalID && model.loginsStore.logins[plainID] == nil)
        let login = try #require(model.loginsStore.logins[Self.personalID])
        #expect(login.monitored && login.record?.lastError == .rateLimited(retryAfter: 60) && login.record?.lastErrorAt == t0 - 120)
        #expect(login.record?.lastGood?.readAt == t0 - 600 && login.record?.lastGood?.windows.first?.usedPercent == 30)
        #expect(model.history.samples(Self.personalID, window: "5h").count == 1 && model.history.samples(plainID, window: "5h").isEmpty)
        #expect(model.list(.claude)?.logins.map(\.id) == [Self.personalID] && model.claudeRow?.batteries.map(\.alias) == ["sam"])
        // The pause holds (Retry-After + 900 s from the saved 429), then one read, under the new id.
        let due = try #require(model.scheduler.nextDue(for: Self.personalID))
        #expect(due >= t0 - 120 + 960 && due <= t0 - 120 + 961)
        fakes.clock.now = due - 1
        await model.settle()
        #expect(claudeReads(fakes).isEmpty)
        fakes.clock.now = due
        await model.settle()
        #expect(claudeReads(fakes) == ["read \(Self.main.id)"])
        #expect(model.records[Self.personalID]?.lastGood?.readAt == due && model.records[Self.personalID]?.lastError == nil)
        // Saved under the new id, the old one gone.
        let saved = LoginsStore(fileURL: stored.fileURL)
        saved.load()
        #expect(Set(saved.logins.keys) == [Self.personalID] && saved.state(of: Self.main.id) == .signedIn(login: Self.personalID))
    }

    /// The same with the login due at launch: its read asks first, the answer renames the login, and that read reads
    /// nothing; the login is read once under its new id, its floor counted from the saved reading.
    @Test func aReadWhoseQuestionRenamesItsLoginReadsItOnceUnderTheNewID() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let t0 = DemoClock.now
        let plainID = LoginsStore.id(provider: .claude, email: Self.sam)
        try fakes.writeStore(accounts: [Self.main])
        let stored = LoginsStore(fileURL: fakes.directory.appendingPathComponent("logins.json"))
        stored.place(Self.sam, in: Self.main, now: t0 - 3_600)
        stored.apply(.success(AccountReading(accountID: plainID, readAt: t0 - 200, plan: "max", email: Self.sam, windows: [
            UsageWindow(seconds: 18_000, usedPercent: 30, resetsAt: t0 + 3_600),
        ])), to: plainID, at: t0 - 200)
        try stored.save()
        Self.answers(fakes, [(Self.main, Self.personal)])
        Self.readings(fakes)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        // Read 200 s ago: the floor holds, so the question comes from the clock, not from a read.
        #expect(model.loginID(of: Self.main) == Self.personalID && claudeReads(fakes).isEmpty)
        #expect(model.scheduler.nextDue(for: Self.personalID) == t0 - 200 + 1 + 300)
        fakes.clock.now = t0 + 101
        await model.settle()
        await model.settle()
        #expect(claudeReads(fakes) == ["read \(Self.main.id)"] && fakes.entries.filter { $0.hasPrefix("auth") }.count == 1)

        // Due at launch instead: the read's own question renames the login, and that read reads nothing.
        let later = try LiveFakes()
        defer { later.cleanUp() }
        try later.writeStore(accounts: [Self.main])
        let old = LoginsStore(fileURL: later.directory.appendingPathComponent("logins.json"))
        old.place(Self.sam, in: Self.main, now: t0 - 3_600)
        old.apply(.success(AccountReading(accountID: plainID, readAt: t0 - 900, plan: "max", email: Self.sam, windows: [
            UsageWindow(seconds: 18_000, usedPercent: 30, resetsAt: t0 + 3_600),
        ])), to: plainID, at: t0 - 900)
        try old.save()
        Self.answers(later, [(Self.main, Self.personal)])
        Self.readings(later)
        let second = later.model()
        defer { second.stop() }
        second.start()
        await second.settle()
        #expect(second.loginID(of: Self.main) == Self.personalID && claudeReads(later).isEmpty)
        #expect(later.entries.filter { $0.hasPrefix("auth") } == ["auth \(Self.main.folder)"])
        await second.settle()
        #expect(claudeReads(later) == ["read \(Self.main.id)"] && later.entries.filter { $0.hasPrefix("auth") }.count == 1)
        #expect(second.records[Self.personalID]?.lastGood?.readAt == t0 && second.loginsStore.logins[plainID] == nil)
    }

    /// P584: the personal Max plan used up, the organization's login is Next; the account list's summary and the usage
    /// window's caption name it whole ("next sam · Research Lab"), and a narrow caption drops a part, never half a name.
    @Test func theNextOrganizationLoginIsNamedWholeInTheSummaryAndTheCaption() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [Self.main, Self.lab])
        Self.answers(fakes, [(Self.main, Self.personal), (Self.lab, Self.research)])
        let labFolder = Self.lab.folder
        fakes.claudeResult = { account, now in
            let team = account.folder == labFolder
            return .success(AccountReading(accountID: account.id, readAt: now, plan: team ? "team" : "max", windows: [
                UsageWindow(seconds: 18_000, usedPercent: team ? 25 : 100, resetsAt: now + 3_600),
            ]))
        }
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()

        let row = try #require(model.claudeRow)
        #expect(row.nextAlias == "sam · Research Lab" && row.batteries.map(\.isNext) == [false, true])
        #expect(AccountListText.summary(row) == "1 of 2 available · next sam · Research Lab")
        let label = try #require(HoverLabelText.full(.provider(.claude), usage: model))
        #expect(label.name == "Claude" && label.parts.prefix(2) == ["1 of 2 available", "next sam · Research Lab"])
        #expect(label.parts.count == 3 && label.parts[2].hasPrefix("oldest reading"))
        let narrow = HoverLabelText.measure(HoverLabel(name: "Claude", parts: Array(label.parts.prefix(2)))) + 1
        #expect(HoverLabelText.fit(label, width: narrow).parts == ["1 of 2 available", "next sam · Research Lab"])
    }

    /// P585 on the live model: `~/.claude-work`, signed out when the update came and in again since, answers the personal
    /// organization before `~/.claude`, which holds the email's old login in a 429 pause. Nothing is read inside the
    /// pause, and once `~/.claude` answers, the old login, its reading and its history are the organization's.
    @Test func aSecondFolderOfTheOrganizationAnsweringFirstKeepsTheOldLoginsPause() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let t0 = DemoClock.now
        let plainID = LoginsStore.id(provider: .claude, email: Self.sam)
        let work = Account(provider: .claude, folder: F.home + "/.claude-work", alias: "Work")
        try fakes.writeStore(accounts: [work, Self.main])
        let stored = LoginsStore(fileURL: fakes.directory.appendingPathComponent("logins.json"))
        stored.place(Self.sam, in: Self.main, now: t0 - 3_600)
        stored.apply(.success(AccountReading(accountID: plainID, readAt: t0 - 600, plan: "max", email: Self.sam, windows: [
            UsageWindow(seconds: 18_000, usedPercent: 30, resetsAt: t0 + 3_600),
        ])), to: plainID, at: t0 - 600)
        stored.apply(.failure(.rateLimited(retryAfter: 600)), to: plainID, at: t0 - 120)
        stored.signOut(work.id)
        try stored.save()
        Self.answers(fakes, [(work, Self.personal), (Self.main, Self.personal)])
        Self.readings(fakes)

        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.entries.filter { $0.hasPrefix("auth") } == ["auth \(work.folder)", "auth \(Self.main.folder)"])
        #expect(model.loginID(of: work) == Self.personalID && model.loginID(of: Self.main) == Self.personalID)
        #expect(model.loginsStore.logins[plainID] == nil && claudeReads(fakes).isEmpty)
        let login = try #require(model.loginsStore.logins[Self.personalID])
        #expect(login.record?.lastError == .rateLimited(retryAfter: 600) && login.record?.lastGood?.readAt == t0 - 600)
        #expect(model.history.samples(Self.personalID, window: "5h").count == 1)
        let due = try #require(model.scheduler.nextDue(for: Self.personalID))
        #expect(due >= t0 - 120 + 1_500)
        fakes.clock.now = due - 1
        await model.settle()
        #expect(claudeReads(fakes).isEmpty)
    }

    /// "+" makes a folder and runs the CLI's own sign-in there, naming no organization (the owner picks it on the sign-in
    /// page); the check finds the email in the Team organization, so the folder is a login and a battery of its own
    /// beside the personal one, its organization in its row.
    @Test func plusPlacesTheNewFolderInTheOrganizationItsSignInPicked() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let record = fakes.directory.appendingPathComponent("login.txt").path
        let login = try fakes.loginCLI("claude", "printf '%s|%s\\n' \"$*\" \"${CLAUDE_CONFIG_DIR:-none}\" > '\(record)'\nexit 0")
        fakes.located = [.claude: login, .codex: URL(fileURLWithPath: "/fake/bin/codex")]
        let main = Account(provider: .claude, folder: home + "/.claude", alias: "Main")
        let newFolder = Account(provider: .claude, folder: home + "/.claude-research", alias: "research")
        try fakes.writeStore(accounts: [main])
        Self.answers(fakes, [(main, Self.personal), (newFolder, Self.research)])
        Self.readings(fakes)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(model.list(.claude)?.logins.map(\.id) == [Self.personalID])

        #expect(try model.addAccount("research", provider: .claude).get() == newFolder)
        for _ in 0..<300 where !model.signingIn.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.signInCoordinator.phase == .done(email: Self.sam))
        let handed = URL(fileURLWithPath: newFolder.folder).standardizedFileURL.resolvingSymlinksInPath().path
        #expect(try String(contentsOfFile: record, encoding: .utf8) == "auth login|\(handed)\n")    // no organization passed
        #expect(model.loginID(of: newFolder) == Self.labID && model.loginID(of: main) == Self.personalID)
        let list = try #require(model.list(.claude))
        #expect(list.logins.map(\.title) == [Self.sam, Self.sam + " · Research Lab"])
        #expect(list.logins.map { $0.folders.map(\.id) } == [[main.id], [newFolder.id]])
        await model.settle()
        #expect(model.claudeRow?.batteries.map(\.alias) == ["sam", "sam · Research Lab"])
    }

    /// P581 through the readers: an organization's login whose CLI reports no limits is No limits after the streak,
    /// dimmed, never Next, read every 6 hours; its row offers no Remove, and Diagnostics says No limits.
    @Test func anOrganizationWithNoLimitsIsNoLimitsNotNoPlan() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [Self.main, Self.lab])
        Self.answers(fakes, [(Self.main, Self.personal), (Self.lab, Self.research)])
        let labFailure = LockedBox<ReadError?>(.noLimitsReported)
        Self.readings(fakes, labResult: labFailure)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let t0 = DemoClock.now
        for at in [300.0, 900, 2_100] {                                         // the backoff: 5, 15 and 35 minutes
            fakes.clock.now = t0 + at
            await model.settle()
        }
        let battery = try #require(model.claudeRow?.batteries.first { $0.id == Self.labID })
        #expect(battery.state == .noLimits && !battery.isNext && !model.panel.attentionNeeded)
        #expect(battery.hoverLabel == "sam · Research Lab · " + NoPlanStreak.usageHover)
        #expect(model.claudeRow?.availability.available == 1 && model.claudeRow?.availability.total == 1)
        #expect(model.scheduler.nextDue(for: Self.labID) == t0 + 2_100 + NoPlanStreak.interval)
        #expect(AccountListText.detail(battery, usage: model).text == "billed by usage")
        let rows = DiagnosticsText.accounts(model.logins, records: model.records, schedule: { model.schedule(of: $0) }, now: model.now)
        #expect(rows.map(\.line.status) == ["OK", "No limits"] && rows[1].line.next == "in 6h")
    }

    /// P731 through the readers: a read of the email's login through Main is under way when Lab's answer names the
    /// organization, so the login takes the organization's id and is read through Lab (its file changed last) under it.
    /// Main's read began first and ends last: the organization's newer reading stays, Main's older one is an attempt only.
    @Test func aReadThatEndsAfterItsLoginWasRenamedNeverReplacesTheNewerReading() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let plainID = LoginsStore.id(provider: .claude, email: Self.sam)
        try fakes.writeStore(accounts: [Self.main, Self.lab])
        let plain = SignInIdentity(email: Self.sam, plan: "max")
        fakes.claudeFolders.withValue {
            $0[Self.main.folder] = LiveFakes.ClaudeFolder(who: .success(plain), stamp: AuthFileStamp(inode: 1, modifiedSeconds: 200))
            $0[Self.lab.folder] = LiveFakes.ClaudeFolder(who: .success(plain), stamp: AuthFileStamp(inode: 2, modifiedSeconds: 100))
        }
        let mainFolder = Self.main.folder
        fakes.claudeResult = { account, now in
            .success(AccountReading(accountID: account.id, readAt: now, plan: "max", windows: [
                UsageWindow(seconds: 18_000, usedPercent: account.folder == mainFolder ? 70 : 40, resetsAt: now + 3_600),
            ]))
        }
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let t0 = DemoClock.now
        #expect(model.loginID(of: Self.main) == plainID && model.loginID(of: Self.lab) == plainID)
        #expect(model.records[plainID]?.lastGood?.readAt == t0 && fakes.reads == ["read \(Self.main.id)"])

        // Due again: its read through Main (its file changed last) is under way.
        fakes.heldReads.withValue { $0.insert(Self.main.folder) }
        fakes.clock.now = t0 + 1_850
        await model.scheduler.tick()
        #expect(await Looks.until(10) { fakes.reads.count == 2 } && model.scheduler.isInFlight(plainID))
        // Lab's CLI now names the organization (its file was rewritten): a look past the recheck interval asks, and the
        // login takes the organization's id, with both folders.
        fakes.claudeFolders.withValue {
            $0[Self.lab.folder] = LiveFakes.ClaudeFolder(who: .success(Self.personal), stamp: AuthFileStamp(inode: 2, modifiedSeconds: 300))
        }
        fakes.clock.now = t0 + 1_900
        await model.look()
        #expect(model.loginID(of: Self.lab) == Self.personalID && model.loginID(of: Self.main) == Self.personalID)
        // Read under its new id, through Lab, at once: the newer reading, 40 % used.
        fakes.clock.now = t0 + 1_910
        await model.scheduler.tick()
        #expect(await Looks.until(10) { model.records[Self.personalID]?.lastGood?.readAt == t0 + 1_910 })
        // Main's read, begun at t0 + 1,850, ends now with 70 % used.
        fakes.heldReads.withValue { $0.removeAll() }
        await model.scheduler.waitForInFlight()
        let record = try #require(model.records[Self.personalID])
        #expect(record.lastGood?.readAt == t0 + 1_910 && record.lastGood?.windows.first?.usedPercent == 40)
        #expect(record.lastAttemptAt == t0 + 1_910 && record.lastError == nil)
        #expect(model.claudeRow?.batteries.map(\.state) == [.available(percentLeft: 60, isLow: false)])
        #expect(model.history.samples(Self.personalID, window: "5h").map(\.used).last == 40)
    }
}
