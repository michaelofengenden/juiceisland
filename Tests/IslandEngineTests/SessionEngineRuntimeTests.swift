import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// What the launch leaves to the process monitor (P86), and what the hook status reads of the helpers (P87).
@MainActor
struct SessionEngineRuntimeTests {
    typealias Box = EngineFixtures.Box

    private func engine(monitorStarts: Box<Int>) -> SessionEngine {
        var dependencies = SessionEngine.Dependencies()
        dependencies.startRuntime = { _ in }
        dependencies.startMonitoring = { _ in monitorStarts.update { $0 += 1 } }
        dependencies.updateProcessRoots = { _ in }
        return SessionEngine(configuration: .headless, dependencies: dependencies)
    }

    private var emptyPayload: SessionDiscoveryCoordinator.StartupDiscoveryPayload {
        SessionDiscoveryCoordinator.StartupDiscoveryPayload(
            codexRecords: [], codexRecordsNeedPrune: false, claudeRecords: [], claudeRecordsNeedPrune: false,
            openCodeRecords: [], openCodeRecordsNeedPrune: false, cursorRecords: [], cursorRecordsNeedPrune: false,
            piRecords: [], piRecordsNeedPrune: false, discoveredCodexRecords: [], discoveredClaudeSessions: [], hooksBinaryURL: nil)
    }

    /// Upstream's launch reconciled once on the main thread (`ps`, `lsof`, AppleScript) before starting the monitor's
    /// loop; the engine only starts the loop, whose first pass resolves all of that off the main thread.
    @Test
    func theLaunchLeavesTheFirstReconcileToTheMonitorLoop() {
        let monitorStarts = Box(0)
        let engine = engine(monitorStarts: monitorStarts)
        let monitoring = ProcessMonitoringCoordinator()
        let stateReads = Box(0)
        monitoring.stateAccessor = {
            stateReads.update { $0 += 1 }
            return SessionState()
        }
        engine.monitoring = monitoring

        engine.applyStartupPayload(emptyPayload)
        #expect(stateReads.current == 0)
        #expect(monitorStarts.current == 1)
    }

    /// A terminal that never answers its probe kept upstream resolving, polling every 2 s and holding back every
    /// rollout signal, for the app's life; the launch's resolution now ends after its limit. The test waits for the
    /// task that ends it, not for a deadline: other suites can hold the main actor for seconds, and the test's own
    /// wake-up could then run before that task.
    @Test
    func theLaunchResolutionEndsAfterItsLimit() async {
        let engine = engine(monitorStarts: Box(0))
        let monitoring = ProcessMonitoringCoordinator()
        monitoring.isResolvingInitialLiveSessions = true
        let ending = engine.endInitialResolution(of: monitoring, after: .milliseconds(50))
        #expect(monitoring.isResolvingInitialLiveSessions)
        await ending.value
        #expect(!monitoring.isResolvingInitialLiveSessions)
        #expect(SessionEngine.initialResolutionLimit == .seconds(30))
        #expect(ProcessMonitoringCoordinator.monitoringPollInterval(isResolvingInitialLiveSessions: false, hasTrackedLiveSessions: true) == 60)
    }
}

/// The helpers are compared by their bytes once, and again only when either file changes (P87).
struct FileComparisonsTests {
    @Test
    func aComparisonIsKeptUntilAFileChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-island-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let managed = folder.appendingPathComponent("managed")
        let bundled = folder.appendingPathComponent("bundled")
        let bytes = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: managed)
        try bytes.write(to: bundled)

        for _ in 0..<5 { #expect(ProfileHookInspector.filesMatch(managed, bundled, fileManager: .default)) }
        #expect(FileComparisons.byteComparisons(of: managed) == 1)

        // Same size, one byte different, written in place: its times change, so it is read again.
        var changed = bytes
        changed[512] ^= 0xFF
        let handle = try FileHandle(forWritingTo: bundled)
        try handle.write(contentsOf: changed)
        try handle.close()
        #expect(!ProfileHookInspector.filesMatch(managed, bundled, fileManager: .default))
        #expect(!ProfileHookInspector.filesMatch(managed, bundled, fileManager: .default))
        #expect(FileComparisons.byteComparisons(of: managed) == 2)

        // A sync renames a new copy over it: a new inode, read again, and the same once more.
        let staging = folder.appendingPathComponent("staging")
        try bytes.write(to: staging)
        #expect(rename(staging.path, bundled.path) == 0)
        #expect(ProfileHookInspector.filesMatch(managed, bundled, fileManager: .default))
        #expect(FileComparisons.byteComparisons(of: managed) == 3)

        // Another size differs without a read.
        let short = folder.appendingPathComponent("short")
        try bytes.prefix(100).write(to: short)
        #expect(!ProfileHookInspector.filesMatch(short, bundled, fileManager: .default))
        #expect(FileComparisons.byteComparisons(of: short) == 0)
        #expect(!ProfileHookInspector.filesMatch(managed, folder.appendingPathComponent("missing"), fileManager: .default))
    }
}
