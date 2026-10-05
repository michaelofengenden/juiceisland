import Foundation
import JuiceCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Step 2 of the owner's plan: Live sessions on by default in the production app, Setup over the real hook manager,
/// drift rows, and tags in every profile. Temporary folders with the fixture names only; no hook socket is probed or
/// bound, no real profile, helper or hook config is read or written.
@MainActor
struct HooksSetupUITests {
    // MARK: Identity

    @Test
    func liveSessionsIsOnByDefaultOnlyInTheProductionApp() throws {
        #expect(AppIdentity(bundleIdentifier: "com.ofengenden.juice") == .production)
        #expect(AppIdentity(bundleIdentifier: "com.ofengenden.juice.dev") == .development)
        #expect(AppIdentity(bundleIdentifier: nil) == .other)
        #expect(AppIdentity.current == .other)

        let name = "ji.test.identity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppSettings(defaults: defaults, identity: .production).liveSessions)
        #expect(!AppSettings(defaults: defaults, identity: .development).liveSessions)
        #expect(!AppSettings.ephemeral().liveSessions)
        // The owner's own choice wins over either default.
        AppSettings(defaults: defaults, identity: .production).liveSessions = false
        #expect(!AppSettings(defaults: defaults, identity: .production).liveSessions)
        AppSettings(defaults: defaults, identity: .development).liveSessions = true
        #expect(AppSettings(defaults: defaults, identity: .development).liveSessions)
    }

    // MARK: Live sessions in the production app

    private final class StubBridge: EngineBridge, @unchecked Sendable {
        func updateStateSnapshot(_ snapshot: SessionState) {}
        func stop() {}
    }

    private final class Probe: @unchecked Sendable {
        var otherIsland = false
        /// The bridge's scratch path stands in for Open Island's own socket.
        var sharedSocket = false
        var ownedSockets = false
        var binds = 0
    }

    private func makeLive(_ probe: Probe, identity: AppIdentity, settings: AppSettings,
                          profiles: LiveProfiles = LiveProfiles(accounts: [], discovered: [])) -> LiveSessions {
        LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            if probe.sharedSocket { configuration.openIslandSocketURL = configuration.socketURL }
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { probe.otherIsland }
            dependencies.socketHasOwner = { _ in probe.ownedSockets }
            dependencies.startBridge = { _ in
                probe.binds += 1
                return StubBridge()
            }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { profiles }, identity: identity)
    }

    @Test
    func theProductionAppGoesLiveAtLaunchAndShowsNoDemo() {
        let probe = Probe()
        let name = "ji.test.prod.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let live = makeLive(probe, identity: .production, settings: AppSettings(defaults: defaults, identity: .production))
        #expect(live.demo == nil)
        #expect(live.rows.isEmpty)
        live.apply()
        #expect(live.mode == .live)
        #expect(probe.binds == 1)
        #expect(live.shortRefusal == nil)
        // Live is the production app's normal state: no badge says so.
        #expect(live.badge == nil)

        // Off: nothing, not the demo.
        live.settings.liveSessions = false
        live.apply()
        #expect(live.mode == .demo)
        #expect(live.demo == nil)
        #expect(live.rows.isEmpty)
        #expect(live.badge == nil)
    }

    @Test
    func theProductionAppKeepsTheSwitchOnWhileOpenIslandRunsAndTriesAgain() {
        let probe = Probe()
        probe.otherIsland = true
        // The app's own socket (P900): live beside Open Island.
        let own = makeLive(probe, identity: .production, settings: AppSettings(defaults: nil, identity: .production))
        own.apply()
        #expect(own.mode == .live && own.badge == nil && probe.binds == 1)
        probe.binds = 0

        // A bridge on Open Island's own socket keeps the switch on and tries again.
        probe.sharedSocket = true
        let settings = AppSettings(defaults: nil, identity: .production)
        #expect(settings.liveSessions)
        let live = makeLive(probe, identity: .production, settings: settings)
        live.apply()
        #expect(live.mode == .demo)
        #expect(live.settings.liveSessions)
        #expect(live.refusal == "Open Island is running — quit it to see live sessions")
        #expect(live.shortRefusal == "Open Island running")
        #expect(live.badge == "Open Island running")
        #expect(live.rows.isEmpty)
        #expect(probe.binds == 0)

        // Still running: the retry is refused again, and binds nothing.
        live.retry()
        #expect(probe.binds == 0)
        #expect(live.shortRefusal == "Open Island running")

        // Open Island quit: the next retry goes live.
        probe.otherIsland = false
        live.retry()
        #expect(live.mode == .live)
        #expect(live.refusal == nil)
        #expect(probe.binds == 1)
        live.retry()
        #expect(probe.binds == 1)
    }

    @Test
    func aBusySocketReadsInTwoWordsAndADevelopmentBuildStillTurnsTheSwitchOff() {
        let probe = Probe()
        probe.ownedSockets = true
        let production = makeLive(probe, identity: .production, settings: AppSettings(defaults: nil, identity: .production))
        production.apply()
        #expect(production.shortRefusal == "Hooks busy")
        #expect(production.settings.liveSessions)

        let development = makeLive(probe, identity: .development, settings: AppSettings.ephemeral())
        #expect(development.badge == "Demo")
        development.settings.liveSessions = true
        development.apply()
        #expect(!development.settings.liveSessions)
        #expect(development.refusal == "Another app is using the hook connection")
        // A retry does nothing once the switch is off.
        probe.ownedSockets = false
        development.retry()
        #expect(development.mode == .demo)
        #expect(probe.binds == 0)
    }

    // MARK: Profiles and account tags

    nonisolated static func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: ProfileHookTargets.normalized(
            FileManager.default.temporaryDirectory.appendingPathComponent("ji-home-\(UUID().uuidString)").path))
        for (name, file) in [(".claude", ".claude.json"), (".claude-work", ".claude.json"), (".claude-lab", ".claude.json"),
                             (".codex", "config.toml"), (".codex-side", "config.toml"), (".codex-fresh", "auth.json")] {
            let folder = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent(file))
        }
        return home
    }

    @Test
    func everyProfileInTheHomeFolderCountsAndTagsItsSessions() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accountsFile = home.appendingPathComponent("accounts.json")
        let store = AccountsStore(fileURL: accountsFile)
        store.add(Account(provider: .claude, folder: home.path + "/.claude-work", alias: "Work"))
        try store.save()

        let profiles = LiveProfiles.load(accountsFile: accountsFile, home: home.path)
        #expect(profiles.accounts.map(\.alias) == ["Work"])
        #expect(profiles.discovered.map(\.suggestedAlias) == ["Claude", "Codex", "lab", "work", "fresh", "side"])
        let targets = ProfileHookTargets.make(accounts: profiles.accounts, discovered: profiles.discovered, home: home.path)
        #expect(targets.map(\.alias) == ["Claude", "Work", "lab", "Codex", "fresh", "side"])

        // A Codex session in a discovered-only home carries that home's alias.
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        engine.setProfiles(accounts: profiles.accounts, discovered: profiles.discovered)
        let transcript = home.path + "/.codex-side/sessions/2026/09/24/rollout-x.jsonl"
        engine.loadPreviewEvents([
            .sessionStarted(SessionStarted(sessionID: "side-1", title: "t", tool: .codex, origin: .live, initialPhase: .running,
                                           summary: "Started.", timestamp: DemoClock.now,
                                           codexMetadata: CodexSessionMetadata(transcriptPath: transcript, lastUserPrompt: "go"))),
            .activityUpdated(SessionActivityUpdated(sessionID: "side-1", summary: "Prompt: go", phase: .running, timestamp: DemoClock.now)),
        ])
        #expect(engine.accountTag(for: "side-1")?.alias == "side")
        let model = EngineSessionsModel(engine: engine, clock: { DemoClock.now })
        #expect(model.rows.first { $0.id == "side-1" }?.accountAlias == "side")
    }

    @Test
    func theDirectoryTellsOthersOnlyWhenTheListChanges() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var scheduled: [@MainActor @Sendable () -> Void] = []
        let directory = ProfileDirectory(load: { LiveProfiles.load(accountsFile: home.appendingPathComponent("none.json"), home: home.path) },
                                         home: home.path, schedule: { _, work in scheduled.append(work) })
        var told: [[String]] = []
        directory.onChange.append { targets in told.append(targets.map(\.alias)) }
        #expect(directory.current.discovered.count == 6)
        #expect(told.isEmpty)

        directory.folderChanged()
        directory.folderChanged()
        for work in scheduled { work() }
        await directory.reloading?.value
        #expect(told.isEmpty)

        let folder = home.appendingPathComponent(".codex-preset")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("config.toml"))
        scheduled = []
        directory.folderChanged()
        for work in scheduled { work() }
        await directory.reloading?.value
        #expect(told == [["Claude", "lab", "work", "Codex", "fresh", "preset", "side"]])
    }

    /// P119: a change in the home folder that is not a profile folder (every Claude session rewrites `~/.claude.json`
    /// there) reloads off the main thread and changes nothing on it: the list held stays the same value, and no one is
    /// told. A profile folder made in a folder that was not one yet (its `.claude.json` appeared) is found by the next
    /// change.
    @Test
    func aHomeFolderChangeOutsideTheProfilesChangesNothing() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var scheduled: [@MainActor @Sendable () -> Void] = []
        let loads = LockedBox<[Bool]>([])                              // one entry per load: whether it ran off main
        let directory = ProfileDirectory(load: {
            loads.withValue { $0.append(!Thread.isMainThread) }
            return LiveProfiles.load(accountsFile: home.appendingPathComponent("none.json"), home: home.path)
        }, home: home.path, schedule: { _, work in scheduled.append(work) })
        var told: [[String]] = []
        directory.onChange.append { targets in told.append(targets.map(\.alias)) }
        directory.activate()
        let before = directory.targets
        loads.withValue { $0 = [] }

        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-next"), withIntermediateDirectories: true)
        directory.folderChanged()
        for work in scheduled { work() }
        await directory.reloading?.value
        #expect(loads.withValue { $0 } == [true])
        #expect(told.isEmpty && directory.targets == before)

        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude-next/.claude.json"))
        scheduled = []
        directory.folderChanged()
        for work in scheduled { work() }
        await directory.reloading?.value
        #expect(told == [["Claude", "lab", "next", "work", "Codex", "fresh", "side"]])
    }

    // MARK: Words

    @Test
    func everyStateReadsInAWordOrTwo() {
        let words = [ProfileHookStatus.State.installed, .notInstalled, .partial(installed: 13, expected: 14),
                     .partial(installed: 3, expected: 4), .codexFeatureOff, .codexNeedsTrust(untrustedEvents: ["Stop"]),
                     .blockedByOtherIsland(vibeEntries: 14), .broken([.binaryNotFound]), .linkedConfig(file: "settings.json"),
                     .hasComments(file: "hooks.json"), .unreadable(file: "config.toml"), .folderMissing].map(HookRowText.word(for:))
        #expect(words == ["Installed", "Not installed", "Partial 13/14", "Partial 3/4", "Hooks off", "Needs /hooks",
                          "Vibe Island hooks", "Broken", "Linked file", "Has comments", "Unreadable", "Folder missing"])
        #expect(HookRowText.detail(for: .codexNeedsTrust(untrustedEvents: ["Stop"]), missing: []) == "Run /hooks once in Codex here")
        #expect(HookRowText.detail(for: .partial(installed: 12, expected: 14), missing: [
            HookEntrySpec(event: "Notification", matcher: "*", timeout: nil), HookEntrySpec(event: "PreCompact", matcher: nil, timeout: nil),
        ]) == "Missing Notification, PreCompact")
        #expect(HookRowText.detail(for: .broken([.binaryNotFound]), missing: []) == "Helper missing")
        #expect(HookRowText.detail(for: .installed, missing: []) == nil)

        let refusals = [ProfileHookRefusal.openIslandRunning, .folderMissing, .linkedConfig(file: "settings.json"),
                        .hasComments(file: "hooks.json"), .unreadable(file: "config.toml"), .otherIslandHooks(count: 14),
                        .helperMissing, .writeFailed].map(HookRowText.refusal)
        #expect(refusals == ["Quit Open Island first", "Folder missing", "Edit settings.json by hand",
                             "Edit hooks.json by hand", "Can't read config.toml", "Remove Vibe Island first",
                             "No helper in this build", "Couldn't write the hooks"])
        #expect(refusals.allSatisfy { $0.split(separator: " ").count <= 5 })

        #expect(HookRowText.folder("/tmp/ji-home/.claude-work", home: "/tmp/ji-home") == "~/.claude-work")
        #expect(HookRowText.folder("/elsewhere/.codex-side", home: "/tmp/ji-home") == "/elsewhere/.codex-side")
        #expect(HookRowText.integrationsLine(HookIntegrations(openIslandRunning: true, vibeProfiles: 2, helperInBuild: false))
                == "No helper in this build · Open Island running · Vibe Island hooks in 2 profiles")
    }

    // MARK: Setup over the real manager

    final class Sandbox {
        let home: URL
        let helper: URL
        let managed: URL
        let defaults: UserDefaults
        private let suite = "ji.test.hooks.\(UUID().uuidString)"

        init(helper withHelper: Bool = true) throws {
            home = try HooksSetupUITests.makeHome()
            helper = home.appendingPathComponent("App.app/Contents/Helpers/OpenIslandHooks")
            managed = home.appendingPathComponent("support/bin/OpenIslandHooks")
            if withHelper {
                try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            }
            defaults = UserDefaults(suiteName: suite)!
        }

        deinit {
            try? FileManager.default.removeItem(at: home)
            defaults.removePersistentDomain(forName: suite)
        }

        func write(_ folder: String, _ file: String, _ text: String) throws {
            try Data(text.utf8).write(to: home.appendingPathComponent(folder).appendingPathComponent(file))
        }

        func read(_ folder: String, _ file: String) -> Data? {
            try? Data(contentsOf: home.appendingPathComponent(folder).appendingPathComponent(file))
        }

        /// Names and bytes of every file in the home folder: proof nothing was written.
        func snapshot() -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(atPath: home.path)
            while let relative = enumerator?.nextObject() as? String {
                result[relative] = (try? Data(contentsOf: home.appendingPathComponent(relative))) ?? Data()
            }
            return result
        }

        /// The drift monitor's clock; tests move it past the 2 s quiet period by hand.
        final class Clock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
        }
        let clock = Clock()

        @MainActor
        func hooks(openIslandRunning: Bool = false, watches: HookDriftMonitor.Watch? = nil,
                   schedule: HookDriftMonitor.Schedule? = nil) -> ProfileHooks {
            let manager = ProfileHookManager(bundledHelperURL: helper, managedHelperURL: managed,
                                             intents: ProfileHookIntentStore(defaults: defaults), codexFeatureKey: { .current },
                                             isOpenIslandAppRunning: { openIslandRunning })
            let home = self.home
            let directory = ProfileDirectory(load: { LiveProfiles.load(accountsFile: home.appendingPathComponent("none.json"), home: home.path) },
                                             home: home.path)
            let clock = self.clock
            return ProfileHooks(manager: manager, directory: directory, home: home.path, watch: watches ?? { _, _ in nil },
                                schedule: schedule ?? { _, _ in }, now: { clock.now }, isOpenIslandRunning: { openIslandRunning })
        }
    }

    private func settle(_ hooks: ProfileHooks, until done: () -> Bool) async {
        for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Launch reads every profile and writes nothing: no install, no repair, no helper, whatever the states.
    @Test
    func launchReadsEveryProfileAndInstallsNothing() async throws {
        let box = try Sandbox()
        let vibe = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"}]}]}}"#
        try box.write(".claude", "settings.json", vibe)
        try box.write(".codex-side", "hooks.json", "{ // mine\n \"hooks\": {} }")
        let before = box.snapshot()
        let hooks = box.hooks()
        hooks.activate()
        await settle(hooks) { hooks.rows.allSatisfy { $0.word != "…" } && hooks.rows.count == 6 }

        let rows = Dictionary(uniqueKeysWithValues: hooks.rows.map { ($0.alias, $0) })
        #expect(hooks.rows.map(\.alias) == ["Claude", "lab", "work", "Codex", "fresh", "side"])
        #expect(rows["Claude"]?.word == "Vibe Island hooks")
        #expect(rows["Claude"]?.refusal == "Remove Vibe Island first")
        #expect(rows["Claude"]?.canClick == false)
        #expect(rows["work"]?.word == "Not installed")
        #expect(rows["work"]?.buttonTitle == "Install")
        #expect(rows["work"]?.canClick == true)
        #expect(rows["work"]?.folder == "~/.claude-work")
        #expect(rows["work"]?.events == "0/14")
        #expect(rows["fresh"]?.events == "0/4")
        #expect(rows["side"]?.word == "Has comments")
        #expect(rows["side"]?.refusal == "Edit hooks.json by hand")
        #expect(hooks.integrations == HookIntegrations(openIslandRunning: false, vibeProfiles: 1, helperInBuild: true))
        #expect(hooks.alerts.isEmpty)
        #expect(hooks.monitor?.recentChecks.map(\.reason) == [.launch])
        await hooks.monitor?.wake()
        #expect(box.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: box.managed.path))
        hooks.stop()
    }

    @Test
    func aClickInstallsOneProfileAndARefusedClickSaysWhyAndWritesNothing() async throws {
        let box = try Sandbox()
        let vibe = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"}]}]}}"#
        try box.write(".claude", "settings.json", vibe)
        let hooks = box.hooks()
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        let work = try #require(hooks.rows.first { $0.alias == "work" })
        let claude = try #require(hooks.rows.first { $0.alias == "Claude" })
        let lab = box.read(".claude-lab", "settings.json")

        hooks.perform(.install, on: work.id)
        await settle(hooks) { hooks.rows.first { $0.alias == "work" }?.word == "Installed" }
        #expect(hooks.rows.first { $0.alias == "work" }?.buttonTitle == "Remove")
        #expect(box.read(".claude-work", "settings.json") != nil)
        #expect(box.read(".claude-lab", "settings.json") == lab)

        // A click the row already refuses: the manager's preflight refuses it too, and the file stays as it was.
        let before = box.snapshot()
        await hooks.run(.install, on: try #require(hooks.directory.targets.first { $0.id == claude.id }))
        #expect(hooks.clickRefusal(for: claude.id) == "Remove Vibe Island first")
        #expect(box.snapshot() == before)
    }

    @Test
    func installForAllMonitoredSkipsEveryRefusedProfile() async throws {
        let box = try Sandbox()
        let vibe = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"}]}]}}"#
        try box.write(".claude", "settings.json", vibe)
        try box.write(".codex-side", "hooks.json", "{ // mine\n \"hooks\": {} }")
        let untouched = [box.read(".claude", "settings.json"), box.read(".codex-side", "hooks.json")]
        let hooks = box.hooks()
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        // Discovered profiles are not monitored accounts: nothing to install for all.
        #expect(hooks.installableMonitoredRows.isEmpty)

        // The same homes as monitored accounts.
        let accounts = AccountsStore(fileURL: box.home.appendingPathComponent("accounts.json"))
        for (provider, name) in [(Provider.claude, ".claude"), (.claude, ".claude-work"), (.codex, ".codex-side"), (.codex, ".codex-fresh")] {
            accounts.add(Account(provider: provider, folder: box.home.path + "/" + name, alias: name))
        }
        try accounts.save()
        let manager = hooks.manager
        let home = box.home
        let directory = ProfileDirectory(load: { LiveProfiles.load(accountsFile: home.appendingPathComponent("accounts.json"), home: home.path) },
                                         home: home.path)
        let monitored = ProfileHooks(manager: manager, directory: directory, home: home.path)
        monitored.activate()
        await settle(monitored) { monitored.rows.allSatisfy { $0.word != "…" } && monitored.rows.count == 6 }
        #expect(Set(monitored.installableMonitoredRows.map(\.alias)) == [".claude-work", ".codex-fresh"])
        monitored.installAllMonitored()
        await settle(monitored) { monitored.installableMonitoredRows.isEmpty && monitored.rows.allSatisfy { !$0.busy } }
        let rows = Dictionary(uniqueKeysWithValues: monitored.rows.map { ($0.alias, $0) })
        #expect(rows[".claude-work"]?.word == "Installed")
        #expect(rows[".codex-fresh"]?.word == "Needs /hooks")
        #expect(rows["lab"]?.word == "Not installed")
        #expect([box.read(".claude", "settings.json"), box.read(".codex-side", "hooks.json")] == untouched)
    }

    /// P163: a managed helper older than this build's is offered as "Hook helper · Update" and replaced only on the
    /// click, by rename; no hook config changes. Nothing is offered with no helper installed, and a click while Open
    /// Island runs is refused with the reason.
    @Test
    func anOlderHelperIsReplacedOnlyOnTheUpdateClick() async throws {
        let box = try Sandbox()
        let hooks = box.hooks()
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        #expect(hooks.helperUpdate == nil)
        let work = try #require(hooks.rows.first { $0.alias == "work" })
        hooks.perform(.install, on: work.id)
        await settle(hooks) { hooks.rows.first { $0.id == work.id }?.word == "Installed" }
        #expect(hooks.helperUpdate == nil)
        // A newer build's helper: the installed one is now older.
        try Data("#!/bin/sh\n# newer\nexit 0\n".utf8).write(to: box.helper)
        await hooks.check(hooks.directory.targets, .wake)
        #expect(hooks.helperUpdate == .available)
        let configs = box.snapshot().filter { !$0.key.hasPrefix("support/") && !$0.key.hasPrefix("App.app/") }
        // Reading again never updates by itself.
        await hooks.check(hooks.directory.targets, .wake)
        #expect(try Data(contentsOf: box.managed) != Data(contentsOf: box.helper))

        hooks.updateHelper()
        #expect(hooks.helperUpdate == .updating)
        await settle(hooks) { hooks.helperUpdate == nil }
        #expect(try Data(contentsOf: box.managed) == Data(contentsOf: box.helper))
        #expect(box.snapshot().filter { !$0.key.hasPrefix("support/") && !$0.key.hasPrefix("App.app/") } == configs)

        // Open Island running holds the click back no more: the helper is Juice's own (P900).
        try Data("#!/bin/sh\n# newest\nexit 0\n".utf8).write(to: box.helper)
        let running = box.hooks(openIslandRunning: true)
        running.activate()
        await settle(running) { running.rows.count == 6 && running.rows.allSatisfy { $0.word != "…" } }
        await running.check(running.directory.targets, .wake)
        #expect(running.helperUpdate == .available)
        running.updateHelper()
        await settle(running) { running.helperUpdate == nil }
        #expect(try Data(contentsOf: box.managed) == Data(contentsOf: box.helper))
    }

    /// After a successful Update click the line reads "…" until every profile is read again, then goes: Update never
    /// comes back, enabled, in between, as if the one click the owner must make had failed.
    @Test
    func theUpdateNeverComesBackAfterASuccessfulClick() async throws {
        let box = try Sandbox()
        let hooks = box.hooks()
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        let work = try #require(hooks.rows.first { $0.alias == "work" })
        hooks.perform(.install, on: work.id)
        await settle(hooks) { hooks.rows.first { $0.id == work.id }?.word == "Installed" }
        try Data("#!/bin/sh\n# newer\nexit 0\n".utf8).write(to: box.helper)
        await hooks.check(hooks.directory.targets, .wake)
        #expect(hooks.helperUpdate == .available)
        hooks.updateHelper()
        var seen: [HelperUpdate?] = [hooks.helperUpdate]
        for _ in 0..<3000 {
            try? await Task.sleep(for: .milliseconds(1))
            let now = hooks.helperUpdate
            if seen.last.flatMap({ $0 }) != now { seen.append(now) }
            if now == nil { break }
        }
        #expect(seen.map { $0.map { "\($0)" } ?? "nil" } == ["updating", "nil"], "\(seen)")
        #expect(try Data(contentsOf: box.managed) == Data(contentsOf: box.helper))
    }

    /// The row is busy from the click on, before the install's task starts, so a second click (or Install for all)
    /// never runs a second install of the same profile beside the first.
    @Test
    func aRowIsBusyFromTheClickSoASecondClickDoesNothing() async throws {
        let box = try Sandbox()
        let hooks = box.hooks()
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        let work = try #require(hooks.rows.first { $0.alias == "work" })
        hooks.perform(.install, on: work.id)
        let clicked = try #require(hooks.rows.first { $0.id == work.id })
        #expect(clicked.busy && !clicked.canClick)
        hooks.perform(.install, on: work.id)
        await settle(hooks) { hooks.rows.first { $0.id == work.id }.map { !$0.busy && $0.word == "Installed" } ?? false }
        #expect(hooks.rows.first { $0.id == work.id }?.word == "Installed")
        // One install: upstream backs settings.json up before a write, so a second install would have left a backup.
        let names = try FileManager.default.contentsOfDirectory(atPath: box.home.appendingPathComponent(".claude-work").path)
        #expect(!names.contains { $0.hasPrefix("settings.json.backup.") })
    }

    /// Install for all installs; it never repairs. A drifted profile has its own Repair (P20: reinstalling moves a
    /// Codex home's trust keys, so the default ~/.codex is repaired only by its own click).
    @Test
    func installForAllOffersOnlyInstallsInMonitoredProfilesThatMayGoAhead() {
        final class Rows: HooksModel {
            let rows: [HookSetupRow]
            let alerts: [HookDriftAlert] = []
            let integrations = HookIntegrations(openIslandRunning: false, vibeProfiles: 0, helperInBuild: true)
            let lastEvents: [String: Date] = [:]
            init(_ rows: [HookSetupRow]) { self.rows = rows }
            func clickRefusal(for id: String) -> String? { nil }
            func perform(_ action: ProfileHookAction, on id: String) {}
            func installAllMonitored() {}
            func activate() {}
        }
        func row(_ id: String, _ action: ProfileHookAction?, refusal: String? = nil, busy: Bool = false, monitored: Bool = true) -> HookSetupRow {
            HookSetupRow(id: id, provider: .codex, alias: id, folder: "~/.codex-" + id, word: "", detail: nil, tone: .normal,
                         action: action, refusal: refusal, busy: busy, events: "", isMonitored: monitored)
        }
        let model = Rows([row("fresh", .install), row("side", .repair), row("preset", .install, refusal: "Edit hooks.json by hand"),
                          row("lab", .install, monitored: false), row("work", .install, busy: true), row("home", .remove)])
        #expect(model.installableMonitoredRows.map(\.id) == ["fresh"])
    }

    /// Drift from a file event: the row shows in the window's list 2 s after the last event, and Repair is a click.
    @Test
    func aFileEventRaisesTheDriftRowAndRepairIsAClick() async throws {
        let box = try Sandbox()
        var fire: [String: @MainActor @Sendable () -> Void] = [:]
        var pending: [@MainActor @Sendable () -> Void] = []
        let hooks = box.hooks(watches: { target, onChange in
            fire[target.alias] = onChange
            return nil
        }, schedule: { _, work in pending.append(work) })
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        let work = try #require(hooks.rows.first { $0.alias == "work" })
        hooks.perform(.install, on: work.id)
        await settle(hooks) { hooks.rows.first { $0.alias == "work" }?.word == "Installed" }

        // Someone drops our Stop entry.
        let url = box.home.appendingPathComponent(".claude-work/settings.json")
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(root["hooks"] as? [String: Any])
        entries["Stop"] = nil
        root["hooks"] = entries
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        let drifted = try Data(contentsOf: url)
        fire["work"]?()
        #expect(hooks.alerts.isEmpty)
        box.clock.now += 2
        for work in pending { work() }
        pending = []
        await settle(hooks) { !hooks.alerts.isEmpty }
        #expect(hooks.alerts.map(\.text) == ["Hooks missing in work · Repair"])
        let row = try #require(hooks.rows.first { $0.alias == "work" })
        #expect(row.word == "Partial 13/14")
        #expect(row.detail == "Missing Stop")
        #expect(row.buttonTitle == "Repair")
        // Nothing repaired it meanwhile.
        #expect(try Data(contentsOf: url) == drifted)

        hooks.perform(.repair, on: work.id)
        await settle(hooks) { hooks.alerts.isEmpty }
        #expect(hooks.rows.first { $0.alias == "work" }?.word == "Installed")
    }

    @Test
    func openIslandRunningHoldsNoButtonBackButNoHelperDoes() async throws {
        // Juice's hooks name its own helper (P900): Open Island running stops no click.
        let running = try Sandbox()
        let hooks = running.hooks(openIslandRunning: true)
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        #expect(hooks.rows.allSatisfy { $0.refusal == nil && $0.canClick })

        let bare = try Sandbox(helper: false)
        let noHelper = bare.hooks()
        noHelper.activate()
        await settle(noHelper) { noHelper.rows.count == 6 && noHelper.rows.allSatisfy { $0.word != "…" } }
        #expect(noHelper.rows.allSatisfy { $0.refusal == "No helper in this build" })
        #expect(!noHelper.integrations.helperInBuild)
    }

    /// A default folder that does not exist is no placeholder row.
    @Test
    func aMissingDefaultFolderIsNotListed() async throws {
        let box = try Sandbox()
        try FileManager.default.removeItem(at: box.home.appendingPathComponent(".codex"))
        let hooks = box.hooks()
        hooks.activate()
        await settle(hooks) { hooks.rows.count == 5 && hooks.rows.allSatisfy { $0.word != "…" } }
        #expect(!hooks.rows.contains { $0.alias == "Codex" })
    }
}
