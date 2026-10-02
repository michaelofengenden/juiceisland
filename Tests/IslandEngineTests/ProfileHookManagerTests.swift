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
            managedHelper = root.appendingPathComponent("managed/bin/OpenIslandHooks")
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

    @Test
    func claudeInstallWritesAll14EventsAManifestAndABackup() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work", files: ["settings.json": #"{"model":"opus"}"#])
        let manager = box.manager()
        await manager.refresh([target])
        #expect(manager.statuses[target.id]?.state == .notInstalled)

        let status = try await manager.install(target)
        #expect(status.state == .installed)
        #expect(status.managedEventCount == 14)
        #expect(status.intent == .installed)
        #expect(box.read(target, ClaudeHookInstallerManifest.fileName) != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: target.folder)
        #expect(files.contains { $0.hasPrefix("settings.json.backup.") })
        #expect(box.read(target, "settings.json")?.contains("\"model\"") == true)
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
    func removeRefusesWhileVibeHooksArePresentAndTheFileStaysByteIdentical() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work")
        let manager = box.manager()
        await manager.refresh([target])
        try await manager.install(target)

        // Vibe Island adds its hook after ours. Upstream's Claude uninstaller would delete it along with ours.
        let settingsURL = URL(fileURLWithPath: target.folder).appendingPathComponent("settings.json")
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        var stop = try #require(hooks["Stop"] as? [[String: Any]])
        stop.append(["hooks": [["type": "command", "command": "/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"]]])
        hooks["Stop"] = stop
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: settingsURL)
        let before = try Data(contentsOf: settingsURL)

        await #expect(throws: ProfileHookError.otherIslandHooksPresent(count: 1)) {
            try await manager.remove(target)
        }
        #expect(try Data(contentsOf: settingsURL) == before)
        #expect(manager.statuses[target.id]?.vibeEntryCount == 1)
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

    @Test
    func nothingIsWrittenWhileOpenIslandRuns() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work")
        let manager = box.manager(openIslandRunning: true)
        await manager.refresh([target])
        await #expect(throws: ProfileHookError.openIslandAppRunning) {
            try await manager.install(target)
        }
        #expect(box.read(target, "settings.json") == nil)
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

    @Test
    func helperSyncWaitsForOpenIslandToQuitAndLeavesNoStagingFile() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.managedHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: box.managedHelper)
        #expect(throws: ProfileHookError.openIslandAppRunning) {
            try box.manager(openIslandRunning: true).syncHelperIfPresent()
        }
        #expect(try Data(contentsOf: box.managedHelper) == Data("old".utf8))

        #expect(try box.manager().syncHelperIfPresent() == true)
        let folder = try FileManager.default.contentsOfDirectory(atPath: box.managedHelper.deletingLastPathComponent().path)
        #expect(folder == ["OpenIslandHooks"])
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
