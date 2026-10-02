import AppKit
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The public README's screenshots (P845), headless, from demo data only: the demo's fictional accounts and money, and
/// four sessions in fictional folders (Claude asks to run a command, Claude edits a file, Codex runs a command, Codex is
/// done). Files `readme-window`, `readme-island`, `readme-approval` and `readme-panel`; `JI_RENDER_DIR=<folder>` writes
/// them there (the README's images are `docs/public/images` here, `docs/images` in the public repository). Nothing is
/// shown on screen: `zsh scripts/render-all.sh ReadmeShotRenders`.
@MainActor
@Suite(.serialized)
struct ReadmeShotRenders {
    static let ask = "readme-ask"
    static let edit = "readme-edit"
    static let codexRun = "readme-codex-run"
    static let codexDone = "readme-codex-done"
    /// The folders the shots may name: none is a real project.
    static let folders: Set<String> = ["notes-site", "field-notes"]

    static func environment() throws -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .section
        settings.islandShowsMoney = true
        settings.glyphStyle = .pixel
        let env = AppEnvironment.demo(settings: settings, sessions: .empty)
        let feed = try #require(env.fixtureFeed)
        let now = DemoClock.now, m: TimeInterval = 60
        var events = FixtureSessionFeed.start(edit, title: "Tighten the card spacing", project: "field-notes",
                                              prompt: "tighten the cards", at: now - 18 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: edit, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "tighten the cards", currentTool: "Edit", currentToolInputPreview: "Sources/Cards/CardView.swift"),
            timestamp: now - 2 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: edit, summary: "Running Edit", phase: .running, timestamp: now - 2 * m)))
        events += FixtureSessionFeed.start(codexRun, title: "Resize the site's images", project: "notes-site",
                                           prompt: "resize the images", tool: .codex, at: now - 12 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: codexRun, codexMetadata: CodexSessionMetadata(
            transcriptPath: FixtureSessionFeed.demoRollout(codexRun), lastUserPrompt: "resize the images", currentTool: "exec_command", currentCommandPreview: "sips -Z 512 *.png"),
            timestamp: now - 1 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: codexRun, summary: "Running exec_command", phase: .running,
                                                              timestamp: now - 1 * m)))
        events += FixtureSessionFeed.start(codexDone, title: "Draft the release notes", project: "notes-site",
                                           prompt: "draft the release notes", tool: .codex, at: now - 40 * m)
        events.append(.sessionCompleted(SessionCompleted(sessionID: codexDone, summary: "Drafted the notes.", timestamp: now - 9 * m)))
        events += FixtureSessionFeed.start(ask, title: "Shoot the site's charts", project: "notes-site", prompt: "shoot the charts",
                                           at: now - 5 * m)
        feed.engine.loadPreviewEvents(events)
        let request = FixtureSessionFeed.claudeRequest(ask, tool: "Bash", useID: "toolu_readme_mkdir", input: [
            "command": "mkdir -p site/shots/light site/shots/dark", "description": "Make the folders for the shots"])
        #expect(feed.engine.loadPreviewHookRequest(request, source: "claude", entrypoint: "cli"))
        return env
    }

    /// Every session the shots show is one of these four, in a fictional folder.
    @Test func theShotsShowOnlyFictionalFolders() throws {
        let env = try Self.environment()
        #expect(Set(env.sessions.rows.map(\.id)) == [Self.ask, Self.edit, Self.codexRun, Self.codexDone])
        #expect(Set(env.sessions.rows.compactMap(\.project)).isSubset(of: Self.folders))
    }

    @Test func window() throws {
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                       "readme-window", size: CGSize(width: 1100, height: 640), env: try Self.environment())
    }

    @Test func island() throws {
        let env = try Self.environment()
        let scene = AppearanceRenders.islandScene(IslandGlassRenders.state(env, surface: .island), size: CGSize(width: 540, height: 340),
                                                  backdrop: .preview, theme: .black, scheme: .dark)
        try RenderHarness.render(scene, "readme-island", env: env)
    }

    @Test func approval() throws {
        let env = try Self.environment()
        let ui = IslandGlassRenders.state(env, surface: .island, card: Self.ask, events: [(0, .present(.card(sessionID: Self.ask)))], at: 1.5)
        let scene = AppearanceRenders.islandScene(ui, size: CGSize(width: 540, height: 330), backdrop: .preview, theme: .black, scheme: .dark)
        try RenderHarness.render(scene, "readme-approval", env: env)
    }

    @Test func panel() throws {
        let env = try Self.environment()
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), "readme-panel",
                                 size: PanelGeometry.windowSize(for: size), env: env, background: PRenders.wallpaper)
    }
}
