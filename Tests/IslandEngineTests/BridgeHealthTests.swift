import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Stands in for BridgeServer: no socket is opened.
final class StandInBridge: EngineBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var didStop = false
    var stopped: Bool { lock.withLock { didStop } }
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() { lock.withLock { didStop = true } }
}

/// P112: the hook socket after the start, on a world of stand-ins: the files at the socket paths (`socketIdentity`),
/// who listens there (`socketHasOwner`), whether Open Island runs, and a bridge that "binds" by putting new files at
/// its paths. No socket is probed, bound or watched.
@MainActor
struct BridgeHealthTests {
    typealias Box = EngineFixtures.Box

    final class World: Sendable {
        let files = Box<[String: SocketIdentity]>([:])
        let owners = Box<Set<String>>([])
        let otherIsland = Box(false)
        let bridges = Box<[StandInBridge]>([])
        let inode = Box<UInt64>(100)

        /// A new file at the path: what a bind leaves, or another app's.
        func newFile(at path: String) {
            inode.update { $0 += 1 }
            let next = inode.current
            files.update { $0[path] = SocketIdentity(device: 1, inode: next) }
        }
    }

    let world = World()
    let sent = Box<[BridgeCommand]>([])
    let socket = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
    var legacy: String { BridgeSocketLocation.legacyURL.path }

    func engine(onOpenIslandsSocket: Bool = false,
                watch: (@MainActor (String, @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)?)? = nil) -> SessionEngine {
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        configuration.socketURL = socket
        if onOpenIslandsSocket { configuration.openIslandSocketURL = socket }
        configuration.watchesBridgeSockets = watch != nil
        var dependencies = SessionEngine.Dependencies()
        let world = world, sent = sent, legacy = legacy
        dependencies.isOtherIslandRunning = { world.otherIsland.current }
        dependencies.socketHasOwner = { world.owners.current.contains($0.path) }
        dependencies.socketIdentity = { world.files.current[$0.path] }
        dependencies.startBridge = { url in
            // BridgeServer binds its own path and the legacy one.
            world.newFile(at: url.path)
            world.newFile(at: legacy)
            let bridge = StandInBridge()
            world.bridges.update { $0.append(bridge) }
            return bridge
        }
        dependencies.sendCommand = { command in sent.update { $0.append(command) } }
        dependencies.startRuntime = { _ in }
        dependencies.updateProcessRoots = { _ in }
        dependencies.watchSocketFolder = watch
        dependencies.now = { EngineFixtures.now }
        return SessionEngine(configuration: configuration, dependencies: dependencies)
    }

    @Test
    func theBridgeNotesItsSocketsAtTheStartAndForgetsThemAtTheStop() throws {
        let engine = engine()
        #expect(engine.bridgeHealth == .off)
        try engine.start()
        #expect(engine.bridgeHealth == .live(sockets: 2))
        #expect(engine.checkBridgeSockets() != nil)
        engine.stop()
        #expect(engine.bridgeHealth == .off && engine.checkBridgeSockets() == nil)
    }

    /// Another app unlinked the socket and bound its own, then quit and left its file behind (upstream never deletes
    /// it): nobody listens there, so the bridge takes the path back, a restart of the bridge alone. A socket that is
    /// simply gone is taken back the same way.
    @Test
    func aLostSocketNobodyListensOnIsTakenBack() async throws {
        let engine = engine()
        try engine.start()
        defer { engine.stop() }
        await engine.checkBridgeSockets()?.value
        #expect(world.bridges.current.count == 1)                      // nothing lost: nothing done

        world.newFile(at: socket.path)
        await engine.checkBridgeSockets()?.value
        #expect(world.bridges.current.count == 2 && world.bridges.current[0].stopped)
        #expect(engine.bridgeHealth == .live(sockets: 2) && engine.bridgeTakenBackAt == EngineFixtures.now)
        #expect(engine.bridgeServer === world.bridges.current[1])

        world.files.update { $0[socket.path] = nil }
        await engine.checkBridgeSockets()?.value
        #expect(world.bridges.current.count == 3 && engine.bridgeHealth == .live(sockets: 2))
    }

    /// A socket another app listens on is never taken from it: the bridge stops and waits, the engine says so, and the
    /// path is taken back only once that app lets it go.
    @Test
    func aSocketAnotherAppListensOnIsNeverTaken() async throws {
        let engine = engine()
        try engine.start()
        defer { engine.stop() }
        world.newFile(at: socket.path)
        world.newFile(at: legacy)
        world.owners.update { $0 = [socket.path, legacy] }
        await engine.checkBridgeSockets()?.value
        #expect(engine.bridgeHealth == .taken && engine.bridgeServer == nil && !engine.isBridgeReady)
        #expect(world.bridges.current.count == 1 && world.bridges.current[0].stopped)
        #expect(engine.lastStatusMessage.hasPrefix("Another app took the hook socket"))

        await engine.checkBridgeSockets()?.value
        #expect(engine.bridgeHealth == .taken && world.bridges.current.count == 1)

        // It quit: its files stay, nobody listens.
        world.owners.update { $0 = [] }
        await engine.checkBridgeSockets()?.value
        #expect(engine.bridgeHealth == .live(sockets: 2) && world.bridges.current.count == 2)
    }

    /// The restart closes the hooks' open connections, so it waits while a session waits on an approval (its hook
    /// holds its connection to the old listener), and happens once it is answered.
    @Test
    func aLostSocketWaitsWhileAHookWaitsOnAnAnswer() async throws {
        let engine = engine()
        try engine.start()
        defer { engine.stop() }
        engine.ingest(EngineFixtures.started("a"), ingress: .bridge)
        engine.ingest(EngineFixtures.permission("a"), ingress: .bridge)
        engine.passAttentionWindows()
        world.files.update { $0[socket.path] = nil }
        await engine.checkBridgeSockets()?.value
        #expect(world.bridges.current.count == 1 && engine.bridgeHealth == .live(sockets: 2))
        #expect(engine.socketRetryTask != nil)

        await engine.approve(sessionID: "a", decision: .allowOnce)
        #expect(engine.state.session(id: "a")?.phase == .running)
        await engine.checkBridgeSockets()?.value
        #expect(world.bridges.current.count == 2 && engine.bridgeHealth == .live(sockets: 2))
    }

    /// Only the legacy `/tmp` socket gone (the system's cleanup of `/tmp`): noted, and left; the primary one listens.
    @Test
    func aLostLegacySocketAloneIsLeft() async throws {
        let engine = engine()
        try engine.start()
        defer { engine.stop() }
        world.files.update { $0[legacy] = nil }
        await engine.checkBridgeSockets()?.value
        #expect(world.bridges.current.count == 1 && engine.bridgeHealth == .live(sockets: 2) && engine.legacySocketLossNoted)
    }

    /// On a socket of its own (P900) Open Island running holds nothing back: a lost socket is taken back at once.
    @Test
    func openIslandRunningLeavesTheAppsOwnSocketAlone() async throws {
        let engine = engine()
        try engine.start()
        defer { engine.stop() }
        world.files.update { $0[socket.path] = nil }
        world.otherIsland.update { $0 = true }
        await engine.checkBridgeSockets()?.value
        #expect(engine.bridgeHealth == .live(sockets: 2) && world.bridges.current.count == 2)
    }

    /// A bridge set up on Open Island's own socket path (a scratch path stands in for it) still yields it: Open Island
    /// started while the socket was lost, so the bridge does not take it back, and waits as taken.
    @Test
    func onOpenIslandsSocketOpenIslandRunningKeepsItsOwn() async throws {
        let engine = engine(onOpenIslandsSocket: true)
        try engine.start()
        defer { engine.stop() }
        world.files.update { $0[socket.path] = nil }
        world.otherIsland.update { $0 = true }
        await engine.checkBridgeSockets()?.value
        #expect(engine.bridgeHealth == .taken && world.bridges.current.count == 1)
        world.otherIsland.update { $0 = false }
        await engine.checkBridgeSockets()?.value
        #expect(engine.bridgeHealth == .live(sockets: 2) && world.bridges.current.count == 2)
    }

    /// The app's engine watches the socket's folder: a change there is looked at once it has been quiet a second, and
    /// the watch ends with the engine.
    @Test
    func theSocketsFolderIsWatchedAndAChangeLooksAgain() async throws {
        final class Token: HookWatchToken, @unchecked Sendable {
            var cancelled = false
            func cancel() { cancelled = true }
        }
        let token = Token()
        let watched = Box<[String]>([])
        let onChange = Box<(@MainActor @Sendable () -> Void)?>(nil)
        let engine = engine(watch: { folder, change in
            watched.update { $0.append(folder) }
            onChange.update { $0 = change }
            return token
        })
        try engine.start()
        #expect(watched.current == [socket.deletingLastPathComponent().path])
        world.files.update { $0[socket.path] = nil }
        onChange.current?()
        await engine.socketFolderSettle?.value
        await engine.socketCheck?.value
        #expect(world.bridges.current.count == 2)
        engine.stop()
        #expect(token.cancelled)
    }
}

/// P114: what the engine keeps per session is bounded by the sessions it shows, not by every session it ever saw.
@MainActor
struct EngineUpkeepTests {
    typealias Box = EngineFixtures.Box

    @Test
    func thousandsOfShortSessionsLeaveNothingBehind() {
        let clock = Box(EngineFixtures.now)
        let engine = EngineFixtures.engine(clock: clock)
        engine.setProfiles(accounts: [], discovered: [.init(provider: .claude, folder: "/Users/test/.claude-work", suggestedAlias: "work")])
        engine.ingest(EngineFixtures.started("kept"), ingress: .bridge)
        engine.ingest(EngineFixtures.prompt("kept"), ingress: .bridge)
        // Upstream's monitor drops every session that no longer shows; "kept" still does.
        func pass(after seconds: TimeInterval) {
            clock.update { $0 += seconds }
            engine.applyMonitoredState(SessionState(sessions: engine.state.sessions.filter { $0.id == "kept" }))
        }
        var peak = 0
        for round in 0..<10 {
            for n in round * 100..<(round + 1) * 100 {
                // Half end with a SessionEnd; half are processes the monitor finds gone and drops with none (its
                // synthetic Claude sessions, a Codex app thread, another tool's).
                let id = n.isMultiple(of: 2) ? "s\(n)" : SessionEngine.syntheticClaudeSessionPrefix + "\(n)"
                clock.update { $0 += 1 }
                engine.ingest(EngineFixtures.started(id, transcript: "/Users/test/.claude-work/projects/-tmp-project/\(n).jsonl"),
                              ingress: .bridge)
                engine.ingest(EngineFixtures.prompt(id), ingress: .bridge)
                engine.ingest(EngineFixtures.running(id), ingress: .bridge)
                engine.ingest(EngineFixtures.completed(id), ingress: .bridge)
                if n.isMultiple(of: 2) { engine.ingest(EngineFixtures.sessionEnd(id), ingress: .bridge) }
            }
            engine.ingest(EngineFixtures.started("ignored-\(round)", cwd: "/tmp/juice-test-cli"), ingress: .bridge)
            pass(after: 700)
            peak = max(peak, engine.bookkeptSessionIDs.count)
        }
        // At most the last two rounds' sessions are kept at any look, never all 1,000.
        #expect(peak <= 201)
        pass(after: 700)
        pass(after: 700)
        pass(after: 3_600)
        #expect(engine.state.sessions.map(\.id) == ["kept"])
        #expect(engine.bookkeptSessionIDs == ["kept"])
        #expect(engine.promptedSessionIDs == ["kept"] && engine.interruptedSessionIDs.isEmpty)
        #expect(engine.activityClocks.keys.allSatisfy { $0 == "kept" } && engine.accountTags.keys.allSatisfy { $0 == "kept" })
        #expect(engine.signals.sessionIDs.isSubset(of: ["kept"]) && engine.lifecycle.sessionIDs.isSubset(of: ["kept"]))
        #expect(engine.hookNotes.sessionIDs.isEmpty && engine.ignoredSessionIDs.isEmpty)
    }

    /// A session gone from the state for less than two looks keeps what the engine knows of it: it may be back (a
    /// monitor pass that missed its process once).
    @Test
    func aSessionGoneForOneLookKeepsItsBookkeeping() {
        let clock = Box(EngineFixtures.now)
        let engine = EngineFixtures.engine(clock: clock)
        let id = SessionEngine.syntheticClaudeSessionPrefix + "1"
        engine.ingest(EngineFixtures.started(id), ingress: .bridge)
        engine.ingest(EngineFixtures.prompt(id), ingress: .bridge)
        clock.update { $0 += 700 }
        engine.applyMonitoredState(SessionState())
        #expect(engine.promptedSessionIDs == [id])
        engine.ingest(EngineFixtures.started(id), ingress: .bridge)
        clock.update { $0 += 700 }
        engine.applyMonitoredState(engine.state)
        #expect(engine.promptedSessionIDs == [id])
    }
}
