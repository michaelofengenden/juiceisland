import AppKit
@testable import IslandEngine
import IslandHookNotes
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 4's lane GEMINI, headless (P1100 to P1124), every file named `gm-*`: Settings › Agents with Gemini CLI (its
/// settings carry a comment: Add by hand), Antigravity CLI (connected) and Grok Build (Connect), as `TableAgents` reads
/// a scratch home; and the island with Gemini CLI's ToolPermission notice (needs you, no Allow or Deny) beside an
/// Antigravity session with its own mark, on Black and Glass in Light and Dark. Scratch folders and made-up projects only.
@MainActor
@Suite(.serialized)
struct GeminiLaneRenders {
    nonisolated static let themes: [JuiceTheme] = [.black, .glass]
    nonisolated static let schemes: [ColorScheme] = [.light, .dark]

    static let antigravityID = "demo-antigravity-running"

    /// An Antigravity session as it reaches the engine: the PreInvocation note (`--source antigravity`), then what
    /// upstream's bridge makes of the helper's BeforeAgent (`AntigravityHooks.payload`): a Gemini CLI session with no
    /// prompt, which the note labels and shows (P1107).
    @discardableResult
    static func addAntigravity(_ feed: FixtureSessionFeed, at date: Date = DemoClock.now - 90) -> Bool {
        let hook = GeminiHookPayload(cwd: FixtureSessionFeed.folder("landing-page"), hookEventName: .beforeAgent, sessionID: antigravityID)
        guard feed.engine.loadPreviewNote(event: "PreInvocation", sessionID: antigravityID, source: "antigravity") else { return false }
        return feed.engine.loadPreviewEvents([
            .sessionStarted(SessionStarted(sessionID: antigravityID, title: hook.sessionTitle, tool: .geminiCLI, origin: .live,
                                           initialPhase: .completed, summary: hook.implicitSummary, timestamp: date,
                                           jumpTarget: hook.defaultJumpTarget)),
            .activityUpdated(SessionActivityUpdated(sessionID: antigravityID, summary: hook.implicitSummary, phase: .running,
                                                    timestamp: date + 1)),
        ])
    }

    /// The three rows as the app reads them, from a scratch home: Gemini CLI's settings with a comment, Antigravity
    /// CLI connected, Grok Build found by its folder.
    static func table() async throws -> (TableAgents, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ji-gm-render-\(UUID().uuidString)", isDirectory: true)
        for folder in [".gemini/tmp", ".gemini/config", ".gemini/antigravity-cli", ".grok/bin"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("{\n  // my theme\n  \"ui\": { \"theme\": \"GitHub\" }\n}\n".utf8).write(to: home.appendingPathComponent(".gemini/settings.json"))
        let installer = AgentHookInstaller(home: home, helperPath: home.path + "/support/bin/JuiceHooks", bundledHelper: HelperRun.binary,
                                           ownFileStem: "juice-island", bridgeSocketPath: home.path + "/support/b.sock")
        try installer.install(AgentHookTable.antigravity)
        let table = TableAgents(installer: installer, specs: [AgentHookTable.gemini, AgentHookTable.antigravity, AgentHookTable.grok],
                                directories: { [] })
        await table.readAgain()
        return (table, home)
    }

    @Test
    func agentsPane() async throws {
        let (table, home) = try await Self.table()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(table.rows.map(\.id) == ["gemini", "antigravity", "grok"])
        #expect(table.rows.allSatisfy { $0.reach == .watch })
        for theme in Self.themes {
            for scheme in Self.schemes {
                let env = AgentsRenders.environment(theme: theme, scheme: scheme)
                env.agentsPane.sources = [table]
                try AgentsRenders.render(.agents, "gm-settings-agents-\(theme.rawValue)-\(AgentsRenders.word(scheme))", env: env,
                                         scheme: scheme)
            }
        }
    }

    /// Gemini CLI's ToolPermission on the island: a notice card that says it needs you and where, with no Allow or Deny;
    /// and the opened list with it, the Antigravity session's arrowhead and OpenCode's question.
    @Test
    func watchNoticeOnTheIsland() throws {
        let id = FixtureSessionFeed.AgentID.geminiRunning
        for theme in Self.themes {
            for scheme in Self.schemes {
                let env = IslandGlassRenders.environment { settings in
                    settings.juiceTheme = theme
                    settings.appearance = scheme == .light ? .light : .dark
                }
                let demo = AppEnvironment.demo(settings: env.settings, sessions: .agentQuestion)
                let feed = try #require(demo.fixtureFeed)
                #expect(Self.addAntigravity(feed))
                #expect(feed.engine.loadPreviewNote(event: "Notification", sessionID: id, notificationType: "ToolPermission", source: "gemini"))
                guard case let .approval(card)? = demo.sessions.card(for: id) else {
                    Issue.record("no notice card")
                    return
                }
                #expect(card.isNotice && !card.isAnswerable)
                let backdrop: GlassBackdrop = scheme == .light ? .white : .busy
                let word = AgentsRenders.word(scheme)
                let cardUI = IslandGlassRenders.state(demo, surface: .island, card: id, events: [(0, .present(.card(sessionID: id)))], at: 1.5)
                try RenderHarness.render(AppearanceRenders.islandScene(cardUI, size: CGSize(width: 540, height: 330), backdrop: backdrop,
                                                                       theme: theme, scheme: scheme),
                                         "gm-card-gemini-notice-\(theme.rawValue)-\(word)", env: demo, scheme: scheme)
                let listUI = IslandGlassRenders.state(demo, surface: .island)
                try RenderHarness.render(AppearanceRenders.islandScene(listUI, size: CGSize(width: 540, height: 400), backdrop: backdrop,
                                                                       theme: theme, scheme: scheme),
                                         "gm-open-\(theme.rawValue)-\(word)", env: demo, scheme: scheme)
            }
        }
    }
}
