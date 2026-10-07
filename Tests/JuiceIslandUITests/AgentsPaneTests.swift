import Foundation
import JuiceCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Settings › Agents (P935 to P939): the rows' words and buttons as pure functions of Setup's folder rows, the "Add by
/// hand" lines, the model over hooks and the agents table's sources, Remove from all agents, and finding agents on a
/// Mac. Temporary folders with the fixture names only; nothing reads or writes the real home, a hook or a helper.
@MainActor
struct AgentsPaneTests {
    // MARK: Fixtures

    static func folder(_ provider: Provider, _ name: String, _ state: ProfileHookStatus.State?, action: ProfileHookAction?,
                       refusal: String? = nil, moves: Bool = false, busy: Bool = false, detail: String? = nil) -> HookSetupRow {
        HookSetupRow(id: "\(provider.rawValue):\(name)", provider: provider, alias: name, folder: "~/" + name,
                     word: state.map(HookRowText.word(for:)) ?? "…", detail: detail, tone: .normal, action: action, refusal: refusal,
                     busy: busy, events: "", isMonitored: true, state: state, movesToJuiceHelper: moves)
    }

    final class Hooks: HooksModel {
        var rows: [HookSetupRow]
        var alerts: [HookDriftAlert] = []
        var integrations = HookIntegrations(openIslandRunning: false, vibeProfiles: 0, helperInBuild: true)
        var lastEvents: [String: Date] = [:]
        var openCodeRow: OpenCodeSetupRow?
        var runs: [String] = []
        var openCode: [String] = []
        var refreshes = 0

        init(_ rows: [HookSetupRow], openCode: OpenCodeSetupRow? = nil) {
            self.rows = rows
            openCodeRow = openCode
        }

        func clickRefusal(for id: String) -> String? { nil }
        func perform(_ action: ProfileHookAction, on id: String) { runs.append("\(action) \(id)") }
        func run(_ action: ProfileHookAction, on ids: [String]) { runs.append("\(action) \(ids.joined(separator: ","))") }
        func installAllMonitored() {}
        func activate() {}
        func performOpenCode() { openCode.append("perform") }
        func removeOpenCode() { openCode.append("remove") }
        func refreshOpenCode() { refreshes += 1 }
    }

    final class Source: AgentRowSource {
        var rows: [AgentRow]
        var notFound: [String]
        var performed: [String] = []
        var refreshes = 0

        init(_ rows: [AgentRow], notFound: [String] = []) {
            self.rows = rows
            self.notFound = notFound
        }

        func perform(_ action: AgentRowAction, on id: String) { performed.append("\(action.rawValue) \(id)") }
        func refresh() { refreshes += 1 }
    }

    static func agent(_ id: String, _ name: String, _ status: AgentRowStatus, actions: [AgentRowAction], reach: AgentReach = .approve,
                      refusal: String? = nil) -> AgentRow {
        AgentRow(id: id, name: name, look: AgentLook(name: name, mark: .tile(String(name.prefix(1))), colour: .gray), reach: reach,
                 place: "~/.\(id)/hooks.json", status: status, actions: actions, refusal: refusal)
    }

    static func openCodeRow(_ word: String, action: OpenCodePluginAction?, refusal: String? = nil) -> OpenCodeSetupRow {
        OpenCodeSetupRow(title: "OpenCode", folder: "~/.config/opencode", word: word, tone: .normal, action: action, refusal: refusal,
                         busy: false)
    }

    // MARK: Words

    /// Each folder state in Agents' words (P936): Connect and Not connected for Install and Not installed, Codex's trust
    /// with Copy /hooks and why, Open Island's helper with Move, and every other state with Setup's word.
    @Test func everyFolderStateReadsInAgentsWords() {
        let helper = "/tmp/ji-helper/OpenIslandHooks"
        func status(_ row: HookSetupRow) -> AgentRowStatus { AgentRowText.profileStatus(row, helperPath: helper) }

        #expect(status(Self.folder(.claude, ".claude", nil, action: nil)) == .checking)
        #expect(status(Self.folder(.claude, ".claude", .installed, action: .remove)) == .connected)
        let fresh = Self.folder(.codex, ".codex-fresh", .notInstalled, action: .install)
        #expect(status(fresh) == .notConnected && status(fresh).word == "Not connected" && !status(fresh).isAmber)
        #expect(AgentRowText.profileButton(fresh) == "Connect")

        let trust = status(Self.folder(.codex, ".codex-side", .codexNeedsTrust(untrustedEvents: ["Stop"]), action: .remove))
        #expect(trust == .needsCodexTrust && trust.word == "Needs Codex trust" && trust.isAmber)
        #expect(trust.detail == "Codex runs new hooks only after you trust them.")
        #expect(trust.copy?.title == "Copy /hooks" && trust.copy?.text == "/hooks")

        let old = Self.folder(.claude, ".claude-lab", .installed, action: .repair, moves: true)
        #expect(status(old) == .moveToJuiceHelper && status(old).word == "Move to \(Product.name)'s helper")
        #expect(status(old).detail == "They still call Open Island's helper.")
        #expect(AgentRowText.profileButton(old) == "Move")
        #expect(AgentRowText.profileButton(Self.folder(.claude, ".claude-lab", .partial(installed: 12, expected: 14), action: .repair)) == "Repair")

        let partial = status(Self.folder(.claude, ".claude-lab", .partial(installed: 12, expected: 14), action: .repair,
                                         detail: "Missing Notification, PreCompact"))
        #expect(partial == .attention(word: "Partial 12/14", detail: "Missing Notification, PreCompact") && partial.isAmber)
        #expect(status(Self.folder(.claude, ".claude", .blockedByOtherIsland(vibeEntries: 14), action: nil))
                == .attention(word: "Vibe Island hooks", detail: "Remove Vibe Island's hooks first"))
        #expect(status(Self.folder(.codex, ".codex-preset", .unreadable(file: "config.toml"), action: nil)).word == "Unreadable")

        // A file Juice will not edit: Add by hand, its file named, and Copy snippet; the row's refusal is not repeated.
        let linked = status(Self.folder(.claude, ".claude-work", .linkedConfig(file: "settings.json"), action: nil,
                                        refusal: "Edit settings.json by hand"))
        guard case let .addByHand(file, snippet, _) = linked else { Issue.record("not Add by hand: \(linked)"); return }
        #expect(file == "settings.json" && linked.word == "Add by hand" && linked.detail == "Paste it into settings.json.")
        #expect(linked.copy?.title == "Copy snippet" && linked.copy?.text == snippet && snippet.contains(helper))
        let toml = status(Self.folder(.codex, ".codex-side", .linkedConfig(file: "config.toml"), action: nil))
        #expect(toml == .addByHand(file: "config.toml", snippet: "[features]\nhooks = true"))
    }

    /// "Add by hand" pastes exactly what Connect writes (P938): the `"hooks"` member of the file the installer makes
    /// from nothing, so a file holding only it reads the same as the installer's, and a file with its own keys keeps them.
    @Test func theSnippetIsWhatConnectWouldWrite() throws {
        let helper = "/tmp/ji helper/OpenIslandHooks"
        func object(_ text: String) throws -> NSDictionary {
            try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        }
        let claude = try #require(AgentSnippets.profile(.claude, file: "settings.json", helperPath: helper))
        let claudeFile = try #require(try ClaudeHookInstaller.installSettingsJSON(
            existingData: nil, hookCommand: ClaudeHookInstaller.hookCommand(for: helper)).contents)
        #expect(try object("{\n" + claude + "\n}") == (try JSONSerialization.jsonObject(with: claudeFile) as? NSDictionary))
        #expect(claude.hasPrefix("\"hooks\"") && claude.contains("--source claude"))
        // Plain slashes, as a person would type the path; the helper's path quoted for the shell.
        #expect(claude.contains("'\(helper)' --source claude") && !claude.contains("\\/"))
        // Pasted beside the owner's own keys.
        let mine = try object("{\n  \"model\": \"opus\",\n" + claude + "\n}")
        #expect(mine["model"] as? String == "opus" && mine["hooks"] != nil)

        let codex = try #require(AgentSnippets.profile(.codex, file: "hooks.json", helperPath: helper))
        let codexFile = try #require(try CodexHookInstaller.installHooksJSON(
            existingData: nil, hookCommand: CodexHookInstaller.hookCommand(for: helper)).contents)
        #expect(try object("{\n" + codex + "\n}") == (try JSONSerialization.jsonObject(with: codexFile) as? NSDictionary))
        #expect(AgentSnippets.profile(.claude, file: "config.toml", helperPath: helper) == nil)
        #expect(AgentSnippets.member(Data("[]".utf8)) == nil)
    }

    // MARK: Claude's and Codex's own rows

    /// A parent row sums its folders (P936): connected, Not connected, "2 of 3 connected", Move, Codex's trust; a folder
    /// that is gone counts for nothing; a refusal every folder shares is the row's, and then no button shows.
    @Test func aParentRowSumsItsFolders() {
        func parent(_ provider: Provider, _ rows: [HookSetupRow]) -> AgentRow {
            AgentRowText.parent(provider, profiles: rows, helperPath: "/tmp/h", reach: .approve)
        }
        let main = Self.folder(.claude, ".claude", .installed, action: .remove)
        let work = Self.folder(.claude, ".claude-work", .notInstalled, action: .install)
        let lab = Self.folder(.claude, ".claude-lab", .installed, action: .remove)
        let gone = Self.folder(.claude, ".claude-gone", .folderMissing, action: nil, refusal: "Folder missing")

        let some = parent(.claude, [main, work, lab, gone])
        #expect(some.status == .partly(connected: 2, of: 3) && some.status.word == "2 of 3 connected")
        #expect(some.actions == [.connect] && some.refusal == nil && some.profiles.count == 4 && some.name == "Claude Code")

        let all = parent(.claude, [main, lab, gone])
        #expect(all.status == .connected && all.actions == [.remove])
        #expect(parent(.claude, [work]).status == .notConnected && parent(.claude, [work]).actions == [.connect])

        let moving = parent(.claude, [main, Self.folder(.claude, ".claude-lab", .installed, action: .repair, moves: true)])
        #expect(moving.status == .moveToJuiceHelper && moving.actions == [.move])

        let side = Self.folder(.codex, ".codex-side", .codexNeedsTrust(untrustedEvents: ["Stop"]), action: .remove)
        let codex = parent(.codex, [side, Self.folder(.codex, ".codex", .installed, action: .remove)])
        #expect(codex.status == .needsCodexTrust && codex.actions == [.remove] && codex.name == "Codex" && codex.status.copy?.text == "/hooks")

        // Open Island running: every folder refuses alike, so the row says it once and offers nothing.
        let running = parent(.claude, [Self.folder(.claude, ".claude", .notInstalled, action: .install, refusal: "Quit Open Island first"),
                                       Self.folder(.claude, ".claude-lab", .installed, action: .remove, refusal: "Quit Open Island first")])
        #expect(running.refusal == "Quit Open Island first" && running.actions.isEmpty && !running.canClick)

        // Found by its command, no folder yet.
        let none = parent(.codex, [])
        #expect(none.status == .notConnected && none.actions.isEmpty && none.refusal == "Start it once first")
        #expect(parent(.claude, [Self.folder(.claude, ".claude", nil, action: nil)]).status == .checking)
    }

    /// The parent row's click runs on its folders: Connect installs only folders offering Install now, never a Repair
    /// (P20); Move repairs only the folders still calling Open Island's helper; Remove only the folders offering Remove.
    @Test func connectNeverRepairsAndRemoveTakesOnlyConnectedFolders() {
        let rows = [Self.folder(.claude, ".claude", .installed, action: .remove),
                    Self.folder(.claude, ".claude-work", .notInstalled, action: .install),
                    Self.folder(.claude, ".claude-lab", .partial(installed: 12, expected: 14), action: .repair),
                    Self.folder(.claude, ".claude-old", .installed, action: .repair, moves: true),
                    Self.folder(.claude, ".claude-busy", .notInstalled, action: .install, busy: true)]
        let connect = AgentRowText.profileRun(.connect, profiles: rows)
        #expect(connect.0 == .install && connect.1 == ["claude:.claude-work"])
        let move = AgentRowText.profileRun(.move, profiles: rows)
        #expect(move.0 == .repair && move.1 == ["claude:.claude-old"])
        let remove = AgentRowText.profileRun(.remove, profiles: rows)
        #expect(remove.0 == .remove && remove.1 == ["claude:.claude"])
        #expect(AgentRowText.profileRun(.update, profiles: rows).0 == nil)
    }

    /// OpenCode's row from Setup's: Connect, Connected and Remove, Juice's older plugin with Update and Remove, Open
    /// Island's plugin with Update only (never removed), and a refusal the row was given.
    @Test func openCodesRowInAgentsWords() {
        let missing = AgentRowText.openCode(Self.openCodeRow("Not installed", action: .install))
        #expect(missing.status == .notConnected && missing.actions == [.connect] && missing.place == "~/.config/opencode")
        let ours = AgentRowText.openCode(Self.openCodeRow("Installed", action: .remove))
        #expect(ours.status == .connected && ours.actions == [.remove] && ours.reach == .approve)
        let older = AgentRowText.openCode(Self.openCodeRow("Older than this build", action: .update))
        #expect(older.status == .connected && older.actions == [.update, .remove])
        #expect(AgentRowText.openCode(Self.openCodeRow("Installed", action: nil, refusal: "Quit Open Island first")).status == .connected)
        let island = AgentRowText.openCode(Self.openCodeRow("Open Island's", action: .update))
        #expect(island.actions == [.update] && island.status == .attention(word: "Open Island's", detail: nil))
        let refused = AgentRowText.openCode(Self.openCodeRow("Installed", action: nil, refusal: "Quit Open Island first"))
        #expect(refused.refusal == "Quit Open Island first" && refused.actions.isEmpty)
        let foreign = AgentRowText.openCode(Self.openCodeRow("Another plugin's file", action: nil, refusal: "Another plugin's file"))
        #expect(foreign.refusal == nil && foreign.actions.isEmpty)
    }

    // MARK: The model

    /// One row per agent found (P935): Claude and Codex by a folder or their command, OpenCode as its row says, then
    /// each source's rows in its order; the rest named once. Codex is Watch while the island does not answer it.
    @Test func theModelListsFoundAgentsAndNamesTheRest() async {
        let hooks = Hooks([Self.folder(.claude, ".claude", .installed, action: .remove)])
        let source = Source([Self.agent("copilot", "Copilot CLI", .connected, actions: [.remove]),
                             Self.agent("cursor", "Cursor", .addByHand(file: "hooks.json", snippet: "{}"), actions: [])],
                            notFound: ["Qwen Code", "Devin", "Kilo"])
        let model = AgentsPaneModel(hooks: { hooks })
        model.sources = [source]
        model.answersCodex = { false }
        #expect(model.rows.map(\.id) == ["claude", "copilot", "cursor"])
        #expect(model.notFound == ["Codex", "OpenCode", "Qwen Code", "Devin", "Kilo"])
        #expect(AgentsPaneText.notFound(model.notFound) == "Not found: Codex, OpenCode, Qwen Code, Devin, Kilo")

        // `codex` on the PATH with no folder: a row of its own, found on the pane's refresh, off the main actor.
        model.findCommands = { ["codex"] }
        model.refresh()
        for _ in 0..<200 where model.commands.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(hooks.refreshes == 1 && source.refreshes == 1)
        #expect(model.rows.map(\.id) == ["claude", "codex", "copilot", "cursor"])
        #expect(model.rows[1].reach == .watch && model.rows[0].reach == .approve)
        model.answersCodex = { true }
        #expect(model.rows[1].reach == .approve)

        hooks.openCodeRow = Self.openCodeRow("Installed", action: .remove)
        #expect(model.rows.map(\.id) == ["claude", "codex", "opencode", "copilot", "cursor"])
        #expect(model.notFound == ["Qwen Code", "Devin", "Kilo"])
    }

    /// Codex is Approve only while the app answers it: Answer Codex in Juice (P947), in either mode, since the
    /// window's Needs you card holds it too (P1050).
    @Test func codexIsApproveOnlyWhileTheIslandAnswersIt() {
        let env = AppEnvironment.demo()
        func codex() -> AgentReach? { env.agents.rows.first { $0.id == "codex" }?.reach }
        #expect(codex() == .watch)
        env.settings.showAs = .window
        #expect(codex() == .watch)
        env.settings.answerCodexOnIsland = true
        #expect(codex() == .approve)
        env.settings.showAs = .island
        #expect(codex() == .approve && env.agents.rows.first?.reach == .approve)
    }

    /// Every click goes where its row came from, and only there.
    @Test func clicksGoWhereTheirRowCameFrom() {
        let hooks = Hooks([Self.folder(.claude, ".claude", .installed, action: .remove),
                           Self.folder(.claude, ".claude-work", .notInstalled, action: .install),
                           Self.folder(.codex, ".codex", .installed, action: .remove)],
                          openCode: Self.openCodeRow("Not installed", action: .install))
        let source = Source([Self.agent("copilot", "Copilot CLI", .connected, actions: [.remove])])
        let model = AgentsPaneModel(hooks: { hooks })
        model.sources = [source]
        model.perform(.connect, on: "claude")
        model.perform(.remove, on: "codex")
        model.performProfile(.remove, on: "claude:.claude")
        model.perform(.connect, on: "opencode")
        model.perform(.remove, on: "opencode")
        model.perform(.remove, on: "copilot")
        model.perform(.remove, on: "nobody")
        #expect(hooks.runs == ["install claude:.claude-work", "remove codex:.codex", "remove claude:.claude"])
        #expect(hooks.openCode == ["perform", "remove"])
        #expect(source.performed == ["remove copilot"])
    }

    /// Remove from all agents (P939) takes ours out of every connected folder in one run, Juice's OpenCode plugin, and
    /// every other agent offering Remove; never a folder or agent that is not connected, waits on a refusal, or is Add by
    /// hand. With nothing connected it is not offered.
    @Test func removeFromAllTakesOursOutOfEveryAgentAndNothingElse() {
        let hooks = Hooks([Self.folder(.claude, ".claude", .installed, action: .remove),
                           Self.folder(.claude, ".claude-work", .notInstalled, action: .install),
                           Self.folder(.claude, ".claude-lab", .installed, action: .repair, moves: true),
                           Self.folder(.codex, ".codex-side", .codexNeedsTrust(untrustedEvents: ["Stop"]), action: .remove),
                           Self.folder(.codex, ".codex-preset", .hasComments(file: "hooks.json"), action: nil,
                                       refusal: "Edit hooks.json by hand")],
                          openCode: Self.openCodeRow("Older than this build", action: .update))
        let source = Source([Self.agent("copilot", "Copilot CLI", .connected, actions: [.remove]),
                             Self.agent("cursor", "Cursor", .addByHand(file: "hooks.json", snippet: "{}"), actions: []),
                             Self.agent("qwen", "Qwen Code", .notConnected, actions: [.connect]),
                             Self.agent("kilo", "Kilo", .connected, actions: [.remove], refusal: "Quit Open Island first")])
        let model = AgentsPaneModel(hooks: { hooks })
        model.sources = [source]
        #expect(model.canRemoveFromAll)
        model.removeFromAll()
        // A folder still on Open Island's helper holds Juice's older hooks: they go too (P932).
        #expect(hooks.runs == ["remove claude:.claude,claude:.claude-lab,codex:.codex-side"])
        #expect(hooks.openCode == ["remove"])
        #expect(source.performed == ["remove copilot"])

        let idle = AgentsPaneModel(hooks: { Hooks([Self.folder(.claude, ".claude-work", .notInstalled, action: .install)]) })
        idle.sources = [Source([Self.agent("qwen", "Qwen Code", .notConnected, actions: [.connect])])]
        #expect(!idle.canRemoveFromAll)
    }

    /// Over the real manager in a temporary home: the Claude row's Connect installs each folder in turn, and Remove from
    /// all agents takes every one out again; Codex's folders, never connected, and a file with comments stay as they were.
    @Test func removeFromAllOverTheRealManager() async throws {
        let box = try HooksSetupUITests.Sandbox()
        try box.write(".codex-side", "hooks.json", "{ // mine\n \"hooks\": {} }")
        let hooks = box.hooks()
        hooks.activate()
        defer { hooks.stop() }
        func settle(_ done: () -> Bool) async { for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(10)) } }
        await settle { hooks.rows.count == 6 && hooks.rows.allSatisfy { $0.word != "…" } }
        let codexBefore = [".codex", ".codex-side", ".codex-fresh"].map { name in
            box.snapshot().filter { $0.key.hasPrefix(name + "/") }
        }
        let model = AgentsPaneModel(hooks: { hooks })
        let claude = try #require(model.rows.first { $0.id == "claude" })
        #expect(claude.status == .notConnected && claude.actions == [.connect])

        model.perform(.connect, on: "claude")
        // Connected, and the last folder's click over (a busy folder is not offered to Remove from all agents).
        await settle { model.rows.first { $0.id == "claude" }?.status == .connected && hooks.rows.allSatisfy { !$0.busy } }
        #expect(model.rows.first { $0.id == "claude" }?.status == .connected)
        for name in [".claude", ".claude-work", ".claude-lab"] {
            #expect(String(decoding: box.read(name, "settings.json") ?? Data(), as: UTF8.self).contains("--source claude"))
        }
        #expect(model.canRemoveFromAll)

        model.removeFromAll()
        await settle { hooks.rows.filter { $0.provider == .claude }.allSatisfy { $0.word == "Not installed" && !$0.busy } }
        for name in [".claude", ".claude-work", ".claude-lab"] {
            #expect(!String(decoding: box.read(name, "settings.json") ?? Data(), as: UTF8.self).contains("OpenIslandHooks"))
        }
        #expect(!model.canRemoveFromAll)
        let codexAfter = [".codex", ".codex-side", ".codex-fresh"].map { name in
            box.snapshot().filter { $0.key.hasPrefix(name + "/") }
        }
        #expect(codexAfter == codexBefore)
    }

    /// Remove from all agents' OpenCode Remove takes out Juice's own plugin, older or current, under its own name or under
    /// Open Island's, and never Open Island's own; Open Island running stands in the way of nothing (P934).
    @Test func removeFromAllLeavesOpenIslandsOpenCodePlugin() async throws {
        let calls = OpenCodeSetupModelTests.Calls()
        let folder = OpenCodeSetupModelTests.folder(create: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let model = OpenCodeSetupModelTests.model(folder: folder, calls: calls)
        let plugin = model.installer.pluginURL, legacy = model.installer.legacyURL
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)

        let theirs = Data((OpenCodePlugin.openIslandMarker + "\nexport default function () {}\n").utf8)
        try theirs.write(to: legacy)
        await model.refresh(askVersion: false)
        await model.perform(only: .remove)
        #expect(try Data(contentsOf: legacy) == theirs)

        try Data((OpenCodePlugin.marker + "0\nexport default {}\n").utf8).write(to: plugin)
        await model.refresh(askVersion: false)
        await model.perform(only: .remove)
        #expect(!FileManager.default.fileExists(atPath: plugin.path) && (try? Data(contentsOf: legacy)) == theirs)

        // Juice's first plugin, under Open Island's name: Juice's to take out.
        try Data((OpenCodePlugin.olderMarker + "1.\nexport default {}\n").utf8).write(to: legacy)
        await model.refresh(askVersion: false)
        await model.perform(only: .remove)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    // MARK: Finding agents

    /// The places looked in (P937): the login shell's PATH first, then Homebrew's, `~/.local/bin`, Bun's, npm's, every
    /// nvm node, Volta's, pnpm's and Yarn's, each once, with `~` and `$HOME` read under the home folder.
    @Test func theSearchCoversTheLoginPathAndTheUsualInstallPlaces() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ji-agents-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        for version in ["v20.11.1", "v22.3.0", ".hidden"] {
            try FileManager.default.createDirectory(atPath: "\(home)/.nvm/versions/node/\(version)/bin", withIntermediateDirectories: true)
        }
        let dirs = AgentDetector.searchDirectories(home: home, loginPATH: "/usr/bin:~/bin:$HOME/.local/bin:/opt/homebrew/bin::/bin")
        #expect(dirs == ["/usr/bin", "\(home)/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/bin", "/usr/local/bin",
                         "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.nvm/versions/node/v22.3.0/bin",
                         "\(home)/.nvm/versions/node/v20.11.1/bin", "\(home)/.volta/bin", "\(home)/Library/pnpm", "\(home)/.yarn/bin"])
    }

    /// An agent is found by a command that may run (a link to one counts; a plain file or a folder of that name does
    /// not) or by its config folder (a file of that name does not). Nothing is opened or run.
    @Test func anAgentIsFoundByACommandOrAFolder() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ji-agents-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        let bin = home + "/.local/bin", other = home + "/elsewhere"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        func file(_ path: String, executable: Bool) throws {
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
            try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
        }
        try file(bin + "/copilot", executable: true)
        try file(bin + "/qwen", executable: false)
        try fm.createDirectory(atPath: bin + "/kilo", withIntermediateDirectories: true)
        try file(other + "/cursor-agent", executable: true)
        try fm.createSymbolicLink(atPath: bin + "/cursor-agent", withDestinationPath: other + "/cursor-agent")
        try fm.createSymbolicLink(atPath: bin + "/devin", withDestinationPath: other + "/missing")
        try fm.createDirectory(atPath: home + "/.config/kilo", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: home + "/.qwen"))

        let dirs = [bin]
        func found(_ executables: [String], _ folders: [String] = []) -> Bool {
            AgentDetector.isPresent(AgentFootprint(executables: executables, folders: folders), home: home, directories: dirs)
        }
        #expect(found(["copilot"]))
        #expect(found(["cursor", "cursor-agent"]))
        #expect(!found(["qwen"], ["~/.qwen"]))
        #expect(!found(["kilo"]))
        #expect(found(["kilo"], ["~/.config/kilo"]))
        #expect(!found(["devin"], ["~/.config/devin"]))
        #expect(!found(["", "../.local/bin/copilot", "/usr/bin/true"]))
        #expect(AgentDetector.expand("~", home: home) == home && AgentDetector.expand("/x", home: home) == "/x")
    }
}
