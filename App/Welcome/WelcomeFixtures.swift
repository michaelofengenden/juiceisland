import Foundation
import IslandEngine
import IslandHookNotes
import JuiceCore

/// The welcome on a made-up Mac, for renders (`ob-welcome-*`, the README's `readme-agents`) and tests: Claude Code with
/// Main and Work, Codex with Home, OpenCode, Copilot CLI and Cursor. Fictional folders, no email; nothing is read from
/// this Mac and every button records only.
extension WelcomeModel {
    /// What the made-up Mac holds.
    enum FixtureMac: Equatable, Sendable {
        /// Nothing connected yet.
        case fresh
        /// After Connect: everything in, Codex waiting on its trust.
        case connected
        /// Vibe Island's hooks in Claude's and Codex's folders, OpenCode's plugin and Cursor's file.
        case vibeIsland
        /// No agent at all.
        case empty
    }

    static func fixture(step: Step, env: AppEnvironment, mac: FixtureMac = .fresh, openIslandRunning: Bool = false,
                        hasNotch: Bool = true, firstRun: Bool = true) -> WelcomeModel {
        env.hooks = WelcomeFixtureHooks(mac)
        env.agentsPane.answersCodex = { true }
        env.agentsPane.sources = [WelcomeFixtureAgents(mac)]
        let services = FixtureWelcomeServices(openIslandRunning: openIslandRunning, hasNotch: hasNotch,
                                              vibe: mac == .vibeIsland ? fixtureVibe : [])
        let model = WelcomeModel(env: env, services: services, step: step, firstRun: firstRun)
        model.showsLaunchAtLogin = true
        model.vibe = services.vibe
        if mac == .connected { model.connectClicked = true }
        return model
    }

    /// Vibe Island's entries on the made-up Mac.
    static let fixtureVibe: [VibeIslandHooks.Found] = [
        VibeIslandHooks.Found(place: .init(agent: "Claude Code", agentID: "claude", url: URL(fileURLWithPath: "/tmp/ji-welcome/.claude/settings.json"),
                                           layout: .claudeGroups), entries: 14, refused: false),
        VibeIslandHooks.Found(place: .init(agent: "Codex", agentID: "codex", url: URL(fileURLWithPath: "/tmp/ji-welcome/.codex/hooks.json"),
                                           layout: .claudeGroups), entries: 5, refused: false),
        VibeIslandHooks.Found(place: .init(agent: "OpenCode", agentID: "opencode",
                                           url: URL(fileURLWithPath: "/tmp/ji-welcome/" + VibeIslandHooks.openCodePlugin), layout: .plugin),
                              entries: 1, refused: false),
        VibeIslandHooks.Found(place: .init(agent: "Cursor", agentID: "cursor", url: URL(fileURLWithPath: "/tmp/ji-welcome/.cursor/hooks.json"),
                                           layout: .cursor), entries: 5, refused: false),
    ]
}

/// The made-up Mac's Claude and Codex folders and OpenCode row.
@MainActor
final class WelcomeFixtureHooks: HooksModel {
    let rows: [HookSetupRow]
    let alerts: [HookDriftAlert] = []
    let integrations = HookIntegrations(openIslandRunning: false, vibeProfiles: 0, helperInBuild: true)
    let lastEvents: [String: Date] = [:]
    let openCodeRow: OpenCodeSetupRow?
    private(set) var runs: [(ProfileHookAction, [String])] = []

    init(_ mac: WelcomeModel.FixtureMac) {
        func row(_ alias: String, _ provider: Provider, _ folder: String, _ state: ProfileHookStatus.State,
                 action: ProfileHookAction?, refusal: String? = nil) -> HookSetupRow {
            HookSetupRow(id: Account.id(provider: provider, folder: folder), provider: provider, alias: alias, folder: folder,
                         word: HookRowText.word(for: state), detail: nil, tone: HookRowText.isProblem(state) ? .amber : .normal,
                         action: action, refusal: refusal, busy: false, events: "", isMonitored: true, state: state)
        }
        switch mac {
        case .fresh:
            rows = [row("Main", .claude, "~/.claude", .notInstalled, action: .install),
                    row("Work", .claude, "~/.claude-work", .notInstalled, action: .install),
                    row("Home", .codex, "~/.codex", .notInstalled, action: .install)]
            openCodeRow = OpenCodeSetupRow(title: "OpenCode", folder: "~/.config/opencode", word: OpenCodeWords.missing, tone: .normal,
                                           action: .install, refusal: nil, busy: false)
        case .connected:
            rows = [row("Main", .claude, "~/.claude", .installed, action: .remove),
                    row("Work", .claude, "~/.claude-work", .installed, action: .remove),
                    row("Home", .codex, "~/.codex", .codexNeedsTrust(untrustedEvents: ["Stop"]), action: .remove)]
            openCodeRow = OpenCodeSetupRow(title: "OpenCode", folder: "~/.config/opencode", word: OpenCodeWords.installed, tone: .normal,
                                           action: .remove, refusal: nil, busy: false)
        case .vibeIsland:
            let held = HookRowText.refusal(.otherIslandHooks(count: 14))
            rows = [row("Main", .claude, "~/.claude", .blockedByOtherIsland(vibeEntries: 14), action: .install, refusal: held),
                    row("Work", .claude, "~/.claude-work", .notInstalled, action: .install),
                    row("Home", .codex, "~/.codex", .blockedByOtherIsland(vibeEntries: 5), action: .install,
                        refusal: HookRowText.refusal(.otherIslandHooks(count: 5)))]
            openCodeRow = OpenCodeSetupRow(title: "OpenCode", folder: "~/.config/opencode", word: OpenCodeWords.missing, tone: .normal,
                                           action: .install, refusal: nil, busy: false)
        case .empty:
            rows = []
            openCodeRow = nil
        }
    }

    /// OpenCode's Connect clicks.
    private(set) var openCodeClicks = 0

    func clickRefusal(for id: String) -> String? { nil }
    func performOpenCode() { openCodeClicks += 1 }
    func perform(_ action: ProfileHookAction, on id: String) { runs.append((action, [id])) }
    func run(_ action: ProfileHookAction, on ids: [String]) { runs.append((action, ids)) }
    func installAllMonitored() {}
    func activate() {}
}

/// The made-up Mac's other agents: Copilot CLI (Approve) and Cursor (Watch).
@MainActor
final class WelcomeFixtureAgents: AgentRowSource {
    let rows: [AgentRow]
    let notFound: [String]
    private(set) var performed: [(AgentRowAction, String)] = []

    init(_ mac: WelcomeModel.FixtureMac) {
        let connected = mac == .connected
        guard mac != .empty else {
            rows = []
            notFound = AgentHookTable.wave1.map(\.name)
            return
        }
        rows = [
            AgentRow(id: AgentKind.copilot.rawValue, name: "Copilot CLI", look: AgentLook.of(GlyphPalette.Agent.kind(.copilot)),
                     reach: .approve, place: "~/.copilot/hooks/juice-island.json", status: connected ? .connected : .notConnected,
                     actions: connected ? [.remove] : [.connect]),
            AgentRow(id: AgentKind.cursor.rawValue, name: "Cursor", look: AgentLook.of(.other(.cursor)), reach: .watch,
                     place: "~/.cursor/hooks.json", status: connected ? .connected : .notConnected, actions: connected ? [.remove] : [.connect]),
        ]
        notFound = ["Qwen Code", "Devin", "Kilo"]
    }

    func perform(_ action: AgentRowAction, on id: String) { performed.append((action, id)) }
    func refresh() {}
}
