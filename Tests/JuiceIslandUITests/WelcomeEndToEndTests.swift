import Foundation
import IslandHookNotes
import JuiceCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 2 end to end, in a temporary home (P950 to P957, P962): the launch's own decision (`WelcomeGate.atLaunch`, as
/// the shell makes it) over a fresh defaults suite, then the welcome's model over the real Agents pane, `ProfileHooks`
/// and `TableAgents` (wave 1's `AgentsEndToEndTests.World`). A stranger's first launch shows the welcome; walking it
/// writes nothing; Connect writes exactly the ticked agents' files, each one that was there backed up first; a second
/// launch, and the owner's Mac (Juice's hooks there, no earlier setting), never show it. Vibe Island's hooks are taken
/// out by Switch to Juice with a backup of each file, then Remove from all agents gives back the files as the switch
/// left them. No app is asked to quit and no terminal opens: the services read and write only the scratch home.
@MainActor
@Suite(.serialized)
struct WelcomeEndToEndTests {
    typealias World = AgentsEndToEndTests.World

    /// The welcome's services over a scratch home: Vibe Island's entries found and taken out there as the app does it
    /// (`LiveWelcomeServices.vibeIsland`, `VibeIslandHooks.remove`), without asking any app to quit.
    @MainActor
    final class ScratchServices: WelcomeServices {
        let home: URL
        private(set) var calls: [String] = []
        init(home: URL) { self.home = home }

        var openIslandRunning: Bool { false }
        var hasNotch: Bool { true }
        var terminalName: String { "Terminal" }

        func findVibeIsland() async -> [VibeIslandHooks.Found] {
            let home = home.path
            return await Task.detached { LiveWelcomeServices.vibeIsland(home: home) }.value
        }

        func switchFromVibeIsland(_ found: [VibeIslandHooks.Found]) async -> [URL: VibeIslandHooks.Outcome] {
            calls.append("switch \(found.count)")
            return await Task.detached { VibeIslandHooks.remove(found) }.value
        }

        func askOpenIslandToQuit() { calls.append("quit Open Island") }
        func start(command: String, folder: String?) async -> Bool {
            calls.append("start \(command)")
            return false
        }
        func copy(_ text: String) { calls.append("copy") }
        func chime() { calls.append("chime") }
    }

    /// A defaults suite of its own, as a Mac where this app never ran.
    @MainActor
    final class Suite {
        let name = "ji.test.welcome-e2e.\(UUID().uuidString)"
        /// The settings as one launch loads them.
        func launch() -> AppSettings {
            AppSettings(defaults: UserDefaults(suiteName: name), identity: .development, domain: name)
        }
        func remove() { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    }

    /// Every file under `home`, by its path there, with its bytes.
    static func snapshot(_ home: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let base = home.resolvingSymlinksInPath().path
        guard let walk = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let path = url.resolvingSymlinksInPath().path
            files[String(path.dropFirst(base.count + 1))] = data
        }
        return files
    }

    static func isBackup(_ path: String) -> Bool { path.contains(".backup.") || path.contains(".vibe-island-backup.") }

    /// The app's environment over the world's real pane and hooks.
    static func environment(_ world: World, settings: AppSettings) -> AppEnvironment {
        let env = AppEnvironment.demo(settings: settings, sessions: .empty)
        env.hooks = world.hooks
        env.agentsPane = world.pane
        return env
    }

    static func line(_ model: WelcomeModel, _ name: String) -> WelcomeModel.Line? { model.lines.first { $0.name == name } }

    static func object(_ data: Data?) -> NSDictionary? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
    }

    // MARK: A stranger's Mac

    /// First launch: the welcome; Hello and Agents write nothing; Connect writes exactly the ticked agents, backing up
    /// each file that was there; Qwen Code, unticked, is left byte for byte. The next launch is not a first run.
    @Test
    func aStrangersFirstLaunchConnectsOnlyWhatIsTickedAndTheNextLaunchShowsNoWelcome() async throws {
        let world = try await World()
        let suite = Suite()
        defer {
            world.stop()
            suite.remove()
        }
        let hookHome = try #require(world.rig.hookHome)
        let original = Self.snapshot(world.home)

        let first = suite.launch()
        #expect(!first.hadEarlierLaunch)
        #expect(WelcomeGate.atLaunch(first, juiceHooks: WelcomeGate.juiceHooksPresent(home: world.home.path, publicFolder: nil)))
        #expect(first.loginItemAwaitsChoice && first.welcomeSeen && first.newAgents.isEmpty)

        let model = WelcomeModel(env: Self.environment(world, settings: first), services: ScratchServices(home: world.home))
        #expect(model.step == .hello)
        model.primary()
        #expect(model.step == .agents)
        await world.ready(AgentsEndToEndTests.agents)
        let names = ["Claude Code", "Codex", "Copilot CLI", "Cursor", "Qwen Code", "Kilo"]
        #expect(await world.rig.waitUntil { names.allSatisfy { Self.line(model, $0)?.state == .tick(true) } })
        #expect(!model.showsVibeCard)

        // Nothing written before the click, not even the helper.
        #expect(Self.snapshot(world.home) == original)
        #expect(!FileManager.default.fileExists(atPath: hookHome.helperURL.path))

        let qwen = try #require(Self.line(model, "Qwen Code"))
        model.toggle(qwen.id)
        #expect(Self.line(model, "Qwen Code")?.state == .tick(false))
        #expect(WelcomeText.agentsButton(model).hasPrefix(WelcomeText.connect))
        model.primary()
        let chosen = names.filter { $0 != "Qwen Code" }
        #expect(await world.rig.waitUntil {
            chosen.allSatisfy { name in Self.line(model, name).map { $0.state == .connected || $0.state == .trust } ?? false }
        })
        #expect(WelcomeText.agentsButton(model) == "Next")
        #expect(FileManager.default.fileExists(atPath: hookHome.helperURL.path))

        // Exactly the ticked agents' files changed or appeared.
        let after = Self.snapshot(world.home)
        let changed = Set(after.keys.filter { !Self.isBackup($0) && after[$0] != original[$0] })
        #expect(changed == [".claude/settings.json", ".codex/hooks.json", ".codex/config.toml", ".copilot/hooks/juice-island.json",
                            ".cursor/hooks.json", ".config/kilo/plugin/juice-island.js"])
        #expect(Set(original.keys).isSubset(of: Set(after.keys)))
        #expect(after[".qwen/settings.json"] == original[".qwen/settings.json"])
        #expect(!after.keys.contains { $0.hasPrefix(".qwen/") && Self.isBackup($0) })
        for path in [".claude/settings.json", ".codex/hooks.json", ".copilot/hooks/juice-island.json", ".cursor/hooks.json"] {
            #expect(String(decoding: after[path] ?? Data(), as: UTF8.self).contains(hookHome.helperURL.path), "\(path)")
        }
        // Each file that was there is backed up first, as it was.
        for path in changed where original[path] != nil {
            let backups = after.filter { $0.key.hasPrefix(path + ".backup.") }
            #expect(backups.count == 1, "\(path) has \(backups.count) backups")
            #expect(backups.values.first == original[path], "\(path)'s backup is not the file as it was")
        }
        // The owner's own hooks stay beside Juice's.
        #expect(String(decoding: after[".claude/settings.json"] ?? Data(), as: UTF8.self).contains("say done"))
        #expect(String(decoding: after[".cursor/hooks.json"] ?? Data(), as: UTF8.self).contains("say done"))

        // The next launch: an earlier launch, so no welcome, and Launch at Login is not held back again.
        let second = suite.launch()
        #expect(second.hadEarlierLaunch && second.welcomeSeen)
        #expect(!WelcomeGate.atLaunch(second, juiceHooks: false))
        // Nor on this Mac with the defaults gone: Juice's hooks are there now.
        let fresh = Suite()
        defer { fresh.remove() }
        #expect(!WelcomeGate.atLaunch(fresh.launch(), juiceHooks: WelcomeGate.juiceHooksPresent(home: world.home.path, publicFolder: nil)))
    }

    // MARK: The owner's Mac

    /// Juice's hooks are there and no setting of ours is (a new user account, or defaults cleared): no welcome, and
    /// Launch at Login is not held back. The public flavor's helper alone counts too.
    @Test
    func theOwnersMacNeverShowsTheWelcome() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("ji-welcome-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude-work", isDirectory: true)
        try fileManager.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: claude.appendingPathComponent(".claude.json"))
        let helper = HookHome(supportFolderNamed: AppFlavor.privateProductName, home: home.path).helperURL.path
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'\#(helper)' --source claude"}]}]}}"#.utf8)
            .write(to: claude.appendingPathComponent("settings.json"))
        let before = Self.snapshot(home)

        let suite = Suite()
        defer { suite.remove() }
        let settings = suite.launch()
        #expect(!settings.hadEarlierLaunch)
        #expect(!WelcomeGate.atLaunch(settings, juiceHooks: WelcomeGate.juiceHooksPresent(home: home.path, publicFolder: nil)))
        #expect(!settings.loginItemAwaitsChoice)
        #expect(Self.snapshot(home) == before)

        // A Mac that ran the public Juice: its helper in its own home, no hook file read at all.
        try fileManager.removeItem(at: claude)
        let publicHelper = HookHome(supportFolderNamed: "org.example.juice", home: home.path).helperURL
        try fileManager.createDirectory(at: publicHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: publicHelper)
        let other = Suite()
        defer { other.remove() }
        #expect(!WelcomeGate.atLaunch(other.launch(), juiceHooks: WelcomeGate.juiceHooksPresent(home: home.path,
                                                                                                publicFolder: "org.example.juice")))
    }

    // MARK: Vibe Island

    static let vibeClaude = "/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"
    static let vibeFiles: [String: String] = [
        ".claude/settings.json": """
            {
              "model": "opus",
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "say done" } ] },
                  { "hooks": [ { "type": "command", "command": "\(vibeClaude)" } ] }
                ],
                "PreToolUse": [
                  { "matcher": "*", "hooks": [ { "type": "command", "command": "\(vibeClaude)" } ] }
                ]
              }
            }

            """,
        ".claude/.claude.json": "{}",
        ".cursor/hooks.json": """
            {
              "version": 1,
              "hooks": {
                "stop": [
                  { "command": "say done" },
                  { "command": "~/.vibe-island/bin/vibe-island-bridge --source cursor" }
                ]
              }
            }

            """,
        ".config/opencode/plugins/vibe-island.js": "// Vibe Island's plugin for OpenCode\nexport const VibeIsland = async () => ({})\n",
    ]

    /// Vibe Island's hooks in Claude's and Cursor's files and its OpenCode plugin: its agents wait on its card, and
    /// walking writes nothing. Switch to Juice backs each file up as Vibe Island left it, takes out only its entries and
    /// its plugin, then connects Juice. Remove from all agents takes Juice's out again: each file is what the switch
    /// left, the owner's own hook still in, and the switch's backups still hold Vibe Island's files byte for byte.
    @Test
    func switchToJuiceTakesOutOnlyVibeIslandsAndRemoveGivesBackTheSwitchedFiles() async throws {
        let world = try await World(files: Self.vibeFiles, folders: [], commands: ["claude", "cursor-agent"], openCode: true)
        let suite = Suite()
        defer {
            world.stop()
            suite.remove()
        }
        let original = Self.snapshot(world.home)
        let settings = suite.launch()
        // Vibe Island's hooks are not Juice's: still a stranger's Mac.
        #expect(WelcomeGate.atLaunch(settings, juiceHooks: WelcomeGate.juiceHooksPresent(home: world.home.path, publicFolder: nil)))

        let services = ScratchServices(home: world.home)
        let model = WelcomeModel(env: Self.environment(world, settings: settings), services: services)
        model.primary()
        await world.ready(["claude", "cursor", AgentRowText.openCodeID])
        #expect(await world.rig.waitUntil { model.showsVibeCard })
        #expect(model.vibeAgents == ["claude", "cursor", AgentRowText.openCodeID])
        #expect(WelcomeText.vibeCard(agents: model.vibeAgents.count) == "Vibe Island is connected to 3 agents.")
        for name in ["Claude Code", "Cursor", "OpenCode"] { #expect(Self.line(model, name)?.state == .vibe, "\(name)") }
        #expect(Self.snapshot(world.home) == original)

        model.switchToJuice()
        #expect(await world.rig.waitUntil { model.vibeChoice == .switched })
        #expect(await world.rig.waitUntil {
            ["Claude Code", "Cursor", "OpenCode"].allSatisfy { Self.line(model, $0)?.state == .connected }
        })
        #expect(services.calls == ["switch 3"])

        // The switch's backups hold Vibe Island's files as they were.
        let switched = Self.snapshot(world.home)
        for path in [".claude/settings.json", ".cursor/hooks.json", ".config/opencode/plugins/vibe-island.js"] {
            let backups = switched.filter { $0.key.hasPrefix(path + ".vibe-island-backup.") }
            #expect(backups.count == 1 && backups.values.first == original[path], "\(path)")
        }
        #expect(switched[".config/opencode/plugins/vibe-island.js"] == nil)
        #expect(switched[".config/opencode/plugins/juice-island.js"] != nil)
        for path in [".claude/settings.json", ".cursor/hooks.json"] {
            let text = String(decoding: switched[path] ?? Data(), as: UTF8.self)
            #expect(!text.contains("vibe-island") && text.contains("say done") && text.contains(HookHome.helperName), "\(path)")
        }

        // Remove from all agents: Juice's lines and plugin out; each file as the switch left it.
        world.pane.removeFromAll()
        #expect(await world.rig.waitUntil {
            ["claude", "cursor", AgentRowText.openCodeID].allSatisfy { id in
                world.row(id).map { !$0.busy && !AgentRowText.isConnected($0.status) } ?? false
            }
        })
        let removed = Self.snapshot(world.home)
        #expect(removed[".config/opencode/plugins/juice-island.js"] == nil)
        #expect(removed[".config/opencode/plugins/vibe-island.js"] == nil)
        let layouts: [String: AgentHookSpec.Layout] = [".claude/settings.json": .claudeGroups, ".cursor/hooks.json": .cursor]
        for (path, layout) in layouts {
            let fixture = try #require(original[path])
            let expected = try HookFileEdits.removing(fixture, layout: layout, owners: VibeIslandHooks.owners)
            #expect(Self.object(removed[path]) == Self.object(expected), "\(path) is not the file the switch left")
            let text = String(decoding: removed[path] ?? Data(), as: UTF8.self)
            #expect(text.contains("say done") && !text.contains(HookHome.helperName) && !text.contains("vibe-island"), "\(path)")
            let backups = removed.filter { $0.key.hasPrefix(path + ".vibe-island-backup.") }
            #expect(backups.values.first == fixture, "\(path)'s switch backup changed")
        }
    }
}
