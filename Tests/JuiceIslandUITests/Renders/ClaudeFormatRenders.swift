import AppKit
import Foundation
@testable import IslandEngine
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 4's Claude-format agents, headless (P1125 to P1149), every file named `cf-*`: Settings › Agents with Qoder,
/// CodeBuddy, Factory Droid and Kimi Code under wave 1's rows, their states read by the real installer from a scratch
/// home (Connected, Connect, Add by hand, the older Kimi CLI), on Black and Glass in Light and Dark; and each agent's
/// card in the island in the same four looks: Qoder's and CodeBuddy's approvals with Allow and Deny, Factory Droid's
/// and Kimi Code's "needs you" with neither (Watch). Fixture folders and sessions only; nothing is read from this Mac.
@MainActor
@Suite(.serialized)
struct ClaudeFormatRenders {
    typealias Look = AlertsRenders.Look

    /// A scratch home holding the four agents' files as `files` gives them, then Connect on `connect`.
    static func table(_ files: [String: String], connect: [AgentHookSpec]) async throws -> TableAgents {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ji-cf-render-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let installer = AgentHookInstaller(home: home, helperPath: "/tmp/ji-render-home/Library/Application Support/Juice Island/bin/JuiceHooks",
                                           bundledHelper: nil, ownFileStem: "juice-island", bridgeSocketPath: "/tmp/ji-render-home/bridge.sock")
        for spec in connect { try installer.install(spec) }
        let table = TableAgents(installer: installer, specs: AgentHookTable.claudeFormat, directories: { [] })
        await table.readAgain()
        return table
    }

    /// Qoder Connected, CodeBuddy to connect, Factory Droid's hooks in `settings.json` (Connect writes there, P1126),
    /// Kimi Code to connect.
    static func usual() async throws -> TableAgents {
        try await table([
            ".qoder/settings.json": "{\n  \"model\": \"auto\"\n}\n",
            ".codebuddy/settings.json": "{\n  \"permissions\": { \"allow\": [\"Read\"] }\n}\n",
            ".factory/settings.json": #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
            ".kimi-code/config.toml": "default_model = \"kimi-k2\"\n",
        ], connect: [AgentHookTable.qoder])
    }

    /// Qoder's file has comments and Kimi Code's ends without a newline (both Add by hand); CodeBuddy and Droid are
    /// Connected, Droid in its own `hooks.json`.
    static func byHand() async throws -> TableAgents {
        try await table([
            ".qoder/settings.json": "{\n  // the IDE's\n  \"model\": \"auto\"\n}\n",
            ".codebuddy/settings.json": "{}\n",
            ".factory/hooks.json": "{}\n",
            ".kimi-code/config.toml": "default_model = \"kimi-k2\"",
        ], connect: [AgentHookTable.codebuddy, AgentHookTable.factory])
    }

    /// Only the older Kimi CLI's folder: its row says Kimi CLI and its file (P1132), Connected.
    static func kimiCLI() async throws -> TableAgents {
        let older = try #require(AgentHookTable.kimi.elsewhere.first)
        return try await table([".kimi/config.toml": "default_model = \"kimi-k2\"\n"], connect: [older])
    }

    static func clear(_ table: TableAgents) { try? FileManager.default.removeItem(at: table.installer.home) }

    static func environment(_ table: TableAgents, theme: JuiceTheme, scheme: ColorScheme) -> AppEnvironment {
        let env = AgentsRenders.environment(theme: theme, scheme: scheme)
        env.agentsPane.sources = [AgentsRenders.TableSource(rows: AgentsRenders.tableRows(), notFound: []), table]
        return env
    }

    @Test(arguments: AgentsRenders.themes, AgentsRenders.schemes)
    func agentsPane(_ theme: JuiceTheme, _ scheme: ColorScheme) async throws {
        let table = try await Self.usual()
        defer { Self.clear(table) }
        #expect(table.rows.map(\.name) == ["Qoder", "CodeBuddy", "Factory Droid", "Kimi Code"])
        #expect(table.rows.first?.status == .connected)
        try AgentsRenders.render(.agents, "cf-settings-agents-\(theme.rawValue)-\(AgentsRenders.word(scheme))",
                                 env: Self.environment(table, theme: theme, scheme: scheme), scheme: scheme)
    }

    @Test func agentsPaneAddByHand() async throws {
        let table = try await Self.byHand()
        defer { Self.clear(table) }
        #expect(table.rows.map(\.place) == ["~/.qoder/settings.json", "~/.codebuddy/settings.json", "~/.factory/hooks.json",
                                            "~/.kimi-code/config.toml"])
        for (theme, scheme) in [(JuiceTheme.black, ColorScheme.dark), (.glass, .light)] {
            try AgentsRenders.render(.agents, "cf-settings-agents-by-hand-\(theme.rawValue)-\(AgentsRenders.word(scheme))",
                                     env: Self.environment(table, theme: theme, scheme: scheme), scheme: scheme)
        }
    }

    @Test func agentsPaneKimiCLI() async throws {
        let table = try await Self.kimiCLI()
        defer { Self.clear(table) }
        #expect(table.rows.map(\.name) == ["Kimi CLI"] && table.rows.first?.place == "~/.kimi/config.toml")
        try AgentsRenders.render(.agents, "cf-settings-agents-kimi-cli-black-dark",
                                 env: Self.environment(table, theme: .black, scheme: .dark), scheme: .dark)
    }

    // MARK: Cards

    enum ID {
        static let qoder = "demo-qoder-push"
        static let codebuddy = "demo-codebuddy-push"
        static let factory = "demo-factory-notice"
        static let kimi = "demo-kimi-notice"
    }

    /// One agent's session in an otherwise empty island, as the bridge and the helper's note give it.
    static func card(_ id: String, look: Look) throws -> AppEnvironment {
        let settings = AlertsRenders.settings(look.theme, look.scheme)
        let env = AppEnvironment.demo(settings: settings, sessions: .empty)
        let feed = try #require(env.fixtureFeed)
        let now = DemoClock.now
        let push = ClaudeHookJSONValue.object(["command": .string("git push origin main"), "description": .string("Push the fix")])
        switch id {
        case ID.qoder, ID.codebuddy:
            // Approve: the bridge's request, answered from the card (Claude's own output, P1125, P1128).
            let source = id == ID.qoder ? "qoder" : "codebuddy"
            feed.engine.loadPreviewEvents(FixtureSessionFeed.claudeFork(id, source: source, project: "notes-site", prompt: "push the fix",
                                                                        at: now - 240)
                + [FixtureSessionFeed.forkApproval(id, source: source, project: "notes-site", tool: "Bash", input: push,
                                                   useID: "call_\(source)_push", at: now - 30)])
        case ID.factory:
            // Watch: Droid's `permission_prompt`, the bridge's line for it, and the helper's note (P1129).
            feed.engine.loadPreviewEvents(FixtureSessionFeed.claudeFork(id, source: "factory", project: "juice-island",
                                                                        prompt: "check the release script", at: now - 240)
                + [notice(id, "Droid needs your permission to use Execute", at: now - 30)])
            feed.engine.loadPreviewNote(event: "Notification", sessionID: id, notificationType: "permission_prompt", source: "factory")
        default:
            // Watch: Kimi's PermissionRequest as the helper shapes it; no prompt event is installed (P1131).
            feed.engine.loadPreviewEvents(Array(FixtureSessionFeed.claudeFork(id, source: "kimi", project: "juice-island",
                                                                              prompt: "", at: now - 240).prefix(1))
                + [notice(id, "Kimi Code needs your permission to use Shell", at: now - 30)])
            feed.engine.loadPreviewNote(event: "Notification", sessionID: id, notificationType: "permission_prompt", source: "kimi")
        }
        return env
    }

    /// What upstream's bridge emits for a Claude-format Notification: the message as the row's line.
    static func notice(_ id: String, _ message: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: message, phase: .running, timestamp: date))
    }

    @Test(arguments: [ID.qoder, ID.codebuddy, ID.factory, ID.kimi])
    func card(_ id: String) throws {
        for look in AlertsRenders.looks {
            let env = try Self.card(id, look: look)
            let state = AlertsRenders.card(env, id)
            try RenderHarness.render(AlertsRenders.scene(state, look: look, size: CGSize(width: 540, height: 300)),
                                     "cf-card-\(id.replacingOccurrences(of: "demo-", with: ""))-\(look.name)", env: env, scheme: look.scheme)
        }
    }
}
