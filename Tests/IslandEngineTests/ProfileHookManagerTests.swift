import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// Every test works in its own temporary folder with fake profile names; nothing touches a real profile.
@MainActor
struct ProfileHookManagerTests {
    private final class Sandbox {
        let root: URL
        let bundledHelper: URL
        let managedHelper: URL
        let defaults: UserDefaults
        private let suite = "ProfileHookManagerTests-\(UUID().uuidString)"

        init() throws {
            root = URL(fileURLWithPath: ProfileHookTargets.normalized(
                FileManager.default.temporaryDirectory.appendingPathComponent("ji-hooks-\(UUID().uuidString)").path))
            bundledHelper = root.appendingPathComponent("bundle/OpenIslandHooks")
            managedHelper = root.appendingPathComponent("managed/bin/JuiceHooks")
            try FileManager.default.createDirectory(at: bundledHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundledHelper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHelper.path)
            defaults = UserDefaults(suiteName: suite)!
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        func profile(_ provider: Provider, _ name: String, files: [String: String] = [:]) throws -> ProfileHookTarget {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, contents) in files { try Data(contents.utf8).write(to: folder.appendingPathComponent(file)) }
            return ProfileHookTarget(provider: provider, folder: folder.path, alias: name, isDefaultFolder: false,
                                     accountID: nil, isMonitored: true)
        }

        @MainActor func manager(openIslandRunning: Bool = false) -> ProfileHookManager {
            ProfileHookManager(bundledHelperURL: bundledHelper, managedHelperURL: managedHelper,
                               intents: ProfileHookIntentStore(defaults: defaults), codexFeatureKey: { .current },
                               isOpenIslandAppRunning: { openIslandRunning })
        }

        func read(_ target: ProfileHookTarget, _ file: String) -> String? {
            try? String(contentsOf: URL(fileURLWithPath: target.folder).appendingPathComponent(file), encoding: .utf8)
        }
    }

    /// Install writes all 14 events naming Juice's own helper, backs the file up and writes no manifest: Open Island
    /// reads its own under that name (P900, P901).
    @Test
    func claudeInstallWritesAll14EventsABackupAndNoManifest() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work", files: ["settings.json": #"{"model":"opus"}"#])
        let manager = box.manager()
        await manager.refresh([target])
        #expect(manager.statuses[target.id]?.state == .notInstalled)

        let status = try await manager.install(target)
        #expect(status.state == .installed)
        #expect(status.managedEventCount == 14)
        #expect(status.intent == .installed)
        #expect(box.read(target, ClaudeHookInstallerManifest.fileName) == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: target.folder)
        #expect(files.contains { $0.hasPrefix("settings.json.backup.") })
        #expect(box.read(target, "settings.json")?.contains("\"model\"") == true)
        #expect(box.read(target, "settings.json")?.contains("JuiceHooks' --source claude") == true)
        #expect(FileManager.default.isExecutableFile(atPath: box.managedHelper.path))
    }

    /// Install then Remove gives every file back byte for byte, in whatever layout the owner keeps it (P916).
    @Test
    func installThenRemoveGivesEveryFileBackByteForByte() async throws {
        let box = try Sandbox()
        let claude = "{\n    \"model\": \"opus\",\n    \"hooks\": {\n        \"Stop\": [\n            {\n                \"hooks\": [\n                    {\"type\": \"command\", \"command\": \"say done\"}\n                ]\n            }\n        ]\n    }\n}\n"
        let compact = #"{"permissions":{"allow":["Bash(ls)"]}}"#
        let codexHooks = "{\n  \"hooks\": {\n    \"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"say done\"}]}]\n  }\n}\n"
        let pretty = try box.profile(.claude, ".claude-work", files: ["settings.json": claude])
        let oneLine = try box.profile(.claude, ".claude-lab", files: ["settings.json": compact])
        let codex = try box.profile(.codex, ".codex-side", files: ["hooks.json": codexHooks, "config.toml": "model = \"gpt-5\"\n"])
        let bare = try box.profile(.codex, ".codex-fresh")
        let switchedOff = "model = \"gpt-5\"\n\n[features]\ncodex_hooks = false\nweb_search = true\n"
        let off = try box.profile(.codex, ".codex-preset", files: ["config.toml": switchedOff])
        let manager = box.manager()
        await manager.refresh([pretty, oneLine, codex, bare, off])
        for target in [pretty, oneLine, codex, bare, off] { try await manager.install(target) }
        #expect(box.read(pretty, "settings.json")?.contains("say done") == true)
        #expect(box.read(off, "config.toml")?.contains("codex_hooks = false") == false)
        for target in [pretty, oneLine, codex, bare, off] { try await manager.remove(target) }
        #expect(box.read(pretty, "settings.json") == claude)
        #expect(box.read(oneLine, "settings.json") == compact)
        #expect(box.read(codex, "hooks.json") == codexHooks)
        // Codex's hooks feature stays on while someone else's hook needs it; Juice turns off only what it turned on.
        #expect(box.read(codex, "config.toml")?.hasPrefix("model = \"gpt-5\"\n") == true)
        #expect(box.read(codex, "config.toml")?.contains("hooks = true") == true)
        // The switch goes back as it was: a config.toml Install made goes, a line it turned on comes back (P910).
        #expect(box.read(bare, "hooks.json") == nil && box.read(bare, "config.toml") == nil)
        #expect(box.read(off, "config.toml") == switchedOff)
    }

    /// Hooks that still call Open Island's helper read as the old helper, with no drift row; Repair (Move) puts Juice's in
    /// their place and keeps everyone else's (P903).
    @Test
    func oldHelperHooksMoveToJuicesHelper() async throws {
        let box = try Sandbox()
        let old = "'/Users/test/Library/Application Support/OpenIsland/bin/OpenIslandHooks' --source claude"
        let settings = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)"}]},{"hooks":[{"type":"command","command":"say done"}]}],"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"\#(old)"}]}]}}"#
        let target = try box.profile(.claude, ".claude-work", files: ["settings.json": settings])
        // Juice set these up before its own helper (P932).
        ProfileHookIntentStore(defaults: box.defaults).setIntent(.installed, for: target.id)
        let manager = box.manager()
        await manager.refresh([target])
        await manager.checkDrift([target])
        #expect(manager.statuses[target.id]?.state == .oldHelper(entries: 2))
        #expect(manager.driftAlerts[target.id] == nil)
        #expect(manager.choice(for: target.id) == ProfileHookChoice(action: .repair, refusal: nil))

        let moved = try await manager.repair(target)
        #expect(moved.state == .installed && moved.oldEntryCount == 0)
        let text = try #require(box.read(target, "settings.json"))
        #expect(!text.contains("OpenIslandHooks") && text.contains("say done"))
    }

    /// Open Island's own hooks, in a profile Juice never set up: not Juice's to move. Connect puts Juice's beside them,
    /// they stay Open Island's afterwards, and Remove gives the file back byte for byte (P932).
    @Test
    func openIslandsOwnHooksAreNotJuicesToMove() async throws {
        let box = try Sandbox()
        let old = "'/Users/test/Library/Application Support/OpenIsland/bin/OpenIslandHooks' --source claude"
        let settings = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)"}]}]}}"#
        let target = try box.profile(.claude, ".claude-work", files: ["settings.json": settings])
        let manager = box.manager()
        await manager.refresh([target])
        await manager.checkDrift([target])
        #expect(manager.statuses[target.id]?.state == .notInstalled)
        #expect(manager.choice(for: target.id) == ProfileHookChoice(action: .install, refusal: nil))
        let installed = try await manager.install(target)
        #expect(installed.state == .installed && installed.oldEntryCount == 0)
        #expect(box.read(target, "settings.json")?.contains("OpenIslandHooks") == true)
        await manager.refresh([target])
        #expect(manager.statuses[target.id]?.state == .installed)
        try await manager.remove(target)
        #expect(box.read(target, "settings.json") == settings)
    }

    /// Remove (and so Remove from all agents) takes Juice's older entries, still on Open Island's helper, as well (P932).
    @Test
    func removeTakesJuicesOlderHooksToo() async throws {
        let box = try Sandbox()
        let old = "'/Users/test/Library/Application Support/OpenIsland/bin/OpenIslandHooks' --source claude"
        let settings = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)"}]}]}}"#
        let target = try box.profile(.claude, ".claude-work", files: ["settings.json": settings])
        ProfileHookIntentStore(defaults: box.defaults).setIntent(.installed, for: target.id)
        let manager = box.manager()
        await manager.refresh([target])
        let removed = try await manager.remove(target)
        #expect(removed.state == .notInstalled && box.read(target, "settings.json") == #"{"model":"opus"}"#)
    }

    /// Remove takes Juice's entries and nothing else: Open Island's helper and Vibe Island's stay (P904).
    @Test
    func removeLeavesOpenIslandsAndVibeIslandsHooks() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work")
        let manager = box.manager()
        await manager.refresh([target])
        try await manager.install(target)
        let url = URL(fileURLWithPath: target.folder).appendingPathComponent("settings.json")
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        var stop = try #require(hooks["Stop"] as? [[String: Any]])
        stop.append(["hooks": [["type": "command", "command": "/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"]]])
        hooks["Stop"] = stop
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: url)
        await manager.refresh([target])

        try await manager.remove(target)
        let text = try #require(box.read(target, "settings.json"))
        #expect(text.contains("vibe-island-bridge") && !text.contains("JuiceHooks"))
    }

    @Test
    func removeDeletesAHooksOnlySettingsFileAndKeepsOtherKeys() async throws {
        let box = try Sandbox()
        let bare = try box.profile(.claude, ".claude-bare")
        let kept = try box.profile(.claude, ".claude-kept", files: ["settings.json": #"{"model":"opus"}"#])
        let manager = box.manager()
        await manager.refresh([bare, kept])
        try await manager.install(bare)
        try await manager.install(kept)

        let bareStatus = try await manager.remove(bare)
        let keptStatus = try await manager.remove(kept)
        #expect(bareStatus.state == .notInstalled)
        #expect(bareStatus.intent == .removed)
        #expect(box.read(bare, "settings.json") == nil)
        #expect(keptStatus.state == .notInstalled)
        #expect(box.read(kept, "settings.json")?.contains("\"model\"") == true)
    }

    @Test
    func vibeIslandHooksBlockInstallAndTheFileStaysByteIdentical() async throws {
        let box = try Sandbox()
        let settings = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"}]}]}}"#
        let target = try box.profile(.claude, ".claude-vibe", files: ["settings.json": settings])
        let manager = box.manager()
        await manager.refresh([target])
        #expect(manager.statuses[target.id]?.state == .blockedByOtherIsland(vibeEntries: 1))
        await #expect(throws: ProfileHookError.otherIslandHooksPresent(count: 1)) {
            try await manager.install(target)
        }
        #expect(box.read(target, "settings.json") == settings)
    }

    @Test
    func unreadableConfigFilesStopInstallAndRemoveAndStayByteIdentical() async throws {
        let box = try Sandbox()
        let claude = try box.profile(.claude, ".claude-lab", files: ["settings.json": #"{"model":"opus"}"#])
        let codex = try box.profile(.codex, ".codex-side", files: ["auth.json": "{}"])
        let settingsURL = URL(fileURLWithPath: claude.folder).appendingPathComponent("settings.json")
        let configURL = URL(fileURLWithPath: codex.folder).appendingPathComponent("config.toml")
        var config = Data("model = \"gpt-5\"\n# ".utf8)
        config.append(0xFF)
        try config.write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settingsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settingsURL.path) }

        let manager = box.manager()
        await manager.refresh([claude, codex])
        #expect(manager.statuses[claude.id]?.state == .unreadable(file: "settings.json"))
        #expect(manager.statuses[codex.id]?.state == .unreadable(file: "config.toml"))
        for (target, file) in [(claude, "settings.json"), (codex, "config.toml")] {
            await #expect(throws: ProfileHookError.invalidConfig(file: file)) { try await manager.install(target) }
            await #expect(throws: ProfileHookError.invalidConfig(file: file)) { try await manager.remove(target) }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settingsURL.path)
        #expect(try Data(contentsOf: settingsURL) == Data(#"{"model":"opus"}"#.utf8))
        #expect(try Data(contentsOf: configURL) == config)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: codex.folder).appendingPathComponent("hooks.json").path))
    }

    @Test
    func symlinkedConfigFilesAreRefusedAndStayLinks() async throws {
        let box = try Sandbox()
        let dotfiles = box.root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let settingsTarget = dotfiles.appendingPathComponent("claude-settings.json")
        let configTarget = dotfiles.appendingPathComponent("codex-config.toml")
        try Data(#"{"model":"opus"}"#.utf8).write(to: settingsTarget)
        try Data("model = \"gpt-5\"\n".utf8).write(to: configTarget)
        let claude = try box.profile(.claude, ".claude-work")
        let codex = try box.profile(.codex, ".codex-side", files: ["auth.json": "{}"])
        let settingsLink = URL(fileURLWithPath: claude.folder).appendingPathComponent("settings.json")
        let configLink = URL(fileURLWithPath: codex.folder).appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: settingsLink, withDestinationURL: settingsTarget)
        try FileManager.default.createSymbolicLink(at: configLink, withDestinationURL: configTarget)

        let manager = box.manager()
        await manager.refresh([claude, codex])
        #expect(manager.statuses[claude.id]?.state == .linkedConfig(file: "settings.json"))
        #expect(manager.statuses[codex.id]?.state == .linkedConfig(file: "config.toml"))
        for (target, file) in [(claude, "settings.json"), (codex, "config.toml")] {
            await #expect(throws: ProfileHookError.linkedConfig(file: file)) { try await manager.install(target) }
            await #expect(throws: ProfileHookError.linkedConfig(file: file)) { try await manager.remove(target) }
        }
        for link in [settingsLink, configLink] {
            let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
            #expect(type == .typeSymbolicLink)
        }
        #expect(try Data(contentsOf: settingsTarget) == Data(#"{"model":"opus"}"#.utf8))
        #expect(try Data(contentsOf: configTarget) == Data("model = \"gpt-5\"\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: codex.folder).appendingPathComponent("hooks.json").path))
    }

    @Test
    func aConfigWithCommentsIsReportedAndNeverRewritten() async throws {
        let box = try Sandbox()
        let settings = "{\n  // my model\n  \"model\": \"opus\", \"url\": \"https://example.com/a//b\"\n}\n"
        let hooks = "{ /* kept by hand */ \"hooks\": {} }"
        let claude = try box.profile(.claude, ".claude-lab", files: ["settings.json": settings])
        let codex = try box.profile(.codex, ".codex-fresh", files: ["hooks.json": hooks])
        let manager = box.manager()
        await manager.refresh([claude, codex])
        #expect(manager.statuses[claude.id]?.state == .hasComments(file: "settings.json"))
        #expect(manager.statuses[codex.id]?.state == .hasComments(file: "hooks.json"))
        for (target, file) in [(claude, "settings.json"), (codex, "hooks.json")] {
            await #expect(throws: ProfileHookError.hasComments(file: file)) { try await manager.install(target) }
            await #expect(throws: ProfileHookError.hasComments(file: file)) { try await manager.remove(target) }
        }
        #expect(box.read(claude, "settings.json") == settings)
        #expect(box.read(codex, "hooks.json") == hooks)
        #expect(JSONComments.stripped(#"{"url":"https://example.com/a//b"}"#) == nil)
    }

    @Test
    func onlyTheNewestThreeUpstreamBackupsOfAFileAreKept() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work", files: ["settings.json": #"{"model":"opus"}"#])
        let folder = URL(fileURLWithPath: target.folder)
        let old = (1...4).map { "settings.json.backup.2025-0\($0)-01T10-00-00Z" }
        let others = ["settings.json.backup", "settings.json.backup.2025-01-01", "settings.json.bak",
                      "hooks.json.backup.2025-01-01T10-00-00Z", "other-settings.json.backup.2025-01-01T10-00-00Z"]
        for name in old + others { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }

        let manager = box.manager()
        await manager.refresh([target])
        try await manager.install(target)
        let names = try FileManager.default.contentsOfDirectory(atPath: target.folder)
        let kept = HookBackups.backups(of: "settings.json", in: names)
        #expect(kept.count == 3)
        #expect(Array(kept.suffix(2)) == ["settings.json.backup.2025-04-01T10-00-00Z", "settings.json.backup.2025-03-01T10-00-00Z"])
        #expect(kept.first?.hasPrefix("settings.json.backup.20") == true && !old.contains(kept[0]))
        for name in others { #expect(names.contains(name)) }
    }

    /// Open Island running holds nothing up any more: Juice's hooks name its own helper (P900).
    @Test
    func openIslandRunningHoldsNothingUp() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work")
        let manager = box.manager(openIslandRunning: true)
        await manager.refresh([target])
        #expect(try await manager.install(target).state == .installed)
    }

    @Test
    func codexInstallTurnsTheFeatureOnAndWaitsForHooksReview() async throws {
        let box = try Sandbox()
        let target = try box.profile(.codex, ".codex-side", files: ["auth.json": "{}"])
        let manager = box.manager()
        await manager.refresh([target])
        let installed = try await manager.install(target)
        #expect(box.read(target, "config.toml")?.contains("hooks = true") == true)
        #expect(installed.codexFeatureEnabled == true)
        #expect(installed.state == .codexNeedsTrust(untrustedEvents: CodexHookEvents.all))

        // What Codex writes after `/hooks` approves each entry (hash values are placeholders).
        let hooksFile = URL(fileURLWithPath: target.folder).appendingPathComponent("hooks.json").path
        let groups = ProfileHookInspector.hookGroups(in: URL(fileURLWithPath: hooksFile))
        var config = box.read(target, "config.toml") ?? ""
        for event in CodexHookEvents.all {
            let group = try #require(groups[event]?.firstIndex { !$0.isEmpty })
            config += "\n[hooks.state.\"\(CodexTrustScanner.key(hooksFile: hooksFile, event: event, group: group, hook: 0))\"]\ntrusted_hash = \"x\"\n"
        }
        try Data(config.utf8).write(to: URL(fileURLWithPath: target.folder).appendingPathComponent("config.toml"))
        await manager.refresh([target])
        #expect(manager.statuses[target.id]?.state == .installed)
    }

    @Test
    func codexRemoveTurnsTheFeatureOffOnlyWhenTheInstallerTurnedItOn() async throws {
        let box = try Sandbox()
        let fresh = try box.profile(.codex, ".codex-fresh", files: ["auth.json": "{}"])
        let preset = try box.profile(.codex, ".codex-preset", files: ["config.toml": "[features]\nhooks = true\n"])
        let manager = box.manager()
        await manager.refresh([fresh, preset])
        try await manager.install(fresh)
        try await manager.install(preset)
        try await manager.remove(fresh)
        try await manager.remove(preset)
        #expect(CodexHookInstaller.isCodexHooksFeatureEnabled(in: box.read(fresh, "config.toml") ?? "") == false)
        #expect(CodexHookInstaller.isCodexHooksFeatureEnabled(in: box.read(preset, "config.toml") ?? "") == true)
    }

    @Test
    func helperSyncOnlyReplacesAnInstalledHelper() throws {
        let box = try Sandbox()
        let manager = box.manager()
        #expect(try manager.syncHelperIfPresent() == false)
        #expect(!FileManager.default.fileExists(atPath: box.managedHelper.path))

        try FileManager.default.createDirectory(at: box.managedHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: box.managedHelper)
        #expect(try manager.syncHelperIfPresent() == true)
        #expect(ProfileHookInspector.filesMatch(box.managedHelper, box.bundledHelper, fileManager: .default))
        #expect(try manager.syncHelperIfPresent() == false)
    }

    /// Juice's own helper is updated whether Open Island runs or not, and no staging file is left (P900).
    @Test
    func helperSyncLeavesNoStagingFileWhateverOpenIslandDoes() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.managedHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: box.managedHelper)
        #expect(try box.manager(openIslandRunning: true).syncHelperIfPresent() == true)
        let folder = try FileManager.default.contentsOfDirectory(atPath: box.managedHelper.deletingLastPathComponent().path)
        #expect(folder == ["JuiceHooks"])
        #expect(FileManager.default.isExecutableFile(atPath: box.managedHelper.path))
    }

    @Test
    func aMissingFolderIsReportedAndRefused() async throws {
        let box = try Sandbox()
        let target = ProfileHookTarget(provider: .claude, folder: box.root.appendingPathComponent(".claude-gone").path,
                                       alias: "gone", isDefaultFolder: false, accountID: nil, isMonitored: true)
        let manager = box.manager()
        await manager.refresh([target])
        #expect(manager.statuses[target.id]?.state == .folderMissing)
        await #expect(throws: ProfileHookError.folderMissing) {
            try await manager.install(target)
        }
    }
}
