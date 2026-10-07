import Foundation
import IslandEngine
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// P1550 to P1553 on `LiveUsageModel`'s fakes, over a temporary home whose Codex folders hold fake login files dated with
/// `touch -t` (only their modification dates are looked at, by `stat`): `~/.codex` and `~/.codex-side` last changed over 9
/// days ago, `~/.codex-fresh` a day ago; each read well once, then twice refused as a rate limit. The two old ones are "login lapsed" on every
/// surface, never "rate limited"; the fresh one stays rate limited. Refresh login opens Codex in the login's folder, on the
/// click only; and once a lapsed login's file changes, it is read at its floor. Nothing opens a window: the terminal is a
/// recorder.
@MainActor
@Suite(.serialized)
struct LoginLapseLiveTests {
    struct Rig {
        let fakes: LiveFakes
        let model: LiveUsageModel
        let home: String
        let codex: Account, side: Account, fresh: Account
        /// What Refresh login asked the terminal to open.
        let opened: LockedBox<[FreshSessionLaunch]>
        /// Another model on the same files and fakes: the app launched again.
        let relaunch: @MainActor () -> LiveUsageModel

        func id(_ folder: Account) -> String { LoginsStore.id(provider: .codex, email: LiveFakes.ownEmail(folder.folder)) }
        @MainActor func battery(_ folder: Account) -> BatteryModel? { model.codexRow?.batteries.first { $0.id == id(folder) } }
    }

    /// `touch -t [[CC]YY]MMDDhhmm[.SS]` in this Mac's time zone.
    static func touch(_ path: String, at date: Date) throws {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyyMMddHHmm.ss"
        let touch = Process()
        touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        touch.arguments = ["-t", format.string(from: date), path]
        try touch.run()
        touch.waitUntilExit()
        #expect(touch.terminationStatus == 0)
    }

    /// The home, its three folders and the model on the fakes, the Codex app-servers' `stat` the real one over the
    /// temporary home; each login read well, then refused as a rate limit twice (the second after its 900 s pause).
    /// Renders pass `withClaude` (a Claude folder read beside them), `failing: false` (every read good: the old logins are
    /// only aging, P1553) and `freshDays`.
    static func rig(_ fakes: LiveFakes, withClaude: Bool = false, failing: Bool = true, freshDays: Double = 1) async throws -> Rig {
        let home = try fakes.tempHome()
        let codex = Account(provider: .codex, folder: home + "/.codex", alias: "default")
        let side = Account(provider: .codex, folder: home + "/.codex-side", alias: "Side")
        let fresh = Account(provider: .codex, folder: home + "/.codex-fresh", alias: "Fresh")
        for (folder, days) in [(codex, 10.0), (side, 11.0), (fresh, freshDays)] {
            try FileManager.default.createDirectory(atPath: folder.folder, withIntermediateDirectories: true)
            let file = folder.folder + "/auth.json"
            try Data("fake".utf8).write(to: URL(fileURLWithPath: file))
            try touch(file, at: DemoClock.now - days * 86_400)
        }
        let claude = Account(provider: .claude, folder: home + "/.claude-work", alias: "Work")
        try fakes.writeStore(accounts: (withClaude ? [claude] : []) + [codex, side, fresh])
        let opened = LockedBox<[FreshSessionLaunch]>([])
        var readers = fakes.readers
        let backend = readers.codex
        readers.codex = { executable in
            var real = backend(executable)
            real.stat = { AuthFileStamp.of(folder: $0) }
            return real
        }
        readers.usualHost = { .iterm }
        readers.openTerminal = { launch in
            opened.withValue { $0.append(launch) }
            return true
        }
        let clock = fakes.clock
        let make: @MainActor () -> LiveUsageModel = { [readers, unowned fakes] in
            LiveUsageModel(directory: fakes.directory, readers: readers, juiceGuard: fakes.juiceGuard, clock: { clock.now },
                           makeScheduler: { [unowned fakes] in fakes.scheduler() }, storeWriter: nil)
        }
        let model = make()
        model.start()
        await model.settle()
        // The three logins' first reads, good (2 s apart at most, the Codex stagger); then every read is refused as a rate
        // limit: one at the 60 s floor, the second after its 900 s pause.
        for _ in 0..<2 {
            fakes.clock.now += 2
            await model.settle()
        }
        if failing { fakes.codexFailure.withValue { $0 = .rateLimited(retryAfter: nil) } }
        fakes.clock.now = DemoClock.now + 65
        await model.settle()
        fakes.clock.now = DemoClock.now + 65 + 905
        await model.settle()
        await model.look()
        return Rig(fakes: fakes, model: model, home: home, codex: codex, side: side, fresh: fresh, opened: opened, relaunch: make)
    }

    @Test
    func aLapsedLoginSaysOpenCodexOnEverySurfaceAndAFreshOnesRateLimitStays() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes)
        defer { rig.model.stop() }
        let model = rig.model
        #expect(fakes.reads.count == 9)
        for folder in [rig.codex, rig.side, rig.fresh] {
            #expect(model.loginsStore.logins[rig.id(folder)]?.record?.consecutiveFailures == 2)
            #expect(model.loginsStore.logins[rig.id(folder)]?.record?.lastError == .rateLimited(retryAfter: nil))
        }
        let lapsed = try #require(rig.battery(rig.side)), home = try #require(rig.battery(rig.codex))
        let fresh = try #require(rig.battery(rig.fresh))
        #expect(lapsed.state == .loginLapsed && home.state == .loginLapsed)
        guard case .stale = fresh.state else { Issue.record("the fresh login is \(fresh.state)"); return }

        // Its hover (the window and the panel), the island's short one, the account list, Settings › Accounts.
        #expect(lapsed.hoverLabel == "side · Open Codex once to refresh this login")
        #expect(HoverLabelText.full(.account(lapsed.id), usage: model)?.parts == ["Open Codex once to refresh this login"])
        #expect(HoverLabelText.short(.account(lapsed.id), usage: model)?.parts == ["login lapsed", "open Codex once"])
        #expect(AccountListText.detail(lapsed, usage: model).text == "Login lapsed")
        let row = try #require(model.list(.codex)?.logins.first { $0.id == lapsed.id })
        #expect(row.battery.state == .loginLapsed)
        // Diagnostics: "Login lapsed" for the two, "Rate limited" for the fresh login's rate limit.
        let lines = DiagnosticsText.accounts(model.logins, records: model.records, schedule: { model.schedule(of: $0) }, now: model.now)
        #expect(lines.map(\.line.status) == ["Login lapsed", "Login lapsed", "Rate limited"])
        // The widget's battery.
        #expect(WidgetSnapshot.Battery(lapsed).state == .loginLapsed && WidgetSnapshot.Battery(lapsed).accessibilityText == "Login lapsed")
        // Nowhere does a lapsed login say "rate limited".
        let said = [lapsed.hoverLabel, home.hoverLabel, HoverLabelText.short(.account(lapsed.id), usage: model)?.text ?? "",
                    AccountListText.detail(lapsed, usage: model).text, lines[0].line.status, lines[1].line.status]
        #expect(!said.contains { $0.lowercased().contains("rate") })
        // The provider's label does not count a lapsed login as used up.
        #expect(model.codexRow?.availability.isKnown == false)
        // Nothing was written into a folder: each still holds only its fake login file.
        for folder in [rig.codex, rig.side, rig.fresh] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.folder) == ["auth.json"])
        }
    }

    /// P1551: the line for each folder, quoted; plain `codex` for `~/.codex`; nothing for the fresh login; and the click
    /// opens it, once, reading nothing.
    @Test
    func refreshLoginOpensCodexInTheLoginsFolderOnTheClickOnly() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes)
        defer { rig.model.stop() }
        let model = rig.model
        #expect(model.loginRefreshLaunch(rig.id(rig.side)) == FreshSessionLaunch(host: .iterm, folder: rig.home,
                                                                                    line: "CODEX_HOME='\(rig.side.folder)' codex"))
        #expect(model.loginRefreshLaunch(rig.id(rig.codex)) == FreshSessionLaunch(host: .iterm, folder: rig.home, line: "codex"))
        #expect(model.loginRefreshLaunch(rig.id(rig.fresh)) == nil)
        #expect(rig.opened.withValue { $0 }.isEmpty)

        let reads = fakes.reads.count
        let env = RRenders.environment(model)
        PanelActions.desktop(env: env).refreshLogin?(rig.id(rig.side))
        #expect(await Looks.until(5) { rig.opened.withValue { $0.count } == 1 })
        #expect(rig.opened.withValue { $0 } == [model.loginRefreshLaunch(rig.id(rig.side))])
        // The island's batteries, and a battery that is not lapsed, which opens nothing.
        PanelActions.island(env: env).refreshLogin?(rig.id(rig.codex))
        model.refreshLogin(rig.id(rig.fresh))
        #expect(await Looks.until(5) { rig.opened.withValue { $0.count } == 2 })
        #expect(rig.opened.withValue { $0.map(\.line) } == ["CODEX_HOME='\(rig.side.folder)' codex", "codex"])
        #expect(fakes.reads.count == reads)
    }

    /// P1552: once a lapsed login's file changes, it is read at its floor (60 s after its last read), not after the 900 s
    /// pause, and its battery comes back; the other lapsed login, whose file did not change, keeps its pause.
    @Test
    func aLapsedLoginWhoseFileChangesIsReadAtItsFloor() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes)
        defer { rig.model.stop() }
        let model = rig.model, side = rig.id(rig.side), home = rig.id(rig.codex)
        let lastRead = try #require(model.loginsStore.logins[side]?.record?.lastAttemptAt)
        let paused = try #require(model.scheduler.nextDue(for: side))
        #expect(paused >= lastRead + 900)
        let homeDue = model.scheduler.nextDue(for: home)
        // Nothing moves while the file stays as it was.
        fakes.clock.now += 5
        await model.look()
        #expect(model.scheduler.nextDue(for: side) == paused)

        // The owner ran Codex there: it refreshed the login (the file's date moves), and reads work again.
        try Self.touch(rig.side.folder + "/auth.json", at: fakes.clock.now)
        fakes.codexFailure.withValue { $0 = nil }
        await model.look()
        #expect(model.scheduler.nextDue(for: side) == lastRead + 60)
        #expect(model.scheduler.nextDue(for: home) == homeDue)
        let before = fakes.reads.count
        fakes.clock.now = lastRead + 59
        await model.settle()
        #expect(fakes.reads.count == before)
        fakes.clock.now = lastRead + 60
        await model.settle()
        #expect(fakes.reads.count == before + 1 && fakes.reads.last == "read \(rig.side.id)")
        #expect(rig.battery(rig.side)?.state == .available(percentLeft: 90, isLow: false))
        #expect(rig.battery(rig.codex)?.state == .loginLapsed)
    }

    /// F1 (P1551): a battery's menu offers Refresh login only where its surface opens the terminal: the panel's, the
    /// island's (its usage block and its header strip) and the battery in Settings › Accounts' row. A surface that wires
    /// nothing keeps Refresh account, greyed, as before, never an item that does nothing.
    @Test
    func refreshLoginIsOfferedOnlyWhereItOpensSomething() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes)
        defer { rig.model.stop() }
        let model = rig.model, env = RRenders.environment(model)
        let lapsed = try #require(rig.battery(rig.side)), home = try #require(rig.battery(rig.codex))
        #expect(BatteryView.firstMenuItem(lapsed, actions: PanelActions()) == .refreshAccount(.init(title: "Refresh account", isEnabled: false)))
        #expect(BatteryView.firstMenuItem(lapsed, actions: .desktop(env: env)) == .refreshLogin)
        #expect(BatteryView.firstMenuItem(lapsed, actions: .island(env: env)) == .refreshLogin)
        let strip = HeaderStripPair.batteryActions(env: env)
        #expect(BatteryView.firstMenuItem(home, actions: strip) == .refreshLogin)
        let row = try #require(model.list(.codex)?.logins.first { $0.id == lapsed.id })
        let id = row.id
        let view = LoginRowView(row: row, now: model.now, home: model.home, refreshLogin: { model.refreshLogin(id) })
        #expect(BatteryView.firstMenuItem(lapsed, actions: view.batteryActions) == .refreshLogin)
        // A row with no Refresh login (Juice's readings, the demo) offers none on its battery either.
        let bare = LoginRowView(row: row, now: model.now, home: model.home)
        #expect(BatteryView.firstMenuItem(lapsed, actions: bare.batteryActions) != .refreshLogin)

        // Each one opens the terminal for its login, on the click.
        view.batteryActions.refreshLogin?(lapsed.id)
        #expect(await Looks.until(5) { rig.opened.withValue { $0.count } == 1 })
        strip.refreshLogin?(home.id)
        #expect(await Looks.until(5) { rig.opened.withValue { $0.count } == 2 })
        #expect(rig.opened.withValue { $0.map(\.line) } == ["CODEX_HOME='\(rig.side.folder)' codex", "codex"])
    }

    /// F2 (P1552): a lapsed login refreshed while the app was not running (the owner ran Codex there, so its file changed
    /// after its last failed read) is read at its floor once the app starts again, not after the 429 pause its failures
    /// restored. The other lapsed login, whose file did not change, keeps its pause.
    @Test
    func aLoginRefreshedWhileTheAppWasNotRunningIsReadAtItsFloorOnLaunch() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes)
        let first = rig.model, side = rig.id(rig.side), home = rig.id(rig.codex)
        let lastRead = try #require(first.loginsStore.logins[side]?.record?.lastAttemptAt)
        let homeRead = try #require(first.loginsStore.logins[home]?.record?.lastAttemptAt)
        first.stop()

        // While the app was not running, the owner's Codex refreshed the side login, and reads work again.
        fakes.clock.now = lastRead + 5
        try Self.touch(rig.side.folder + "/auth.json", at: fakes.clock.now)
        fakes.codexFailure.withValue { $0 = nil }
        fakes.clock.now = lastRead + 10
        let model = rig.relaunch()
        defer { model.stop() }
        model.start()
        await model.settle()
        // Its floor counts from the saved attempt, a second later (the file keeps whole seconds, so a restored wait never
        // ends early).
        #expect(model.scheduler.nextDue(for: side) == lastRead + 61)
        #expect(try #require(model.scheduler.nextDue(for: home)) >= homeRead + 900)
        let before = fakes.reads.count
        fakes.clock.now = lastRead + 60
        await model.settle()
        #expect(fakes.reads.count == before)
        fakes.clock.now = lastRead + 61
        await model.settle()
        #expect(fakes.reads.count == before + 1 && fakes.reads.last == "read \(rig.side.id)")
        #expect(model.codexRow?.batteries.first { $0.id == side }?.state == .available(percentLeft: 90, isLow: false))
        #expect(model.codexRow?.batteries.first { $0.id == home }?.state == .loginLapsed)
    }
}
