import Foundation
import JuiceCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Sessions in the demo's account folders, fed through the engine's live paths on a headless preview engine and tagged
/// with their accounts by their transcripts' folders (P810): two Claude logins with sessions in each (Work's running,
/// Lab's two finished, one of them the newest of all), a Claude session in Alt (a folder no login holds) and one in a
/// folder that is no account's, and a Codex chat in Team. Every folder is a fixture's, under the home folder; nothing is
/// read or opened.
@MainActor
enum InUseFixtures {
    static let work = "inuse-work"
    static let lab = "inuse-lab"
    static let labOlder = "inuse-lab-older"
    static let alt = "inuse-alt"
    static let elsewhere = "inuse-elsewhere"
    static let codex = "inuse-codex"

    /// The demo's batteries by folder (`DemoUsageModel` builds them per folder).
    static func battery(_ provider: Provider, _ folder: String) -> String { Account.id(provider: provider, folder: folder) }
    static let workBattery = battery(.claude, "~/.claude-work")
    static let labBattery = battery(.claude, "~/.claude-lab")
    static let mainBattery = battery(.claude, "~/.claude")
    static let teamBattery = battery(.codex, "~/.codex-team")
    static let homeBattery = battery(.codex, "~/.codex")

    static func folder(_ name: String) -> String { NSHomeDirectory() + "/" + name }

    /// A Claude session in `profile` (its transcript under `<profile>/projects/`), running, or finished at `doneAt`.
    static func claude(_ engine: SessionEngine, _ id: String, profile: String, project: String, at start: Date, doneAt: Date? = nil) {
        claude(engine, id, transcript: folder(profile + "/projects/" + project + "/" + id + ".jsonl"), project: project, at: start, doneAt: doneAt)
    }

    /// A Claude session whose transcript is at `transcript`.
    static func claude(_ engine: SessionEngine, _ id: String, transcript: String, project: String, at start: Date, doneAt: Date? = nil) {
        engine.loadPreviewEvents(FixtureSessionFeed.start(id, title: "Work in " + project, project: project, prompt: "go on", at: start))
        engine.loadPreviewEvents([.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(
            sessionID: id, claudeMetadata: ClaudeSessionMetadata(transcriptPath: transcript, lastUserPrompt: "go on"),
            timestamp: start + 2))])
        if let doneAt {
            engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: doneAt))])
        }
    }

    /// The demo's accounts as the engine takes them, their folders written out.
    static var accounts: [Account] {
        DemoUsageData.accounts.map { account in
            Account(provider: account.provider, folder: (account.folder as NSString).expandingTildeInPath, alias: account.alias,
                    monitored: account.monitored, knownEmail: account.knownEmail)
        }
    }

    /// `sessions`: false leaves the engine with none.
    static func engine(now: Date = DemoClock.now, sessions: Bool = true) -> SessionEngine {
        let engine = SessionEngine.preview(clock: { now })
        if sessions {
            claude(engine, work, profile: ".claude-work", project: "notes-site", at: now - 900)
            claude(engine, lab, profile: ".claude-lab", project: "juice-tools", at: now - 600, doneAt: now - 30)
            claude(engine, labOlder, profile: ".claude-lab", project: "store-assets", at: now - 3_000, doneAt: now - 2_000)
            claude(engine, alt, profile: ".claude-alt", project: "scratch", at: now - 120)
            claude(engine, elsewhere, profile: ".claude-elsewhere", project: "elsewhere", at: now - 60)
            engine.loadPreviewEvents(FixtureSessionFeed.start(codex, title: "Resize the store images", project: "store-assets",
                                                              prompt: "resize the store images", tool: .codex, at: now - 400,
                                                              transcript: folder(".codex-team/sessions/2026/09/24/rollout-inuse.jsonl")))
        }
        // The profiles once every session is in: each is tagged with its account from its transcript's folder.
        engine.setProfiles(accounts: accounts, discovered: [])
        return engine
    }

    static func env(now: Date = DemoClock.now, sessions: Bool = true, settings: AppSettings = .ephemeral()) -> AppEnvironment {
        env(engine(now: now, sessions: sessions), now: now, settings: settings)
    }

    static func env(_ engine: SessionEngine, now: Date = DemoClock.now, settings: AppSettings = .ephemeral()) -> AppEnvironment {
        AppEnvironment(settings: settings, usage: DemoUsageModel(now: now), sessions: EngineSessionsModel(engine: engine, clock: { now }))
    }

    static func engine(of env: AppEnvironment) throws -> SessionEngine {
        try #require((env.sessions as? EngineSessionsModel)?.engine)
    }
}

@MainActor
struct AccountsInUseTests {
    typealias F = InUseFixtures

    // MARK: P810 Which accounts are in use

    @Test
    func aSessionsRowNamesItsAccountsFolder() throws {
        let env = F.env()
        let work = try #require(env.sessions.row(id: F.work)?.account)
        #expect(work.provider == .claude && LimitAlternative.same(work.folder, "~/.claude-work"))
        #expect(env.sessions.row(id: F.codex)?.account?.provider == .codex)
        // A folder that is no account's is never guessed.
        #expect(env.sessions.row(id: F.elsewhere)?.account == nil)
    }

    @Test
    func theAccountsInUseAreTheLiveSessionsFirstThenTheMostRecent() {
        let env = F.env()
        let inUse = env.accountsInUseNow
        // Work runs; Lab finished most recently of all, so it comes after Work. Lab's two sessions are one account.
        #expect(inUse.ids(.claude) == [F.workBattery, F.labBattery])
        #expect(inUse.ids(.codex) == [F.teamBattery])
        #expect(inUse.contains(F.labBattery) && !inUse.contains(F.mainBattery))
    }

    @Test
    func aFolderNoLoginHoldsIsNoAccountInUse() {
        let env = F.env()
        let inUse = env.accountsInUseNow
        // Alt is tagged (an account folder) but no login holds it (no email named); the other folder is no account's.
        #expect(!inUse.contains(F.battery(.claude, "~/.claude-alt")))
        #expect(inUse.ids(.claude).count == 2)
        // Only the logins the batteries draw: Alt alone gives nothing.
        let alt = SessionRow.inUseRow("a", account: RowAccount(provider: .claude, folder: F.folder(".claude-alt")))
        #expect(AccountsInUse.make(rows: [alt], logins: env.usage.logins, panel: env.usage.panel).isEmpty)
    }

    @Test
    func noSessionsNoAccountInUse() {
        let env = F.env(sessions: false)
        #expect(env.sessions.rows.isEmpty && env.accountsInUseNow == .none)
    }

    @Test
    func aLiveSessionComesBeforeAMoreRecentFinishedOne() {
        let env = F.env()
        let work = RowAccount(provider: .claude, folder: F.folder(".claude-work"))
        let lab = RowAccount(provider: .claude, folder: F.folder(".claude-lab"))
        let main = RowAccount(provider: .claude, folder: F.folder(".claude"))
        let rows = [
            SessionRow.inUseRow("done-new", account: lab, bucket: .done, at: DemoClock.now - 10),
            SessionRow.inUseRow("done-old", account: main, bucket: .done, at: DemoClock.now - 900),
            SessionRow.inUseRow("waits", account: work, bucket: .needsYou, at: DemoClock.now - 600),
        ]
        let inUse = AccountsInUse.make(rows: rows, logins: env.usage.logins, panel: env.usage.panel)
        #expect(inUse.ids(.claude) == [F.workBattery, F.labBattery, F.mainBattery])
    }

    /// With none live, the newest finished session decides (P810): two logins, each with finished sessions.
    @Test
    func withNoneLiveTheNewestFinishedSessionDecides() throws {
        let now = DemoClock.now
        let engine = SessionEngine.preview(clock: { now })
        F.claude(engine, "work-done", profile: ".claude-work", project: "notes-site", at: now - 900, doneAt: now - 600)
        F.claude(engine, "lab-done", profile: ".claude-lab", project: "juice-tools", at: now - 500, doneAt: now - 40)
        F.claude(engine, "work-older", profile: ".claude-work", project: "store-assets", at: now - 4_000, doneAt: now - 3_000)
        engine.setProfiles(accounts: F.accounts, discovered: [])
        let env = F.env(engine)
        #expect(env.sessions.rows.count == 3 && env.sessions.rows.allSatisfy { $0.bucket == .done })
        let inUse = env.accountsInUseNow
        #expect(inUse.ids(.claude) == [F.labBattery, F.workBattery] && inUse.ids(.codex).isEmpty)
        #expect(HeaderStripPair.battery(try #require(env.usage.claudeRow), inUse: inUse, first: .inUse)?.id == F.labBattery)
    }

    /// A profile folder kept as a symlink (dotfiles, a synced folder): the engine tags the session with the folder the
    /// link resolves to while the login holds the link, and the folder's account id still names the login, for the
    /// accounts in use and for Open in's other account alike (P810, P704).
    @Test
    func aSymlinkedProfileFolderStillNamesItsLogin() throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent("inuse-link-" + UUID().uuidString)
        defer { try? files.removeItem(at: base) }
        let real = base.appendingPathComponent("real-claude"), link = base.appendingPathComponent("link-claude")
        try files.createDirectory(at: real.appendingPathComponent("projects/demo"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: link, withDestinationURL: real)
        // An empty file where the transcript would be: the engine resolves the link through what exists.
        #expect(files.createFile(atPath: real.path + "/projects/demo/linked.jsonl", contents: nil))
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        F.claude(engine, "linked", transcript: link.path + "/projects/demo/linked.jsonl", project: "demo", at: DemoClock.now - 60)
        engine.setProfiles(accounts: [Account(provider: .claude, folder: link.path, alias: "link")], discovered: [])
        let model = EngineSessionsModel(engine: engine, clock: { DemoClock.now })
        let account = try #require(model.row(id: "linked")?.account)
        // The engine's folder is the link's target, which the login's folder does not spell.
        #expect(!LimitAlternative.same(account.folder, link.path))

        let own = LimitWarningTests.login("own", .available(percentLeft: 20, isLow: false), folder: link.path)
        let two = LimitWarningTests.login("two", .available(percentLeft: 40, isLow: false), folder: base.appendingPathComponent("two").path)
        let logins = [ProviderLogins(provider: .claude, logins: [own, two], folders: [])]
        let batteries = [own.battery, two.battery]
        let panel = PanelModel(rows: [ProviderRowModel(provider: .claude, batteries: batteries,
                                                       availability: Rules.availability(states: batteries.map(\.state)),
                                                       nextAlias: nil, oldestReadingAge: nil, hoverLabel: "")],
                               money: [], attentionNeeded: false)
        #expect(AccountsInUse.make(rows: model.rows, logins: logins, panel: panel).ids(.claude) == ["own"])
        // Open in's other account: the row's limit carries the same tag.
        let tag = try #require(engine.accountTag(for: "linked"))
        let limit = RowLimit(SessionLimit(kind: .usageLimit, resetsAt: DemoClock.now + 600), provider: tag.provider, folder: tag.folder,
                             accountID: tag.accountID, now: DemoClock.now)
        #expect(LimitAlternative.best(for: limit, logins: logins)?.loginID == "two")
    }

    // MARK: P812 The strip, the block and U

    @Test
    func theStripShowsTheAccountInUseElseNext() throws {
        let env = F.env()
        let inUse = env.accountsInUseNow
        let claude = try #require(env.usage.claudeRow), codex = try #require(env.usage.codexRow)
        #expect(HeaderStripPair.battery(claude, inUse: inUse, first: .inUse)?.id == F.workBattery)
        #expect(HeaderStripPair.battery(codex, inUse: inUse, first: .inUse)?.id == F.teamBattery)
        // Next, as it was: Main and Home, without their bars.
        #expect(HeaderStripPair.battery(claude, inUse: inUse, first: .next)?.id == F.mainBattery)
        #expect(HeaderStripPair.battery(codex, inUse: inUse, first: .next)?.id == F.homeBattery)
        #expect(HeaderStripPair.battery(claude, inUse: inUse, first: .inUse)?.isNext == false)
        // None in use: Next, whatever the setting.
        #expect(HeaderStripPair.battery(claude, inUse: .none, first: .inUse)?.id == F.mainBattery)
    }

    @Test
    func theBlockPutsTheAccountsInUseFirstThenTheRestAsTheyWere() throws {
        let env = F.env()
        let inUse = env.accountsInUseNow
        let claude = try #require(env.usage.claudeRow)
        let rest = claude.batteries.map(\.id).filter { $0 != F.workBattery && $0 != F.labBattery }
        #expect(inUse.arranged(claude, first: .inUse).batteries.map(\.id) == [F.workBattery, F.labBattery] + rest)
        #expect(inUse.arranged(claude, first: .next) == claude)
        #expect(AccountsInUse.none.arranged(claude, first: .inUse) == claude)
        // U steps through them as the block draws them (P461).
        let order = UsageCycle.order(env.usage, inUse: inUse, first: .inUse)
        #expect(Array(order.prefix(2)) == [F.workBattery, F.labBattery])
        #expect(order.contains(F.teamBattery) && order.firstIndex(of: F.teamBattery) == claude.batteries.count)
        #expect(UsageCycle.order(env.usage) == [env.usage.claudeRow, env.usage.codexRow].compactMap { $0 }.flatMap { $0.batteries.map(\.id) })
    }

    /// The island takes them at a fresh open only: never while it shows, nor at a reverse of its close; with usage
    /// hidden it makes none.
    @Test
    func theIslandTakesThemAtAFreshOpenOnly() throws {
        let env = F.env()
        let ui = IslandUIState()
        ui.opens(reverse: false, env: env)
        #expect(ui.inUse == env.accountsInUseNow && ui.inUse.ids(.claude) == [F.workBattery, F.labBattery])
        // A session in Main starts while the island shows: a reverse keeps what is in sight, the next fresh open takes it.
        F.claude(try F.engine(of: env), "inuse-main", profile: ".claude", project: "third", at: DemoClock.now - 10)
        ui.opens(reverse: true, env: env)
        #expect(!ui.inUse.contains(F.mainBattery))
        ui.opens(reverse: false, env: env)
        #expect(ui.inUse.ids(.claude) == [F.mainBattery, F.workBattery, F.labBattery])
        env.settings.islandShowsUsage = false
        ui.opens(reverse: false, env: env)
        #expect(ui.inUse == .none)
    }

    /// The island's open makes the call, before the director's open, while nothing of the island shows (P812).
    @Test
    func theIslandsOpenTakesThem() throws {
        let source = try String(contentsOf: RenderHarness.root.appendingPathComponent("App/Island/IslandPanelController.swift"), encoding: .utf8)
        let open = try #require(source.range(of: "case let .open(reason):"))
        let send = try #require(source.range(of: "director?.send(.open(", range: open.upperBound..<source.endIndex))
        #expect(source[open.upperBound..<send.lowerBound].contains("ui.opens(reverse: resetPending, env: env)"))
    }

    // MARK: P813 The setting

    @Test
    func usageShowsFirstIsInUseByDefaultAndStored() throws {
        #expect(AppSettings.ephemeral().usageFirst == .inUse)
        let suite = "inuse-settings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, identity: .development)
        #expect(settings.usageFirst == .inUse)
        settings.usageFirst = .next
        #expect(defaults.string(forKey: AppSettings.Key.usageFirst) == "next")
        #expect(AppSettings(defaults: defaults, identity: .development).usageFirst == .next)
        defaults.set("sideways", forKey: AppSettings.Key.usageFirst)
        #expect(AppSettings(defaults: defaults, identity: .development).usageFirst == .inUse)
    }

    // MARK: P814, P815 The panel and the widget

    @Test
    func thePanelKeepsItsOrderAndFollowsTheAccountsInUse() async throws {
        let env = F.env()
        env.watchAccountsInUse(true)
        defer { env.watchAccountsInUse(false) }
        #expect(env.accountsInUse == env.accountsInUseNow)
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings, inUse: env.accountsInUse)
        #expect(content.rows == env.usage.panel.rows.filter { !$0.batteries.isEmpty })
        #expect(content.inUse.contains(F.workBattery) && content.inUse.contains(F.teamBattery))

        // A new session in an account already in use changes nothing the panel draws; one in Main adds Main.
        let redraws = Redraws()
        redraws.watch { _ = env.accountsInUse }
        let engine = try #require((env.sessions as? EngineSessionsModel)?.engine)
        F.claude(engine, "inuse-work-2", profile: ".claude-work", project: "second", at: DemoClock.now - 20)
        _ = env.sessions.rows
        try await Task.sleep(for: .milliseconds(50))
        #expect(redraws.count == 0)
        F.claude(engine, "inuse-main", profile: ".claude", project: "third", at: DemoClock.now - 10)
        _ = env.sessions.rows
        try await Task.sleep(for: .milliseconds(50))
        #expect(redraws.count == 1 && env.accountsInUse.contains(F.mainBattery))
    }

    /// The panel body's first read follows the accounts in use alone: it makes nothing that adds the rows to what the
    /// body follows, so a row's new status word never redraws it (P814). The watch is started outside it.
    @Test
    func thePanelsFirstReadFollowsNothingElse() async throws {
        let env = F.env()
        let redraws = Redraws()
        redraws.watch { _ = env.accountsInUse }
        #expect(env.accountsInUse == .none && !env.inUseWatch.isRunning)
        F.claude(try F.engine(of: env), "inuse-work-2", profile: ".claude-work", project: "second", at: DemoClock.now - 20)
        _ = env.sessions.rows
        try await Task.sleep(for: .milliseconds(50))
        #expect(redraws.count == 0)
    }

    /// The panel's watch lives while the panel is on: switched off, the accounts in use are no longer made (P814).
    @Test
    func thePanelsWatchStopsWithThePanel() async throws {
        let env = F.env()
        let screen = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
        let surface = FakePanelSurface()
        let controller = DesktopPanelController(env: env, store: PanelPositionStore(defaults: nil), screens: { [screen] },
                                                makeSurface: { surface })
        defer { controller.stop() }
        controller.start(live: false)
        #expect(surface.isShown && env.inUseWatch.isRunning && env.accountsInUse.contains(F.workBattery))
        env.settings.panelShowOnDesktop = false
        for _ in 0..<20 where surface.isShown { await Task.yield() }
        #expect(!surface.isShown && !env.inUseWatch.isRunning)
        F.claude(try F.engine(of: env), "inuse-main", profile: ".claude", project: "third", at: DemoClock.now - 10)
        _ = env.sessions.rows
        try await Task.sleep(for: .milliseconds(50))
        #expect(!env.accountsInUse.contains(F.mainBattery))
        // On again: made afresh, Main included; the controller's stop ends it.
        env.settings.panelShowOnDesktop = true
        for _ in 0..<20 where !surface.isShown { await Task.yield() }
        #expect(env.inUseWatch.isRunning && env.accountsInUse.contains(F.mainBattery))
        controller.stop()
        #expect(!env.inUseWatch.isRunning)
    }

    @Test
    func theWidgetMarksTheAccountsInUseInThePanelsOrder() throws {
        let env = F.env()
        let snapshot = WidgetSnapshot.make(env, at: DemoClock.now)
        let claude = try #require(env.usage.claudeRow)
        #expect(snapshot.claude.count == claude.batteries.count)
        let marked = zip(claude.batteries, snapshot.claude).filter { $0.1.showsInUse }.map(\.0.id)
        #expect(marked == [F.workBattery, F.labBattery].sorted { a, b in
            claude.batteries.firstIndex { $0.id == a }! < claude.batteries.firstIndex { $0.id == b }!
        })
        #expect(snapshot.codex.filter(\.showsInUse).count == 1)
        // A battery not in use writes no key, and a file without it reads as not in use.
        let data = try JSONEncoder().encode(WidgetSnapshot.Battery(state: .unknown, isNext: false))
        #expect(!String(decoding: data, as: UTF8.self).contains("inUse"))
        let old = try JSONDecoder().decode(WidgetSnapshot.Battery.self, from: Data(#"{"state":{"unknown":{}},"isNext":true}"#.utf8))
        #expect(!old.showsInUse && old.isNext)
    }
}

extension SessionRow {
    /// A bare row in `account`, for the accounts in use.
    static func inUseRow(_ id: String, account: RowAccount?, bucket: SessionBucket = .running, at date: Date = DemoClock.now) -> SessionRow {
        SessionRow(id: id, agent: .claude, bucket: bucket, project: "demo", task: "A task", status: bucket == .done ? .done : .thinking,
                   detail: nil, lastPrompt: nil, host: nil, accountAlias: nil, updatedAt: date, isCodexApp: false,
                   glyph: .bang, glyphState: .waiting, hasCard: bucket == .needsYou,
                   account: account)
    }
}
