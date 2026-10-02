import AppKit
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Permission modes on cards (P450-P455), headless. `MC-card-{clean,detailed,window}-plan`: a plan with Keep planning,
/// Approve, Accept edits, Manual and Open; `MC-card-clean-plan-bypass`: the same plan in a session seen in bypass
/// (Bypass in Accept edits' place); `MC-card-clean-plan-hints`: ⌃ held, the mode buttons with no key;
/// `MC-card-clean-plan-off`: Permission modes on cards off, as before; `MC-card-{clean,window}-edit`: an edit with
/// Claude's own Accept edits; `MC-card-clean-edit-bypass`: the edit in a session seen in bypass; `MC-card-clean-push`:
/// a push, whose suggestion is a rule only, with no mode; `MC-card-{clean,window}-crowded(-hints)`: the most a card
/// offers (No, Yes, Always allow, Accept edits, Bypass); `MC-settings-general`: Settings › General with the row.
@MainActor
@Suite(.serialized)
struct ModeRenders {
    typealias ID = FixtureSessionFeed.ID

    private func env(_ scenario: FixtureSessionFeed.Scenario, bypass: String? = nil, off: Bool = false) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        let env = AppEnvironment.demo(settings: settings, sessions: scenario)
        // A note in bypass from the session's agent: it was launched with bypass available (P451).
        if let bypass { env.fixtureFeed?.engine.loadPreviewNote(event: "PreToolUse", sessionID: bypass, permissionMode: "bypassPermissions") }
        if off { env.fixtureFeed?.engine.offersModeChoices = false }
        return env
    }

    /// A card as tall as it is, as the island (660 wide, under its 36 pt header) or the window (595) draws it.
    private func card(_ name: String, id: String, style: CardStyle, env: AppEnvironment, hints: Bool = false) throws {
        let card = try #require(env.sessions.card(for: id))
        let content = VStack(spacing: 0) {
            Color.black.frame(height: style == .window ? 8 : 36)
            SessionCardView(card: card, style: style).padding(.top, style == .islandClean ? 4 : style == .window ? 0 : 6)
        }
        .padding(.horizontal, style == .window ? 8 : 12)
        .padding(.bottom, 12)
        .frame(width: style == .window ? 595 : 660)
        .background(Color.black)
        .environment(\.sessionGlyphsAnimated, false)
        .environment(\.showsShortcutHints, hints)
        let probe = NSHostingView(rootView: content.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(content, name, size: probe.fittingSize, env: env)
    }

    private func modes(_ env: AppEnvironment, _ id: String) -> [ClaudePermissionMode] {
        switch env.sessions.card(for: id) {
        case let .plan(card)?: card.modes
        case let .approval(card)?: card.modes
        default: []
        }
    }

    @Test func cleanPlan() throws {
        let env = env(.allStates)
        #expect(modes(env, ID.plan) == [.acceptEdits, .default])
        try card("MC-card-clean-plan", id: ID.plan, style: .islandClean, env: env)
    }
    @Test func detailedPlan() throws { try card("MC-card-detailed-plan", id: ID.plan, style: .islandDetailed, env: env(.allStates)) }
    @Test func windowPlan() throws { try card("MC-card-window-plan", id: ID.plan, style: .window, env: env(.allStates)) }
    @Test func cleanPlanBypass() throws {
        let env = env(.allStates, bypass: ID.plan)
        #expect(modes(env, ID.plan) == [.bypassPermissions, .default])
        try card("MC-card-clean-plan-bypass", id: ID.plan, style: .islandClean, env: env)
    }
    @Test func cleanPlanHints() throws {
        try card("MC-card-clean-plan-hints", id: ID.plan, style: .islandClean, env: env(.allStates), hints: true)
    }
    @Test func cleanPlanOff() throws {
        let env = env(.allStates, off: true)
        #expect(modes(env, ID.plan).isEmpty)
        try card("MC-card-clean-plan-off", id: ID.plan, style: .islandClean, env: env)
    }
    @Test func cleanLongPlan() throws { try card("MC-card-clean-plan-long", id: ID.longPlan, style: .islandClean, env: env(.cards)) }

    @Test func cleanEdit() throws {
        let env = env(.cards)
        #expect(modes(env, ID.edit) == [.acceptEdits])
        try card("MC-card-clean-edit", id: ID.edit, style: .islandClean, env: env)
    }
    @Test func windowEdit() throws { try card("MC-card-window-edit", id: ID.edit, style: .window, env: env(.cards)) }
    @Test func cleanEditBypass() throws {
        let env = env(.cards, bypass: ID.edit)
        #expect(modes(env, ID.edit) == [.acceptEdits, .bypassPermissions])
        try card("MC-card-clean-edit-bypass", id: ID.edit, style: .islandClean, env: env)
    }
    @Test func cleanPush() throws {
        let env = env(.prototype)
        #expect(modes(env, ID.approval).isEmpty)
        try card("MC-card-clean-push", id: ID.approval, style: .islandClean, env: env)
    }

    /// The most a card can offer: a Bash command that makes folders, with Claude's rule and its Accept edits, in a session
    /// seen in bypass: No, Yes, Always allow, Accept edits and Bypass in one row (the island and the window).
    private func crowded(off: Bool = false) throws -> AppEnvironment {
        let env = env(.cards)
        let feed = try #require(env.fixtureFeed)
        let id = "demo-mode-crowded"
        feed.engine.loadPreviewEvents(FixtureSessionFeed.start(id, title: "Shoot the site's charts", project: "notes-site",
                                                               prompt: "shoot the charts", at: DemoClock.now - 300))
        feed.engine.loadPreviewNote(event: "PreToolUse", sessionID: id, permissionMode: "bypassPermissions")
        var request = FixtureSessionFeed.claudeRequest(id, tool: "Bash", useID: "toolu_demo_mode_mkdir", input: [
            "command": "mkdir -p site/shots/light site/shots/dark", "description": "Make the folders for the shots"])
        request["permission_suggestions"] = [
            ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "mkdir -p site/shots:*"]], "behavior": "allow",
             "destination": "localSettings"],
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ]
        feed.engine.loadPreviewHookRequest(request, source: "claude", entrypoint: "cli")
        #expect(modes(env, id) == [.acceptEdits, .bypassPermissions])
        return env
    }

    @Test func cleanCrowded() throws { try card("MC-card-clean-crowded", id: "demo-mode-crowded", style: .islandClean, env: try crowded()) }
    @Test func windowCrowded() throws { try card("MC-card-window-crowded", id: "demo-mode-crowded", style: .window, env: try crowded()) }
    @Test func windowCrowdedHints() throws {
        try card("MC-card-window-crowded-hints", id: "demo-mode-crowded", style: .window, env: try crowded(), hints: true)
    }

    @Test func settingsGeneral() throws {
        let env = AppEnvironment.demo(settings: AppSettings.ephemeral())
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .general), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "MC-settings-general", size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }
}
