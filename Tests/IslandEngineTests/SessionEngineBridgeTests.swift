import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// Stands in for BridgeServer: no socket is opened.
private final class FakeBridge: EngineBridge, @unchecked Sendable {
    private(set) var stopped = false
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() { stopped = true }
}

private struct BindFailed: Error {}

@MainActor
struct SessionEngineStartTests {
    typealias Box = EngineFixtures.Box

    /// An engine whose bridge, socket probe and runtime are all stand-ins, counted in the boxes.
    private func engine(otherIsland: Bool = false, owned: Set<String> = [], failingBinds: Int = 0,
                        binds: Box<[URL]>, runtimeStarts: Box<Int>) -> SessionEngine {
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        configuration.loadRuntimeState = true
        configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
        var dependencies = SessionEngine.Dependencies()
        dependencies.isOtherIslandRunning = { otherIsland }
        dependencies.socketHasOwner = { owned.contains($0.path) }
        dependencies.startBridge = { url in
            binds.update { $0.append(url) }
            if binds.current.count <= failingBinds { throw BindFailed() }
            return FakeBridge()
        }
        dependencies.startRuntime = { _ in runtimeStarts.update { $0 += 1 } }
        dependencies.updateProcessRoots = { _ in }
        return SessionEngine(configuration: configuration, dependencies: dependencies)
    }

    @Test
    func startingTheBridgeIsRefusedWhileOpenIslandRuns() {
        let binds = Box<[URL]>([])
        let runtimeStarts = Box(0)
        let engine = engine(otherIsland: true, binds: binds, runtimeStarts: runtimeStarts)
        #expect(throws: SessionEngineError.otherIslandRunning) { try engine.start() }
        #expect(engine.isBridgeReady == false)
        #expect(binds.current.isEmpty)
        #expect(runtimeStarts.current == 0)
    }

    /// A2: a live listener on either hook socket is never taken over, whoever owns it.
    @Test
    func aLiveHookSocketIsNeverTakenOver() {
        let legacy = BridgeSocketLocation.legacyURL.path
        let binds = Box<[URL]>([])
        let runtimeStarts = Box(0)
        let engine = engine(owned: [legacy], binds: binds, runtimeStarts: runtimeStarts)
        #expect(throws: SessionEngineError.hookSocketInUse(path: legacy)) { try engine.start() }
        #expect(binds.current.isEmpty)
        #expect(runtimeStarts.current == 0)
        #expect(engine.hasStarted == false)
        #expect(HookSocketProbe.paths(for: engine.configuration.socketURL).map(\.path)
                == [engine.configuration.socketURL.path, BridgeSocketLocation.defaultURL.path, legacy])
    }

    /// A2: stale or missing socket files are replaced as upstream does.
    @Test
    func staleSocketFilesAreReplaced() throws {
        let binds = Box<[URL]>([])
        let runtimeStarts = Box(0)
        let engine = engine(binds: binds, runtimeStarts: runtimeStarts)
        try engine.start()
        defer { engine.stop() }
        #expect(binds.current == [engine.configuration.socketURL])
        #expect(runtimeStarts.current == 1)
        #expect(engine.hasStarted)
    }

    /// A3: a failed bind starts nothing; the retry starts the bridge, then discovery and monitoring, once.
    @Test
    func aFailedBindStartsNothingAndTheRetryStartsEverythingOnce() throws {
        let binds = Box<[URL]>([])
        let runtimeStarts = Box(0)
        let engine = engine(failingBinds: 1, binds: binds, runtimeStarts: runtimeStarts)
        #expect(throws: BindFailed.self) { try engine.start() }
        #expect(engine.hasStarted == false)
        #expect(engine.bridgeServer == nil)
        #expect(runtimeStarts.current == 0)
        #expect(engine.lastStatusMessage.hasPrefix("Could not start the hook bridge"))

        try engine.start()
        defer { engine.stop() }
        #expect(engine.hasStarted)
        #expect(engine.bridgeServer != nil)
        #expect(runtimeStarts.current == 1)
        try engine.start()
        #expect(binds.current.count == 2)
        #expect(runtimeStarts.current == 1)
    }

    /// A2: on macOS a live listener with a full backlog refuses like a stale file, so a refused path is probed a
    /// second time before it counts as stale.
    @Test
    func aRefusedSocketIsProbedAgainBeforeItCountsAsStale() {
        func probe(_ answers: [HookSocketProbe.Result]) -> (result: HookSocketProbe.Result, calls: Int) {
            var calls = 0
            let result = HookSocketProbe.probe(URL(fileURLWithPath: "/tmp/juice-island-probe-test.sock"), recheckAfter: 0) { _, _ in
                calls += 1
                return answers[min(calls, answers.count) - 1]
            }
            return (result, calls)
        }
        let busy = probe([.stale, .live])
        #expect(busy.result == .live && busy.calls == 2)
        let stale = probe([.stale, .stale])
        #expect(stale.result == .stale && stale.calls == 2)
        let free = probe([.free])
        #expect(free.result == .free && free.calls == 1)
        let live = probe([.live])
        #expect(live.result == .live && live.calls == 1)
    }

    @Test
    func aRestoredApprovalEndsAsInterruptedAndALiveOneStays() throws {
        let engine = EngineFixtures.engine()
        engine.ingest(EngineFixtures.started("live"), ingress: .bridge)
        engine.ingest(EngineFixtures.permission("live"), ingress: .bridge)
        engine.passAttentionWindows()
        // What upstream restores after a relaunch: the phase without the request.
        let restored = AgentSession(id: "restored", title: "Claude · project", tool: .claudeCode, phase: .waitingForApproval,
                                    summary: "Wants to run Bash.", updatedAt: EngineFixtures.now.addingTimeInterval(-60))
        engine.state = SessionState(sessions: engine.state.sessions + [restored])
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }

        engine.settleRestoredWaits()
        let settled = try #require(engine.state.session(id: "restored"))
        #expect(settled.phase == .completed)
        #expect(settled.summary == SessionEngine.restartedSummary)
        #expect(engine.statusWord(for: settled) == .interrupted)
        #expect(engine.state.session(id: "live")?.phase == .waitingForApproval)
        #expect(engine.needsYouCount == 1)
        #expect(signals.isEmpty)
    }
}

/// End to end through a real BridgeServer on a scratch socket. Runs only when JUICE_ISLAND_BRIDGE_TESTS=1, which
/// scripts/test.sh sets after checking that no island app is running: BridgeServer also binds the legacy
/// /tmp/open-island-<uid>.sock and deletes whatever socket file is already there.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JUICE_ISLAND_BRIDGE_TESTS"] == "1"))
struct SessionEngineBridgeTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test
    func aHookEventReachesTheEngineTaggedWithItsProfile() async throws {
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        configuration.socketURL = BridgeSocketLocation.uniqueTestURL()
        var dependencies = SessionEngine.Dependencies()
        dependencies.isOtherIslandRunning = { false }
        dependencies.updateProcessRoots = { _ in }
        // Swift Testing runs suites in parallel, and every BridgeServer that upstream's Core tests start also binds the
        // legacy /tmp socket, so the real probe would find that test's server live there and refuse. scripts/test.sh
        // has already refused to run while any app owns it, so only the legacy path is skipped; the scratch and
        // default sockets keep the real probe.
        dependencies.socketHasOwner = { $0.path != BridgeSocketLocation.legacyURL.path && HookSocketProbe.probe($0).hasOwner }
        let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
        engine.setProfiles(accounts: [Account(provider: .claude, folder: "/Users/test/.claude-work", alias: "Work")], discovered: [])
        try engine.start()
        defer { engine.stop() }

        try await waitUntil { engine.isBridgeReady }
        #expect(engine.isBridgeReady)

        let payload = ClaudeHookPayload(cwd: "/tmp/project", hookEventName: .userPromptSubmit, sessionID: "bridge-1",
                                        transcriptPath: "/Users/test/.claude-work/projects/-tmp-project/bridge-1.jsonl",
                                        prompt: "hello")
        let socketURL = configuration.socketURL
        _ = try await Task.detached { try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(payload)) }.value
        try await waitUntil { engine.accountTag(for: "bridge-1") != nil && engine.signals.turn(for: "bridge-1") == 1 }
        #expect(engine.state.session(id: "bridge-1") != nil)
        #expect(engine.accountTag(for: "bridge-1")?.alias == "Work")
        // The real bridge still marks a UserPromptSubmit with the prefix the pipeline counts turns by.
        #expect(engine.signals.turn(for: "bridge-1") == 1)
        #expect(engine.rows.map(\.id) == ["bridge-1"])

        // And still gives PermissionDenied the fixed summary the pipeline tells apart from a Stop.
        func send(_ payload: ClaudeHookPayload) async throws {
            _ = try await Task.detached { try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(payload)) }.value
        }
        func word() -> StatusWord? { engine.state.session(id: "bridge-1").map { engine.statusWord(for: $0) } }
        try await send(ClaudeHookPayload(cwd: "/tmp/project", hookEventName: .permissionDenied, sessionID: "bridge-1",
                                         transcriptPath: nil, toolName: "Bash", toolUseID: "toolu_1"))
        try await waitUntil { word() == .denied(tool: "Bash") }
        #expect(word() == .denied(tool: "Bash"))
    }

    /// The probe tells a live listener from a file nobody listens on, on a scratch socket.
    @Test
    func theProbeTellsALiveSocketFromAStaleOne() throws {
        let url = BridgeSocketLocation.uniqueTestURL()
        #expect(HookSocketProbe.probe(url) == .free)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 4) == 0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HookSocketProbe.probe(url) == .live)
        close(fd)
        #expect(HookSocketProbe.probe(url) == .stale)
    }
}
