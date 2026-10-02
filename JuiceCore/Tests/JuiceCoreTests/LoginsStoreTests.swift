import Foundation
import Testing
@testable import JuiceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let home = Account(provider: .codex, folder: "/h/.codex", alias: "default")
private let side = Account(provider: .codex, folder: "/h/.codex-side", alias: "Side")
private let fresh = Account(provider: .codex, folder: "/h/.codex-fresh", alias: "Fresh")
private let lab = Account(provider: .claude, folder: "/h/.claude-lab", alias: "Lab")
private let a = "a@example.com", b = "b@example.com"

private func reading(_ id: String, at date: Date, used: Double, email: String? = nil) -> AccountReading {
    AccountReading(accountID: id, readAt: date, plan: "pro", email: email,
                   windows: [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: date + 3_600)])
}

private func good(_ id: String, at date: Date, used: Double, email: String? = nil) -> AccountRecord {
    AccountRecord(lastGood: reading(id, at: date, used: used, email: email), lastAttemptAt: date)
}

@MainActor
private func store() -> (LoginsStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("juice-logins-\(UUID().uuidString)")
    return (LoginsStore(fileURL: dir.appendingPathComponent("logins.json")), dir)
}

private func loginID(_ provider: Provider, _ email: String) -> String { LoginsStore.id(provider: provider, email: email) }

/// A key is a hash of the trimmed, lowercased email: the same for any spelling of it, never the email itself.
@Test func aLoginsKeyIsAStableHashOfItsEmail() {
    let key = LoginsStore.key(for: "a@example.com")
    #expect(LoginsStore.key(for: " A@Example.com\n") == key)
    #expect(key.count == 16 && key.allSatisfy(\.isHexDigit) && !key.contains("@"))
    #expect(LoginsStore.key(for: "b@example.com") != key)
    #expect(key == "c3fb7bfbec41e131")       // pinned: a key must not change between runs or builds
    #expect(LoginsStore.id(provider: .codex, email: "A@example.com") == "codex#c3fb7bfbec41e131")
    #expect(LoginsStore.id(provider: .claude, email: a) != LoginsStore.id(provider: .codex, email: a))
}

/// Two folders signed in to one account are one login, holding both folders; a folder switched off holds nothing.
@MainActor
@Test func twoFoldersOfOneAccountAreOneLogin() {
    let (logins, _) = store()
    let first = logins.place(a, in: home, now: t0)
    let second = logins.place("A@example.com ", in: side, now: t0)
    #expect(first == Placement(login: loginID(.codex, a), previous: .unknown, isNew: true) && first.moved)
    #expect(second == Placement(login: loginID(.codex, a), previous: .unknown, isNew: false))
    #expect(logins.logins.count == 1 && logins.logins[first.login]?.email == a)
    #expect(logins.folders(of: first.login, in: [home, side, fresh]) == [home, side])
    var off = side
    off.monitored = false
    #expect(logins.folders(of: first.login, in: [home, off]) == [home])
    #expect(!logins.place(a, in: home, now: t0).moved)
}

/// A→B in one folder while another folder keeps A: A keeps its record and its other folder, and B starts with none of
/// A's. A keeps its record while no folder holds it, and has it again when one signs in to it.
@MainActor
@Test func aFolderThatChangesLoginJoinsTheOther() {
    let (logins, _) = store()
    let idA = logins.place(a, in: home, now: t0).login
    logins.place(a, in: side, now: t0)
    logins.apply(.failure(.rateLimited(retryAfter: 60)), to: idA, at: t0)
    let moved = logins.place(b, in: side, now: t0 + 10)
    #expect(moved.previous == .signedIn(login: idA) && moved.isNew && moved.moved)
    #expect(logins.logins[moved.login]?.record == nil)
    #expect(logins.logins[idA]?.record?.lastError == .rateLimited(retryAfter: 60))
    #expect(logins.folders(of: idA, in: [home, side]) == [home] && logins.folders(of: moved.login, in: [home, side]) == [side])

    #expect(logins.signOut(home.id) == .signedIn(login: idA))
    #expect(logins.state(of: home.id) == .signedOut && logins.login(holding: home.id) == nil)
    #expect(logins.folders(of: idA, in: [home, side]).isEmpty && logins.logins[idA]?.record?.lastError == .rateLimited(retryAfter: 60))
    // Back in: A is held again, with its record.
    logins.place(a, in: home, now: t0 + 40)
    #expect(logins.folders(of: idA, in: [home, side]) == [home] && logins.logins[idA]?.record?.lastError == .rateLimited(retryAfter: 60))
}

/// A read's outcome is its login's, whichever folder made it: the reading is filed under the login's id.
@MainActor
@Test func aReadIsFiledUnderItsLogin() {
    let (logins, _) = store()
    let id = logins.place(a, in: side, now: t0).login
    logins.apply(.success(reading(side.id, at: t0, used: 30, email: a)), to: id, at: t0)
    #expect(logins.logins[id]?.record?.lastGood?.accountID == id)
    logins.apply(.failure(.timeout), to: id, at: t0 + 60)
    logins.apply(.failure(.timeout), to: id, at: t0 + 120)
    #expect(logins.logins[id]?.record?.consecutiveFailures == 2 && logins.logins[id]?.record?.lastGood?.readAt == t0)
    logins.apply(.success(reading(side.id, at: t0 + 180, used: 35)), to: id, at: t0 + 180)
    #expect(logins.logins[id]?.record?.consecutiveFailures == 0 && logins.logins[id]?.record?.lastError == nil)
    #expect(logins.logins[id]?.record?.lastGood?.email == a)                   // a reading that named no login names its own
    logins.apply(.success(reading(side.id, at: t0, used: 1)), to: "codex#unknown", at: t0)
    #expect(logins.logins.count == 1)
}

/// A folder's first answer takes the record readings.json kept for it (a store from before logins were keyed by
/// account), unless the reading names another login.
@MainActor
@Test func aFoldersFirstAnswerTakesItsOldRecord() {
    let (logins, _) = store()
    let id = logins.place(a, in: lab, record: good(lab.id, at: t0 - 60, used: 40), now: t0).login
    #expect(logins.logins[id]?.record?.lastGood?.readAt == t0 - 60 && logins.logins[id]?.record?.lastGood?.accountID == id)
    let other = logins.place(b, in: side, record: good(side.id, at: t0 - 60, used: 40, email: a), now: t0).login
    #expect(logins.logins[other]?.record == nil)
    // Only a folder not placed before brings its record.
    logins.place(b, in: lab, record: good(lab.id, at: t0 - 10, used: 90), now: t0)
    #expect(logins.logins[loginID(.claude, b)]?.record == nil)
}

/// Two records of one login: the newest reading and the stricter wait. A 429 from before the newest reading counts
/// while its pause runs, dated the last attempt so a relaunch restores it; a sign-in failure is its folder's.
@MainActor
@Test func mergingKeepsTheNewestReadingAndTheStricterPause() throws {
    let id = loginID(.codex, a)
    let paused = AccountRecord(lastGood: reading(home.id, at: t0 - 500, used: 20), lastError: .rateLimited(retryAfter: 60),
                               lastErrorAt: t0 - 100, lastAttemptAt: t0 - 100, consecutiveFailures: 1)
    let newer = good(side.id, at: t0 - 30, used: 50)
    let merged = try #require(LoginsStore.merge([paused, newer], as: id, now: t0))
    #expect(merged.lastGood?.readAt == t0 - 30 && merged.lastGood?.accountID == id)
    #expect(merged.lastError == .rateLimited(retryAfter: 60) && merged.lastErrorAt == t0 - 100 && merged.lastAttemptAt == t0 - 100)
    #expect(merged.consecutiveFailures == 1)
    // The scheduler takes that pause back.
    let scheduler = RefreshScheduler(now: { t0 })
    scheduler.setTargets([ReadTarget(id: id, provider: .codex)])
    scheduler.seed(from: [id: merged])
    #expect(scheduler.nextDue(for: id) == t0 - 100 + 1 + 960)

    // Once the pause is over, the newer reading stands alone.
    let later = try #require(LoginsStore.merge([paused, newer], as: id, now: t0 + 1_000))
    #expect(later.lastError == nil && later.lastAttemptAt == t0 - 30)
    // A backoff from before the newest reading is over by then.
    var timedOut = paused
    timedOut.lastError = .timeout
    #expect(try #require(LoginsStore.merge([timedOut, newer], as: id, now: t0)).lastError == nil)
    // A failure after the newest reading always counts; of two, the one that waits longer.
    let late429 = AccountRecord(lastError: .rateLimited(retryAfter: 300), lastErrorAt: t0 - 10, lastAttemptAt: t0 - 10, consecutiveFailures: 1)
    let lateTimeout = AccountRecord(lastError: .timeout, lastErrorAt: t0 - 5, lastAttemptAt: t0 - 5, consecutiveFailures: 1)
    let both = try #require(LoginsStore.merge([newer, lateTimeout, late429], as: id, now: t0))
    #expect(both.lastError == .rateLimited(retryAfter: 300) && both.lastAttemptAt == t0 - 5)
    // A sign-in failure stays with its folder.
    let out = AccountRecord(lastError: .signInRequired, lastErrorAt: t0, lastAttemptAt: t0, consecutiveFailures: 1)
    #expect(LoginsStore.merge([out], as: id, now: t0) == nil)
    #expect(try #require(LoginsStore.merge([newer, out], as: id, now: t0)).lastError == nil)
    // The same record twice is itself.
    #expect(LoginsStore.merge([paused, paused], as: id, now: t0)?.lastGood == paused.lastGood.map { var r = $0; r.accountID = id; return r })
}

/// The first launch after logins were keyed by account: P80's logins.json (per folder) and readings.json fold into
/// logins. Two folders of one account become one login with the newest reading and the stricter pause; a login a folder
/// held before comes back with the record it kept; a signed-out folder stays signed out; a folder never
/// asked keeps its record for its first answer.
@MainActor
@Test func theOldStoreFoldsIntoLogins() throws {
    let (logins, dir) = store()
    let v1 = """
    {"version": 1, "folders": {
      "\(home.id)": {"current": "\(LoginsStore.key(for: a))", "logins": {
        "\(LoginsStore.key(for: a))": {"email": "\(a)", "alias": "default"}}},
      "\(side.id)": {"current": "\(LoginsStore.key(for: a))", "logins": {
        "\(LoginsStore.key(for: a))": {"email": "\(a)", "alias": "Side"},
        "\(LoginsStore.key(for: b))": {"email": "\(b)", "alias": "b", "parked": {"consecutiveFailures": 0,
          "lastAttemptAt": "2027-01-15T07:00:00Z",
          "lastGood": {"accountID": "\(side.id)", "readAt": "2027-01-15T07:00:00Z", "email": "\(b)", "ordinaryUsageAllowed": true,
                       "windows": [{"seconds": 18000, "usedPercent": 70}]}}}}},
      "\(fresh.id)": {"logins": {}}
    }}
    """
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(v1.utf8).write(to: logins.fileURL)
    logins.load()
    let paused = AccountRecord(lastGood: reading(home.id, at: t0 - 500, used: 20, email: a), lastError: .rateLimited(retryAfter: 60),
                               lastErrorAt: t0 - 100, lastAttemptAt: t0 - 100, consecutiveFailures: 1)
    let records: [String: AccountRecord] = [
        home.id: paused,
        side.id: good(side.id, at: t0 - 30, used: 50, email: a),
        fresh.id: AccountRecord(lastError: .signInRequired, lastErrorAt: t0 - 60, lastAttemptAt: t0 - 60, consecutiveFailures: 1),
        lab.id: good(lab.id, at: t0 - 90, used: 40),
    ]
    let accounts = [home, side, fresh, lab]
    logins.fold(records, accounts: accounts, now: t0)
    let idA = loginID(.codex, a), idB = loginID(.codex, b)
    #expect(Set(logins.logins.keys) == [idA, idB])
    let record = try #require(logins.logins[idA]?.record)
    #expect(record.lastGood?.readAt == t0 - 30 && record.lastError == .rateLimited(retryAfter: 60))
    #expect(logins.folders(of: idA, in: accounts) == [home, side])
    #expect(logins.logins[idB]?.record?.lastGood?.windows.first?.usedPercent == 70)
    #expect(logins.state(of: fresh.id) == .signedOut && logins.state(of: lab.id) == .unknown)
    // Folding again changes nothing; a saved store loads as it was.
    let before = logins.logins
    logins.fold(records, accounts: accounts, now: t0)
    #expect(logins.logins == before)
    try logins.save()
    let reloaded = LoginsStore(fileURL: logins.fileURL)
    reloaded.load()
    #expect(reloaded.logins == logins.logins && reloaded.folders == logins.folders)
    // The Claude folder's record waits for its first answer.
    let idLab = reloaded.place("c@example.com", in: lab, record: records[lab.id], now: t0).login
    #expect(reloaded.logins[idLab]?.record?.lastGood?.readAt == t0 - 90)
}

/// What standalone Juice wrote while it ran comes back in: a reading goes to the login it names, else to the login its
/// folder holds, and never pulls a login back to an older one.
@MainActor
@Test func standaloneJuicesReadsFoldBackIn() {
    let (logins, _) = store()
    let idA = logins.place(a, in: home, now: t0).login
    logins.place(a, in: side, now: t0)
    logins.apply(.success(reading(home.id, at: t0, used: 10)), to: idA, at: t0)
    let accounts = [home, side]
    logins.fold([home.id: good(home.id, at: t0 + 300, used: 60), side.id: good(side.id, at: t0 - 300, used: 99)], accounts: accounts, now: t0 + 300)
    #expect(logins.logins[idA]?.record?.lastGood?.readAt == t0 + 300 && logins.logins[idA]?.record?.lastGood?.windows.first?.usedPercent == 60)
    // A reading that names a login no folder holds is kept for it.
    logins.fold([side.id: good(side.id, at: t0 + 400, used: 5, email: b)], accounts: accounts, now: t0 + 400)
    #expect(logins.logins[loginID(.codex, b)]?.record?.lastGood?.readAt == t0 + 400 && logins.state(of: side.id) == .signedIn(login: idA))
}

/// readings.json follows the logins: a folder signed in has its login's record under its own id, a signed-out folder a
/// sign-in failure (kept once written), and a folder not asked yet or switched off keeps what it had.
@MainActor
@Test func readingsJSONHoldsEachFoldersLoginsRecord() {
    let (logins, _) = store()
    let idA = logins.place(a, in: home, now: t0).login
    logins.place(a, in: side, now: t0)
    logins.apply(.success(reading(home.id, at: t0, used: 30, email: a)), to: idA, at: t0)
    logins.signOut(fresh.id)
    var off = lab
    off.monitored = false
    let kept = good(lab.id, at: t0 - 999, used: 1)
    let projected = logins.projection(of: [home, side, fresh, off], onto: [lab.id: kept], now: t0 + 5)
    #expect(projected[home.id]?.lastGood?.accountID == home.id && projected[side.id]?.lastGood?.accountID == side.id)
    #expect(projected[home.id]?.lastGood?.readAt == t0)
    #expect(projected[fresh.id] == AccountRecord(lastError: .signInRequired, lastErrorAt: t0 + 5, lastAttemptAt: t0 + 5, consecutiveFailures: 1))
    #expect(projected[lab.id] == kept)
    #expect(logins.projection(of: [fresh], onto: projected, now: t0 + 60)[fresh.id] == projected[fresh.id])
    // Folding the projection back in changes nothing.
    let before = logins.logins
    logins.fold(projected, accounts: [home, side, fresh], now: t0 + 5)
    #expect(logins.logins == before && logins.state(of: fresh.id) == .signedOut)
}

/// P731: two reads of one login can be under way at once (one started under the id it had before its organization was
/// named, one under the new id; a folder that answered for the login during another folder's read). The one that began
/// first and ended last is an attempt only: its reading never replaces the newer one, its reset credits with it, and it
/// never clears a failure that ended after it began, so a 429's pause still holds after a relaunch.
@MainActor
@Test func aReadThatBeganEarlierButEndedLaterNeverReplacesTheNewerReading() {
    let (logins, _) = store()
    let id = logins.place(a, in: side, now: t0).login
    var newer = reading(side.id, at: t0 + 10, used: 40, email: a)
    newer.resetCredits = 2
    var older = reading(side.id, at: t0, used: 90, email: a)
    older.resetCredits = 5
    logins.apply(.success(newer), to: id, at: t0 + 12)
    logins.apply(.success(older), to: id, at: t0 + 20)
    var record = logins.logins[id]?.record
    #expect(record?.lastGood?.readAt == t0 + 10 && record?.lastGood?.windows.first?.usedPercent == 40)
    #expect(record?.lastGood?.resetCredits == 2 && record?.lastAttemptAt == t0 + 20)
    // A 429 ends at t0 + 30; a read that began before it (t0 + 25) ends after it: its reading is newer than the last good
    // one and is kept, the 429 stands.
    logins.apply(.failure(.rateLimited(retryAfter: 60)), to: id, at: t0 + 30)
    logins.apply(.success(reading(side.id, at: t0 + 25, used: 50, email: a)), to: id, at: t0 + 40)
    record = logins.logins[id]?.record
    #expect(record?.lastGood?.readAt == t0 + 25 && record?.lastError == .rateLimited(retryAfter: 60))
    #expect(record?.lastErrorAt == t0 + 30 && record?.consecutiveFailures == 1)
    // A read that began after the 429 ended clears it, as before.
    logins.apply(.success(reading(side.id, at: t0 + 1_000, used: 55, email: a)), to: id, at: t0 + 1_001)
    record = logins.logins[id]?.record
    #expect(record?.lastGood?.readAt == t0 + 1_000 && record?.lastError == nil && record?.consecutiveFailures == 0)
    // A clock set back an hour: a read that began and ended before the last one is no stale one; it is the newest, as
    // before, and so is its failure's clearing.
    logins.apply(.failure(.timeout), to: id, at: t0 + 1_100)
    logins.apply(.success(reading(side.id, at: t0 - 2_500, used: 60, email: a)), to: id, at: t0 - 2_499)
    record = logins.logins[id]?.record
    #expect(record?.lastGood?.readAt == t0 - 2_500 && record?.lastError == nil && record?.lastAttemptAt == t0 - 2_499)
    // A clock set back an hour, and its first outcome a failure (offline right after a wake): the reads after it end after
    // the last attempt, but a last good reading dated after they end was read before the clock went back. Each one is the
    // newest, as before, so the battery never stays on the reading from before the set back.
    logins.apply(.success(reading(side.id, at: t0 + 5_000, used: 40, email: a)), to: id, at: t0 + 5_002)
    logins.apply(.failure(.offline), to: id, at: t0 + 1_410)
    logins.apply(.success(reading(side.id, at: t0 + 1_420, used: 70, email: a)), to: id, at: t0 + 1_421)
    record = logins.logins[id]?.record
    #expect(record?.lastGood?.readAt == t0 + 1_420 && record?.lastError == nil && record?.consecutiveFailures == 0)
    logins.apply(.success(reading(side.id, at: t0 + 2_000, used: 80, email: a)), to: id, at: t0 + 2_001)
    #expect(logins.logins[id]?.record?.lastGood?.windows.first?.usedPercent == 80)
}
