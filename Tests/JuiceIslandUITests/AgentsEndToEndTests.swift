import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 1 end to end, in a temporary home (P900 to P949). Fake commands and config folders for Claude Code, Codex, Copilot
/// CLI, Cursor, Qwen Code and Kilo; each is connected with the Agents pane's own model (`AgentsPaneModel` over the real
/// `ProfileHooks` and `TableAgents`), which copies the built helper into the scratch `HookHome` as the app copies it into
/// its own. Each agent's hook payloads, in the shapes its docs record, then run through the command the installer wrote
/// (the copied helper, finding its sockets from its own path), to the engine's real sockets and a stand-in for upstream's
/// bridge (`AttentionRig`). Each session shows as a row with its own agent's mark; an Approve agent's approval is a card
/// whose answer comes back in that agent's words; Remove gives every file back byte for byte. Nothing here names a path
/// outside the scratch folder, and no agent runs: the fake commands only have to exist.
@MainActor
@Suite(.serialized)
struct AgentsEndToEndTests {
    typealias E = AttentionEndToEndTests

    /// The owner's files before Connect: other tools' hooks in Claude's, Cursor's and Qwen's, so Remove must keep them.
    static let before: [String: String] = [
        ".claude/settings.json": """
            {
              "model": "opus",
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "say done" } ] }
                ]
              }
            }

            """,
        ".claude/.claude.json": "{}",
        ".codex/config.toml": "model = \"gpt-5\"\n",
        ".cursor/hooks.json": "{\n  \"version\": 1,\n  \"hooks\": {\n    \"stop\": [{ \"command\": \"say done\" }]\n  }\n}\n",
        ".qwen/settings.json": #"{"model":{"name":"qwen3-coder"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
    ]
    static let emptyFolders = [".copilot", ".config/kilo"]
    static let commands = ["claude", "codex", "copilot", "cursor-agent", "qwen", "kilo"]
    static let agents = ["claude", "codex", "copilot", "cursor", "qwen", "kilo"]

    /// The pane over a scratch home: `rig.home` holds the agents' folders, `rig.hookHome` the helper and the sockets.
    @MainActor
    final class World {
        let rig: AttentionRig
        let hooks: ProfileHooks
        let pane: AgentsPaneModel
        let table: TableAgents
        let bin: URL
        private let suite = "ji.test.agents.\(UUID().uuidString)"
        let defaults: UserDefaults

        /// `prepare` writes what else the home holds, before the pane first reads it.
        /// `installedBefore`: the default folders whose hooks Juice set up before its own helper (their intent says so).
        /// `openCode`: OpenCode's row reads the scratch home's `.config/opencode` (found when that folder is there; no
        /// `opencode` runs); without it the row is inert.
        init(legacyRelay: Bool = false, files: [String: String] = AgentsEndToEndTests.before,
             folders: [String] = AgentsEndToEndTests.emptyFolders, commands: [String] = AgentsEndToEndTests.commands,
             installedBefore: [Provider] = [], openCode: Bool = false, prepare: (URL) throws -> Void = { _ in }) async throws {
            rig = try await AttentionRig(helperHome: true, legacyRelay: legacyRelay)
            let home = rig.home, hookHome = try #require(rig.hookHome)
            let bin = rig.folder.appendingPathComponent("fakebin", isDirectory: true)
            self.bin = bin
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in commands {
                let url = bin.appendingPathComponent(name)
                try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            for folder in folders {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for (path, text) in files {
                let url = home.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            try prepare(home)
            defaults = UserDefaults(suiteName: suite)!
            for provider in installedBefore {
                let folder = ProfileHookTargets.normalized(home.appendingPathComponent(provider.defaultFolderName).path)
                ProfileHookIntentStore(defaults: defaults).setIntent(.installed, for: Account.id(provider: provider, folder: folder))
            }
            let manager = ProfileHookManager(bundledHelperURL: HelperRun.binary, managedHelperURL: hookHome.helperURL,
                                             intents: ProfileHookIntentStore(defaults: defaults), codexFeatureKey: { .current },
                                             isOpenIslandAppRunning: { false })
            let directory = ProfileDirectory(load: { LiveProfiles.load(accountsFile: home.appendingPathComponent("none.json"), home: home.path) },
                                             home: home.path)
            let openCodeModel = openCode ? OpenCodePluginModel(
                installer: OpenCodePluginInstaller(configDirectory: OpenCodePluginInstaller.defaultConfigDirectory(home: home.path),
                                                   fileStem: "juice-island"),
                locate: { false }, probe: { nil }) : nil
            let hooks = ProfileHooks(manager: manager, directory: directory, home: home.path, openCode: openCodeModel,
                                     watch: { _, _ in nil }, schedule: { _, _ in })
            self.hooks = hooks
            let search = bin.path
            let table = TableAgents(installer: AgentHookInstaller(home: home, helperPath: hookHome.helperURL.path,
                                                                  bundledHelper: HelperRun.binary, ownFileStem: "juice-island",
                                                                  bridgeSocketPath: hookHome.bridgeURL.path),
                                    directories: { [search] })
            self.table = table
            let pane = AgentsPaneModel(hooks: { hooks })
            self.pane = pane
            pane.sources = [table]
            pane.helperPath = { hookHome.helperURL.path }
            pane.findCommands = {
                Set(["claude", "codex"].filter {
                    AgentDetector.isPresent(AgentFootprint(executables: [$0], folders: []), home: home.path, directories: [search])
                })
            }
            // A click that changed hooks makes the engine look again at Open Island's socket, as the app wires it (P932).
            let engine = rig.engine
            hooks.onHooksChanged = { engine.hooksChanged() }
            hooks.activate()
            pane.refresh()
        }

        func stop() {
            rig.stop()
            defaults.removePersistentDomain(forName: suite)
        }

        var home: URL { rig.home }
        func url(_ path: String) -> URL { home.appendingPathComponent(path) }
        func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
        func row(_ id: String) -> AgentRow? { pane.rows.first { $0.id == id } }

        /// Every agent's row, read.
        func ready(_ ids: [String]) async {
            await rig.waitUntil { ids.allSatisfy { id in row(id).map { $0.status != .checking && !$0.busy } ?? false } }
        }

        /// One click on the row's button, then its file read again.
        func click(_ action: AgentRowAction, on id: String, until done: (AgentRow) -> Bool) async {
            pane.perform(action, on: id)
            await rig.waitUntil { row(id).map { !$0.busy && done($0) } ?? false }
        }
    }

    // MARK: Fixtures

    /// The command the installer wrote for `event`, from any layout: a Claude group's hook, Copilot's `bash`, Cursor's
    /// `command`.
    static func command(_ world: World, _ path: String, event: String, helper: String = HookHome.helperName) -> String? {
        guard let data = try? Data(contentsOf: world.url(path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] else { return nil }
        for entry in entries {
            let commands = ((entry["hooks"] as? [[String: Any]]) ?? [entry]).compactMap { ($0["bash"] ?? $0["command"]) as? String }
            if let found = commands.first(where: { $0.contains(helper) }) { return found }
        }
        return nil
    }

    static func started(_ id: String, tool: AgentTool, title: String) -> AgentEvent {
        .sessionStarted(SessionStarted(
            sessionID: id, title: title, tool: tool, origin: .live, initialPhase: .running, summary: "Started.", timestamp: .now,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "agent", workingDirectory: "/tmp/project")))
    }

    static func activity(_ id: String, _ summary: String) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: summary, phase: .running, timestamp: .now))
    }

    static func asked(_ id: String, tool: String = "Bash") -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: tool, summary: "git push origin main", affectedPath: "/tmp/project", toolName: tool), timestamp: .now))
    }

    /// A Claude-shaped hook input (Copilot CLI's PascalCase events and Qwen Code send Claude's snake_case fields).
    static func claudeShaped(_ event: String, session: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": event, "session_id": session, "cwd": "/tmp/project"].merging(extra) { $1 }
    }

    /// Cursor's hook input (cursor.com/docs/agent/hooks).
    static func cursorShaped(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": event, "conversation_id": "cu-1", "generation_id": "g-1", "workspace_roots": ["/tmp/project"]]
            .merging(extra) { $1 }
    }

    static func object(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }

    func approval(_ rig: AttentionRig, _ id: String) -> ApprovalCardModel? {
        if case let .approval(card)? = rig.card(id) { card } else { nil }
    }

    // MARK: The whole wave

    /// Every agent connected from the pane, its hooks through the installed helper to labelled rows, each Approve agent's
    /// answer back in its own words, then Remove: every file as it was, byte for byte.
    @Test
    func everyAgentConnectsShowsItsOwnRowsAnswersInItsWordsAndRemovesByteForByte() async throws {
        let world = try await World()
        defer { world.stop() }
        let rig = world.rig, hookHome = try #require(rig.hookHome)
        await world.ready(Self.agents)
        #expect(world.pane.rows.map(\.id) == Self.agents)
        // The table's agents with no command or folder here are listed after OpenCode, in the table's order.
        #expect(world.pane.notFound == ["OpenCode"] + AgentHookTable.wave1.filter { !Self.agents.contains($0.kind.rawValue) }.map(\.name))
        #expect(Self.agents.allSatisfy { world.row($0)?.status == .notConnected })
        #expect(world.row("cursor")?.reach == .watch && ["copilot", "qwen", "kilo"].allSatisfy { world.row($0)?.reach == .approve })
        #expect(world.row("copilot")?.look == AgentLook.of(GlyphPalette.Agent.kind(.copilot)))

        // Connect, one click each: nothing was written before.
        #expect(!FileManager.default.fileExists(atPath: hookHome.helperURL.path))
        for id in Self.agents {
            await world.click(.connect, on: id) { [.connected, .needsCodexTrust].contains($0.status) }
        }
        #expect(FileManager.default.isExecutableFile(atPath: hookHome.helperURL.path))
        #expect(world.text(".claude/settings.json")?.contains("say done") == true)

        try await claude(world)
        try await codex(world)
        try await copilot(world)
        try await cursor(world)
        try await qwen(world)
        try await kilo(world)

        // Remove, one click each: every file as it was, and the files only Juice wrote are gone.
        for id in Self.agents {
            await world.click(.remove, on: id) { $0.status == .notConnected }
        }
        for (path, text) in Self.before {
            #expect(world.text(path) == text, "\(path) is not as it was")
        }
        for path in [".codex/hooks.json", ".copilot/hooks/juice-island.json", ".config/kilo/plugin/juice-island.js"] {
            #expect(!FileManager.default.fileExists(atPath: world.url(path).path), "\(path) is still there")
        }
    }

    /// Claude Code: an approval held by the broker, shown once Claude's notice says so, answered in Claude's words.
    private func claude(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".claude/settings.json", event: "PermissionRequest"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source claude")
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))], command: command)
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "fix the tests"]),
                           events: E.prompt("s1", "fix the tests", transcript: E.transcript(rig, "s1")), command: command)
        #expect(rig.row("s1")?.agent == .claude)
        await rig.finished(E.claude(rig, "PreToolUse", tool: "Bash", input: E.push, toolUseID: "U1"), events: [E.running("s1")],
                           command: command)
        let count = rig.engine.openRequests.count
        let run = rig.hook(E.claude(rig, "PermissionRequest", tool: "Bash", input: E.push), command: command)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        rig.advance(6)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt",
                                                                 "message": "Claude needs your permission to use Bash"]), command: command)
        #expect(approval(rig, "s1")?.request?.answerable == true)
        await rig.model.decide("s1", .allowOnce)
        let result = await run.result(within: 30)
        let decision = (Self.object(result?.stdout ?? Data())?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "allow")
        await rig.settle()
    }

    /// Codex, with Answer Codex on the island: its hooks as Juice writes them (the helper alone, no `--source`, P290), its
    /// approval held while the card shows and answered with Codex's exact output.
    private func codex(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".codex/hooks.json", event: "PermissionRequest"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)'")
        rig.engine.answersCodex = true
        let url = rig.folder.appendingPathComponent("rollout-c1.jsonl")
        let meta = RolloutLines.line("session_meta", ["id": "c1", "cwd": "/tmp/project", "originator": "codex_cli_rs", "source": "cli"], at: 0)
        try RolloutLines.text([meta, RolloutLines.turnContext(reviewer: "user"), RolloutLines.event("task_started", at: 0)])
            .write(to: url, atomically: true, encoding: .utf8)
        await rig.finished(E.codex("SessionStart", transcript: url.path), source: nil, entrypoint: nil,
                           events: [E.started("c1", tool: .codex, transcript: url.path)], command: command)
        await rig.finished(E.codex("UserPromptSubmit", transcript: url.path, extra: ["prompt": "run the migration"]), source: nil,
                           entrypoint: nil, events: E.prompt("c1", "run the migration", tool: .codex, transcript: url.path), command: command)
        #expect(rig.row("c1")?.agent == .codex)
        let tracker = CodexRolloutTracker(pollInterval: 60)
        defer { tracker.stop() }
        tracker.attentionHandler = { [weak engine = rig.engine] update in
            Task { @MainActor in engine?.ingestCodexAttention(update) }
        }
        tracker.eventHandler = { [weak engine = rig.engine] event in
            Task { @MainActor in engine?.ingest(event, ingress: .rollout) }
        }
        tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: "c1", transcriptPath: url.path)])
        tracker.waitUntilIdle()
        await rig.settle()
        let count = rig.engine.openRequests.count
        let run = rig.hook(E.codex("PermissionRequest", transcript: url.path, input: ["command": "python3 scripts/migrate.py --apply"]),
                           source: nil, entrypoint: nil, command: command)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        await rig.waitUntil { approval(rig, "c1")?.isAnswerable == true }
        let request = try #require(approval(rig, "c1")?.request)
        rig.model.islandShows(requestID: request.id)
        await rig.model.decide("c1", .allowOnce, request: request.id)
        let result = await run.result(within: 30)
        let printed = Self.object(result?.stdout ?? Data())
        #expect(printed?["continue"] as? Bool == true)
        let output = printed?["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
        #expect((output?["decision"] as? [String: Any]).map { $0.count == 1 && $0["behavior"] as? String == "allow" } == true)
        await rig.settle()
    }

    /// Copilot CLI: Juice's own file in `~/.copilot/hooks/`, the helper's own runner (Copilot's `--source` would read as
    /// Codex upstream, P908), a row with Copilot's mark, and its approval answered `{"behavior":"allow"}`.
    private func copilot(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".copilot/hooks/juice-island.json", event: "PermissionRequest"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source copilot")
        await rig.finished(Self.claudeShaped("SessionStart", session: "cp-1", extra: ["source": "new"]), entrypoint: nil,
                           events: [Self.started("cp-1", tool: .codebuddy, title: "Copilot · project")], command: command)
        await rig.finished(Self.claudeShaped("UserPromptSubmit", session: "cp-1", extra: ["prompt": "fix the tests"]), entrypoint: nil,
                           events: [Self.activity("cp-1", "Prompt: fix the tests")], command: command)
        #expect(rig.row("cp-1")?.agent == .kind(.copilot), "\(String(describing: rig.row("cp-1")?.agent)) \(rig.engine.state.sessions.map { "\($0.id) \($0.tool)" }) \(rig.upstream.current?.commands.map { "\($0.event) \($0.session) \($0.source)" } ?? [])")
        #expect(rig.upstream.current?.commands.last.map { $0.source == ClaudeFamilyRunner.carrier && $0.session == "cp-1" } == true)
        let count = rig.engine.openRequests.count
        let run = rig.hook(Self.claudeShaped("PermissionRequest", session: "cp-1",
                                             extra: ["tool_name": "bash", "tool_input": ["command": "git push origin main"]]),
                           entrypoint: nil, events: [Self.asked("cp-1", tool: "bash")], command: command)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        await rig.waitUntil { approval(rig, "cp-1")?.request?.answerable == true }
        await rig.model.decide("cp-1", .allowOnce)
        let result = await run.result(within: 30)
        #expect(result?.printed == "{\"behavior\":\"allow\"}\n")
        await rig.settle()
    }

    /// Cursor (Watch): its row with Cursor's mark, a shell call shown on the island and answered with nothing at all, so
    /// Cursor's own rules decide (P930); no card.
    private func cursor(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".cursor/hooks.json", event: "beforeShellExecution"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source cursor")
        await rig.finished(Self.cursorShaped("beforeSubmitPrompt", extra: ["prompt": "fix the tests"]), entrypoint: nil,
                           events: [Self.started("cu-1", tool: .cursor, title: "Cursor · project"), Self.activity("cu-1", "Prompt: fix the tests")],
                           command: command)
        #expect(rig.row("cu-1")?.agent == .other(.cursor))
        let result = await rig.finished(Self.cursorShaped("beforeShellExecution", extra: ["command": "git push origin main", "cwd": "/tmp/project"]),
                                        entrypoint: nil, events: [Self.activity("cu-1", "Running: git push origin main")], command: command)
        #expect(result.stdout.isEmpty && result.status == 0)
        #expect(rig.row("cu-1")?.agent == .other(.cursor))
        #expect(rig.card("cu-1") == nil)
    }

    /// Qwen Code: Claude's events under `--source qwen`, upstream's Claude path, its row with Qwen's mark, and its approval
    /// answered in Claude's output, which Qwen reads.
    private func qwen(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".qwen/settings.json", event: "PermissionRequest"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source qwen")
        await rig.finished(Self.claudeShaped("SessionStart", session: "qw-1", extra: ["source": "startup"]), entrypoint: nil,
                           events: [Self.started("qw-1", tool: .qwenCode, title: "Qwen · project")], command: command)
        await rig.finished(Self.claudeShaped("UserPromptSubmit", session: "qw-1", extra: ["prompt": "fix the tests"]), entrypoint: nil,
                           events: [Self.activity("qw-1", "Prompt: fix the tests")], command: command)
        #expect(rig.row("qw-1")?.agent == .other(.qwenCode), "\(String(describing: rig.row("qw-1")?.agent)) \(rig.engine.state.sessions.map { "\($0.id) \($0.tool)" }) \(rig.upstream.current?.commands.map { "\($0.event) \($0.session) \($0.source)" } ?? [])")
        let count = rig.engine.openRequests.count
        let run = rig.hook(Self.claudeShaped("PermissionRequest", session: "qw-1",
                                             extra: ["tool_name": "run_shell_command", "tool_input": ["command": "git push origin main"]]),
                           entrypoint: nil, events: [Self.asked("qw-1", tool: "run_shell_command")], command: command)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        await rig.waitUntil { approval(rig, "qw-1")?.request?.answerable == true }
        await rig.model.decide("qw-1", .allowOnce)
        let result = await run.result(within: 30)
        let output = Self.object(result?.stdout ?? Data())?["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
        #expect((output?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        await rig.settle()
    }

    /// Kilo: Juice's plugin in `~/.config/kilo/plugin/`, dialing the helper home's bridge with `kilo-` sessions. What the
    /// plugin sends goes to that socket here as the plugin sends it; the row has Kilo's mark and the answer comes back as
    /// OpenCode's directive, which the plugin passes to Kilo.
    private func kilo(_ world: World) async throws {
        let rig = world.rig
        let plugin = try #require(world.text(".config/kilo/plugin/juice-island.js"))
        #expect(plugin.contains("const SOCKET_PATH = \"\(rig.hookHome!.bridgeURL.path)\";"))
        #expect(plugin.contains("`kilo-${sessionID}`") && plugin.contains("`kilo2-${sessionID}`") && !plugin.contains("`opencode-${"))
        let socket = rig.bridgeURL
        let send: @Sendable (OpenCodeHookPayload) async -> BridgeResponse? = { payload in
            await Task.detached { try? BridgeCommandClient(socketURL: socket).send(.processOpenCodeHook(payload), timeout: 30) }.value
        }
        rig.upstream.current?.plan(event: "SessionStart", session: "kilo-k1",
                                   events: [Self.started("kilo-k1", tool: .openCode, title: "Kilo · project")])
        #expect(await send(OpenCodeHookPayload(hookEventName: .sessionStart, sessionID: "kilo-k1", cwd: "/tmp/project")) == .acknowledged)
        rig.upstream.current?.plan(event: "UserPromptSubmit", session: "kilo-k1", events: [Self.activity("kilo-k1", "Prompt: fix the tests")])
        #expect(await send(OpenCodeHookPayload(hookEventName: .userPromptSubmit, sessionID: "kilo-k1", cwd: "/tmp/project",
                                               prompt: "fix the tests")) == .acknowledged)
        await rig.settle()
        #expect(rig.row("kilo-k1")?.agent == .kind(.kilo), "\(String(describing: rig.row("kilo-k1")?.agent)) \(rig.engine.state.sessions.map { "\($0.id) \($0.tool)" }) \(rig.upstream.current?.commands.map { "\($0.event) \($0.session) \($0.source)" } ?? [])")
        rig.upstream.current?.plan(event: "PermissionRequest", session: "kilo-k1", events: [Self.asked("kilo-k1", tool: "bash")])
        let count = rig.engine.openRequests.count
        let answer = Task {
            await send(OpenCodeHookPayload(hookEventName: .permissionRequest, sessionID: "kilo-k1", cwd: "/tmp/project", toolName: "bash",
                                           toolInput: "git push origin main", permissionID: "per-1", permissionTitle: "git push origin main"))
        }
        await rig.waitUntil { rig.engine.openRequests.count > count }
        await rig.waitUntil { approval(rig, "kilo-k1")?.request?.answerable == true }
        await rig.model.decide("kilo-k1", .allowOnce)
        #expect(await answer.value == .openCodeHookDirective(.allow))
        await rig.settle()
    }

    // MARK: Moving off Open Island's helper

    /// Hooks Juice wrote before its own helper still call Open Island's: they keep reaching the app through the relayed
    /// socket, the row says Move, one click points them at Juice's helper and keeps everyone else's, and the moved hooks
    /// reach the app on its own socket. Open Island's own Cursor hook is Open Island's: Connect puts Juice's beside it and
    /// Remove gives the file back (P932).
    @Test
    func oldHooksKeepWorkingAndMoveToJuicesHelperOnAClick() async throws {
        let old = "Library/Application Support/\(LegacyHookHome.folderName)/bin/\(LegacyHookHome.helperName)"
        var cursorBefore = ""
        let world = try await World(legacyRelay: true, files: [".claude/.claude.json": "{}"], folders: [".cursor"],
                                    commands: ["claude", "cursor-agent"], installedBefore: [.claude]) { home in
            let oldHelper = home.appendingPathComponent(old)
            try FileManager.default.createDirectory(at: oldHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: HelperRun.binary, to: oldHelper)
            let settings = try #require(try ClaudeHookInstaller.installSettingsJSON(
                existingData: Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8),
                hookCommand: ClaudeHookInstaller.hookCommand(for: oldHelper.path, source: "claude")).contents)
            try settings.write(to: home.appendingPathComponent(".claude/settings.json"))
            let cursor = "'\(oldHelper.path)' --source cursor"
            cursorBefore = #"{"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"\#(cursor)"}],"stop":[{"command":"say done"},{"command":"\#(cursor)"}]}}"#
            try Data(cursorBefore.utf8).write(to: home.appendingPathComponent(".cursor/hooks.json"))
        }
        defer { world.stop() }
        let rig = world.rig, legacy = try #require(rig.legacyURL)
        await world.ready(["claude", "cursor"])
        await rig.waitUntil { rig.engine.relaysLegacySocket }

        // The old helper, as installed: Open Island's socket (here the scratch path the engine relays) and the notes and
        // requests sockets every older helper names.
        rig.extraEnvironment = ["OPEN_ISLAND_SOCKET_PATH": legacy.path, HookNoteSocket.overrideKey: rig.notesURL.path,
                                HookRequestSocket.overrideKey: rig.requestsURL.path]
        let oldCommand = try #require(Self.command(world, ".claude/settings.json", event: "SessionStart", helper: LegacyHookHome.helperName))
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))], command: oldCommand)
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "fix the tests"]),
                           events: E.prompt("s1", "fix the tests", transcript: E.transcript(rig, "s1")), command: oldCommand)
        #expect(rig.row("s1")?.agent == .claude, "\(String(describing: rig.row("s1")?.agent)) \(rig.engine.state.sessions.map { "\($0.id) \($0.tool)" }) \(rig.upstream.current?.commands.map { "\($0.event) \($0.session) \($0.source)" } ?? [])")

        #expect(world.row("claude")?.status == .moveToJuiceHelper && world.row("claude")?.actions == [.move])
        #expect(world.row("cursor")?.status == .notConnected && world.row("cursor")?.actions == [.connect])
        // Once moved, nothing of Juice's dials Open Island's socket: the relay stops after the click.
        rig.relayWanted.update { $0 = false }
        await world.click(.move, on: "claude") { $0.status == .connected }
        await rig.waitUntil { !rig.engine.relaysLegacySocket }
        #expect(!rig.engine.relaysLegacySocket)
        await world.click(.connect, on: "cursor") { $0.status == .connected }
        let claudeText = try #require(world.text(".claude/settings.json"))
        #expect(!claudeText.contains(LegacyHookHome.helperName) && claudeText.contains(HookHome.helperName) && claudeText.contains("say done"))
        let cursorText = try #require(world.text(".cursor/hooks.json"))
        #expect(cursorText.contains(LegacyHookHome.helperName) && cursorText.contains(HookHome.helperName) && cursorText.contains("say done"))
        let settings = try #require(Self.object(Data(contentsOf: world.url(".claude/settings.json"))))
        #expect(settings["model"] as? String == "opus")
        await world.click(.remove, on: "cursor") { $0.status == .notConnected }
        #expect(world.text(".cursor/hooks.json") == cursorBefore)

        // Moved: the same session's next hook runs Juice's helper, which finds the app's own sockets from its path.
        rig.extraEnvironment = [:]
        let command = try #require(Self.command(world, ".claude/settings.json", event: "UserPromptSubmit"))
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "now the docs"]),
                           events: E.prompt("s1", "now the docs", transcript: E.transcript(rig, "s1")), command: command)
        #expect(rig.row("s1")?.lastPrompt == "now the docs")
        #expect(rig.upstream.current?.commands.map(\.event) == ["SessionStart", "UserPromptSubmit", "UserPromptSubmit"])
    }
}
