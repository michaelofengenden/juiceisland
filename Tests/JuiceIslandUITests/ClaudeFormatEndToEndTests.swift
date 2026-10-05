import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 4's Claude-format agents end to end, in a temporary home (P1125 to P1149): Qoder, CodeBuddy, Factory Droid and
/// Kimi Code connected from the Agents pane's own model, their hook inputs (in the shapes their docs and source give,
/// `ClaudeFormatFixtures` and the comments below) run through the commands the installer wrote, with the built helper
/// copied into the scratch home, to the engine's real sockets and the stand-in for upstream's bridge. Approve agents'
/// approvals are cards answered in Claude's output; Watch agents' prompts are "needs you" with no Allow or Deny; Remove
/// gives every file back byte for byte. No agent runs: the fake commands only have to exist.
@MainActor
@Suite(.serialized)
struct ClaudeFormatEndToEndTests {
    /// Each agent's hook input, as its docs and source give it (the engine tests' `ClaudeFormatFixtures` have the same).
    enum Fixtures {
        /// Qoder CLI's PermissionRequest (`firePermissionRequestEvent`: base input, tool, no `tool_use_id`).
        /// Source: https://registry.npmjs.org/@qoder-ai/qodercli/-/qodercli-1.1.65.tgz (bundle/qodercli.js);
        /// https://docs.qoder.com/cli/hooks.
        static var qoderAsk: [String: Any] {
            ["session_id": "qd-1", "transcript_path": "/tmp/project/.qoder/qd-1.jsonl", "cwd": "/tmp/project",
             "hook_event_name": "PermissionRequest", "permission_mode": "default", "tool_name": "Bash",
             "tool_input": ["command": "git push origin main"], "permission_suggestions": [] as [Any]]
        }

        /// CodeBuddy Code's PermissionRequest (`executePermissionRequestHooks`), with its own mode `fullAccess`.
        /// Source: https://registry.npmjs.org/@tencent-ai/codebuddy-code/-/codebuddy-code-2.161.1.tgz (dist/codebuddy.js);
        /// https://www.codebuddy.ai/docs/cli/hooks.
        static var codebuddyAsk: [String: Any] {
            ["session_id": "cb-1", "transcript_path": "/tmp/project/.codebuddy/cb-1.jsonl", "cwd": "/tmp/project",
             "hook_event_name": "PermissionRequest", "permission_mode": "fullAccess", "tool_name": "Bash",
             "tool_input": ["command": "git push origin main"], "call_id": "call_9", "tool_use_id": "call_9"]
        }

        /// Factory Droid's Notification. Source: https://docs.factory.com/reference/hooks-reference.
        static func factoryNotice(_ type: String) -> [String: Any] {
            ["session_id": "fd-1", "transcript_path": "/tmp/project/.factory/fd-1.jsonl", "cwd": "/tmp/project",
             "permission_mode": "auto-low", "hook_event_name": "Notification", "message_id": "m-3",
             "message": type == "permission_prompt" ? "Droid needs your permission to use Execute" : "Droid has a question",
             "notification_type": type]
        }

        /// Kimi Code's PermissionRequest (`PermissionApprovalRequestedPayload`, snake case, its main agent `main`).
        /// Source: https://github.com/MoonshotAI/kimi-code (21406fb) packages/agent-core-v2/src/agent/toolApproval/
        /// toolApprovalService.ts and features/externalHooks/internal/matchHooks.ts.
        static var kimiAsk: [String: Any] {
            ["hook_event_name": "PermissionRequest", "session_id": "km-1", "cwd": "/tmp/project", "client_type": "kimi_code_cli",
             "session_title": "Fix the login page", "id": "apr-1", "agent_id": "main", "turn_id": 3, "tool_call_id": "call_1",
             "tool_name": "Shell", "action": "run command", "display": ["kind": "command", "command": "git push"],
             "tool_input": ["command": "git push"]]
        }

        /// Kimi Code's Interrupt (Esc). Source: as above, agent/agentExternalHooksService.ts `notifyTurnEnded`.
        static var kimiInterrupt: [String: Any] {
            ["hook_event_name": "Interrupt", "session_id": "km-1", "cwd": "/tmp/project", "client_type": "kimi_code_cli",
             "session_title": "Fix the login page", "turn_id": 3, "reason": "cancelled"]
        }
    }

    typealias World = AgentsEndToEndTests.World

    /// The owner's files before Connect. Factory Droid keeps its hooks in `settings.json` (no `hooks.json`), so Droid
    /// reads that and Connect writes there (P1126); Kimi Code's config has a table of its own after the model.
    static let before: [String: String] = [
        ".qoder/settings.json": "{\n  \"model\": \"auto\",\n  \"hooks\": {\n    \"Stop\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"say done\" }] }]\n  }\n}\n",
        ".codebuddy/settings.json": "{\n  \"permissions\": { \"allow\": [\"Read\"] }\n}\n",
        ".factory/settings.json": #"{"model":"claude-opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
        ".kimi-code/config.toml": "default_model = \"kimi-k2\"\n\n[loop_control]\nmax_steps_per_turn = 100\n",
    ]
    static let commands = ["qodercli", "codebuddy", "droid", "kimi"]
    static let agents = ["qoder", "codebuddy", "factory", "kimi"]

    /// The command the installer wrote for `event` in a JSON file (`"hooks"` or, in Droid's `hooks.json`, the top).
    static func command(_ world: World, _ path: String, event: String) -> String? {
        guard let data = try? Data(contentsOf: world.url(path)), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let events = (root["hooks"] as? [String: Any]) ?? root
        for entry in (events[event] as? [[String: Any]]) ?? [] {
            for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                if let command = hook["command"] as? String, command.contains(HookHome.helperName) { return command }
            }
        }
        return nil
    }

    /// The command in Kimi's `config.toml` for `event`.
    static func tomlCommand(_ world: World, event: String) throws -> String? {
        let data = try Data(contentsOf: world.url(".kimi-code/config.toml"))
        return try TOMLHookEdits.Scan(data).tables.first { $0.event == event && $0.command?.contains(HookHome.helperName) == true }?.command
    }

    static func started(_ id: String, tool: AgentTool, title: String) -> AgentEvent { AgentsEndToEndTests.started(id, tool: tool, title: title) }

    static func shaped(_ event: String, session: String, extra: [String: Any] = [:]) -> [String: Any] {
        AgentsEndToEndTests.claudeShaped(event, session: session, extra: extra)
    }

    func approval(_ rig: AttentionRig, _ id: String) -> ApprovalCardModel? {
        if case let .approval(card)? = rig.card(id) { card } else { nil }
    }

    /// Allow all never covers a Watch agent's card: the table says which are (P1129).
    @Test
    func allowAllLeavesTheWatchAgentsOut() {
        let watch = BatchAnswer.watchAgents(AppSettings.ephemeral())
        #expect(watch.isSuperset(of: [.other(.factory), .other(.kimiCLI)]))
        #expect(watch.isDisjoint(with: [.other(.qoder), .other(.codebuddy)]))
    }

    @Test
    func eachConnectsShowsItsRowsAnswersWhatItCanAndRemovesByteForByte() async throws {
        let world = try await World(files: Self.before, folders: [], commands: Self.commands)
        defer { world.stop() }
        await world.ready(Self.agents)
        #expect(world.pane.rows.map(\.id) == Self.agents)
        #expect(Self.agents.allSatisfy { world.row($0)?.status == .notConnected })
        #expect(world.row("qoder")?.reach == .approve && world.row("codebuddy")?.reach == .approve)
        #expect(world.row("factory")?.reach == .watch && world.row("kimi")?.reach == .watch)
        #expect(world.row("factory")?.place == "~/.factory/settings.json" && world.row("kimi")?.place == "~/.kimi-code/config.toml")
        #expect(world.row("kimi")?.name == "Kimi Code" && world.row("factory")?.name == "Factory Droid")
        #expect(world.row("qoder")?.look == AgentLook.of(.other(.qoder)) && world.row("kimi")?.look == AgentLook.of(.other(.kimiCLI)))

        for id in Self.agents {
            await world.click(.connect, on: id) { $0.status == .connected }
        }
        #expect(!FileManager.default.fileExists(atPath: world.url(".factory/hooks.json").path), "Droid reads settings.json here")

        try await qoder(world)
        try await codebuddy(world)
        try await factory(world)
        try await kimi(world)

        for id in Self.agents {
            await world.click(.remove, on: id) { $0.status == .notConnected }
        }
        for (path, text) in Self.before {
            #expect(world.text(path) == text, "\(path) is not as it was")
        }
    }

    /// Qoder's CLI (`QODER_HOOK_SOURCE=cli`): a row with Qoder's mark, its approval a card answered in Claude's output.
    /// The IDE's approval (no such variable) is "needs you" with no Allow or Deny, and the helper prints nothing.
    private func qoder(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".qoder/settings.json", event: "PermissionRequest"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source qoder")
        rig.extraEnvironment = ["QODER_HOOK_SOURCE": "cli"]
        defer { rig.extraEnvironment = [:] }
        await rig.finished(Self.shaped("SessionStart", session: "qd-1", extra: ["source": "startup", "permission_mode": "default"]),
                           entrypoint: nil, events: [Self.started("qd-1", tool: .qoder, title: "Qoder · project")], command: command)
        await rig.finished(Self.shaped("UserPromptSubmit", session: "qd-1", extra: ["prompt": "fix the tests"]), entrypoint: nil,
                           events: [AgentsEndToEndTests.activity("qd-1", "Prompt: fix the tests")], command: command)
        #expect(rig.row("qd-1")?.agent == .other(.qoder))
        let count = rig.engine.openRequests.count
        var ask = Fixtures.qoderAsk
        ask["session_id"] = "qd-1"
        let run = rig.hook(ask, entrypoint: nil, events: [AgentsEndToEndTests.asked("qd-1", tool: "Bash")], command: command)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        await rig.waitUntil { approval(rig, "qd-1")?.request?.answerable == true }
        #expect(approval(rig, "qd-1")?.isNotice == false)
        await rig.model.decide("qd-1", .allowOnce)
        let result = await run.result(within: 30)
        let output = AgentsEndToEndTests.object(result?.stdout ?? Data())?["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
        #expect((output?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        await rig.settle()

        // The IDE: the same approval, a notice.
        rig.extraEnvironment = [:]
        await rig.finished(Self.shaped("SessionStart", session: "qd-2", extra: ["source": "startup"]), entrypoint: nil,
                           events: [Self.started("qd-2", tool: .qoder, title: "Qoder · project")], command: command)
        ask["session_id"] = "qd-2"
        let ide = await rig.finished(ask, entrypoint: nil, command: command) { approval(rig, "qd-2") != nil }
        #expect(ide.stdout.isEmpty && ide.status == 0)
        #expect(approval(rig, "qd-2")?.isNotice == true && approval(rig, "qd-2")?.isAnswerable == false)
        #expect(rig.row("qd-2")?.bucket == .needsYou)
        #expect(rig.upstream.current?.commands.last.map { $0.event == "Notification" && $0.source == "qoder" } == true)
    }

    /// CodeBuddy: its own permission mode left out, a row with its mark, its approval answered in Claude's output.
    private func codebuddy(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".codebuddy/settings.json", event: "PermissionRequest"))
        await rig.finished(Self.shaped("SessionStart", session: "cb-1", extra: ["source": "startup", "permission_mode": "fullAccess"]),
                           entrypoint: nil, events: [Self.started("cb-1", tool: .codebuddy, title: "CodeBuddy · project")], command: command)
        await rig.finished(Self.shaped("UserPromptSubmit", session: "cb-1", extra: ["prompt": "fix the tests"]), entrypoint: nil,
                           events: [AgentsEndToEndTests.activity("cb-1", "Prompt: fix the tests")], command: command)
        #expect(rig.row("cb-1")?.agent == .other(.codebuddy))
        let count = rig.engine.openRequests.count
        var ask = Fixtures.codebuddyAsk
        ask["session_id"] = "cb-1"
        let run = rig.hook(ask, entrypoint: nil, events: [AgentsEndToEndTests.asked("cb-1", tool: "Bash")], command: command)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        await rig.waitUntil { approval(rig, "cb-1")?.request?.answerable == true }
        await rig.model.decide("cb-1", .deny)
        let result = await run.result(within: 30)
        let output = AgentsEndToEndTests.object(result?.stdout ?? Data())?["hookSpecificOutput"] as? [String: Any]
        #expect((output?["decision"] as? [String: Any])?["behavior"] as? String == "deny")
        await rig.settle()
    }

    /// Factory Droid (Watch): its `permission_prompt` is "needs you" with no Allow or Deny, its `elicitation_dialog` a
    /// question shown only; nothing printed.
    private func factory(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(Self.command(world, ".factory/settings.json", event: "Notification"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source factory")
        #expect(Self.command(world, ".factory/settings.json", event: "PreToolUse") == nil)
        await rig.finished(Self.shaped("SessionStart", session: "fd-1", extra: ["source": "startup", "permission_mode": "auto-low"]),
                           entrypoint: nil, events: [Self.started("fd-1", tool: .factory, title: "Factory · project")], command: command)
        await rig.finished(Self.shaped("UserPromptSubmit", session: "fd-1", extra: ["prompt": "fix the tests"]), entrypoint: nil,
                           events: [AgentsEndToEndTests.activity("fd-1", "Prompt: fix the tests")], command: command)
        #expect(rig.row("fd-1")?.agent == .other(.factory))
        var notice = Fixtures.factoryNotice("permission_prompt")
        notice["session_id"] = "fd-1"
        let shown = await rig.finished(notice, entrypoint: nil, command: command) { approval(rig, "fd-1") != nil }
        #expect(shown.stdout.isEmpty && shown.status == 0)
        #expect(approval(rig, "fd-1")?.isNotice == true && approval(rig, "fd-1")?.isAnswerable == false)
        #expect(rig.row("fd-1")?.bucket == .needsYou)
        await rig.finished(Self.shaped("Stop", session: "fd-1", extra: ["stop_hook_active": false]), entrypoint: nil, command: command)
        notice = Fixtures.factoryNotice("elicitation_dialog")
        notice["session_id"] = "fd-1"
        await rig.finished(notice, entrypoint: nil, command: command) { rig.card("fd-1") != nil }
        #expect(rig.row("fd-1")?.bucket == .needsYou)
    }

    /// Kimi Code (Watch): its PermissionRequest, which it fires and forgets as its own prompt opens, is "needs you" with
    /// no Allow or Deny; PermissionResult clears it; an Esc ends the turn. Its tables are in config.toml, after the
    /// owner's.
    private func kimi(_ world: World) async throws {
        let rig = world.rig
        let command = try #require(try Self.tomlCommand(world, event: "PermissionRequest"))
        #expect(command == "'\(rig.hookHome!.helperURL.path)' --source kimi")
        #expect(try Self.tomlCommand(world, event: "PreToolUse") == nil)
        #expect(world.text(".kimi-code/config.toml")?.hasPrefix(Self.before[".kimi-code/config.toml"]! + "\n[[hooks]]\n") == true)
        // Kimi Code's SessionStart: source, session title, model and profile (sessionExternalHooksService.ts).
        await rig.finished(["hook_event_name": "SessionStart", "session_id": "km-1", "cwd": "/tmp/project", "client_type": "kimi_code_cli",
                            "source": "startup", "session_title": "Fix the login page", "model": "kimi-k2", "profile": "default"],
                           entrypoint: nil, events: [Self.started("km-1", tool: .kimiCLI, title: "Kimi · project")], command: command)
        // No prompt event is installed (one fires before an approval, P1131), so the row shows while Kimi waits.
        var ask = Fixtures.kimiAsk
        ask["session_id"] = "km-1"
        let shown = await rig.finished(ask, entrypoint: nil, command: command) { approval(rig, "km-1") != nil }
        #expect(shown.stdout.isEmpty && shown.status == 0)
        #expect(rig.row("km-1")?.agent == .other(.kimiCLI))
        #expect(approval(rig, "km-1")?.isNotice == true && approval(rig, "km-1")?.isAnswerable == false)
        #expect(rig.row("km-1")?.bucket == .needsYou)
        #expect(rig.upstream.current?.commands.last.map { $0.event == "Notification" && $0.source == "kimi" } == true)
        // Answered in Kimi: PermissionResult, which upstream's decoder has no word for, still tells the engine.
        var result = ask
        result["hook_event_name"] = "PermissionResult"
        result["decision"] = "approved"
        await rig.finished(result, entrypoint: nil, command: command) { approval(rig, "km-1") == nil }
        #expect(rig.row("km-1")?.bucket != .needsYou)
        var interrupt = Fixtures.kimiInterrupt
        interrupt["session_id"] = "km-1"
        rig.upstream.current?.plan(event: "Stop", session: "km-1", events: [
            .sessionCompleted(SessionCompleted(sessionID: "km-1", summary: "Interrupted", timestamp: .now, isInterrupt: true))])
        await rig.finished(interrupt, entrypoint: nil, command: command)
        #expect(rig.upstream.current?.commands.last.map { $0.event == "Stop" && $0.source == "kimi" } == true)
    }
}
