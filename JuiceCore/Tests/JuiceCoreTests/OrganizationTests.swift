import Foundation
import Testing
@testable import JuiceCore

/// P580: one email signed in to two Claude organizations (a personal Max plan and a Team or Enterprise organization the
/// sign-in page picked) is two logins, never one. P581: an organization or Console login billed by usage, whose CLI
/// reports no plan limits, is No limits, never "subscription ended?" or signed out. Shapes from Claude Code 2.1's own
/// `claude auth status --json` and `get_usage` schema; fictional emails, organizations and folders only.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let sam = "sam@example.com"
private let main = Account(provider: .claude, folder: "/h/.claude", alias: "Main")
private let lab = Account(provider: .claude, folder: "/h/.claude-lab", alias: "Lab")
private let work = Account(provider: .claude, folder: "/h/.claude-work", alias: "Work")
/// Two organization ids, as `claude auth status` prints them (fictional).
private let personalID = "0b7e5c2a-1111-4c3d-9e8f-000000000001"
private let labID = "0b7e5c2a-2222-4c3d-9e8f-000000000002"
private let personal = LoginIdentity(email: sam, org: LoginOrganization.key(for: personalID))
private let research = LoginIdentity(email: sam, org: LoginOrganization.key(for: labID), orgName: "Research Lab")

private func authStatus(_ fields: String) -> String {
    #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "analyticsDisabled": false, "#
        + #""projectsDirectory": "/h/.claude-lab/projects", "configDirectory": "/h/.claude-lab", "# + fields + "}"
}

private func reading(_ id: String, at date: Date, used: Double, email: String? = nil, plan: String = "max") -> AccountReading {
    AccountReading(accountID: id, readAt: date, plan: plan, email: email,
                   windows: [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: date + 3_600)])
}

@MainActor
private func store() -> LoginsStore {
    LoginsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("juice-orgs-\(UUID().uuidString)/logins.json"))
}

// MARK: What the CLI says

/// `claude auth status --json` names the organization: its id goes no further than a hash, and its name only when it is
/// not the personal one Claude names after the email. A Console login is billed by usage; signed out is signed out; a
/// CLI too old to name an organization names none.
@Test func authStatusNamesTheOrganizationByItsHashAndItsNameOnlyWhenShown() throws {
    let personalAnswer = try CLIIdentityChecker.claudeIdentity(fromAuthStatus: authStatus(
        #""email": "sam@example.com", "orgId": "\#(personalID)", "orgName": "sam@example.com's Organization", "subscriptionType": "max""#)).get()
    #expect(personalAnswer == SignInIdentity(email: sam, plan: "max", org: LoginOrganization.key(for: personalID)))
    #expect(personalAnswer.login == personal)
    let labAnswer = try CLIIdentityChecker.claudeIdentity(fromAuthStatus: authStatus(
        #""email": "sam@example.com", "orgId": "\#(labID)", "orgName": "Research Lab", "subscriptionType": "team""#)).get()
    #expect(labAnswer.login == research && labAnswer.plan == "team" && !labAnswer.usageBilled)
    // The id itself is never kept: only its 16 hex digits.
    #expect(!String(describing: labAnswer).contains(labID) && labAnswer.org?.count == 16 && labAnswer.org != personalAnswer.org)

    let console = try CLIIdentityChecker.claudeIdentity(fromAuthStatus: authStatus(
        #""apiKeySource": "/login managed key", "email": "sam@example.com", "orgId": "\#(labID)", "orgName": "Research Lab", "subscriptionType": null"#)).get()
    #expect(console.usageBilled && console.plan == nil && console.login == research)
    #expect(CLIIdentityChecker.claudeIdentity(fromAuthStatus: #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#)
        == .failure(.signInRequired))
    let older = try CLIIdentityChecker.claudeIdentity(fromAuthStatus: #"{"loggedIn": true, "email": "sam@example.com", "subscriptionType": "max"}"#).get()
    #expect(older.login == LoginIdentity(email: sam) && !older.usageBilled)
}

@Test func onlyAnOrganizationThatIsNotThePersonalOneIsNamed() {
    #expect(LoginOrganization.shownName("sam@example.com's Organization", email: "Sam@Example.com") == nil)
    #expect(LoginOrganization.shownName("SAM@EXAMPLE.COM\u{2019}s organization", email: sam) == nil)
    // Nothing that holds an "@" is shown, whosever email it is.
    #expect(LoginOrganization.shownName("other@example.com's Organization", email: sam) == nil)
    #expect(LoginOrganization.shownName("  Research Lab ", email: sam) == "Research Lab")
    #expect(LoginOrganization.shownName("", email: sam) == nil && LoginOrganization.shownName(nil, email: sam) == nil)
    #expect(LoginOrganization.key(for: " \(labID.uppercased())\n") == LoginOrganization.key(for: labID))
    #expect(LoginOrganization.key(for: "  ") == nil)
}

// MARK: What get_usage says

/// A Team organization with windows is a battery like any other, with its plan word.
@Test func anOrganizationsPlanWithWindowsReadsAsABattery() throws {
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture("claude-get-usage-team"))
    let readAt = try #require(ISO8601DateFormatter.juiceDate("2026-09-29T12:00:00Z"))   // before the fixture's resets
    let team = try response.reading(accountID: lab.id, readAt: readAt)
    #expect(team.plan == "team" && team.windows.map(\.seconds) == [18_000, 604_800] && team.windows.map(\.usedPercent) == [12, 30])
    #expect(AccountRecord(lastGood: team).planWord == "Team")
    #expect(Rules.state(reading: team, lastError: nil, signingIn: false, provider: .claude, now: readAt + 60)
        == .available(percentLeft: 70, isLow: false))
}

/// An organization billed by usage reports no limits (`rate_limits_available:true` with every window null), and so does
/// a Console login: neither is a personal plan's "no plan limits" (P360) nor a sign-out. `rate_limits_available:false`
/// with any plan named is the CLI's answer that the login lost its inference scope, as an ended plan's does (P583): a
/// seat taken away is No plan, "subscription ended?", with Remove in its row, never "billed by usage".
@Test func anOrganizationWithNoLimitsSaysSoInItsOwnWords() throws {
    func answer(_ data: Data) -> ReadError? {
        do {
            _ = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data).reading(accountID: lab.id, readAt: t0)
            return nil
        } catch {
            return error as? ReadError
        }
    }
    #expect(answer(try fixture("claude-get-usage-enterprise-no-limits")) == .noLimitsReported)
    #expect(answer(Data(#"{"subscription_type":"enterprise","rate_limits_available":false,"rate_limits":null}"#.utf8)) == .noPlanLimits)
    #expect(answer(Data(#"{"subscription_type":"team","rate_limits_available":false,"rate_limits":null}"#.utf8)) == .noPlanLimits)
    // Null windows count as no limits only where the CLI says it has limits to report: without that word they are no
    // reading yet, as a personal plan's are.
    #expect(answer(Data(#"{"subscription_type":"team","rate_limits":{"five_hour":null,"seven_day":null}}"#.utf8))
        == .incomplete("no windows reported"))
    // P360 unchanged: a personal plan's explicit answer is No plan's, its empty windows no reading yet.
    #expect(answer(try fixture("claude-get-usage-no-plan")) == .noPlanLimits)
    #expect(answer(Data(#"{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":null}}"#.utf8))
        == .incomplete("no windows reported"))
    // A Console login's answer is a signed-out one's: only its folder's question tells them apart (`ClaudeIdentityWatch`).
    #expect(answer(try fixture("claude-get-usage-console")) == .signInRequired)
    #expect(ReadError.noLimitsReported != .noPlanLimits && ReadError.noLimitsReported.saysNoPlanLimits)
}

// MARK: Logins

/// One email in two organizations: two logins, each with its folder, its record and its switch; a third folder in one
/// of them joins it.
@MainActor
@Test func oneEmailInTwoOrganizationsIsTwoLogins() {
    let logins = store()
    let first = logins.place(personal, in: main, now: t0)
    let second = logins.place(research, in: lab, now: t0)
    let third = logins.place(research, in: work, now: t0)
    #expect(first.login != second.login && second.login == third.login && first.isNew && second.isNew && !third.isNew)
    #expect(first.login == LoginsStore.id(provider: .claude, email: sam, org: personal.org))
    #expect(second.login.hasPrefix(LoginsStore.id(provider: .claude, email: sam) + "@") && !second.login.contains("Research"))
    #expect(logins.logins[second.login]?.orgName == "Research Lab" && logins.logins[first.login]?.orgName == nil)
    #expect(logins.folders(of: second.login, in: [main, lab, work]) == [lab, work])
    logins.apply(.success(reading(second.login, at: t0, used: 40, plan: "team")), to: second.login, at: t0)
    #expect(logins.logins[second.login]?.record?.lastGood?.org == research.org)
    #expect(logins.logins[second.login]?.record?.lastGood?.orgName == "Research Lab" && logins.logins[first.login]?.record == nil)
    // The organization renamed on its side: the name follows.
    logins.place(LoginIdentity(email: sam, org: research.org, orgName: "Research Lab 2"), in: lab, now: t0)
    #expect(logins.logins[second.login]?.orgName == "Research Lab 2")

    let lists = LoginList.build(accounts: [main, lab, work], logins: logins.logins, folders: logins.folders, signingIn: [], now: t0, home: "/h")
    let rows = lists.first?.logins ?? []
    #expect(rows.map(\.battery.alias) == ["sam", "sam · Research Lab 2"] && rows.map(\.org) == [nil, "Research Lab 2"])
    #expect(rows.map(\.title) == [sam, sam + " · Research Lab 2"] && rows.map(\.folders) == [[main], [lab, work]])
    #expect(LoginList.panelEntries(lists).map(\.id) == [first.login, second.login])
}

/// Existing users: a login from before organizations were named keeps its id until a folder holding it names one. Then
/// it takes that organization's id with everything it had (reading, 429 pause, backoff, switch), and every folder that
/// held it follows; a folder that then answers another organization starts a login of its own with none of it.
@MainActor
@Test func aLoginFromBeforeOrganizationsTakesItsOrganizationWithEverything() throws {
    let logins = store()
    let plain = logins.place(sam, in: main, now: t0).login
    logins.place(sam, in: lab, now: t0)
    #expect(plain == LoginsStore.id(provider: .claude, email: sam))   // unchanged: nothing moves before an answer names one
    logins.apply(.success(reading(plain, at: t0, used: 40)), to: plain, at: t0)
    logins.apply(.failure(.rateLimited(retryAfter: 60)), to: plain, at: t0 + 300)
    logins.setMonitored(plain, false)
    let before = try #require(logins.logins[plain])

    let named = logins.place(personal, in: main, now: t0 + 400)
    #expect(named.renamed == plain && named.moved && !named.isNew && logins.logins[plain] == nil)
    let rehomed = try #require(logins.logins[named.login])
    #expect(rehomed.org == personal.org && !rehomed.monitored)
    #expect(rehomed.record?.lastError == .rateLimited(retryAfter: 60) && rehomed.record?.lastErrorAt == before.record?.lastErrorAt)
    #expect(rehomed.record?.consecutiveFailures == 1 && rehomed.record?.lastGood?.readAt == t0)
    #expect(rehomed.record?.lastGood?.accountID == named.login && rehomed.record?.lastGood?.org == personal.org)
    #expect(logins.state(of: lab.id) == .signedIn(login: named.login))

    // `~/.claude-lab` answers the other organization: a login of its own, starting with nothing.
    let other = logins.place(research, in: lab, now: t0 + 500)
    #expect(other.renamed == nil && other.isNew && logins.logins[other.login]?.record == nil && logins.logins[other.login]?.monitored == true)
    #expect(logins.folders(of: named.login, in: [main, lab]) == [main] && logins.folders(of: other.login, in: [main, lab]) == [lab])

    // A login with no organization named keeps its email's id (Codex; a CLI too old to name one).
    let codex = Account(provider: .codex, folder: "/h/.codex", alias: "default")
    #expect(logins.place(sam, in: codex, now: t0).login == LoginsStore.id(provider: .codex, email: sam))
}

/// A folder not asked yet brings no one else's login: the email's old login stays with the folders that hold it. One no
/// folder holds goes to the first organization named for its email, and only to the first.
@MainActor
@Test func onlyTheFoldersOwnOldLoginIsRehomed() {
    let logins = store()
    let plain = logins.place(sam, in: main, now: t0).login
    logins.apply(.success(reading(plain, at: t0, used: 40)), to: plain, at: t0)
    // A folder new to the app, signed in to another organization, does not take `~/.claude`'s login.
    let fresh = logins.place(research, in: lab, now: t0)
    #expect(fresh.renamed == nil && logins.logins[plain]?.record != nil && logins.logins[fresh.login]?.record == nil)
    // `~/.claude` still takes its own login into its organization, the other one seen first.
    #expect(logins.place(personal, in: main, now: t0).renamed == plain)

    // No folder holds the old login (a folder signed out since): it goes to the first organization, not to a second.
    let loose = store()
    let old = loose.place(sam, in: main, now: t0).login
    loose.apply(.success(reading(old, at: t0, used: 40)), to: old, at: t0)
    loose.signOut(main.id)
    let first = loose.place(personal, in: work, now: t0)
    #expect(first.renamed == old && loose.logins[first.login]?.record?.lastGood != nil)
    #expect(loose.place(research, in: lab, now: t0).renamed == nil)
    // Another organization of the email seen while the old login was still held: once no folder holds it, it goes to
    // neither, since it may be either's.
    let unheld = store()
    let kept = unheld.place(sam, in: main, now: t0).login
    unheld.place(research, in: lab, now: t0)
    unheld.signOut(main.id)
    #expect(unheld.place(personal, in: work, now: t0).renamed == nil && unheld.logins[kept] != nil)
}

/// P585: another folder of the same organization answers first, while `~/.claude` still holds the email's old login;
/// when `~/.claude` answers, the old login is merged into the organization's (the newest reading, the stricter wait,
/// Monitor off when either was off), never left behind with its pause while the shown login starts empty and is read.
@MainActor
@Test func theOldLoginJoinsItsOrganizationWhenAnotherFolderNamedItFirst() throws {
    let logins = store()
    let plain = logins.place(sam, in: main, now: t0).login
    logins.apply(.success(reading(plain, at: t0, used: 40)), to: plain, at: t0)
    logins.apply(.failure(.rateLimited(retryAfter: 600)), to: plain, at: t0 + 300)
    logins.setMonitored(plain, false)
    logins.signOut(work.id)                                            // signed out when the update came, in again since

    let first = logins.place(personal, in: work, now: t0 + 400)
    #expect(first.renamed == nil && first.isNew && logins.logins[plain] != nil)
    // Until `~/.claude` answers, the new login may be the old one: it waits out the old one's pause (P586).
    #expect(logins.logins[first.login]?.record?.lastError == .rateLimited(retryAfter: 600))
    #expect(logins.logins[first.login]?.record?.lastErrorAt == t0 + 300 && logins.logins[first.login]?.record?.lastGood == nil)

    let second = logins.place(personal, in: main, now: t0 + 410)
    #expect(second.login == first.login && second.renamed == plain && !second.isNew && logins.logins[plain] == nil)
    let merged = try #require(logins.logins[first.login])
    #expect(!merged.monitored && merged.org == personal.org)
    #expect(merged.record?.lastError == .rateLimited(retryAfter: 600) && merged.record?.lastErrorAt == t0 + 300)
    #expect(merged.record?.lastGood?.readAt == t0 && merged.record?.lastGood?.accountID == first.login)
    #expect(merged.record?.lastGood?.org == personal.org && merged.record?.consecutiveFailures == 1)
    #expect(logins.folders(of: first.login, in: [main, work]) == [main, work])
    #expect(!logins.folders.values.contains(.signedIn(login: plain)))
}

/// P586: the email's old login goes only to an organization whose plan is of its own kind (a personal Pro or Max, or an
/// organization's Team or Enterprise), whichever answers first. A login of the email made meanwhile keeps the old
/// login's unexpired pause, so the floors hold whichever way the split goes.
@MainActor
@Test func theOldLoginGoesOnlyToAnOrganizationOfItsPlansKind() throws {
    let maxAnswer = try #require(SignInIdentity(email: sam, plan: "max", org: personal.org).login)
    let teamAnswer = try #require(SignInIdentity(email: sam, plan: "team", org: research.org, orgName: "Research Lab").login)

    // A: the personal login's only folder is signed out, in a 429 pause, when the owner adds the organization's folder.
    let logins = store()
    let plain = logins.place(sam, in: main, now: t0).login
    logins.apply(.success(reading(plain, at: t0, used: 40)), to: plain, at: t0)
    logins.apply(.failure(.rateLimited(retryAfter: 900)), to: plain, at: t0 + 300)
    logins.signOut(main.id)
    let joined = logins.place(teamAnswer, in: lab, now: t0 + 500)
    #expect(joined.renamed == nil && joined.isNew && logins.logins[plain] != nil)
    let fresh = try #require(logins.logins[joined.login])
    #expect(fresh.record?.lastGood == nil && fresh.record?.lastError == .rateLimited(retryAfter: 900) && fresh.monitored)
    // `~/.claude` signs in again: the personal answer takes the old login, its reading, pause and history.
    let back = logins.place(maxAnswer, in: main, now: t0 + 600)
    #expect(back.renamed == plain && logins.logins[plain] == nil)
    #expect(logins.logins[back.login]?.record?.lastGood?.readAt == t0 && logins.logins[back.login]?.record?.lastError == .rateLimited(retryAfter: 900))
    // A pause that has ended is not handed on.
    let later = store()
    let ended = later.place(sam, in: main, now: t0).login
    later.apply(.failure(.rateLimited(retryAfter: 60)), to: ended, at: t0)
    #expect(later.place(teamAnswer, in: lab, now: t0 + 961).isNew && later.logins[LoginsStore.id(provider: .claude, teamAnswer)]?.record == nil)

    // B: two folders the old build merged under the email; the organization's folder answers first.
    let merged = store()
    let old = merged.place(sam, in: main, now: t0).login
    merged.place(sam, in: lab, now: t0)
    merged.apply(.success(reading(old, at: t0, used: 40)), to: old, at: t0)       // the Max plan's reading
    let org = merged.place(teamAnswer, in: lab, now: t0 + 60)
    #expect(org.renamed == nil && merged.logins[old] != nil && merged.state(of: main.id) == .signedIn(login: old))
    #expect(merged.logins[org.login]?.record == nil)
    let own = merged.place(maxAnswer, in: main, now: t0 + 60)
    #expect(own.renamed == old && merged.logins[own.login]?.record?.lastGood?.readAt == t0 && merged.logins[old] == nil)
    #expect(merged.folders(of: own.login, in: [main, lab]) == [main] && merged.folders(of: org.login, in: [main, lab]) == [lab])
}

/// N2 (P587): two logins of one email whose organizations show no name (the personal one, and one whose name holds an
/// email) are told apart by their plan words, or, before a reading, by their first folders' names.
@MainActor
@Test func twoLoginsOfOneEmailWithNoOrganizationNameShownAreToldApart() throws {
    let hidden = try #require(SignInIdentity(email: sam, plan: "team", org: research.org,
                                             orgName: LoginOrganization.shownName("admin@example.com's Organization", email: sam)).login)
    let logins = store()
    let mine = logins.place(personal, in: main, now: t0).login
    let theirs = logins.place(hidden, in: lab, now: t0).login
    func aliases() -> [String] {
        let lists = LoginList.build(accounts: [main, lab], logins: logins.logins, folders: logins.folders, signingIn: [], now: t0, home: "/h")
        return lists.first?.logins.map(\.battery.alias) ?? []
    }
    #expect(aliases() == ["sam · Main", "sam · Lab"])
    logins.apply(.success(reading(mine, at: t0, used: 40)), to: mine, at: t0)
    logins.apply(.success(reading(theirs, at: t0, used: 20, plan: "team")), to: theirs, at: t0)
    #expect(aliases() == ["sam · Max", "sam · Team"])
    // Another email of the same local part: every one of them takes its whole email, as before organizations.
    let other = Account(provider: .claude, folder: "/h/.claude-work", alias: "Work")
    logins.place("sam@example.org", in: other, now: t0)
    let lists = LoginList.build(accounts: [main, lab, other], logins: logins.logins, folders: logins.folders, signingIn: [], now: t0, home: "/h")
    #expect(lists.first?.logins.map(\.battery.alias) == [sam + " · Max", sam + " · Team", "sam@example.org"])
}

/// logins.json keeps each login's organization, and a file from before organizations reads as it did.
@MainActor
@Test func theFileKeepsTheOrganizationAndOlderFilesReadAsBefore() throws {
    let logins = store()
    defer { try? FileManager.default.removeItem(at: logins.fileURL.deletingLastPathComponent()) }
    let id = logins.place(research, in: lab, now: t0).login
    try logins.save()
    let again = LoginsStore(fileURL: logins.fileURL)
    again.load()
    #expect(again.logins[id]?.identity == research && again.state(of: lab.id) == .signedIn(login: id))
    let text = try String(contentsOf: logins.fileURL, encoding: .utf8)
    #expect(!text.contains(labID) && text.contains("Research Lab"))

    let plainID = LoginsStore.id(provider: .claude, email: sam)
    let older = #"{"version":2,"logins":{"\#(plainID)":{"provider":"claude","email":"sam@example.com","monitored":true}},"folders":{}}"#
    try Data(older.utf8).write(to: logins.fileURL)
    again.load()
    #expect(again.logins.values.map(\.org) == [nil] && again.logins.values.first?.id == LoginsStore.id(provider: .claude, email: sam))
}

/// readings.json, as standalone Juice writes it, names no organization: a folder's record goes to the login it holds,
/// whatever its organization; and each folder's projected record names its login's organization.
@MainActor
@Test func standaloneReadingsFoldIntoTheFoldersOrganizationLogin() {
    let logins = store()
    let labLogin = logins.place(research, in: lab, now: t0).login
    let mainLogin = logins.place(personal, in: main, now: t0).login
    let standalone = [lab.id: AccountRecord(lastGood: reading(lab.id, at: t0 + 60, used: 55, email: sam), lastAttemptAt: t0 + 60),
                      main.id: AccountRecord(lastGood: reading(main.id, at: t0 + 30, used: 10, email: sam), lastAttemptAt: t0 + 30)]
    logins.fold(standalone, accounts: [main, lab], now: t0 + 90)
    #expect(logins.logins.count == 2 && logins.logins[labLogin]?.record?.lastGood?.windows.first?.usedPercent == 55)
    #expect(logins.logins[mainLogin]?.record?.lastGood?.windows.first?.usedPercent == 10)
    let projected = logins.projection(of: [main, lab], onto: [:], now: t0 + 90)
    #expect(projected[lab.id]?.lastGood?.org == research.org && projected[lab.id]?.lastGood?.orgName == "Research Lab")
    #expect(projected[main.id]?.lastGood?.org == personal.org && projected[main.id]?.lastGood?.accountID == main.id)
}

/// Standalone Juice's and the demo's rule: folders of one email in two organizations are two batteries; a folder whose
/// reading names no organization goes with its email's first folder, as before.
@Test func foldersOfOneEmailInTwoOrganizationsAreTwoBatteries() {
    func record(_ account: Account, org: String?) -> AccountRecord {
        var reading = reading(account.id, at: t0, used: 20, email: sam)
        reading.org = org
        return AccountRecord(lastGood: reading, lastAttemptAt: t0)
    }
    let records = [main.id: record(main, org: personal.org), lab.id: record(lab, org: research.org), work.id: record(work, org: nil)]
    #expect(AccountIdentity.uniqueAccounts([main, lab, work], records: records) == [main, lab])
    #expect(AccountIdentity.duplicateOf(work, in: [main, lab, work], records: records) == main)
}

/// A login that takes its organization's id keeps its samples and the notices given for it.
@Test func aRenamedLoginKeepsItsHistory() {
    var history = UsageHistory()
    history.record(reading("old", at: t0, used: 20), for: "old")
    history.record(reading("old", at: t0 + 600, used: 30), for: "old")
    history.rename("old", to: "new")
    #expect(history.samples("new", window: "5h").map(\.used) == [20, 30] && history.samples("old", window: "5h").isEmpty)
    var alerts = QuotaAlertState(said: [.init(account: "old", window: "5h", resetsAt: nil, at: t0)])
    alerts.rename("old", to: "new")
    #expect(alerts.said.map(\.account) == ["new"])
}
