import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// Switch to Juice (the owner's decision B, P955 to P957) in a temporary home: Vibe Island's entries are found, and on the
/// click taken out of each file after a backup, every other byte left; its OpenCode plugin goes whole; a file Juice will
/// not edit is left as it is; and ours connects afterwards. Nothing outside the temporary folder is read or written.
@MainActor
struct VibeIslandHooksTests {
    static let bridge = "/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"

    private final class Home {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: ProfileHookTargets.normalized(
                FileManager.default.temporaryDirectory.appendingPathComponent("ji-vibe-\(UUID().uuidString)").path), isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ path: String, _ text: String) throws -> URL {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            return file
        }

        func read(_ path: String) -> String? { try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path) }
        func names(_ folder: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent(folder).path)) ?? [] }
    }

    @Test
    func onlyItsBridgeIsVibeIslands() {
        #expect(VibeIslandHooks.isBridge(Self.bridge))
        #expect(VibeIslandHooks.isBridge("/Users/x/.vibe-island/bin/vibe-island-hook --source codex"))
        #expect(!VibeIslandHooks.isBridge("'/x/Library/Application Support/Juice Island/bin/JuiceHooks' --source claude"))
        #expect(!VibeIslandHooks.isBridge("'/x/Library/Application Support/OpenIsland/bin/OpenIslandHooks' --source claude"))
        #expect(!VibeIslandHooks.isBridge("~/bin/vibe-check.sh"))
    }

    /// What holds Connect back beside Vibe Island (the agents table, P933) is what the switch takes out: an owner's own
    /// script that only mentions Vibe Island in its name is neither, so it never leaves an agent that cannot connect after
    /// the switch.
    @Test
    func connectWaitsOnlyOnWhatTheSwitchTakesOut() {
        for command in [Self.bridge, "~/.vibe-island/bin/vibe-island-bridge --source cursor", "vibe-island-bridge --source copilot",
                        "~/scripts/vibe-island-notes.sh", "say done"] {
            #expect(HookFileEdits.isVibeIsland(command) == VibeIslandHooks.isBridge(command), "\(command)")
        }
        #expect(!HookFileEdits.isVibeIsland("~/scripts/vibe-island-notes.sh"))
    }

    /// Claude's settings with Vibe Island's entries beside the owner's own hook and Juice's: only Vibe Island's come out,
    /// a backup holds the file as it was, and the inspector then counts no Vibe Island entry.
    @Test
    func theSwitchTakesOutOnlyVibeIslandsEntriesAfterABackup() throws {
        let home = try Home()
        let own = #"{"type":"command","command":"~/bin/notify.sh"}"#
        let vibe = #"{"type":"command","command":"\#(Self.bridge)"}"#
        let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [{"hooks": [\(own), \(vibe)]}],
            "PermissionRequest": [{"matcher": "*", "hooks": [\(vibe)]}],
            "SessionStart": [{"hooks": [\(vibe)]}]
          }
        }

        """
        try home.write(".claude/settings.json", original)
        let places = VibeIslandHooks.places(home: home.url, profiles: [(.claude, home.url.appendingPathComponent(".claude").path)])
        let found = VibeIslandHooks.scan(places)
        #expect(found.count == 1)
        #expect(found.first?.entries == 3 && found.first?.place.agentID == "claude")
        #expect(home.read(".claude/settings.json") == original)

        let outcomes = VibeIslandHooks.remove(found, now: Date(timeIntervalSince1970: 1_800_000_000))
        let file = home.url.appendingPathComponent(".claude/settings.json")
        guard case let .removed(backup)? = outcomes[file] else { Issue.record("not removed: \(outcomes)"); return }
        #expect(backup.lastPathComponent == "settings.json.vibe-island-backup.2027-01-15T08-00-00Z")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let after = try #require(home.read(".claude/settings.json"))
        #expect(!after.contains("vibe-island") && after.contains("~/bin/notify.sh") && after.contains(#""model": "opus""#))
        #expect(after == """
        {
          "model": "opus",
          "hooks": {
            "Stop": [{"hooks": [\(own)]}]
          }
        }

        """)
        let target = ProfileHookTarget(provider: .claude, folder: file.deletingLastPathComponent().path, alias: "Main", isDefaultFolder: true,
                                       accountID: nil, isMonitored: true)
        let status = ProfileHookInspector.status(for: target, intent: .untouched, managedHelperURL: home.url.appendingPathComponent("bin/JuiceHooks"),
                                                 bundledHelperURL: home.url.appendingPathComponent("bundle/OpenIslandHooks"))
        #expect(status.vibeEntryCount == 0 && status.state == .notInstalled)
        #expect(VibeIslandHooks.scan(places).isEmpty)
    }

    /// Its OpenCode plugin goes whole (backed up under a name OpenCode does not load); Copilot's file of Vibe Island's
    /// only goes too; Cursor's shared file keeps the owner's entry.
    @Test
    func itsPluginAndItsOwnFilesGoAndSharedFilesKeepTheRest() throws {
        let home = try Home()
        try home.write(VibeIslandHooks.openCodePlugin, "export const VibeIsland = async () => ({})\n")
        try home.write(".config/opencode/plugins/mine.js", "export const Mine = async () => ({})\n")
        try home.write(".copilot/hooks/vibe-island.json",
                       #"{"version": 1, "hooks": {"sessionStart": [{"type": "command", "bash": "$HOME/.vibe-island/bin/vibe-island-bridge --source copilot"}]}}"#)
        try home.write(".cursor/hooks.json", """
        {"version": 1, "hooks": {"stop": [{"command": "~/bin/mine.sh"}, {"command": "$HOME/.vibe-island/bin/vibe-island-bridge --source cursor"}]}}
        """)
        let found = VibeIslandHooks.scan(VibeIslandHooks.places(home: home.url, profiles: []))
        #expect(Set(VibeIslandHooks.agents(found)) == ["opencode", "copilot", "cursor"])
        let outcomes = VibeIslandHooks.remove(found)
        #expect(outcomes.values.allSatisfy { if case .removed = $0 { true } else { false } })
        #expect(!home.exists(VibeIslandHooks.openCodePlugin) && home.exists(".config/opencode/plugins/mine.js"))
        #expect(home.names(".config/opencode/plugins").contains { $0.hasPrefix("vibe-island.js.vibe-island-backup.") && !$0.hasSuffix(".js") })
        #expect(!home.exists(".copilot/hooks/vibe-island.json"))
        #expect(!home.names(".copilot/hooks").contains { $0.hasSuffix(".json") })
        #expect(home.read(".cursor/hooks.json") == """
        {"version": 1, "hooks": {"stop": [{"command": "~/bin/mine.sh"}]}}
        """)
    }

    /// A file with comments, or a link, is never written: left, and said.
    @Test
    func aFileJuiceWillNotEditIsLeftAsItIs() throws {
        let home = try Home()
        let commented = "{\n  // mine\n  \"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"\(Self.bridge)\"}]}]}\n}\n"
        try home.write(".claude/settings.json", commented)
        let real = try home.write("elsewhere/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "\#(Self.bridge)"}]}]}}"#)
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent(".codex/hooks.json"), withDestinationURL: real)
        let found = VibeIslandHooks.scan(VibeIslandHooks.places(home: home.url, profiles: [
            (.claude, home.url.appendingPathComponent(".claude").path), (.codex, home.url.appendingPathComponent(".codex").path)]))
        #expect(found.count == 2 && found.allSatisfy(\.refused))
        let outcomes = VibeIslandHooks.remove(found)
        #expect(outcomes.values.allSatisfy { $0 == .left("Add by hand") })
        #expect(home.read(".claude/settings.json") == commented)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("vibe-island-bridge"))
        #expect(home.names(".claude") == ["settings.json"])
    }

    /// After the switch, ours connects where Vibe Island's held Install up (P904, P955).
    @Test
    func oursConnectsOnceVibeIslandsEntriesAreOut() async throws {
        let home = try Home()
        let folder = home.url.appendingPathComponent(".claude-vibe", isDirectory: true)
        try home.write(".claude-vibe/settings.json", #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(Self.bridge)"}]}]}}"#)
        let bundled = try home.write("bundle/OpenIslandHooks", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let suite = "VibeIslandHooksTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProfileHookManager(bundledHelperURL: bundled, managedHelperURL: home.url.appendingPathComponent("managed/bin/JuiceHooks"),
                                         intents: ProfileHookIntentStore(defaults: defaults), codexFeatureKey: { .current },
                                         isOpenIslandAppRunning: { false })
        let target = ProfileHookTarget(provider: .claude, folder: folder.path, alias: "Vibe", isDefaultFolder: false, accountID: nil,
                                       isMonitored: true)
        await manager.refresh([target])
        await #expect(throws: ProfileHookError.otherIslandHooksPresent(count: 1)) { try await manager.install(target) }
        _ = VibeIslandHooks.remove(VibeIslandHooks.scan(VibeIslandHooks.places(home: home.url, profiles: [(.claude, folder.path)])))
        try await manager.install(target)
        #expect(manager.statuses[target.id]?.state == .installed)
        let text = try #require(home.read(".claude-vibe/settings.json"))
        #expect(text.contains("JuiceHooks") && !text.contains("vibe-island"))
        // The switch's own backup survives the Connect's.
        #expect(home.names(".claude-vibe").contains { $0.hasPrefix("settings.json.vibe-island-backup.") })
    }
}

/// The first run's Start (P960): the terminal the owner uses, never launched to find out.
struct FirstSessionTerminalTests {
    @Test
    func theUsualTerminalIsTheRunningOneElseAnInstalledOneElseTerminal() {
        let ids = (terminal: "com.apple.Terminal", iterm: "com.googlecode.iterm2", ghostty: "com.mitchellh.ghostty")
        #expect(FreshSessionLaunch.usualHost(isRunning: { $0 == ids.iterm }, isInstalled: { _ in true }) == .iterm)
        #expect(FreshSessionLaunch.usualHost(isRunning: { $0 == ids.terminal }, isInstalled: { _ in true }) == .terminal)
        #expect(FreshSessionLaunch.usualHost(isRunning: { _ in false }, isInstalled: { $0 == ids.ghostty }) == .ghostty)
        #expect(FreshSessionLaunch.usualHost(isRunning: { _ in false }, isInstalled: { _ in false }) == .terminal)
        let launch = FreshSessionLaunch.firstSession(command: "claude", host: .terminal, home: "/tmp/ji-home")
        #expect(launch.line == "claude" && launch.folder == "/tmp/ji-home")
        #expect(FreshSessionLaunch.script(launch).contains(#"do script "claude""#))
        // In the latest session's folder when it is still there; else, or with none, the home folder.
        let folders: Set<String> = ["/tmp/ji-home/notes-site"]
        #expect(FreshSessionLaunch.firstSession(command: "claude", host: .terminal, folder: "/tmp/ji-home/notes-site", home: "/tmp/ji-home",
                                                isFolder: folders.contains).folder == "/tmp/ji-home/notes-site")
        #expect(FreshSessionLaunch.firstSession(command: "claude", host: .terminal, folder: "/tmp/ji-home/gone", home: "/tmp/ji-home",
                                                isFolder: folders.contains).folder == "/tmp/ji-home")
        #expect(FreshSessionLaunch.firstSession(command: "claude", host: .terminal, folder: nil, home: "/tmp/ji-home",
                                                isFolder: folders.contains).folder == "/tmp/ji-home")
    }
}
