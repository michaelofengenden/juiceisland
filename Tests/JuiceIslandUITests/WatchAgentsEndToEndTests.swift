import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 4's lane GEMINI end to end, in a temporary home (P1100 to P1124). Fake `claude`, `gemini`, `agy` and `grok`
/// commands and their folders; each agent connected from the Agents pane's own model, which copies the built helper into
/// the scratch `HookHome`. Each agent's hook inputs, in the shapes its docs and source record (named beside each), run
/// through the command the installer wrote, as the agent runs it (`sh -c`), to the engine's real sockets and a stand-in for
/// upstream's bridge (`AttentionRig`). Every row is its own agent's, every one Watch: no card with an answer, nothing
/// printed, and "needs you" where the agent says its prompt shows. Remove gives every file back byte for byte. No agent
/// runs and nothing names a path outside the scratch folder.
@MainActor
@Suite(.serialized)
struct WatchAgentsEndToEndTests {
    typealias World = AgentsEndToEndTests.World
    typealias E = AgentsEndToEndTests

    /// The owner's files before Connect: a hook of someone else's in Claude's and in Gemini's.
    static let before: [String: String] = [
        ".claude/settings.json": #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
        ".claude/.claude.json": "{}",
        // https://geminicli.com/docs/hooks/reference/ (Configuration schema)
        ".gemini/settings.json": """
            {
              "general": { "vimMode": true },
              "hooks": {
                "AfterAgent": [
                  { "hooks": [ { "type": "command", "command": "say done", "timeout": 5000 } ] }
                ]
              }
            }

            """,
    ]
    static let folders = [".gemini/tmp", ".gemini/config", ".gemini/antigravity-cli", ".grok/bin"]
    static let commands = ["claude", "gemini", "agy", "grok"]
    static let agents = ["claude", "gemini", "antigravity", "grok"]

    /// The command the installer wrote for `source`, wherever it sits in the file (a Claude group, a flat handler or
    /// a hook name's block).
    static func command(_ world: World, _ path: String, source: String) -> String? {
        guard let data = try? Data(contentsOf: world.url(path)), let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func find(_ value: Any) -> String? {
            if let object = value as? [String: Any] {
                if let command = object["command"] as? String, command.contains(HookHome.helperName),
                   command.contains("--source \(source)") { return command }
                return object.values.lazy.compactMap(find).first
            }
            return (value as? [Any])?.lazy.compactMap(find).first
        }
        return find(root)
    }

    /// The command as the agent runs it: Gemini CLI through its shell, Grok Build through `sh -c`, agy through a shell.
    static func shell(_ command: String) -> String { "/bin/sh -c \(AgentHookTable.shellQuote(command))" }

    func approval(_ rig: AttentionRig, _ id: String) -> ApprovalCardModel? {
        if case let .approval(card)? = rig.card(id) { card } else { nil }
    }

    @Test
    func theThreeConnectShowTheirOwnRowsNeverAnswerAndRemoveByteForByte() async throws {
        let world = try await World(files: Self.before, folders: Self.folders, commands: Self.commands)
        defer { world.stop() }
        let rig = world.rig
        await world.ready(Self.agents)
        #expect(Self.agents.allSatisfy { world.row($0)?.status == .notConnected })
        #expect(["gemini", "antigravity", "grok"].allSatisfy { world.row($0)?.reach == .watch })
        #expect(world.row("gemini")?.name == "Gemini CLI" && world.row("antigravity")?.name == "Antigravity"
                && world.row("grok")?.name == "Grok Build")
        #expect(world.row("antigravity")?.look == AgentLook.of(GlyphPalette.Agent.kind(.antigravity)))

        // Claude first: Grok runs Claude's hooks before its own are connected.
        await world.click(.connect, on: "claude") { $0.status == .connected }
        try await grokThroughClaudesHooks(world)

        for id in ["gemini", "antigravity", "grok"] {
            await world.click(.connect, on: id) { $0.status == .connected }
        }
        #expect(world.text(".gemini/settings.json")?.contains("vimMode") == true)
        try await gemini(world)
        try await antigravity(world)
        try await grok(world)
        #expect(rig.engine.openRequests.allSatisfy { !$0.isAnswerable })

        for id in Self.agents {
            await world.click(.remove, on: id) { $0.status == .notConnected }
        }
        for (path, text) in Self.before {
            #expect(world.text(path) == text, "\(path) is not as it was")
        }
        for path in [".gemini/config/hooks.json", ".grok/hooks/juice-island.json", ".grok/hooks"] {
            #expect(!FileManager.default.fileExists(atPath: world.url(path).path), "\(path) is still there")
        }
        #expect(FileManager.default.fileExists(atPath: world.url(".gemini/config").path))
    }

    /// Grok Build running Claude's `settings.json` hooks (P1111): its hook variable names it, the row is Grok's, the
    /// bridge hears Grok, never Claude, and nothing is printed.
    private func grokThroughClaudesHooks(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(E.command(world, ".claude/settings.json", event: "SessionStart"))
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "session_start"]
        defer { rig.extraEnvironment = [:] }
        let result = await rig.finished(Self.grok("SessionStart", camel: "session_start", session: "gk-0", extra: ["source": "startup"]),
                                        source: nil, entrypoint: nil,
                                        events: [E.started("gk-0", tool: .grokBuild, title: "Grok · project")], command: command)
        #expect(result.stdout.isEmpty && result.status == 0)
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "user_prompt_submit"]
        let prompt = try #require(E.command(world, ".claude/settings.json", event: "UserPromptSubmit"))
        await rig.finished(Self.grok("UserPromptSubmit", camel: "user_prompt_submit", session: "gk-0", extra: ["prompt": "fix the tests"]),
                           source: nil, entrypoint: nil, events: [E.activity("gk-0", "Prompt: fix the tests")], command: prompt)
        await rig.waitUntil { rig.row("gk-0")?.agent == .other(.grokBuild) }
        #expect(rig.row("gk-0")?.agent == .other(.grokBuild), "\(String(describing: rig.row("gk-0")?.agent)) \(rig.engine.state.sessions.map { "\($0.id) \($0.tool)" }) \(rig.upstream.current?.commands.map { "\($0.event) \($0.session) \($0.source)" } ?? []) \(String(decoding: result.stdout, as: UTF8.self))")
        #expect(rig.upstream.current?.commands.filter { $0.session == "gk-0" }
                    .map { "\($0.event) \($0.source)" } == ["SessionStart grok", "UserPromptSubmit grok"])
    }

    /// Gemini CLI: its own words to upstream's Gemini path, its tool events as notes alone, its ToolPermission as
    /// "needs you" with no answer, gone once the tool runs (P1101, P1103).
    private func gemini(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".gemini/settings.json", source: "gemini"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source gemini 2>/dev/null || true")
        // hookRunner.ts adds these to every hook's environment, `CLAUDE_PROJECT_DIR` "for compatibility".
        rig.extraEnvironment = ["GEMINI_SESSION_ID": "g-1", "GEMINI_CWD": "/tmp/project", "CLAUDE_PROJECT_DIR": "/tmp/project"]
        defer { rig.extraEnvironment = [:] }
        let run = Self.shell(command)
        await rig.finished(Self.gemini("SessionStart", extra: ["source": "startup"]), source: nil, entrypoint: nil,
                           events: [E.started("g-1", tool: .geminiCLI, title: "Gemini · project")], command: run)
        await rig.finished(Self.gemini("BeforeAgent", extra: ["prompt": "fix the tests"]), source: nil, entrypoint: nil,
                           events: [E.activity("g-1", "Prompt: fix the tests")], command: run)
        await rig.waitUntil { rig.row("g-1")?.agent == .other(.geminiCLI) }
        let permission = await rig.finished(Self.gemini("Notification", extra: [
            "notification_type": "ToolPermission", "message": "Tool Shell requires execution",
            "details": ["type": "exec", "title": "Shell", "command": "npm test", "rootCommand": "npm"],
        ]), source: nil, entrypoint: nil, command: run)
        #expect(permission.stdout.isEmpty && permission.status == 0)
        await rig.waitUntil { approval(rig, "g-1")?.isNotice == true }
        #expect(approval(rig, "g-1")?.isAnswerable == false)
        let told = rig.upstream.current?.commands.count ?? 0
        let tool = await rig.finished(Self.gemini("AfterTool", extra: [
            "tool_name": "run_shell_command", "tool_input": ["command": "npm test"], "tool_response": ["llmContent": "ok"],
        ]), source: nil, entrypoint: nil, command: run)
        #expect(tool.stdout.isEmpty && tool.status == 0)
        await rig.waitUntil { rig.card("g-1") == nil }
        #expect(rig.upstream.current?.commands.count == told, "a tool event reaches upstream's helper")
        await rig.finished(Self.gemini("AfterAgent", extra: ["prompt": "fix the tests", "prompt_response": "Done."]), source: nil,
                           entrypoint: nil, events: [E.activity("g-1", "Done.")], command: run)
        #expect(rig.upstream.current?.commands.filter { $0.session == "g-1" }.map(\.event)
                    == ["SessionStart", "BeforeAgent", "Notification", "AfterAgent"])
        #expect(rig.upstream.current?.commands.filter { $0.session == "g-1" }.allSatisfy { $0.source == "gemini" } == true)
    }

    /// Antigravity CLI: no event name in its input, so each is told by its fields, in Gemini CLI's words, under its own
    /// row; nothing printed for any of them, and a Stop with work still running tells nothing (P1106, P1107).
    private func antigravity(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".gemini/config/hooks.json", source: "antigravity"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source antigravity 2>/dev/null || true")
        let id = "ec33ebf9-0cba-4100-8142-c61503f6c587", run = Self.shell(command)
        rig.upstream.current?.plan(event: "BeforeAgent", session: id,
                                   events: [E.started(id, tool: .geminiCLI, title: "Antigravity · project")])
        let start = await rig.hook(Self.antigravity(["invocationNum": 0, "initialNumSteps": 1], id: id), source: nil, entrypoint: nil,
                                   command: run).result()
        #expect(start.stdout.isEmpty && start.status == 0)
        await rig.waitUntil { rig.row(id)?.agent == .kind(.antigravity) }
        #expect(rig.row(id)?.agent == .kind(.antigravity), "\(String(describing: rig.row(id)?.agent)) \(rig.engine.state.sessions.map { "\($0.id) \($0.tool)" }) \(rig.upstream.current?.commands.map { "\($0.event) \($0.session) \($0.source)" } ?? [])")
        let tool = await rig.hook(Self.antigravity([
            "toolCall": ["name": "run_command", "args": ["CommandLine": "npm test", "Cwd": "/tmp/project"]], "stepIdx": 5, "error": "",
        ], id: id), source: nil, entrypoint: nil, command: run).result()
        #expect(tool.stdout.isEmpty && tool.status == 0)
        let busy = await rig.hook(Self.antigravity(["executionNum": 1, "terminationReason": "model_stop", "fullyIdle": false], id: id),
                                  source: nil, entrypoint: nil, command: run).result()
        let done = await rig.hook(Self.antigravity(["executionNum": 1, "terminationReason": "model_stop", "error": "", "fullyIdle": true],
                                                   id: id), source: nil, entrypoint: nil, command: run).result()
        #expect(busy.stdout.isEmpty && done.stdout.isEmpty && done.status == 0)
        await rig.waitUntil { rig.upstream.current?.commands.contains { $0.session == id && $0.event == "AfterAgent" } == true }
        #expect(rig.upstream.current?.commands.filter { $0.session == id }.map(\.event) == ["BeforeAgent", "BeforeAgent", "AfterAgent"])
        #expect(rig.card(id) == nil && rig.row(id)?.agent == .kind(.antigravity))
    }

    /// Grok Build through its own file: the row is Grok's, its permission prompt is "needs you" with no answer, and the
    /// copy of the same event through Claude's hooks brings nothing, so nothing is counted twice (P1111, P1112).
    private func grok(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".grok/hooks/juice-island.json", source: "grok"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source grok")
        let run = Self.shell(command)
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "session_start"]
        defer { rig.extraEnvironment = [:] }
        await rig.finished(Self.grok("SessionStart", camel: "session_start", session: "gk-1", extra: ["source": "startup"]), source: nil,
                           entrypoint: nil, events: [E.started("gk-1", tool: .grokBuild, title: "Grok · project")], command: run)
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "user_prompt_submit"]
        await rig.finished(Self.grok("UserPromptSubmit", camel: "user_prompt_submit", session: "gk-1", extra: ["prompt": "fix the tests"]),
                           source: nil, entrypoint: nil, events: [E.activity("gk-1", "Prompt: fix the tests")], command: run)
        await rig.waitUntil { rig.row("gk-1")?.agent == .other(.grokBuild) }
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "notification"]
        let asked = await rig.finished(Self.grok("Notification", camel: "notification", session: "gk-1", extra: [
            "notificationType": "permission_prompt", "message": "Tool permission requested", "level": "info",
        ]), source: nil, entrypoint: nil, command: run)
        #expect(asked.stdout.isEmpty && asked.status == 0)
        await rig.waitUntil { approval(rig, "gk-1")?.isNotice == true }
        #expect(approval(rig, "gk-1")?.isAnswerable == false)
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "post_tool_use"]
        await rig.finished(Self.grok("PostToolUse", camel: "post_tool_use", session: "gk-1", extra: [
            "toolName": "run_terminal_command", "tool_name": "run_terminal_command", "toolInput": ["command": "npm test"],
        ]), source: nil, entrypoint: nil, command: run)
        await rig.waitUntil { rig.card("gk-1") == nil }
        let told = rig.upstream.current?.commands.filter { $0.session == "gk-1" }.count
        #expect(rig.upstream.current?.commands.filter { $0.session == "gk-1" }.allSatisfy { $0.source == "grok" } == true)

        // Last, as the rig counts a note for every hook it starts: the same Stop through Claude's hooks, once Grok's own
        // file is in, ends silent; the bridge hears it once, from Grok's own.
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "stop"]
        await rig.finished(Self.grok("Stop", camel: "stop", session: "gk-1"), source: nil, entrypoint: nil, command: run)
        let heard = rig.notesHeard.current
        let claude = try #require(E.command(world, ".claude/settings.json", event: "Stop"))
        let copy = await rig.hook(Self.grok("Stop", camel: "stop", session: "gk-1"), source: nil, entrypoint: nil, command: claude).result()
        #expect(copy.stdout.isEmpty && copy.status == 0)
        await rig.settle()
        #expect(rig.notesHeard.current == heard)
        #expect(rig.upstream.current?.commands.filter { $0.session == "gk-1" }.count == told.map { $0 + 1 })
    }

    // MARK: Inputs, from each agent's docs and source

    /// https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/hooks/types.ts (`HookInput` and each
    /// event's own fields).
    static func gemini(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "g-1", "transcript_path": "/tmp/project/.gemini/chat.json", "cwd": "/tmp/project", "hook_event_name": event,
         "timestamp": "2026-10-03T10:00:00.000Z"].merging(extra) { $1 }
    }

    /// https://antigravity.google/docs/hooks/ (Input and output contract): the common fields, then the event's own; no
    /// event name.
    static func antigravity(_ fields: [String: Any], id: String) -> [String: Any] {
        ["conversationId": id, "workspacePaths": ["/tmp/project"],
         "transcriptPath": "/Users/test/.gemini/antigravity-cli/brain/\(id)/.system_generated/logs/transcript.jsonl",
         "artifactDirectoryPath": "/Users/test/.gemini/antigravity-cli/brain/\(id)", "modelName": "gemini-3.6-flash-medium"]
            .merging(fields) { $1 }
    }

    /// https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-hooks/src/event.rs (`HookEventEnvelope`,
    /// `SNAKE_CASE_ALIASES`): camelCase keys, with Claude's snake_case names for some.
    static func grok(_ event: String, camel: String, session: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["hookEventName": camel, "hook_event_name": event, "sessionId": session, "session_id": session, "cwd": "/tmp/project",
         "workspaceRoot": "/tmp/project", "timestamp": "2026-10-03T10:00:00Z"].merging(extra) { $1 }
    }
}
