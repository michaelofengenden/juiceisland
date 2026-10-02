import Foundation
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Permission modes on cards in the app (P450-P455): which cards carry mode buttons, what each says, that no key sends a
/// mode, and that the setting reaches the engine. The helper's own output is `ModeChoiceEndToEndTests`'.
@MainActor
struct ModeChoiceUITests {
    typealias ID = FixtureSessionFeed.ID

    private func modes(_ card: SessionCard?) -> [ClaudePermissionMode]? {
        switch card {
        case let .plan(model)?: model.modes
        case let .approval(model)?: model.modes
        default: nil
        }
    }

    /// The demo's plan and edit carry Claude's modes; a push (a rule only), a Codex approval and a question none.
    @Test
    func cardsCarryOnlyTheModesTheirRequestOffers() {
        let all = AppEnvironment.demo(sessions: .allStates).sessions
        #expect(modes(all.card(for: ID.plan)) == [.acceptEdits, .default])
        let cards = AppEnvironment.demo(sessions: .cards).sessions
        #expect(modes(cards.card(for: ID.edit)) == [.acceptEdits])
        #expect(modes(cards.card(for: ID.longBash)) == [])
        #expect(modes(cards.card(for: ID.codexShort)) == [])
        let prototype = AppEnvironment.demo(sessions: .prototype).sessions
        #expect(modes(prototype.card(for: ID.approval)) == [])
        if case .question? = prototype.card(for: ID.question) {} else { Issue.record("no question card") }
    }

    /// Titles in Claude's own words for its modes; the tooltip says what the click does, Approve or Yes first.
    @Test
    func buttonsAreNamedAsClaudeNamesItsModes() {
        #expect([ClaudePermissionMode.acceptEdits, .default, .bypassPermissions].map(ModeButtons.title) == ["Accept edits", "Manual", "Bypass"])
        #expect(ModeButtons.help(.acceptEdits, plan: true) == "Approve, and accept edits for the rest of the session")
        #expect(ModeButtons.help(.default, plan: true) == "Approve, and ask before each edit (Manual)")
        #expect(ModeButtons.help(.bypassPermissions, plan: false) == "Yes, and bypass permissions for the rest of the session")
        #expect(PlanCardView.approveHelp == "Approve, and go back to the mode Claude planned from")
    }

    /// No key sends a mode, on a plan or an approval that offers them, in the island or the window: ⌃A is the plain
    /// Allow, and nothing else answers with a mode (P450).
    @Test
    func noKeySendsAMode() throws {
        let plan = try #require(AppEnvironment.demo(sessions: .allStates).sessions.card(for: ID.plan))
        let edit = try #require(AppEnvironment.demo(sessions: .cards).sessions.card(for: ID.edit))
        let characters = "abcdefghijklmnopqrstuvwxyz0123456789\r\u{1B} ".map(String.init)
        for card in [plan, edit] {
            #expect(modes(card)?.isEmpty == false)
            for character in characters {
                for (control, shift, option, command) in [(true, false, false, false), (true, true, false, false), (false, false, false, false),
                                                         (true, false, true, false), (false, false, false, true)] {
                    let island = IslandKeyRouter.command(for: IslandKeyPress(characters: character, control: control, shift: shift,
                                                                               command: command, option: option), card: card)
                    if case let .approve(_, decision)? = island, case .allowSwitchingMode = decision {
                        Issue.record("island key \(character) sends a mode")
                    }
                    let window = WindowKeyRouter.command(for: .init(character: character, control: control, shift: shift, option: option,
                                                                    command: command))
                    if case let .decide(decision)? = window, case .allowSwitchingMode = decision {
                        Issue.record("window key \(character) sends a mode")
                    }
                }
            }
        }
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "a", control: true), card: plan) == .approve(sessionID: ID.plan, .allowOnce))
    }

    /// The live engine takes Permission modes on cards at its start and on every change of the setting.
    @Test
    func theLiveEngineFollowsTheSetting() async throws {
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        settings.modeChoicesOnCards = false
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { false }
            dependencies.socketHasOwner = { _ in false }
            dependencies.startBridge = { _ in ModeStubBridge() }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, identity: .development)
        live.activate()
        let engine = try #require(live.engine)
        #expect(live.mode == .live && !engine.offersModeChoices)
        settings.modeChoicesOnCards = true
        for _ in 0..<50 where !engine.offersModeChoices { await Task.yield() }
        #expect(engine.offersModeChoices)
        live.settings.liveSessions = false
        live.apply()
    }

    /// Permission modes on cards: on by default; off, the engine offers none, and the card draws none.
    @Test
    func theSettingReachesTheEngine() {
        #expect(AppSettings.ephemeral().modeChoicesOnCards)
        let env = AppEnvironment.demo(sessions: .allStates)
        env.fixtureFeed?.engine.offersModeChoices = false
        #expect(modes(env.sessions.card(for: ID.plan)) == [])
        env.fixtureFeed?.engine.offersModeChoices = true
        #expect(modes(env.sessions.card(for: ID.plan)) == [.acceptEdits, .default])
    }
}

/// Stands in for BridgeServer: no socket is opened.
private final class ModeStubBridge: EngineBridge, @unchecked Sendable {
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() {}
}
