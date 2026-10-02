import AppKit
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 6's cards and rows in the live island at the widths it offers (not the 660 pt card harness), with and without ⌃
/// held. `SH-crowded-{clean,detailed}-{460,480}(-hints)`: the most a card offers (No, Yes, Always allow's rule, Accept
/// edits, Bypass), its mode buttons on a line of their own when the row is wider than the lane (P490);
/// `SH-edit-clean-480-hints`: Claude's rule and Accept edits with ⌃ held; `SH-push-clean-{460,480}-hints`: the prototype's
/// push; `SH-plan-clean-{460,480}(-15)`: a plan's buttons; `SH-done-{table,code,links}-clean-460-15`: a Done card's
/// message, grid and box at Text size 15 (P491); `SH-details-detailed-{460,480}-15`: Detailed rows at 15 pt, each line's
/// tags on that line and the state word whole (P492). Nothing is shown on screen: `zsh scripts/render-all.sh ShipRenders`.
@MainActor
@Suite(.serialized)
struct ShipRenders {
    typealias ID = FixtureSessionFeed.ID
    static let notch = IslandTheme.Metrics.referenceNotch

    private func crowdedEnv(_ style: IslandStyle, bypass: Bool = true, long: Bool = true) throws -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        let env = AppEnvironment.demo(settings: settings, sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        let id = "demo-mode-crowded"
        feed.engine.loadPreviewEvents(FixtureSessionFeed.start(id, title: "Shoot the site's charts", project: "notes-site",
                                                               prompt: "shoot the charts", at: DemoClock.now - 300))
        if bypass { feed.engine.loadPreviewNote(event: "PreToolUse", sessionID: id, permissionMode: "bypassPermissions") }
        var request = FixtureSessionFeed.claudeRequest(id, tool: "Bash", useID: "toolu_demo_mode_mkdir", input: [
            "command": "mkdir -p site/shots/light site/shots/dark", "description": "Make the folders for the shots"])
        request["permission_suggestions"] = [
            ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": long ? "mkdir -p site/shots/light:*" : "mkdir -p site/shots:*"]],
             "behavior": "allow", "destination": "localSettings"],
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ]
        feed.engine.loadPreviewHookRequest(request, source: "claude", entrypoint: "cli")
        return env
    }

    private func render(_ name: String, _ presentation: IslandPresentation, env: AppEnvironment, size: IslandSize, hints: Bool = false) throws {
        let view = OpenedIslandView(presentation: presentation, notch: Self.notch, ui: IslandUIState(), animated: false)
            .environment(\.islandSize, size)
            .environment(\.showsShortcutHints, hints)
            .environment(\.sessionGlyphsAnimated, false)
        let scene = DScene.island(view, notch: Self.notch)
        if presentation == .list {
            try RenderHarness.render(scene, name, env: env)
            return
        }
        // Cards hold AppKit text fields, which `ImageRenderer` leaves blank: draw them hosted, at the scene's own size.
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    @Test func crowded() throws {
        for style in [IslandStyle.clean, .detailed] {
            for width in [460, 480] {
                for hints in [false, true] {
                    try render("SH-crowded-\(style.rawValue)-\(width)\(hints ? "-hints" : "")", .card(sessionID: "demo-mode-crowded"),
                               env: try crowdedEnv(style), size: IslandSize(width: width, text: 12), hints: hints)
                }
            }
        }
    }

    @Test func editWithHints() throws {
        try render("SH-edit-clean-480-hints", .card(sessionID: "demo-mode-crowded"), env: try crowdedEnv(.clean, bypass: false, long: false),
                   size: IslandSize(width: 480, text: 12), hints: true)
        try render("SH-edit-clean-480", .card(sessionID: "demo-mode-crowded"), env: try crowdedEnv(.clean, bypass: false, long: false),
                   size: IslandSize(width: 480, text: 12))
    }

    @Test func push() throws {
        for width in [460, 480] {
            let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .prototype)
            try render("SH-push-clean-\(width)-hints", .card(sessionID: ID.approval), env: env, size: IslandSize(width: width, text: 12), hints: true)
        }
    }

    @Test func plan() throws {
        for (width, text) in [(460, 12), (480, 12), (460, 15), (480, 15)] {
            let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .allStates)
            try render("SH-plan-clean-\(width)\(text == 15 ? "-15" : "")", .card(sessionID: ID.plan), env: env,
                       size: IslandSize(width: width, text: text))
        }
    }

    @Test func done() throws {
        for (name, id) in [("table", FixtureSessionFeed.RepliesID.table), ("code", FixtureSessionFeed.RepliesID.code),
                           ("links", FixtureSessionFeed.RepliesID.links)] {
            let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .replies)
            try render("SH-done-\(name)-clean-460-15", .card(sessionID: id), env: env, size: IslandSize(width: 460, text: 15))
        }
    }

    @Test func details() throws {
        for width in [460, 480] {
            let settings = AppSettings.ephemeral()
            settings.islandStyle = .detailed
            let env = AppEnvironment.demo(settings: settings, sessions: .details)
            try render("SH-details-detailed-\(width)-15", .list, env: env, size: IslandSize(width: width, text: 15))
        }
    }
}
