import AppKit
import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// `LiveUsageModel` on fakes (`LiveFakes`): a temp store, a fake clock, logged readers. No test runs a real reader.
@MainActor
struct LiveUsageModelTests {
    typealias F = LiveFakes

    static func reading(_ account: Account, at date: Date, used: Double = 30) -> AccountReading {
        AccountReading(accountID: account.id, readAt: date, plan: "pro", windows: [
            UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: date + 3_600),
            UsageWindow(seconds: 604_800, usedPercent: used / 2, resetsAt: date + 86_400),
        ])
    }

    @Test
    func readsEveryMonitoredAccountAndWritesJuicesStore() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        var off = F.fresh
        off.monitored = false
        try fakes.writeStore(accounts: [F.work, F.side, off])
        let model = fakes.model()
        defer { model.stop() }
        #expect(model.phase == .idle && fakes.entries.isEmpty)       // nothing before start
        model.start()
        #expect(model.phase == .reading && model.refreshUnavailableReason == nil)
        await model.settle()
        #expect(Set(fakes.entries.filter { $0.hasPrefix("locate") }) == ["locate claude", "locate codex"])
        #expect(Set(fakes.reads) == ["read \(F.work.id)", "read \(F.side.id)"])
        #expect(model.claudeExecutable?.path == "/fake/bin/claude" && model.codexExecutable?.path == "/fake/bin/codex")
        // The same store standalone Juice keeps: a fresh ReadingsStore on that file sees both readings.
        let saved = ReadingsStore(fileURL: fakes.directory.appendingPathComponent("readings.json"))
        saved.load()
        #expect(saved.records[F.work.id]?.lastGood?.readAt == DemoClock.now && saved.records[F.side.id]?.lastGood != nil)
        #expect(model.claudeRow?.batteries.map(\.state) == [.available(percentLeft: 60, isLow: false)])
        #expect(model.codexRow?.batteries.map(\.alias) == ["side"])     // the unmonitored home leaves every surface (P34)
        #expect(model.plan(for: F.work.id) == "Max")
        // Floors: nothing is read again before its interval.
        fakes.clock.now += 59
        await model.settle()
        #expect(fakes.reads.count == 2)
        fakes.clock.now += 1
        await model.settle()
        #expect(fakes.reads.last == "read \(F.side.id)" && fakes.reads.count == 3)
    }

    @Test
    func neverStartsAReaderWhileStandaloneJuiceRuns() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work, F.side], records: [F.work.id: AccountRecord(lastGood: Self.reading(F.work, at: DemoClock.now - 600))])
        fakes.running = [F.juiceApp]
        let model = fakes.model()
        defer { model.stop() }
        let before = fakes.storeBytes()
        model.start()
        #expect(model.phase == .waitingForJuice)
        #expect(model.refreshUnavailableReason == "Juice is running — quit it to read here")
        #expect(LiveAccountsText.statusLine(model) == LiveUsageModel.juiceRunningText)
        // Juice's readings are mirrored, read only.
        #expect(model.accounts == [F.work, F.side] && model.records[F.work.id]?.lastGood != nil)
        model.refreshAll()
        model.tick()
        await model.scheduler.tick(); await model.scheduler.waitForInFlight()
        #expect(!model.signIn(id: F.work.id) && model.signingIn.isEmpty)
        model.setMonitored(F.work.id, false)
        model.remove(F.side.id)
        model.rename(F.work.id, to: "Renamed")
        #expect(!model.canEdit && model.accounts == [F.work, F.side])
        #expect(fakes.entries.isEmpty)                                // no locate, no read, no app-server
        #expect(fakes.storeBytes() == before)                         // Juice's files untouched
        #expect(model.wiring == nil && !model.scheduler.isRunning)

        // Juice writes while it runs; the mirror follows on the next tick.
        try fakes.writeStore(accounts: [F.work], records: [:])
        model.tick()
        #expect(model.accounts == [F.work])

        // Juice quits: the readers start by themselves, from what Juice saved.
        fakes.running = [F.juiceApp]                                  // still listed while it terminates
        model.appTerminated(F.juiceApp)
        #expect(model.phase == .reading)
        await model.settle()
        #expect(fakes.reads == ["read \(F.work.id)"])
    }

    @Test
    func stopsReadingWhenStandaloneJuiceStarts() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work, F.side])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.reads.count == 2)
        fakes.running = [F.juiceApp]
        model.appLaunched(F.juiceApp)
        #expect(model.phase == .waitingForJuice && !model.scheduler.isRunning)
        for _ in 0..<100 where !fakes.entries.contains("shutdownAll") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fakes.entries.contains("shutdownAll"))               // the Codex app-servers go
        fakes.clock.now += 3_600
        model.tick()
        model.refreshAll()
        #expect(model.phase == .waitingForJuice && !model.scheduler.isRunning && model.wiring == nil)
        #expect(fakes.reads.count == 2)

        // Another app starting changes nothing.
        model.appLaunched(RunningAppInfo(processIdentifier: 9, bundleIdentifier: "com.apple.finder", bundleURL: nil))
        #expect(model.phase == .waitingForJuice)
    }

    /// §7 amendment 3: a relaunch keeps each account's wait, and a reading made by standalone Juice sets the floor. Each
    /// folder's saved record goes to the login its CLI names when it is first asked (P93).
    @Test
    func restoresSavedWaitsAndCountsFloorsFromJuicesReadings() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let t0 = DemoClock.now
        let limited = AccountRecord(lastGood: Self.reading(F.work, at: t0 - 7_200), lastError: .rateLimited(retryAfter: 60),
                                    lastErrorAt: t0 - 60, lastAttemptAt: t0 - 60, consecutiveFailures: 1)
        let justRead = AccountRecord(lastGood: Self.reading(F.lab, at: t0 - 30), lastAttemptAt: t0 - 30)
        let codexOld = AccountRecord(lastGood: Self.reading(F.side, at: t0 - 100), lastAttemptAt: t0 - 100)
        try fakes.writeStore(accounts: [F.work, F.lab, F.side], records: [F.work.id: limited, F.lab.id: justRead, F.side.id: codexOld])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let work = try #require(model.loginID(of: F.work)), lab = try #require(model.loginID(of: F.lab))
        let paused = try #require(model.scheduler.nextDue(for: work))
        #expect(paused >= t0 - 60 + 60 + 900 && paused <= t0 - 60 + 60 + 900 + 1)
        #expect(try #require(model.scheduler.nextDue(for: lab)) >= t0 - 30 + 300)
        #expect(fakes.reads == ["read \(F.side.id)"])                 // only the Codex home was due
        model.refreshAll()                                             // the 429 pause and the floors hold
        await model.settle()
        #expect(fakes.reads == ["read \(F.side.id)"])
    }

    @Test
    func refreshAllKeepsToTheFloorsAndShowsProgress() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work, F.side])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.reads.count == 2)
        fakes.clock.now += 30
        model.refreshAll()
        #expect(model.refreshProgress == nil)                          // both read 30 s ago: nothing to refresh yet
        await model.settle()
        #expect(fakes.reads.count == 2)

        fakes.clock.now += 30                                          // Codex's floor (60 s) has passed, Claude's (120 s) not
        model.refreshAll()
        #expect(model.scheduler.batchTotal == 1)
        #expect(LiveAccountsText.statusLine(model) == "Refreshing 1 of 1…")    // counted from the batch, not the list
        #expect(model.refreshTotal == 1)
        #expect(PanelMenu.items(usage: model, settings: .ephemeral()).first??.title == "Refreshing 1 of 1…")
        await model.settle()
        #expect(fakes.reads.count == 3 && fakes.reads.last == "read \(F.side.id)")

        fakes.clock.now += 70                                          // Claude's boosted floor (120 s) has passed
        model.refreshAll()
        #expect(model.refreshProgress == 1 && model.scheduler.batchTotal == 2)
        #expect(LiveAccountsText.statusLine(model) == "Refreshing 1 of 2…")
        await model.settle()
        #expect(fakes.reads.count == 5 && model.refreshProgress == nil)
        #expect(LiveAccountsText.statusLine(model) == nil)
    }

    @Test
    func addMonitorRenameAndRemoveEditTheStore() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        fakes.discovered = [
            DiscoveredProfile(provider: .claude, folder: F.work.folder, suggestedAlias: "work"),
            DiscoveredProfile(provider: .claude, folder: F.lab.folder, suggestedAlias: "lab"),
            DiscoveredProfile(provider: .codex, folder: F.fresh.folder, suggestedAlias: "fresh", hasAuthFile: false),
        ]
        try fakes.writeStore(accounts: [F.work, F.side])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        model.refreshDiscovery()
        await model.discovery?.value
        #expect(model.discovered.map(\.folder) == [F.lab.folder, F.fresh.folder])

        model.add(fakes.discovered[2])
        #expect(model.accounts.map(\.id) == [F.work.id, F.side.id, F.fresh.id] && model.discovered.map(\.folder) == [F.lab.folder])
        let stored = AccountsStore(fileURL: fakes.directory.appendingPathComponent("accounts.json"))
        stored.load()
        #expect(stored.accounts.map(\.id) == model.accounts.map(\.id))
        await model.settle()
        #expect(fakes.reads.contains("read \(F.fresh.id)"))           // a new account is asked and read at once

        model.setMonitored(F.side.id, false)
        let fresh = try #require(model.loginID(of: F.fresh))
        #expect(model.codexRow?.batteries.map(\.id) == [fresh])
        for _ in 0..<100 where !fakes.entries.contains("shutdown \(F.side.folder)") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fakes.entries.contains("shutdown \(F.side.folder)"))  // its app-server stops with it

        model.rename(F.work.id, to: "  Main  ")
        #expect(model.account(id: F.work.id)?.alias == "Main")
        model.rename(F.work.id, to: "   ")
        #expect(model.account(id: F.work.id)?.alias == "Main")

        model.remove(F.work.id)
        #expect(model.account(id: F.work.id) == nil && model.records[F.work.id] == nil)
        #expect(model.discovered.map(\.folder).contains(F.work.folder))
        stored.load()
        #expect(!stored.accounts.contains { $0.id == F.work.id })
    }

    /// §7 amendment 8: a Codex home not placed yet is restarted and asked who is signed in before anything is read. It
    /// holds another account than its known email says, so its old record stays out of that login, which is new and read
    /// at once, and the known email follows.
    @Test
    func theIdentityWatchRunsInsideTheCodexRead() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        var side = F.side
        side.knownEmail = "old@example.com"
        let old = AccountRecord(lastGood: Self.reading(side, at: DemoClock.now - 600), lastAttemptAt: DemoClock.now - 600)
        try fakes.writeStore(accounts: [side], records: [side.id: old])
        fakes.authStamp = AuthFileStamp(inode: 7, modifiedSeconds: 1)
        fakes.codexEmail = "new@example.com"
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.entries.filter { !$0.hasPrefix("locate") } == ["shutdown \(side.folder)", "identity \(side.folder)", "read \(side.id)"])
        #expect(model.account(id: side.id)?.knownEmail == "new@example.com")
        #expect(model.records[side.id]?.lastGood?.readAt == DemoClock.now)
        let login = try #require(model.loginID(of: side))
        #expect(model.records[login]?.lastGood?.email == "new@example.com" && model.records[login]?.lastAttemptAt == DemoClock.now)
    }

    @Test
    func aMissingCLIIsLookedForAgainOnRefresh() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        fakes.located = [.codex: URL(fileURLWithPath: "/fake/bin/codex")]
        try fakes.writeStore(accounts: [F.work, F.side])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        // With no CLI to ask, the Claude folder is not placed: it is listed on its own, and no battery stands for it.
        #expect(model.claudeExecutable == nil && model.claudeRow == nil)
        #expect(model.list(.claude)?.folders.map(\.state) == [.unknown] && model.codexRow?.batteries.count == 1)
        // Nothing asks it, so it shows no "…"; the status line says why, once.
        #expect(model.asking.isEmpty && model.unanswered.isEmpty && LiveAccountsText.statusLine(model) == "Claude CLI not found")
        let searches = fakes.entries.filter { $0 == "locate claude" }.count
        model.refreshAll()
        await model.wiring?.value
        #expect(fakes.entries.filter { $0 == "locate claude" }.count == searches + 1)
    }

    /// A folder not placed yet shows "…" only while it is asked: during the CLI search and until its question ends. A
    /// question that fails offers Sign In until the folder is asked again, after the read backoff, and answers.
    @Test
    func aFolderIsShownAsAskedOnlyWhileItsQuestionIsPending() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        fakes.claudeFolders.withValue { $0[F.work.folder] = LiveFakes.ClaudeFolder(who: .failure(.timeout), stamp: nil) }
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        #expect(model.asking == [F.work.id] && model.unanswered.isEmpty)       // the CLI search runs
        await model.look()
        #expect(model.asking.isEmpty && model.unanswered == [F.work.id] && LiveAccountsText.statusLine(model) == nil)
        fakes.claude(F.work, "work@example.com", stamp: nil)
        fakes.clock.now += 29
        await model.look()
        #expect(model.unanswered == [F.work.id])                             // its backoff: 30 s
        fakes.clock.now += 1
        await model.look()
        #expect(model.asking.isEmpty && model.unanswered.isEmpty && model.loginID(of: F.work) != nil)
    }

    @Test
    func stopAndShutdownEndEverything() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        let model = fakes.model()
        model.start()
        await model.settle()
        await model.shutdown()
        #expect(model.phase == .idle && !model.scheduler.isRunning && fakes.entries.last == "shutdownAll")
        fakes.clock.now += 3_600
        model.tick()
        model.refreshAll()
        #expect(model.phase == .idle && !model.scheduler.isRunning && model.wiring == nil && fakes.reads.count == 1)
        #expect(!model.signIn(id: F.side.id))
    }

    /// A quit (P98): the readers stop before `stopForQuit` returns, and only the app-servers' shutdown is left for the
    /// quit to wait on, off the main actor; with nothing reading there is nothing to wait on.
    @Test
    func stopForQuitStopsAtOnceAndHandsBackTheShutdown() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        let model = fakes.model()
        model.start()
        await model.settle()
        let shutdown = try #require(model.stopForQuit())
        #expect(model.phase == .idle && !model.scheduler.isRunning && fakes.entries.last != "shutdownAll")
        await Task.detached { await shutdown() }.value
        #expect(fakes.entries.last == "shutdownAll")
        #expect(model.stopForQuit() == nil)
    }

    /// Sign In with no CLI found fails at once and launches nothing (the coordinator has no executable to start).
    @Test
    func signInWithoutACLIFailsWithoutLaunchingAnything() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        fakes.located = [:]
        try fakes.writeStore(accounts: [F.work])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(model.signIn(id: F.work.id))
        #expect(!model.signIn(id: F.work.id) || model.signingIn.isEmpty)     // one flow at a time
        for _ in 0..<100 where model.signInPhase(for: F.work.id).map({ if case .failed = $0 { false } else { true } }) ?? true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.signInPhase(for: F.work.id) == .failed("claude CLI not found"))
        #expect(model.signingIn.isEmpty && !model.signIn(id: "claude:/nowhere"))
    }

    /// P69: the launch and quit notifications count before `NSWorkspace`'s list catches up, so a list that lags never
    /// lets both apps read, and a Juice that quit but is still listed does not stop the readers again.
    @Test
    func theNotificationsCountBeforeTheListCatchesUp() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.reads.count == 1)

        model.appLaunched(F.juiceApp)                                  // not listed yet
        #expect(model.phase == .waitingForJuice && !model.scheduler.isRunning)
        fakes.clock.now += 5
        model.tick()
        #expect(model.phase == .waitingForJuice)
        fakes.running = [F.juiceApp]                                  // the list catches up
        model.tick()
        #expect(model.phase == .waitingForJuice)

        model.appTerminated(F.juiceApp)                               // still listed
        #expect(model.phase == .reading)
        fakes.clock.now += 5
        model.tick()
        #expect(model.phase == .reading)
        fakes.running = []
        model.tick()
        #expect(model.phase == .reading)

        // A launch the list never shows stops counting after the grace, so a missed quit cannot stop reading for good.
        let other = RunningAppInfo(processIdentifier: 4_243, bundleIdentifier: nil, bundleURL: URL(fileURLWithPath: "/Applications/Juice.app"))
        model.appLaunched(other)
        #expect(model.phase == .waitingForJuice)
        fakes.clock.now += LiveUsageModel.launchGrace
        model.tick()
        #expect(model.phase == .reading)
        await model.settle()
        #expect(fakes.reads.count == 1)                               // and the floor still holds
    }

    /// Juice launching while the CLIs are being looked for: nothing is wired and nothing starts.
    @Test
    func aJuiceLaunchDuringTheCLISearchWiresNothing() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work, F.side])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        let search = try #require(model.wiring)
        fakes.running = [F.juiceApp]
        model.appLaunched(F.juiceApp)
        await search.value
        #expect(model.phase == .waitingForJuice && !model.scheduler.isRunning)
        #expect(model.claudeExecutable == nil && model.codexExecutable == nil)
        #expect(fakes.entries.allSatisfy { $0.hasPrefix("locate ") })
    }

    /// P118: a sleep whose wake never came does not pause reads for good. The clock does not tick while the Mac sleeps,
    /// so ticks going on a minute after `willSleep` (a sleep called off) resume reads, and so do the first ticks after
    /// a long sleep whose `didWake` was lost; the ticks between `willSleep` and the sleep itself do not.
    @Test
    func aSleepWithoutAWakeEndsOnTheClock() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.reads.count == 1)

        // Called off: the ticks go on.
        model.willSleep()
        for _ in 0..<11 {
            fakes.clock.now += 5
            model.tick()
        }
        #expect(model.scheduler.isPaused)                             // 55 s: the Mac may still be going to sleep
        fakes.clock.now += 5
        model.tick()
        #expect(!model.scheduler.isPaused)

        // A long sleep whose wake was lost: one tick before it, then the clock's first two after it.
        model.willSleep()
        fakes.clock.now += 3
        model.tick()
        fakes.clock.now += 3 * 3_600
        #expect(model.scheduler.isPaused)
        model.tick()
        #expect(!model.scheduler.isPaused)
        await model.settle()
        #expect(fakes.reads == ["read \(F.work.id)", "read \(F.work.id)"])

        // A wake that did come leaves nothing for the clock to do.
        model.willSleep()
        fakes.clock.now += 5
        model.tick()
        model.didWake()
        #expect(!model.scheduler.isPaused)
    }

    /// P113: with the app's writer the files are written off the main thread, a file's changes within its delay as one
    /// write, and only a file that changed: a read writes readings.json and logins.json, never an unchanged
    /// accounts.json. What waits is written when the readers stop.
    @Test
    func readsWriteOnlyWhatChangedOffTheMainThread() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        let before = fakes.storeBytes()
        let writer = StoreWriter(delay: 3_600)
        let model = fakes.model(storeWriter: writer)
        model.start()
        await model.settle()
        #expect(fakes.reads.count == 1)
        #expect(writer.writeCount == 0 && fakes.storeBytes() == before)  // nothing on disk yet: it waits for the delay
        model.stop()                                                     // the readers stop: what waits is written
        #expect(writer.writeCount == 2)
        #expect(fakes.storeBytes()[0] == before[0] && fakes.storeBytes()[1] != before[1])
        let readings = fakes.directory.appendingPathComponent("readings.json")
        let saved = ReadingsStore(fileURL: readings)
        saved.load()
        #expect(saved.records[F.work.id]?.lastGood?.readAt == DemoClock.now)
        #expect(FileManager.default.fileExists(atPath: fakes.directory.appendingPathComponent("logins.json").path))
    }

    /// P113: when standalone Juice starts, what waits to be written goes at once, before the store is read again and
    /// before Juice can load readings.json, so it finds this run's last readings (a 429's pause among them).
    @Test
    func standaloneJuiceStartingWritesWhatWaits() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        let writer = StoreWriter(delay: 3_600)
        let model = fakes.model(storeWriter: writer)
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(fakes.reads.count == 1 && writer.writeCount == 0)
        fakes.running = [F.juiceApp]
        model.appLaunched(F.juiceApp)
        #expect(model.phase == .waitingForJuice)
        #expect(writer.writeCount == 2)
        let saved = ReadingsStore(fileURL: fakes.directory.appendingPathComponent("readings.json"))
        saved.load()
        #expect(saved.records[F.work.id]?.lastGood?.readAt == DemoClock.now)
        #expect(model.records[F.work.id]?.lastGood?.readAt == DemoClock.now)
    }

    /// Spec §9.5: reads pause over sleep, also in a scheduler started before the wake (Juice quit in between).
    @Test
    func sleepPausesReadsAcrossARestart() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        fakes.running = [F.juiceApp]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        model.willSleep()
        fakes.running = []
        model.appTerminated(F.juiceApp)
        #expect(model.phase == .reading && model.scheduler.isPaused)
        await model.settle()
        #expect(fakes.reads.isEmpty)
        model.didWake()
        #expect(!model.scheduler.isPaused)
        await model.settle()
        #expect(fakes.reads == ["read \(F.work.id)"])
    }
}

/// The quit hook lives in an extension (`AppDelegate+Readers.swift`): AppKit must see it, and a source that reads
/// nothing quits at once.
@MainActor
struct AppDelegateReadersTests {
    @Test
    func appKitSeesTheQuitHookAndOtherSourcesQuitAtOnce() {
        let delegate = AppDelegate(environment: .demo())
        #expect(delegate.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }
}
