import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Wave 4's lane GEMINI one piece at a time (P1100 to P1124): Gemini CLI, Antigravity CLI and Grok Build in the agents
/// table, their files connected and given back, their hooks through the helper, and the island's "needs you" from what
/// each says when its own prompt shows. Every payload below is shaped from the agent's current docs and source, named
/// beside it; none was captured from a running agent (P927). Scratch homes and made-up paths only; no socket is dialled.
enum WatchFixtures {
    static let helper = "/tmp/ji-home/bin/JuiceHooks"

    // Gemini CLI: snake_case, `HookInput` and each event's own fields.
    // https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/hooks/types.ts
    static func gemini(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "g-1", "transcript_path": "/tmp/project/.gemini/chat.json", "cwd": "/tmp/project", "hook_event_name": event,
         "timestamp": "2026-10-03T10:00:00.000Z"].merging(extra) { $1 }
    }

    // Gemini CLI's ToolPermission notification, fired just before its own prompt shows
    // (packages/core/src/scheduler/confirmation.ts `notifyHooks`; hookSystem.ts `toSerializableDetails`).
    static var geminiPermission: [String: Any] {
        gemini("Notification", extra: [
            "notification_type": "ToolPermission", "message": "Tool Shell requires execution",
            "details": ["type": "exec", "title": "Shell", "command": "npm test", "rootCommand": "npm"],
        ])
    }

    // Antigravity CLI: camelCase, no event name; the common fields, then the event's own.
    // https://antigravity.google/docs/hooks/ (Input and output contract), as captured by
    // https://github.com/entireio/cli/tree/main/cmd/entire/cli/agent/antigravity/testdata
    static var antigravityCommon: [String: Any] {
        ["conversationId": "ec33ebf9-0cba-4100-8142-c61503f6c587", "workspacePaths": ["/tmp/project"],
         "transcriptPath": "/Users/test/.gemini/antigravity-cli/brain/ec33ebf9/.system_generated/logs/transcript.jsonl",
         "artifactDirectoryPath": "/Users/test/.gemini/antigravity-cli/brain/ec33ebf9", "modelName": "gemini-3.6-flash-medium"]
    }
    static var preInvocation: [String: Any] { antigravityCommon.merging(["invocationNum": 0, "initialNumSteps": 1]) { $1 } }
    static var postToolUse: [String: Any] {
        antigravityCommon.merging([
            "toolCall": ["name": "run_command", "args": ["CommandLine": "npm test", "Cwd": "/tmp/project", "WaitMsBeforeAsync": 5000]],
            "stepIdx": 5, "error": "",
        ]) { $1 }
    }
    static var stop: [String: Any] {
        antigravityCommon.merging(["executionNum": 1, "terminationReason": "model_stop", "error": "", "fullyIdle": true]) { $1 }
    }
    static var stopBusy: [String: Any] {
        antigravityCommon.merging(["executionNum": 1, "terminationReason": "model_stop", "fullyIdle": false]) { $1 }
    }

    // Grok Build: the envelope's camelCase keys (`hookEventName` in snake_case words) plus Claude's snake_case aliases for
    // some of them (`hook_event_name` in PascalCase); never `notification_type`.
    // https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-hooks/src/event.rs (`HookEventEnvelope`,
    // `to_hook_json`, `SNAKE_CASE_ALIASES`); notification types from `acp_session_impl/updates.rs` and `spawn.rs`.
    static func grok(_ event: String, camel: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["hookEventName": camel, "hook_event_name": event, "sessionId": "gk-1", "session_id": "gk-1", "cwd": "/tmp/project",
         "workspaceRoot": "/tmp/project", "timestamp": "2026-10-03T10:00:00Z"].merging(extra) { $1 }
    }

    static var grokPermission: [String: Any] {
        grok("Notification", camel: "notification", extra: [
            "notificationType": "permission_prompt", "message": "Tool permission requested", "level": "info"])
    }
}

struct WatchAgentsTableTests {
    typealias Home = AgentHookInstallerTests.Home
    typealias W = WatchFixtures

    /// All three Watch: no approval event, no event that decides a call (Gemini's BeforeTool, Antigravity's PreToolUse,
    /// Grok's PreToolUse), Gemini's timeouts in milliseconds, and the fail-open tail where a failed hook would block.
    @Test
    func theThreeAreWatchAndRegisterNothingThatDecides() {
        for spec in [AgentHookTable.gemini, AgentHookTable.antigravity, AgentHookTable.grok] {
            #expect(spec.answers == .watch && spec.approvalEvents.isEmpty, "\(spec.kind)")
            #expect(!spec.events.contains { ["PreToolUse", "BeforeTool", "PermissionRequest", "PostInvocation"].contains($0.event) },
                    "\(spec.kind)")
            #expect(AgentHookTable.spec(spec.kind)?.name == spec.name)
        }
        #expect(AgentHookTable.gemini.events.allSatisfy { ($0.timeout ?? 0) >= 1_000 })
        #expect(AgentHookTable.gemini.events.map(\.event) == ["SessionStart", "BeforeAgent", "AfterTool", "Notification", "AfterAgent", "SessionEnd"])
        #expect(AgentHookTable.antigravity.events.map(\.event) == ["PreInvocation", "PostToolUse", "Stop"])
        #expect(Set(AgentHookTable.antigravity.events.map(\.event)) == Set(AntigravityHooks.Event.allCases.map(\.rawValue)))
        #expect(AgentHookTable.grok.events.allSatisfy { $0.timeout == 10 })
        #expect(Set(AgentHookTable.grok.events.map(\.event)).isSubset(of: Set(GrokHookEventName.allCases.map(\.rawValue))))
        let gemini = AgentHookTable.gemini.command(helperPath: W.helper)
        #expect(gemini == "'/tmp/ji-home/bin/JuiceHooks' --source gemini 2>/dev/null || true")
        #expect(AgentHookTable.isOurs(gemini, source: "gemini", helperPath: W.helper, tail: AgentHookTable.gemini.shellTail))
        #expect(!AgentHookTable.isOurs(gemini, source: "gemini", helperPath: W.helper))
        #expect(!AgentHookTable.isOurs("'/tmp/ji-home/bin/JuiceHooks' --source gemini", source: "gemini", helperPath: W.helper,
                                       tail: AgentHookTable.gemini.shellTail))
        #expect(AgentHookTable.grok.command(helperPath: W.helper) == "'/tmp/ji-home/bin/JuiceHooks' --source grok")
        // Found by their own command or folder, never by `~/.gemini` alone (P1100).
        #expect(AgentHookTable.gemini.footprintFolders == [".gemini/tmp"] && AgentHookTable.antigravity.footprintFolders == [".gemini/antigravity-cli"])
        // Grok Build only by the folders its installer makes: Homebrew's `grok` is a regex tool (P1187).
        #expect(AgentHookTable.antigravity.executables == ["agy"] && AgentHookTable.grok.executables.isEmpty)
        #expect(AgentHookTable.grok.footprintFolders == [".grok/bin", ".grok/hooks", ".grok/downloads"])
        #expect(AgentHookTable.cursor.footprintFolders == [".cursor"])
        #expect(AgentHookTable.antigravity.hooksKey(stem: "juice") == "juice" && AgentHookTable.gemini.hooksKey(stem: "juice") == "hooks")
    }

    /// Gemini CLI's settings: Juice's groups under `"hooks"` beside the owner's own settings and hooks, a backup first,
    /// and Remove gives the file back byte for byte; a file with comments is Add by hand with the exact lines.
    @Test
    func geminisSettingsAreEditedInPlaceAndGivenBack() throws {
        let home = Home(), spec = AgentHookTable.gemini
        try home.folder(".gemini")
        #expect(home.installer.status(spec) == .notConnected)
        let text = """
            {
              "general": { "vimMode": true },
              "hooks": {
                "AfterAgent": [{ "hooks": [{ "type": "command", "command": "say done" }] }]
              }
            }

            """
        try home.write(".gemini/settings.json", text)
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected && home.backups(".gemini").count == 1)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.url(".gemini/settings.json"))) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect((hooks["AfterAgent"] as? [Any])?.count == 2 && (root["general"] as? [String: Any])?["vimMode"] as? Bool == true)
        let tool = try #require((hooks["AfterTool"] as? [[String: Any]])?.first)
        #expect(tool["matcher"] as? String == "*")
        let hook = try #require((tool["hooks"] as? [[String: Any]])?.first)
        #expect(hook["timeout"] as? Int == 10_000 && hook["command"] as? String == spec.command(helperPath: W.helper))
        #expect((hooks["Notification"] as? [[String: Any]])?.first?["matcher"] == nil)
        try home.installer.remove(spec)
        #expect(home.read(".gemini/settings.json") == text)

        // Gemini reads its settings with comments: such a file is never written; its row gives the whole `"hooks"`.
        let commented = "{\n  // mine\n  \"hooks\": {}\n}\n"
        try home.write(".gemini/settings.json", commented)
        guard case let .addByHand(file, snippet, replaces) = home.installer.status(spec) else {
            Issue.record("not Add by hand: \(home.installer.status(spec))")
            return
        }
        #expect(file == "settings.json" && replaces && snippet.hasPrefix("\"hooks\": {") && snippet.contains("2>/dev/null || true"))
        #expect(throws: AgentHookInstaller.Failure.addByHand) { try home.installer.install(spec) }
        #expect(home.read(".gemini/settings.json") == commented)
    }

    /// No settings yet: Connect makes the file, Remove takes it away again.
    @Test
    func aGeminiWithNoSettingsGetsAFileThatRemoveTakes() throws {
        let home = Home(), spec = AgentHookTable.gemini
        try home.folder(".gemini")
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected)
        try home.installer.remove(spec)
        #expect(!FileManager.default.fileExists(atPath: home.url(".gemini/settings.json").path))
        #expect(home.installer.status(spec) == .notConnected)
    }

    /// Antigravity CLI's `hooks.json`: Juice's own hook name beside the owner's, flat handlers for PreInvocation and Stop,
    /// a matcher group for PostToolUse (the shapes agy accepts, antigravity-cli#925); the other flavor's name is the
    /// other flavor's (P925); Remove gives the file back byte for byte.
    @Test
    func antigravityGetsAHookNameOfItsOwn() throws {
        let home = Home(), spec = AgentHookTable.antigravity
        try home.folder(".gemini")
        #expect(home.installer.status(spec) == .notFound)
        #expect(throws: AgentHookInstaller.Failure.folderMissing) { try home.installer.install(spec) }
        // https://antigravity.google/docs/hooks/ (Schema and file format), the owner's own hooks.
        let text = """
            {
              "my-linter-hook": {
                "PostToolUse": [
                  { "matcher": "run_command", "hooks": [{ "type": "command", "command": "./scripts/lint.sh", "timeout": 10 }] }
                ]
              },
              "reminder": {
                "PreInvocation": [{ "type": "command", "command": "./scripts/reminder.sh" }]
              }
            }

            """
        try home.write(".gemini/config/hooks.json", text)
        #expect(home.installer.status(spec) == .notConnected)
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected && home.backups(".gemini/config").count == 1)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.url(".gemini/config/hooks.json"))) as? [String: Any])
        #expect(Set(root.keys) == ["my-linter-hook", "reminder", "juice-island"])
        let ours = try #require(root["juice-island"] as? [String: Any])
        let command = spec.command(helperPath: W.helper)
        for event in ["PreInvocation", "Stop"] {
            let entry = try #require((ours[event] as? [[String: Any]])?.first)
            #expect(entry["command"] as? String == command && entry["timeout"] as? Int == 10 && entry["hooks"] == nil, "\(event)")
        }
        let tool = try #require((ours["PostToolUse"] as? [[String: Any]])?.first)
        #expect(tool["matcher"] as? String == "*" && tool["command"] == nil)
        #expect((tool["hooks"] as? [[String: Any]])?.first?["command"] as? String == command)
        // A public Juice beside it reads its own name, not this one.
        let publicFlavor = AgentHookInstaller(home: home.root, helperPath: "/tmp/ji-public/bin/JuiceHooks", bundledHelper: nil,
                                              ownFileStem: "juice", bridgeSocketPath: "/tmp/ji-public/bridge.sock")
        #expect(publicFlavor.status(spec) == .notConnected)
        try home.installer.remove(spec)
        #expect(home.read(".gemini/config/hooks.json") == text)
    }

    /// An Antigravity file with only Juice's name in it was Juice's from the start: Remove takes it.
    @Test
    func antigravitysFileJuiceMadeGoesWithIt() throws {
        let home = Home(), spec = AgentHookTable.antigravity
        try home.folder(".gemini/config")
        try home.installer.install(spec)
        let snippet = home.installer.snippet(spec)
        #expect(snippet.hasPrefix("\"juice-island\": {") && snippet.contains("\"PreInvocation\""))
        try home.installer.remove(spec)
        #expect(!FileManager.default.fileExists(atPath: home.url(".gemini/config/hooks.json").path))
        #expect(FileManager.default.fileExists(atPath: home.url(".gemini/config").path))
    }

    /// Vibe Island's hooks under any other name of Antigravity's file hold Connect back (P933), and Switch to Juice finds
    /// and takes out only them (P955).
    @Test
    func vibeIslandsAntigravityHooksHoldConnectBackAndSwitchFindsThem() throws {
        let home = Home(), spec = AgentHookTable.antigravity
        let text = """
            {
              "vibe-island": {
                "Stop": [{ "type": "command", "command": "~/.vibe-island/bin/vibe-island-bridge --source antigravity" }]
              },
              "reminder": { "PreInvocation": [{ "type": "command", "command": "./scripts/reminder.sh" }] }
            }

            """
        try home.write(".gemini/config/hooks.json", text)
        #expect(home.installer.status(spec) == .vibeIsland(entries: 1, ours: 0))
        #expect(throws: AgentHookInstaller.Failure.vibeIsland) { try home.installer.install(spec) }
        let found = VibeIslandHooks.scan(VibeIslandHooks.places(home: home.root, profiles: []))
        #expect(found.map(\.place.agentID) == ["antigravity"] && found.first?.entries == 1)
        _ = VibeIslandHooks.remove(found)
        let left = try #require(home.read(".gemini/config/hooks.json"))
        #expect(!left.contains("vibe-island-bridge") && left.contains("./scripts/reminder.sh"))
        #expect(home.installer.status(spec) == .notConnected)
    }

    /// Grok Build: Juice's own file in its hooks folder, written whole, Claude's group shape; Remove takes the file and the
    /// folder Connect made; another file of Vibe Island's there holds Connect back.
    @Test
    func grokGetsItsOwnFileInItsHooksFolder() throws {
        let home = Home(), spec = AgentHookTable.grok
        try home.folder(".grok")
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.url(".grok/hooks/juice-island.json"))) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(spec.events.map(\.event)) && root["version"] == nil)
        #expect(OwnAgentHooks.connected(.grok, home: home.root.path))
        try home.installer.remove(spec)
        #expect(!FileManager.default.fileExists(atPath: home.url(".grok/hooks").path))
        #expect(!OwnAgentHooks.connected(.grok, home: home.root.path))
        try home.write(".grok/hooks/vibe-island.json",
                       #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.vibe-island/bin/vibe-island-bridge --source grok"}]}]}}"#)
        #expect(home.installer.status(spec) == .vibeIsland(entries: 1, ours: 0))
        let found = VibeIslandHooks.scan(VibeIslandHooks.places(home: home.root, profiles: []))
        #expect(found.map(\.place.agentID) == ["grok"])
    }
}

struct WatchAgentsHelperTests {
    typealias Box = EngineFixtures.Box
    typealias W = WatchFixtures

    private final class Calls: @unchecked Sendable {
        let notes = Box<[Data]>([])
        let bridged = Box<[BridgeCommand]>([])
    }

    private static func run(_ object: [String: Any], source: String, name: String? = nil, path: String? = nil,
                            environment: [String: String] = [:], connected: Bool = false, calls: Calls) -> HookPrelude.Outcome {
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        let input = try! JSONSerialization.data(withJSONObject: object)
        let io = HookPrelude.IO(
            preparePipe: { StdinPipe.make(replacing: fd) }, readStandardInput: { input }, agentPID: { 4242 },
            send: { data, _ in calls.notes.update { $0.append(data) } },
            agentName: { _ in name }, agentPath: { _ in path }, ownHooksConnected: { _ in connected },
            bridge: { command, _, _ in
                calls.bridged.update { $0.append(command) }
                return .acknowledged
            })
        return HookPrelude.run(environment: environment, arguments: ["JuiceHooks", "--source", source], io: io)
    }

    private static func gemini(_ command: BridgeCommand?) -> GeminiHookPayload? {
        if case let .processGeminiHook(payload)? = command { payload } else { nil }
    }

    /// Gemini CLI's tool events end with their note: upstream's helper cannot decode them, and its stderr would reach the
    /// owner as Gemini's message (P1101). Its other events go to upstream's helper as before, the permission notice's note
    /// carrying its type.
    @Test
    func geminisToolEventsEndWithTheirNoteAlone() {
        let calls = Calls()
        let after = W.gemini("AfterTool", extra: ["tool_name": "run_shell_command", "tool_input": ["command": "npm test"],
                                                   "tool_response": ["llmContent": "ok"]])
        guard case let .finished(note, output) = Self.run(after, source: "gemini", calls: calls) else {
            Issue.record("not finished")
            return
        }
        #expect(note?.event == "AfterTool" && note?.agentSource == "gemini" && note?.toolName == "run_shell_command" && output == nil)
        #expect(calls.bridged.current.isEmpty)
        guard case let .forwarded(permission) = Self.run(W.geminiPermission, source: "gemini", calls: calls) else {
            Issue.record("not forwarded")
            return
        }
        #expect(permission?.notificationType == "ToolPermission" && permission?.sessionID == "g-1")
        guard case .forwarded = Self.run(W.gemini("BeforeAgent", extra: ["prompt": "fix the tests"]), source: "gemini", calls: calls) else {
            Issue.record("not forwarded")
            return
        }
    }

    /// Antigravity CLI: each event told by its fields, told to the bridge in Gemini CLI's words, its note in Claude's
    /// names, and nothing printed (P1106, P1107).
    @Test
    func antigravitysHooksAreToldInGeminisWordsAndAnsweredWithNothing() throws {
        let calls = Calls()
        #expect(AntigravityHooks.event(of: W.preInvocation) == .preInvocation && AntigravityHooks.event(of: W.postToolUse) == .postToolUse)
        #expect(AntigravityHooks.event(of: W.stop) == .stop && AntigravityHooks.event(of: W.antigravityCommon) == nil)
        for (object, name) in [(W.preInvocation, GeminiHookEventName.beforeAgent), (W.postToolUse, .beforeAgent), (W.stop, .afterAgent)] {
            let before = calls.bridged.current.count
            guard case let .finished(note, output) = Self.run(object, source: "antigravity", calls: calls) else {
                Issue.record("not finished")
                continue
            }
            #expect(output == nil)
            #expect(note?.sessionID == "ec33ebf9-0cba-4100-8142-c61503f6c587" && note?.agentSource == "antigravity")
            let payload = try #require(Self.gemini(calls.bridged.current.dropFirst(before).first))
            #expect(payload.hookEventName == name && payload.sessionID == note?.sessionID && payload.cwd == "/tmp/project")
            #expect(payload.transcriptPath == nil && payload.prompt == nil)
        }
        let tool = try #require(HookContextNote.decode(calls.notes.current[1]))
        #expect(tool.event == "PostToolUse" && tool.toolName == "run_command")
        // A Stop whose background work still runs tells the bridge nothing; its note still goes.
        let before = calls.bridged.current.count
        guard case let .finished(note, nil) = Self.run(W.stopBusy, source: "antigravity", calls: calls) else {
            Issue.record("not finished")
            return
        }
        #expect(note?.event == "Stop" && calls.bridged.current.count == before)
        // Fields it cannot place: no note, nothing told, nothing printed.
        let notes = calls.notes.current.count
        #expect(Self.run(W.antigravityCommon, source: "antigravity", calls: calls) == .finished(note: nil, output: nil))
        #expect(calls.notes.current.count == notes && calls.bridged.current.count == before)
    }

    /// Grok Build through Claude's settings (it runs them, P1111): the helper names it by its process, its executable's
    /// path or its hook variable, tells the bridge as Grok's, never as Claude Code's, and prints nothing. With Grok's own
    /// file in, that copy brings nothing at all.
    @Test
    func grokThroughClaudesHooksIsGroksNeverClaudes() throws {
        let start = W.grok("SessionStart", camel: "session_start", extra: ["source": "startup"])
        for (name, path, environment) in [("grok", nil, [:]), ("agent", "/Users/someone/.grok/downloads/grok-darwin-arm64", [:]),
                                          ("agent", nil, ["GROK_HOOK_EVENT": "session_start"])] as [(String, String?, [String: String])] {
            let calls = Calls()
            guard case let .finished(note, output) = Self.run(start, source: "claude", name: name, path: path, environment: environment,
                                                              calls: calls) else {
                Issue.record("not finished: \(name)")
                continue
            }
            #expect(note?.agentSource == "grok" && output == nil, "\(name)")
            guard case let .processGrokHook(payload)? = calls.bridged.current.first else {
                Issue.record("not Grok's: \(calls.bridged.current)")
                continue
            }
            #expect(payload.sessionID == "gk-1" && payload.hookEventName == .sessionStart && calls.bridged.current.count == 1)
        }
        // Snake_case alone (an older Grok, or a test's Claude-shaped input) decodes too.
        let calls = Calls()
        _ = Self.run(["hook_event_name": "Stop", "session_id": "gk-2", "cwd": "/tmp/project"], source: "claude", name: "grok", calls: calls)
        guard case let .processGrokHook(stop)? = calls.bridged.current.first else {
            Issue.record("nothing told")
            return
        }
        #expect(stop.sessionID == "gk-2" && stop.hookEventName == .stop)
        let silent = Calls()
        #expect(Self.run(start, source: "claude", name: "grok", connected: true, calls: silent) == .finished(note: nil, output: nil))
        #expect(silent.notes.current.isEmpty && silent.bridged.current.isEmpty)
    }

    /// Grok's own hooks go to upstream's helper as before, their notes in Claude's names so the engine reads Grok's
    /// permission_prompt (P1112); Grok running Cursor's hooks brings nothing (P1111).
    @Test
    func grokNotesNameTheirTypeAndItsCursorCopyIsSilent() throws {
        let calls = Calls()
        guard case let .forwarded(note) = Self.run(W.grokPermission, source: "grok", calls: calls) else {
            Issue.record("not forwarded")
            return
        }
        #expect(note?.event == "Notification" && note?.notificationType == "permission_prompt" && note?.agentSource == "grok")
        let camelOnly: [String: Any] = ["hookEventName": "post_tool_use", "sessionId": "gk-3", "toolName": "run_terminal_command"]
        let normalized = GrokHookFields.noteObject(camelOnly)
        #expect(normalized["hook_event_name"] as? String == "PostToolUse" && normalized["session_id"] as? String == "gk-3")
        #expect(normalized["tool_name"] as? String == "run_terminal_command")
        let cursor = ["hook_event_name": "PreToolUse", "hookEventName": "pre_tool_use", "session_id": "gk-1", "sessionId": "gk-1",
                      "conversation_id": "gk-1", "cwd": "/tmp/project"]
        let quiet = Calls()
        #expect(Self.run(cursor, source: "cursor", name: "grok", calls: quiet) == .finished(note: nil, output: nil))
        #expect(quiet.notes.current.isEmpty && quiet.bridged.current.isEmpty)
    }

    /// Grok's hook variable and its install's path name it; its MCP servers' `GROK_SESSION_ID` and a plain `agent` do not.
    @Test
    func grokIsNamedOnlyOnItsOwnSigns() {
        func agent(_ name: String?, _ path: String? = nil, _ environment: [String: String] = [:]) -> AgentKind? {
            HookCaller.agent(HookCaller.Signs(agentName: name, agentPath: path, environment: environment))
        }
        #expect(agent("agent", nil, ["GROK_HOOK_EVENT": "stop"]) == .grok)
        #expect(agent("agent", "/Users/someone/.grok/downloads/grok-darwin-arm64") == .grok)
        #expect(agent("node", nil, ["GROK_SESSION_ID": "gk-1"]) == nil && agent("agent") == nil)
        #expect(agent("claude", nil, ["GROK_HOOK_EVENT": "stop"]) == nil)
        #expect(agent("node", "/Users/someone/.grok/bin/node") == nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ji-grok-own-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".grok/hooks/juice.json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/tmp/p/bin/JuiceHooks' --source grok"}]}]}}"#.utf8).write(to: file)
        #expect(OwnAgentHooks.connected(.grok, home: home.path) && !OwnAgentHooks.connected(.devin, home: home.path))
    }
}

/// What the island says of the three: Gemini's ToolPermission and Grok's permission_prompt are "needs you" with no
/// answer (a notice), gone once the agent moves on; an Antigravity session is labelled Antigravity's (P1103, P1107, P1112).
@MainActor
struct WatchAgentsAttentionTests {
    typealias W = WatchFixtures

    @Test
    func geminisPermissionNoticeNeedsYouUntilItsToolRuns() {
        let scene = AttentionScene()
        scene.begin("g-1", tool: .geminiCLI)
        scene.hook(W.geminiPermission, source: "gemini", entrypoint: nil)
        let head = scene.head("g-1")
        #expect(head?.content == .notice && head?.isAnswerable == false && head?.kind == .approval)
        #expect(scene.needsYou.count == 1)
        scene.hook(W.gemini("AfterTool", extra: ["tool_name": "run_shell_command"]), source: "gemini", entrypoint: nil)
        #expect(scene.head("g-1") == nil)
        // Its other notifications say nothing.
        scene.hook(W.gemini("Notification", extra: ["notification_type": "Other"]), source: "gemini", entrypoint: nil)
        #expect(scene.head("g-1") == nil)
    }

    @Test
    func groksPermissionPromptNeedsYouAndItsQuestionAsksWithoutAnswers() {
        let scene = AttentionScene()
        scene.begin("gk-1", tool: .grokBuild)
        let note = GrokHookFields.noteObject(W.grokPermission)
        scene.hook(note, source: "grok", entrypoint: nil)
        #expect(scene.head("gk-1")?.content == .notice && scene.head("gk-1")?.isAnswerable == false)
        scene.hook(GrokHookFields.noteObject(W.grok("PostToolUse", camel: "post_tool_use", extra: ["toolName": "run_terminal_command"])),
                   source: "grok", entrypoint: nil)
        #expect(scene.head("gk-1") == nil)
        scene.hook(GrokHookFields.noteObject(W.grok("Notification", camel: "notification", extra: ["notificationType": "elicitation_dialog"])),
                   source: "grok", entrypoint: nil)
        #expect(scene.head("gk-1")?.kind == .elicitation && scene.head("gk-1")?.isAnswerable == false)
    }

    @Test
    func anAntigravitySessionIsAntigravitys() throws {
        let scene = AttentionScene()
        let id = "ec33ebf9-0cba-4100-8142-c61503f6c587"
        scene.begin(id, tool: .geminiCLI)
        scene.hook(try #require(AntigravityHooks.noteObject(W.preInvocation)), source: "antigravity", entrypoint: nil)
        let session = try #require(scene.engine.state.session(id: id))
        #expect(scene.engine.agent(of: session) == .antigravity)
        #expect(AgentKind.antigravity.carrierTool == .geminiCLI && AgentKind.antigravity.needsLabel)
        // A Gemini CLI session stays Gemini's.
        scene.begin("g-1", tool: .geminiCLI)
        scene.hook(W.gemini("BeforeAgent"), source: "gemini", entrypoint: nil)
        #expect(scene.engine.agent(of: try #require(scene.engine.state.session(id: "g-1"))) == .gemini)
    }

    /// agy's hooks carry no prompt: its first model call since its last Stop begins the owner's turn, so the session
    /// shows without one (P155), its later calls in the turn begin nothing, and each turn's Done is its own (P1107).
    @Test
    func anAntigravityTurnShowsItsSessionAndEachTurnIsDoneOnce() throws {
        typealias F = EngineFixtures
        let scene = AttentionScene()
        let id = "ec33ebf9-0cba-4100-8142-c61503f6c587"
        let call = try #require(AntigravityHooks.noteObject(W.preInvocation))
        let tool = try #require(AntigravityHooks.noteObject(W.postToolUse))
        let stop = try #require(AntigravityHooks.noteObject(W.stop))
        // The turn upstream's bridge is told of in Gemini CLI's words, with no prompt.
        let started = F.running(id, summary: "Gemini CLI started a new turn in project.")
        scene.hook(call, source: "antigravity", entrypoint: nil)
        scene.bridge(F.started(id, tool: .geminiCLI, title: "Gemini CLI · project", phase: .completed), started)
        #expect(scene.engine.rows.map(\.id) == [id])
        scene.hook(tool, source: "antigravity", entrypoint: nil)
        scene.hook(call, source: "antigravity", entrypoint: nil)
        #expect(scene.engine.signals.turn(for: id) == 1)
        scene.hook(stop, source: "antigravity", entrypoint: nil)
        scene.bridge(F.completed(id))
        scene.at(scene.t + 2)
        #expect(scene.dones == [.done(sessionID: id)])
        scene.hook(call, source: "antigravity", entrypoint: nil)
        scene.bridge(started)
        #expect(scene.engine.signals.turn(for: id) == 2)
        scene.hook(stop, source: "antigravity", entrypoint: nil)
        scene.bridge(F.completed(id))
        scene.at(scene.t + 2)
        #expect(scene.dones.count == 2)
        // Gemini CLI's own sessions still wait for a prompt.
        scene.hook(W.gemini("BeforeTool", extra: ["tool_name": "read_file"]), source: "gemini", entrypoint: nil)
        scene.bridge(F.started("g-2", tool: .geminiCLI, title: "Gemini CLI · project"))
        #expect(!scene.engine.rows.contains { $0.id == "g-2" })
    }
}
