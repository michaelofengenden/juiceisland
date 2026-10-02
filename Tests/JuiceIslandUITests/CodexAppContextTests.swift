import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The owner's screenshot of 2026-09-30 (P660, P661): a Codex app thread's question card never shows the app's in-app
/// browser context as its prompt, says "in Codex", and its Open goes to the thread in the Codex app, never to the
/// thread's folder in Finder. Fixture events and a stand-in runner: nothing is opened, no app is activated.
@MainActor
struct CodexAppContextTests {
    typealias ID = FixtureSessionFeed.CodexAppID

    static let machineWords = ["in-app-browser", "ambient", "This block is", "## My request"]

    @Test
    func theCardShowsTheOwnersWordsAndTheQuestion() throws {
        let model = FixtureSessionFeed(scenario: .codexAppContext).makeModel()
        let row = try #require(model.row(id: ID.thread))
        #expect(row.task == FixtureSessionFeed.benchPrompt)
        #expect(row.status == .question && row.detail == FixtureSessionFeed.benchQuestion)
        // The prompt is the title's, so the status line says the question instead (P203).
        #expect(SessionRowText.cleanStatus(row).text == FixtureSessionFeed.benchQuestion)
        for text in [row.task, row.lastPrompt, row.detail, SessionRowText.cleanStatus(row).text].compactMap({ $0 }) {
            #expect(!Self.machineWords.contains { text.contains($0) }, "\(text)")
        }
        guard case let .question(card)? = model.card(for: ID.thread) else {
            Issue.record("no question card")
            return
        }
        #expect(card.request?.place == .codexApp)
        #expect(CardText.status(.question(card), host: row.host).text == "Task set · in Codex")
    }

    final class Opens: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func add(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
        var all: [[String]] { lock.withLock { calls } }
    }

    /// Open on the card: the thread's own link, checked with the app in front; no folder, no Finder.
    @Test
    func openGoesToTheThreadInTheCodexApp() async throws {
        let opens = Opens()
        var runner = JumpRunner()
        runner.appURL = { URL(fileURLWithPath: "/Applications/\($0).app") }
        runner.isAppRunning = { $0 == ExactJump.codexBundleID }
        runner.appleScript = { _, _ in "" }
        runner.open = { arguments, _ in opens.add(arguments) }
        runner.command = { _, _, _ in false }
        runner.frontmostBundleID = { ExactJump.codexBundleID }
        runner.pause = { _ in }
        var dependencies = SessionEngine.Dependencies()
        dependencies.jumpRunner = runner
        dependencies.sendCommand = { _ in }
        dependencies.updateProcessRoots = { _ in }
        dependencies.isOtherIslandRunning = { false }
        dependencies.ttyForPID = { _ in nil }
        dependencies.appForPID = { _ in nil }
        dependencies.confirmsRequestsAtOnce = true
        let now = DemoClock.now
        dependencies.now = { now }
        var configuration = SessionEngine.Configuration.headless
        configuration.excludedWorkingDirectories = []
        let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
        engine.loadPreviewEvents(FixtureSessionFeed.events(.codexAppContext, now: now))
        FixtureSessionFeed.loadAttention(.codexAppContext, into: engine, now: now)
        let head = try #require(engine.attentionHead(for: ID.thread))
        let outcome = try #require(await engine.openRequest(requestID: head.id))
        #expect(outcome.result == .matched && outcome.host == "Codex.app")
        #expect(opens.all == [["codex://threads/\(ID.thread)"]])
        #expect(JumpNote.text(for: outcome) == nil)
    }
}
