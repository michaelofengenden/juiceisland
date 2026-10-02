import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Stands in for BridgeServer: no socket is opened.
private final class PreviewTestBridge: EngineBridge, @unchecked Sendable {
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() {}
}

@MainActor
struct SessionEnginePreviewTests {
    typealias F = EngineFixtures

    @Test
    func previewEventsGoThroughTheNormalIngestPathAndCommandsStayInside() async {
        let sent = F.Box<[BridgeCommand]>([])
        let engine = SessionEngine.preview(clock: { F.now }, commands: { command in sent.update { $0.append(command) } })
        #expect(engine.loadPreviewEvents([F.started("a"), F.prompt("a"), F.started("b"), F.permission("b"), F.started("quiet")]))
        // Surfaced exactly as bridge events would be: a prompt or a request shows, a bare start does not (P11).
        #expect(Set(engine.rows.map(\.id)) == ["a", "b"])
        #expect(engine.needsYouCount == 1)
        await engine.approve(sessionID: "b", decision: .allowOnce)
        #expect(sent.current.count == 1)
        #expect(engine.needsYouCount == 0)
    }

    @Test
    func previewEventsAreRefusedWhileTheBridgeRuns() throws {
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
        var dependencies = SessionEngine.Dependencies()
        dependencies.isOtherIslandRunning = { false }
        dependencies.socketHasOwner = { _ in false }
        dependencies.startBridge = { _ in PreviewTestBridge() }
        dependencies.startRuntime = { _ in }
        dependencies.updateProcessRoots = { _ in }
        dependencies.now = { F.now }
        let engine = SessionEngine(configuration: configuration, dependencies: dependencies)

        try engine.start()
        #expect(engine.loadPreviewEvents([F.started("a"), F.prompt("a")]) == false)
        #expect(engine.state.sessions.isEmpty)

        engine.stop()
        #expect(engine.loadPreviewEvents([F.started("a"), F.prompt("a")]))
        #expect(engine.rows.map(\.id) == ["a"])
    }
}
