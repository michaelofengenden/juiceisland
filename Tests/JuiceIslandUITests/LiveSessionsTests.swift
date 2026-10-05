import Foundation
import JuiceCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Stands in for BridgeServer: no socket is opened.
private final class StubBridge: EngineBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var didStop = false
    var stopped: Bool { lock.withLock { didStop } }
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() { lock.withLock { didStop = true } }
}

/// The Live sessions switch over an engine whose bridge starter, owner probe and Open Island check are stand-ins:
/// no hook socket is probed or bound, and no runtime (discovery, monitoring) starts.
@MainActor
struct LiveSessionsTests {
    fileprivate final class Probe: @unchecked Sendable {
        var otherIsland = false
        /// The bridge's scratch path stands in for Open Island's own socket.
        var sharedSocket = false
        var ownedSockets = false
        var binds: [URL] = []
        var bridges: [StubBridge] = []
    }

    private func makeLive(_ probe: Probe, settings: AppSettings = .ephemeral(),
                          profiles: LiveProfiles = LiveProfiles(accounts: [], discovered: []),
                          identity: AppIdentity = .development) -> LiveSessions {
        LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            if probe.sharedSocket { configuration.openIslandSocketURL = configuration.socketURL }
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { probe.otherIsland }
            dependencies.socketHasOwner = { _ in probe.ownedSockets }
            dependencies.startBridge = { url in
                let bridge = StubBridge()
                probe.binds.append(url)
                probe.bridges.append(bridge)
                return bridge
            }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            // No osascript and no `open`: every runner step fails at once.
            var runner = JumpRunner()
            runner.appURL = { _ in nil }
            runner.isAppRunning = { _ in false }
            runner.appleScript = { _, _ in throw CocoaError(.featureUnsupported) }
            runner.open = { _, _ in throw CocoaError(.featureUnsupported) }
            runner.command = { _, _, _ in false }
            dependencies.jumpRunner = runner
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { profiles }, identity: identity)
    }

    /// P112: a hook socket another app took after the start. The production app, silent while live, says "Hooks busy"
    /// with the reason in its help and in Diagnostics' Bridge row; once the socket is back, nothing again.
    @Test
    func aSocketAnotherAppTookShowsAsHooksBusy() throws {
        let probe = Probe()
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        let live = makeLive(probe, settings: settings, identity: .production)
        live.apply()
        let engine = try #require(live.engine)
        #expect(live.mode == .live && live.hooksReachApp && live.badge == nil && live.hooksProblem == nil)

        engine.bridgeHealth = .taken
        #expect(!live.hooksReachApp && live.badge == "Hooks busy" && live.shortRefusal == "Hooks busy")
        #expect(live.hooksProblem == LiveSessions.takenText)
        #expect(DiagnosticsText.bridge(switchOn: true, live: true, refusal: nil, health: engine.bridgeHealth, takenBackAt: nil,
                                       notesProblem: nil, now: DemoClock.now)
                == "Another app took the hook socket · waiting for it to quit")

        engine.bridgeHealth = .live(sockets: 2)
        #expect(live.hooksReachApp && live.badge == nil)
        let development = makeLive(probe)
        development.settings.liveSessions = true
        development.apply()
        development.engine?.bridgeHealth = .taken
        #expect(development.badge == "Hooks busy")
    }

    @Test
    func offShowsTheDemoAndStartsNothing() {
        let probe = Probe()
        let live = makeLive(probe)
        live.activate()
        #expect(live.settings.liveSessions == false)
        #expect(live.mode == .demo)
        #expect(live.engine == nil)
        #expect(probe.binds.isEmpty)
        #expect(live.rows.map(\.id).contains(FixtureSessionFeed.ID.question))
    }

    @Test
    func onStartsTheBridgeWithProfilesAndClearsTheDemo() {
        let probe = Probe()
        let work = Account(provider: .claude, folder: "/tmp/juice-live-test/.claude-work", alias: "Work")
        let defaults = [DiscoveredProfile(provider: .claude, folder: "/tmp/juice-live-test/.claude", suggestedAlias: "Claude"),
                        DiscoveredProfile(provider: .codex, folder: "/tmp/juice-live-test/.codex", suggestedAlias: "Codex")]
        let live = makeLive(probe, profiles: LiveProfiles(accounts: [work], discovered: defaults))
        live.settings.liveSessions = true
        live.apply()
        #expect(probe.binds.count == 1)
        #expect(live.mode == .live)
        #expect(live.refusal == nil)
        #expect(live.demo == nil)
        #expect(live.rows.isEmpty)
        #expect(Set(live.engine?.profileTargets.map(\.alias) ?? []) == ["Work", "Claude", "Codex"])
        #expect(live.engine?.loadPreviewEvents([]) == false)
    }

    @Test
    func refusedWhileOpenIslandRunsAndTheSwitchGoesBackOff() {
        let probe = Probe()
        probe.otherIsland = true
        // On a socket of its own (the app's, P900) Open Island running holds nothing back.
        let own = makeLive(probe)
        own.settings.liveSessions = true
        own.apply()
        #expect(own.refusal == nil && own.mode == .live && probe.binds.count == 1)
        own.settings.liveSessions = false
        own.apply()
        probe.binds = []

        // On Open Island's own socket it still does.
        probe.sharedSocket = true
        let live = makeLive(probe)
        live.settings.liveSessions = true
        live.apply()
        #expect(live.refusal == "Open Island is running — quit it to see live sessions")
        #expect(live.settings.liveSessions == false)
        #expect(live.mode == .demo)
        #expect(probe.binds.isEmpty)
        #expect(live.rows.map(\.id).contains(FixtureSessionFeed.ID.question))
    }

    @Test
    func refusedWhileAHookSocketHasAnOwner() {
        let probe = Probe()
        probe.ownedSockets = true
        let live = makeLive(probe)
        live.settings.liveSessions = true
        live.apply()
        #expect(live.refusal == "Another app is using the hook connection")
        #expect(live.settings.liveSessions == false)
        #expect(probe.binds.isEmpty)

        // The next try clears the line.
        probe.ownedSockets = false
        live.settings.liveSessions = true
        live.apply()
        #expect(live.refusal == nil)
        #expect(live.mode == .live)
    }

    @Test
    func offAgainStopsTheBridgeAndBringsTheDemoBack() {
        let probe = Probe()
        let live = makeLive(probe)
        live.settings.liveSessions = true
        live.apply()
        let engine = live.engine
        live.settings.liveSessions = false
        live.apply()
        #expect(probe.bridges.first?.stopped == true)
        #expect(live.mode == .demo)
        #expect(live.rows.map(\.id).contains(FixtureSessionFeed.ID.question))

        // On again: the same engine (one process monitor), a new bridge.
        live.settings.liveSessions = true
        live.apply()
        #expect(live.engine === engine)
        #expect(probe.binds.count == 2)
        #expect(live.rows.isEmpty)
    }

    @Test
    func aClickJumpsOnlyInLiveMode() async {
        let probe = Probe()
        let live = makeLive(probe)
        live.activate()
        live.jump(FixtureSessionFeed.ID.question)
        #expect(live.jumpNote?.text == "Demo session")

        live.settings.liveSessions = true
        live.apply()
        #expect(live.jumpNote == nil)
        live.jump("s1")
        for _ in 0..<200 where live.jumpNote == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(live.engine?.recentJumps.map(\.sessionID) == ["s1"])
        #expect(live.jumpNote == JumpNote(id: live.jumpNote?.id ?? UUID(), sessionID: "s1", text: "No terminal known for this session yet"))
    }

    @Test
    func quittingStopsTheBridgeAndKeepsTheSetting() {
        let probe = Probe()
        let live = makeLive(probe)
        live.settings.liveSessions = true
        live.apply()
        live.shutdown()
        #expect(probe.bridges.first?.stopped == true)
        #expect(live.settings.liveSessions)
    }

    /// Juice's accounts file is only read; the default folders count even without it. Fictional folders, temp files.
    @Test
    func profilesComeFromJuicesAccountsFilePlusTheDefaults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("accounts.json")
        let store = AccountsStore(fileURL: file)
        store.add(Account(provider: .codex, folder: "/tmp/juice-live-test/.codex-side", alias: "Side"))
        try store.save()
        let saved = try Data(contentsOf: file)

        let profiles = LiveProfiles.load(accountsFile: file, home: "/tmp/juice-live-test")
        #expect(profiles.accounts.map(\.alias) == ["Side"])
        #expect(profiles.discovered.map(\.folder) == ["/tmp/juice-live-test/.claude", "/tmp/juice-live-test/.codex"])
        #expect(try Data(contentsOf: file) == saved)

        let missing = LiveProfiles.load(accountsFile: folder.appendingPathComponent("none.json"), home: "/tmp/juice-live-test")
        #expect(missing.accounts.isEmpty)
        #expect(missing.discovered.count == 2)
    }
}
