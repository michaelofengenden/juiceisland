import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// P80, P93 on `LiveUsageModel`'s fakes: the unit is the login a CLI reports, not the folder. Several folders can hold
/// one login, a folder can change login, and a folder can be signed out. Fictional folders and emails only.
@MainActor
struct LoginsByAccountTests {
    typealias F = LiveFakes

    static let a = "a@example.com", b = "b@example.com"
    /// The default Codex home and Claude folder of the fake home.
    static let codexHome = Account(provider: .codex, folder: F.home + "/.codex", alias: "default")
    static let claudeHome = Account(provider: .claude, folder: F.home + "/.claude", alias: "Main")

    static func stamp(_ inode: UInt64, _ seconds: Int) -> AuthFileStamp { AuthFileStamp(inode: inode, modifiedSeconds: seconds) }

    func codexStates(_ model: LiveUsageModel) -> [AccountState] { model.codexRow?.batteries.map(\.state) ?? [] }
    func codexReads(_ fakes: LiveFakes) -> [String] { fakes.reads.filter { $0.hasPrefix("read codex") } }

    /// `~/.codex-side` and `~/.codex`, both signed in to A, `~/.codex` the fresher login file: both are asked who is
    /// signed in as soon as the CLI is found, then A is read once, through `~/.codex`. A Codex home only asked stops its
    /// server.
    func twoHomesOfA(_ fakes: LiveFakes) async throws -> LiveUsageModel {
        try fakes.writeStore(accounts: [F.side, Self.codexHome])
        fakes.codex(F.side, Self.a, stamp: Self.stamp(1, 100))
        fakes.codex(Self.codexHome, Self.a, stamp: Self.stamp(2, 200))
        fakes.codexUsed.withValue { $0 = [Self.a: 30, Self.b: 70] }
        let model = fakes.model()
        model.start()
        await model.settle()
        return model
    }

    /// Two folders signed in to one account: one question each, one read per floor window, one row and one battery.
    @Test
    func twoFoldersOfOneAccountAreReadOnceAndShownOnce() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await twoHomesOfA(fakes)
        defer { model.stop() }
        let side = F.side.folder, home = Self.codexHome.folder
        #expect(fakes.entries.filter { !$0.hasPrefix("locate") } == [
            "shutdown \(side)", "identity \(side)", "shutdown \(home)", "identity \(home)",
            "shutdown \(side)",                                              // only asked: its server stops
            "read \(Self.codexHome.id)",
        ])
        let idA = LoginsStore.id(provider: .codex, email: Self.a)
        let list = try #require(model.list(.codex))
        #expect(list.logins.map(\.id) == [idA] && list.logins[0].email == Self.a && list.logins[0].plan == "Plus")
        #expect(list.logins[0].folders == [Self.codexHome, F.side] && list.folders.isEmpty)
        #expect(model.codexRow?.batteries.map(\.id) == [idA] && codexStates(model) == [.available(percentLeft: 70, isLow: false)])
        #expect(model.records[idA]?.lastGood?.email == Self.a)
        // readings.json: each folder's record is A's.
        let saved = ReadingsStore(fileURL: fakes.directory.appendingPathComponent("readings.json"))
        saved.load()
        #expect(saved.records[F.side.id]?.lastGood?.readAt == DemoClock.now && saved.records[Self.codexHome.id]?.lastGood != nil)

        // The floor is A's, whichever folder: nothing before 60 s, Refresh all included, then one read.
        fakes.clock.now += 30
        await model.look()
        model.refreshAll()
        await model.settle()
        #expect(codexReads(fakes).count == 1)
        fakes.clock.now += 30
        await model.settle()
        #expect(codexReads(fakes) == ["read \(Self.codexHome.id)", "read \(Self.codexHome.id)"])
    }

    /// Retry-After + 900 s holds the login in every folder: a 429 read through one home keeps the other quiet too.
    @Test
    func aPauseHoldsTheLoginInEveryFolder() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await twoHomesOfA(fakes)
        defer { model.stop() }
        let t0 = DemoClock.now
        fakes.clock.now += 60
        fakes.codexFailure.withValue { $0 = .rateLimited(retryAfter: 60) }
        await model.settle()
        fakes.codexFailure.withValue { $0 = nil }
        #expect(codexReads(fakes).count == 2)
        fakes.clock.now += 120
        model.refreshAll()
        await model.look()
        await model.settle()
        #expect(codexReads(fakes).count == 2)
        let idA = LoginsStore.id(provider: .codex, email: Self.a)
        #expect(model.scheduler.nextDue(for: idA) == t0 + 60 + 960)
        fakes.clock.now = t0 + 60 + 960
        await model.settle()
        #expect(codexReads(fakes).count == 3)
    }

    /// A→B in one folder while the other keeps A: the folder joins B, which is new and read at once; A keeps its
    /// record and waits, and is read through its other folder when its floor ends.
    @Test
    func aFolderThatSwitchesJoinsTheOtherLoginWhileTheSecondKeepsA() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await twoHomesOfA(fakes)
        defer { model.stop() }
        let t0 = DemoClock.now
        let idA = LoginsStore.id(provider: .codex, email: Self.a), idB = LoginsStore.id(provider: .codex, email: Self.b)

        // `codex logout`, then `codex login` as B, in `~/.codex`.
        fakes.clock.now += 10
        fakes.codex(Self.codexHome, Self.b, stamp: Self.stamp(3, 300))
        let before = fakes.entries.count
        await model.look()
        #expect(Array(fakes.entries.dropFirst(before)) == ["shutdown \(Self.codexHome.folder)", "identity \(Self.codexHome.folder)"])
        #expect(model.loginID(of: Self.codexHome) == idB && model.loginID(of: F.side) == idA)
        await model.settle()
        #expect(codexReads(fakes) == ["read \(Self.codexHome.id)", "read \(Self.codexHome.id)"])
        #expect(model.list(.codex)?.logins.map(\.email) == [Self.a, Self.b])
        #expect(model.list(.codex)?.logins.map(\.folders) == [[F.side], [Self.codexHome]])
        #expect(codexStates(model) == [.available(percentLeft: 70, isLow: false), .available(percentLeft: 30, isLow: false)])
        #expect(model.records[idA]?.lastGood?.readAt == t0 && model.records[idA]?.lastGood?.email == Self.a)

        // A's floor ends: A is read through the folder that still holds it.
        fakes.clock.now = t0 + 60
        await model.settle()
        #expect(codexReads(fakes).last == "read \(F.side.id)" && codexReads(fakes).count == 3)
        #expect(model.records[idA]?.lastGood?.readAt == t0 + 60)
    }

    /// A folder signs out: its login is read through its other folder, the folder is listed as signed out, and the sign-in
    /// badge goes up with no battery of its own.
    @Test
    func aSignedOutFolderLeavesItsLoginToTheOther() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await twoHomesOfA(fakes)
        defer { model.stop() }
        fakes.clock.now += 20
        fakes.codex(Self.codexHome, nil, stamp: nil)
        await model.look()
        let list = try #require(model.list(.codex))
        #expect(list.logins.map(\.folders) == [[F.side]])
        #expect(list.folders == [LooseFolder(folder: Self.codexHome, state: .signedOut)])
        #expect(model.panel.attentionNeeded && codexStates(model) == [.available(percentLeft: 70, isLow: false)])
        let saved = ReadingsStore(fileURL: fakes.directory.appendingPathComponent("readings.json"))
        saved.load()
        #expect(saved.records[Self.codexHome.id]?.lastError == .signInRequired && saved.records[F.side.id]?.lastGood != nil)
        fakes.clock.now += 40
        await model.settle()
        #expect(codexReads(fakes).last == "read \(F.side.id)")

        // Every folder of a login signed out while its read is due: the read finds none and records nothing.
        fakes.codex(F.side, nil, stamp: Self.stamp(1, 100))
        fakes.clock.now += 60
        await model.settle()
        #expect(codexReads(fakes).last == "read \(F.side.id)" && model.list(.codex)?.folders.count == 2)
        #expect(model.codexRow == nil && model.records[LoginsStore.id(provider: .codex, email: Self.a)]?.lastError == nil)
    }

    /// A read's sign-in failure marks its folder signed out, though its `auth.json` never changed, and it may pass: after
    /// the sign-in delay the folder is asked again (one question, no usage read), and an answer puts it back.
    @Test
    func aSignedOutFolderIsAskedAgainAfterTheSignInDelay() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        fakes.codex(F.side, Self.a, stamp: Self.stamp(1, 1))
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        fakes.clock.now += 60
        fakes.codexFailure.withValue { $0 = .signInRequired }
        await model.settle()
        fakes.codexFailure.withValue { $0 = nil }
        #expect(model.list(.codex)?.folders == [LooseFolder(folder: F.side, state: .signedOut)] && model.codexRow == nil)

        let before = fakes.entries.count
        fakes.clock.now += 3_599
        await model.look()
        await model.settle()
        #expect(fakes.entries.count == before)                               // only its file is looked at
        fakes.clock.now += 1
        await model.look()
        #expect(Array(fakes.entries.dropFirst(before)) == ["shutdown \(F.side.folder)", "identity \(F.side.folder)"])
        #expect(model.loginID(of: F.side) == LoginsStore.id(provider: .codex, email: Self.a))
        await model.settle()
        #expect(codexReads(fakes).count == 3 && model.codexRow?.batteries.count == 1)
    }

    /// A folder added later is asked who is signed in, with no usage read: one of A's is placed and read on A's floor
    /// only; one of a login new to the app is read at once.
    @Test
    func anUnknownFolderIsPlacedByOneQuestion() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        fakes.codex(F.side, Self.a, stamp: Self.stamp(1, 100))
        fakes.codex(F.fresh, Self.a, stamp: Self.stamp(2, 100))
        let preset = Account(provider: .codex, folder: F.home + "/.codex-preset", alias: "preset")
        fakes.codex(preset, Self.b, stamp: Self.stamp(3, 100))
        fakes.discovered = [DiscoveredProfile(provider: .codex, folder: F.fresh.folder, suggestedAlias: "fresh"),
                            DiscoveredProfile(provider: .codex, folder: preset.folder, suggestedAlias: "preset")]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        #expect(codexReads(fakes) == ["read \(F.side.id)"])
        model.refreshDiscovery()
        await model.discovery?.value
        model.add(fakes.discovered[0])
        #expect(model.list(.codex)?.folders.map(\.id) == [F.fresh.id] && model.list(.codex)?.folders.first?.state == .unknown)
        let before = fakes.entries.count
        await model.look()
        await model.settle()
        #expect(Array(fakes.entries.dropFirst(before)) == [
            "shutdown \(F.fresh.folder)", "identity \(F.fresh.folder)", "shutdown \(F.fresh.folder)",
        ])
        #expect(model.list(.codex)?.logins.map { $0.folders.map(\.id) } == [[F.side.id, F.fresh.id]] && codexReads(fakes).count == 1)

        model.add(fakes.discovered[1])
        #expect(model.discovered.isEmpty)
        await model.look()
        await model.settle()
        #expect(codexReads(fakes).last == "read \(preset.id)")
        #expect(model.list(.codex)?.logins.map(\.email) == [Self.a, Self.b] && model.codexRow?.batteries.count == 2)
    }

    /// A folder asked for the first time after its login was read brings its old record: a 429 pause recorded through it
    /// (by standalone Juice, or before logins were keyed by account) holds the login from then on.
    @Test
    func aFolderPlacedLaterBringsItsPause() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let t0 = DemoClock.now
        let limited = AccountRecord(lastError: .rateLimited(retryAfter: 60), lastErrorAt: t0 - 10, lastAttemptAt: t0 - 10,
                                    consecutiveFailures: 1)
        try fakes.writeStore(accounts: [F.side], records: [F.fresh.id: limited])
        fakes.codex(F.side, Self.a, stamp: Self.stamp(1, 100))
        fakes.codex(F.fresh, Self.a, stamp: Self.stamp(2, 100))
        fakes.discovered = [DiscoveredProfile(provider: .codex, folder: F.fresh.folder, suggestedAlias: "fresh")]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let idA = LoginsStore.id(provider: .codex, email: Self.a)
        #expect(codexReads(fakes).count == 1 && model.scheduler.nextDue(for: idA) == t0 + 60)
        model.refreshDiscovery()
        await model.discovery?.value
        model.add(fakes.discovered[0])
        await model.settle()
        #expect(model.loginID(of: F.fresh) == idA && model.records[idA]?.lastError == .rateLimited(retryAfter: 60))
        #expect(model.scheduler.nextDue(for: idA) == t0 - 10 + 1 + 960 && codexReads(fakes).count == 1)
    }

    /// Claude: the default `~/.claude` and `~/.claude-work` signed in to one account are one login: each is asked
    /// `claude auth status` once, and `get_usage` runs once per 300 s, through the folder whose `.claude.json` changed last.
    @Test
    func aClaudeAccountInTwoFoldersIsReadOnce() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let w = "w@example.com"
        try fakes.writeStore(accounts: [F.work, Self.claudeHome])
        fakes.claude(F.work, w, stamp: Self.stamp(1, 200))
        fakes.claude(Self.claudeHome, w, stamp: Self.stamp(2, 100))
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        #expect(fakes.entries.filter { !$0.hasPrefix("locate") } == [
            "auth \(F.work.folder)", "auth \(Self.claudeHome.folder)", "read \(F.work.id)",
        ])
        let list = try #require(model.list(.claude))
        #expect(list.logins.count == 1 && list.logins[0].email == w && list.logins[0].folders.map(\.id) == [Self.claudeHome.id, F.work.id])
        #expect(model.claudeRow?.batteries.map(\.state) == [.available(percentLeft: 60, isLow: false)])
        fakes.clock.now += 299
        await model.look()
        await model.settle()
        #expect(fakes.reads.count == 1)
        fakes.clock.now += 1
        await model.settle()
        #expect(fakes.reads == ["read \(F.work.id)", "read \(F.work.id)"])

        // `/login` as another account in `~/.claude`, which W is not read through: a check notices the change half an
        // hour after the last question, and the account is read at once as a login new to the app.
        fakes.claude(Self.claudeHome, Self.b, stamp: Self.stamp(2, 900))
        fakes.clock.now += 1_800
        await model.look()
        await model.settle()
        #expect(model.list(.claude)?.logins.map(\.email) == [w, Self.b])       // the account list's order
        #expect(fakes.reads.suffix(2).sorted() == ["read \(Self.claudeHome.id)", "read \(F.work.id)"])
    }

    /// `/login` as B in the folder W is read through, five minutes after the last question: its `.claude.json` is now the
    /// freshest of W's folders, so W's next read goes there. That read asks first, because the file changed: it finds B,
    /// leaves the folder to B and reads W through its other folder, so none of B's usage is filed under W. B is read once
    /// per floor window, through whichever of its folders changed last.
    @Test
    func aClaudeLoginIsNotReadThroughAFolderThatSwitchedSinceItsLastAnswer() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let w = "w@example.com", b = Self.b
        try fakes.writeStore(accounts: [F.work, Self.claudeHome, F.lab])
        fakes.claude(F.work, w, stamp: Self.stamp(1, 200))
        fakes.claude(Self.claudeHome, w, stamp: Self.stamp(2, 100))
        fakes.claude(F.lab, b, stamp: Self.stamp(3, 100))
        // W's usage reads 40 % used, B's 70 %.
        let folders = fakes.claudeFolders
        fakes.claudeResult = { account, now in
            let isB = folders.withValue { $0[account.folder]?.who } == .success(SignInIdentity(email: b, plan: "max"))
            return .success(AccountReading(accountID: account.id, readAt: now, plan: "max", windows: [
                UsageWindow(seconds: 18_000, usedPercent: isB ? 70 : 40, resetsAt: now + 3_600),
            ]))
        }
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        let t0 = DemoClock.now
        let idW = LoginsStore.id(provider: .claude, email: w), idB = LoginsStore.id(provider: .claude, email: b)
        #expect(fakes.reads.sorted() == ["read \(F.lab.id)", "read \(F.work.id)"])

        fakes.clock.now = t0 + 300
        fakes.claude(Self.claudeHome, b, stamp: Self.stamp(2, 900))
        let before = fakes.entries.count
        await model.look()                                                    // the check waits its half hour
        #expect(model.loginID(of: Self.claudeHome) == idW && fakes.entries.count == before)
        await model.settle()
        #expect(model.loginID(of: Self.claudeHome) == idB)
        #expect(Array(fakes.entries.dropFirst(before)).filter { $0.hasPrefix("auth ") } == ["auth \(Self.claudeHome.folder)"])
        #expect(fakes.reads.dropFirst(2).sorted() == ["read \(F.lab.id)", "read \(F.work.id)"])
        #expect(model.records[idW]?.lastGood?.readAt == t0 + 300 && model.records[idW]?.lastGood?.windows.first?.usedPercent == 40)
        #expect(model.records[idB]?.lastGood?.readAt == t0 + 300 && model.records[idB]?.lastGood?.windows.first?.usedPercent == 70)
        #expect(model.list(.claude)?.logins.map { $0.folders.map(\.id) } == [[F.work.id], [Self.claudeHome.id, F.lab.id]])

        fakes.clock.now = t0 + 600
        await model.settle()
        #expect(fakes.reads.dropFirst(4).sorted() == ["read \(Self.claudeHome.id)", "read \(F.work.id)"])
        #expect(model.records[idB]?.lastGood?.readAt == t0 + 600 && model.records[idW]?.lastGood?.windows.first?.usedPercent == 40)
    }

    /// The first launch after this change: P80's logins.json (per folder) and readings.json fold into logins. Two homes
    /// of A are one login with the newest reading and the stricter pause, which holds across the launch; a Claude folder
    /// no login held yet is asked, and its old reading sets its login's floor.
    @Test
    func theOldStoreFoldsIntoLoginsAtLaunch() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let t0 = DemoClock.now
        func reading(_ account: Account, at date: Date, used: Double, email: String?) -> AccountReading {
            var reading = LiveUsageModelTests.reading(account, at: date, used: used)
            reading.email = email
            return reading
        }
        let paused = AccountRecord(lastGood: reading(Self.codexHome, at: t0 - 500, used: 20, email: Self.a),
                                   lastError: .rateLimited(retryAfter: 60), lastErrorAt: t0 - 100, lastAttemptAt: t0 - 100,
                                   consecutiveFailures: 1)
        let newer = AccountRecord(lastGood: reading(F.side, at: t0 - 30, used: 50, email: Self.a), lastAttemptAt: t0 - 30)
        let work = AccountRecord(lastGood: reading(F.work, at: t0 - 60, used: 30, email: nil), lastAttemptAt: t0 - 60)
        try fakes.writeStore(accounts: [Self.codexHome, F.side, F.work],
                             records: [Self.codexHome.id: paused, F.side.id: newer, F.work.id: work])
        let key = LoginsStore.key(for: Self.a)
        let v1 = """
        {"version": 1, "folders": {
          "\(Self.codexHome.id)": {"current": "\(key)", "logins": {"\(key)": {"email": "\(Self.a)", "alias": "default"}}},
          "\(F.side.id)": {"current": "\(key)", "logins": {"\(key)": {"email": "\(Self.a)", "alias": "Side"}}}}}
        """
        try Data(v1.utf8).write(to: fakes.directory.appendingPathComponent("logins.json"))
        fakes.codex(Self.codexHome, Self.a, stamp: Self.stamp(1, 100))
        fakes.codex(F.side, Self.a, stamp: Self.stamp(2, 100))
        fakes.claude(F.work, "work@example.com", stamp: Self.stamp(3, 100))            // the account its known email names
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let idA = LoginsStore.id(provider: .codex, email: Self.a)
        #expect(model.records[idA]?.lastGood?.readAt == t0 - 30 && model.records[idA]?.lastError == .rateLimited(retryAfter: 60))
        #expect(model.scheduler.nextDue(for: idA) == t0 - 100 + 1 + 960)
        #expect(codexStates(model) == [.available(percentLeft: 50, isLow: false)])
        let file = try String(contentsOf: fakes.directory.appendingPathComponent("logins.json"), encoding: .utf8)
        #expect(file.contains("\"version\":2"))

        await model.look()
        await model.settle()
        #expect(fakes.reads.isEmpty)
        let idW = LoginsStore.id(provider: .claude, email: "work@example.com")
        #expect(model.records[idW]?.lastGood?.readAt == t0 - 60 && model.claudeRow?.batteries.map(\.id) == [idW])
        fakes.clock.now = t0 + 241                                           // its floor from the saved reading
        await model.settle()
        #expect(fakes.reads == ["read \(F.work.id)"])
        fakes.clock.now = t0 + 861
        await model.settle()
        #expect(codexReads(fakes).count == 1)
    }

    /// A login's Monitor switch: switched off, it is read through none of its folders and leaves the panel, and its
    /// Codex app-server stops; the list still shows it.
    @Test
    func aLoginSwitchedOffIsReadThroughNoFolder() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await twoHomesOfA(fakes)
        defer { model.stop() }
        let idA = LoginsStore.id(provider: .codex, email: Self.a)
        model.setMonitored(login: idA, false)
        await model.stopping?.value
        #expect(fakes.entries.last == "shutdown \(Self.codexHome.folder)")
        #expect(model.codexRow == nil && model.list(.codex)?.logins.map(\.monitored) == [false])
        fakes.clock.now += 3_600
        await model.look()
        model.refreshAll()
        await model.settle()
        #expect(codexReads(fakes).count == 1)
        model.setMonitored(login: idA, true)
        await model.settle()
        #expect(codexReads(fakes).count == 2)
    }

    /// A→B→A in one folder: A's 429 pause stays with A, so B is read at once; back on A while A waits, nothing is read,
    /// and B, which no folder holds now, leaves the list and keeps its reading for a folder that signs in to it again. A
    /// is read when its own pause ends.
    @Test
    func aFolderGoingBackAndForthKeepsEachLoginsWaits() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        fakes.codex(F.side, Self.a, stamp: Self.stamp(1, 1))
        fakes.codexUsed.withValue { $0 = [Self.a: 30, Self.b: 70] }
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        let t0 = DemoClock.now
        fakes.clock.now += 60
        fakes.codexFailure.withValue { $0 = .rateLimited(retryAfter: 60) }
        await model.settle()
        fakes.codexFailure.withValue { $0 = nil }

        fakes.clock.now += 10
        fakes.codex(F.side, Self.b, stamp: Self.stamp(2, 2))
        await model.look()
        await model.settle()
        #expect(codexReads(fakes).count == 3 && codexStates(model) == [.available(percentLeft: 30, isLow: false)])

        fakes.clock.now += 60
        fakes.codex(F.side, Self.a, stamp: Self.stamp(3, 3))
        await model.settle()                                                 // B's read finds A: nothing is read
        #expect(codexReads(fakes).count == 3)
        let idA = LoginsStore.id(provider: .codex, email: Self.a), idB = LoginsStore.id(provider: .codex, email: Self.b)
        #expect(model.loginID(of: F.side) == idA && model.codexRow?.batteries.map(\.id) == [idA])
        #expect(model.list(.codex)?.logins.map(\.id) == [idA])
        #expect(model.records[idB]?.lastGood?.windows.first?.usedPercent == 70)
        model.refreshAll()
        await model.settle()
        #expect(codexReads(fakes).count == 3)                                // Refresh all keeps to A's pause
        fakes.clock.now = t0 + 60 + 960
        await model.settle()
        #expect(codexReads(fakes).count == 4 && model.records[idA]?.lastError == nil)
    }

    /// The sign-in check of a Codex home asks `account/read` through a fresh server and makes no usage read: the login
    /// it finds keeps its own floor.
    @Test
    func theCodexSignInCheckOnlyAsks() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        fakes.codex(F.side, Self.a, stamp: Self.stamp(1, 1))
        let backend = fakes.readers.codex(URL(fileURLWithPath: "/fake/bin/codex"))
        let checker = LiveIdentityChecker(claude: fakes.readers.claudeIdentity(nil), codex: backend)
        #expect(await checker.identity(for: F.side) == .success(SignInIdentity(email: Self.a, plan: "plus")))
        #expect(fakes.entries == ["shutdown \(F.side.folder)", "identity \(F.side.folder)"])
    }

    /// Sign In to another account moves the folder to that login; the login it held keeps its record.
    @Test
    func aSignInToAnotherAccountMovesTheFolder() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        fakes.codex(F.side, Self.a, stamp: Self.stamp(1, 1))
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.look()
        await model.settle()
        model.signInCoordinator.onFinished?(F.side, .done(email: Self.b))
        let idA = LoginsStore.id(provider: .codex, email: Self.a), idB = LoginsStore.id(provider: .codex, email: Self.b)
        #expect(model.loginID(of: F.side) == idB && model.records[idA]?.lastGood != nil && model.records[idB] == nil)
        fakes.codex(F.side, Self.b, stamp: Self.stamp(1, 1))
        await model.settle()
        #expect(codexReads(fakes).count == 2 && model.records[idB]?.lastGood?.email == Self.b)
    }
}
