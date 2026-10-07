import Foundation
@testable import IslandEngine
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// Stands in for BridgeServer: no socket is opened.
private final class BackgroundStubBridge: EngineBridge, @unchecked Sendable {
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() {}
}

/// The card of a folded Claude Code session in Claude Code's own background (wave 8, P1450 to P1484), as the island
/// draws it from the engine: its line in each stage, its reply field, Stop and Open in terminal, and Settings › Agents'
/// switch. Headless, on the fold fixtures; nothing is listed, typed, attached, stopped or opened.
@MainActor
struct ClaudeBackgroundCardTests {
    typealias ID = FoldFixtures.ID

    /// A fixture fold put in `stage`, as the move leaves it.
    static func env(_ id: String, _ stage: FoldBackground.Stage, setUp: (inout FoldBackground) -> Void = { _ in }) -> AppEnvironment {
        let feed = FoldFixtures.feed(folded: [id])
        var background = FoldBackground(stage: stage, shortID: stage == .moved ? "0ca371e5" : nil, profile: "/tmp/ji-home/.claude",
                                        folder: "/tmp/juice-island")
        setUp(&background)
        feed.engine.folds[id]?.background = background
        return FoldFixtures.env(feed)
    }

    static func card(_ env: AppEnvironment, _ id: String) throws -> (FoldedCardModel, SessionRow) {
        let card = try #require(env.sessions.foldedCard(id))
        return (card, card.row)
    }

    @Test
    func eachStageHasItsOneLine() throws {
        let cases: [(String, FoldBackground.Stage, (inout FoldBackground) -> Void, String)] = [
            (ID.idle, .moved, { _ in }, "Background"),
            (ID.idle, .moved, { $0.attachedIn = "Terminal" }, "Background · attached in Terminal"),
            (ID.idle, .moved, { $0.stoppedByOwner = true }, "Background · stopped"),
            (ID.working, .waitsForTurnEnd, { _ in }, "Moves to the background when this turn ends"),
            (ID.working, .moving, { _ in }, "Moving to the background…"),
            (ID.idle, .notMoved(.stillInTab), { _ in }, "Not moved · it is still in its tab"),
            (ID.idle, .notMoved(.asksInItsTab), { _ in }, "Not moved · Claude asks something in its tab"),
            (ID.idle, .notMoved(.cannotTell), { _ in }, "Not sure it moved to the background"),
        ]
        for (id, stage, setUp, words) in cases {
            let env = Self.env(id, stage, setUp: setUp)
            let (card, row) = try Self.card(env, id)
            let background = try #require(card.background, "\(words)")
            #expect(background.words == words)
            guard case .background = FoldedCardLine.left(card, row: row) else {
                Issue.record("\(words): \(FoldedCardLine.left(card, row: row))")
                continue
            }
        }
    }

    /// In the background: the field shows (a reply goes through the hidden attach), Stop and Open in terminal on the
    /// right; stopped, no Stop; Open in terminal's tooltip says closing its window leaves it running.
    @Test
    func aMovedCardRepliesStopsAndOpensAttached() throws {
        let env = Self.env(ID.idle, .moved)
        let (card, _) = try Self.card(env, ID.idle)
        #expect(card.reach == .background && FoldedCardView.showsField(card) && card.stoppable)
        #expect(FoldedCardLine.openTitle(card) == "Open in terminal")
        #expect(FoldedCardLine.openHelp(card) == "Open it in a new window; closing that window leaves it running")
        let stopped = Self.env(ID.idle, .moved) { $0.stoppedByOwner = true }
        #expect(try Self.card(stopped, ID.idle).0.stoppable == false)
    }

    /// Working there: Background · Working, from its hooks.
    @Test
    func aMovedCardWorkingSaysBackgroundAndWorking() throws {
        let env = Self.env(ID.working, .moved)
        let (card, row) = try Self.card(env, ID.working)
        #expect(card.working)
        #expect(FoldedCardLine.left(card, row: row) == .background(FoldedBackgroundModel(stage: .moved), working: true))
    }

    /// A `/background` that did not move it as seen: no field, Open in terminal to reply; a sure miss (not typed, or its tab in
    /// front) gives way to Working once a turn runs in its tab (P1457).
    @Test
    func aMissSaysWhyAndASureOneGivesWayToWorking() throws {
        let unsure = Self.env(ID.idle, .notMoved(.stillInTab))
        let (card, _) = try Self.card(unsure, ID.idle)
        #expect(card.reach == .openOnly && !FoldedCardView.showsField(card))
        #expect(FoldedCardLine.openTitle(card) == "Open in terminal to reply")
        let sure = Self.env(ID.working, .notMoved(.tabInFront))
        let (working, row) = try Self.card(sure, ID.working)
        #expect(working.background == nil && working.reach == .tab)
        if case .background = FoldedCardLine.left(working, row: row) { Issue.record("a sure miss while working") }
        let idle = Self.env(ID.idle, .notMoved(.notTyped))
        #expect(try Self.card(idle, ID.idle).0.background?.words == "Not moved · it could not be typed")
    }

    /// Its Open in terminal did not open a window: "Not opened" says so first; a session a reply woke reads Background
    /// and Working, not stopped, while its turn runs (P1462, P1463).
    @Test
    func notOpenedAndAWokenSessionSayWhereTheyStand() throws {
        let feed = FoldFixtures.feed(folded: [ID.idle])
        var background = FoldBackground(stage: .moved, shortID: "0ca371e5", profile: "/tmp/ji-home/.claude", folder: "/tmp/juice-island")
        feed.engine.folds[ID.idle]?.background = background
        feed.engine.folds[ID.idle]?.notOpened = true
        let notOpened = FoldFixtures.env(feed)
        let (card, row) = try Self.card(notOpened, ID.idle)
        #expect(FoldedCardLine.left(card, row: row) == .note("Not opened"))
        background.listed = ClaudeBackgroundEntry(id: "0ca371e5", sessionID: ID.working, kind: .background, state: "stopped")
        #expect(EngineSessionsModel.backgroundModel(background, working: false)?.stage == .stopped)
        #expect(EngineSessionsModel.backgroundModel(background, working: true)?.stage == .moved)
    }

    /// The app hands its engine the backgrounder it made and mirrors the switch into it, as it changes (P1450).
    @Test
    func liveSessionsHandsTheEngineItsBackgrounderAndTheSwitch() async throws {
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { false }
            dependencies.socketHasOwner = { _ in false }
            dependencies.startBridge = { _ in BackgroundStubBridge() }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            var runner = JumpRunner()
            runner.appURL = { _ in nil }
            runner.isAppRunning = { _ in false }
            runner.appleScript = { _, _ in throw CocoaError(.featureUnsupported) }
            runner.open = { _, _ in throw CocoaError(.featureUnsupported) }
            runner.command = { _, _, _ in false }
            dependencies.jumpRunner = runner
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, backgrounder: { engine in
            var dependencies = ClaudeBackgrounder.Dependencies()
            dependencies.hasRoster = { _ in false }
            return ClaudeBackgrounder(engine: engine, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) })
        live.activate()
        let engine = try #require(live.engine)
        #expect(engine.claudeBackground === live.backgrounder && live.backgrounder != nil)
        #expect(engine.keepsClaudeRunning)
        settings.keepClaudeRunning = false
        var looks = 3_000
        while engine.keepsClaudeRunning, looks > 0 {
            looks -= 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!engine.keepsClaudeRunning)
        settings.liveSessions = false
        live.apply()
    }

    /// Settings › Agents › Keep Claude sessions running when their window closes: on by default (P1450, P1470).
    @Test
    func theSwitchIsOnByDefault() {
        let settings = AppSettings.ephemeral()
        #expect(settings.keepClaudeRunning)
        settings.keepClaudeRunning = false
        #expect(!settings.keepClaudeRunning)
        #expect(AgentsPaneText.keepRunningTitle == "Keep Claude sessions running when their window closes")
        #expect(!AgentsPaneText.keepRunning.contains("\u{2014}"))
    }

    /// `/background` is typed after whatever sits unsent in its tab's prompt, and goes with it: the switch and the card's
    /// line say so, as no key clears that prompt for sure (P1543). A held reply its attached window in front gave back
    /// says why (P1542).
    @Test
    func theSwitchAndTheCardSayThatUnsentTextGoesWithBackground() {
        #expect(AgentsPaneText.keepRunning.contains("/background") && AgentsPaneText.keepRunning.contains("send or clear"))
        let waits = FoldedBackgroundModel(stage: .waits).help, moving = FoldedBackgroundModel(stage: .moving).help
        let missed = FoldedBackgroundModel(stage: .notMoved("Not moved · it is still in its tab")).help
        #expect(waits.contains("/background") && waits.contains("send or clear"))
        #expect(moving.contains("/background") && moving.contains("not sent"))
        #expect(missed.contains("not sent"))
        #expect(FoldedBackgroundModel(stage: .moved).help == "It runs in Claude Code's background: closing a window leaves it running")
        for words in [waits, moving, missed, AgentsPaneText.keepRunning] { #expect(!words.contains("\u{2014}")) }
        #expect(EngineSessionsModel.unsentWords(.windowInFront, reach: .background) == "Not sent · its window was in front")
    }
}
