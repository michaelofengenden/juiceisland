import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Wave 1's pieces one at a time (P900 to P934): Juice's helper home, the agents table's file edits and installer, who
/// fired a Claude hook, the helper's own runner and its answers, Open Island's socket relayed, and the rows' agent labels.
/// Scratch folders with made-up paths only; the relay binds scratch sockets.
struct HookHomeTests {
    @Test
    func aHomeHoldsTheHelperAndItsSockets() {
        let home = HookHome(supportFolderNamed: "Juice Island", home: "/Users/test")
        #expect(home.helperURL.path == "/Users/test/Library/Application Support/Juice Island/bin/JuiceHooks")
        #expect(home.bridgeURL.path == "/Users/test/Library/Application Support/Juice Island/bridge.sock")
        #expect(home.notesURL.lastPathComponent == "hook-notes.sock" && home.requestsURL.lastPathComponent == "hook-requests.sock")
        #expect(LegacyHookHome.helperURL(home: "/Users/test").path == "/Users/test/Library/Application Support/OpenIsland/bin/OpenIslandHooks")
        #expect(!HookHome.helperName.lowercased().contains("openislandhooks"))
    }

    /// A long folder (a public flavor's bundle id) gets the short socket names, so both sides still agree (P902).
    @Test
    func aLongFolderUsesTheShortSocketNames() {
        let home = HookHome(folder: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 84)))
        #expect(home.notesURL.lastPathComponent == "notes.sock" && home.requestsURL.lastPathComponent == "requests.sock")
        #expect(HookHome.fitsSocketAddress(home.notesURL) && HookHome.fitsSocketAddress(home.requestsURL))
    }

    /// Only `<folder>/bin/JuiceHooks` has a home: Open Island's helper and a build product keep their old sockets.
    @Test
    func onlyAHelperInABinFolderHasAHome() {
        #expect(HookHome.of(helperExecutable: URL(fileURLWithPath: "/tmp/a/bin/JuiceHooks"))?.folder.path == "/tmp/a")
        #expect(HookHome.of(helperExecutable: URL(fileURLWithPath: "/tmp/a/bin/OpenIslandHooks")) == nil)
        #expect(HookHome.of(helperExecutable: URL(fileURLWithPath: "/tmp/a/JuiceHooks")) == nil)
        #expect(HookHome.of(helperExecutable: nil) == nil)
        let home = HookHome(folder: URL(fileURLWithPath: "/tmp/a"))
        #expect(HookPrelude.bridgeURL(environment: [:], home: home) == home.bridgeURL)
        #expect(HookNoteSocket.helperURL(environment: [:], home: home) == home.notesURL)
        #expect(HookNoteSocket.helperURL(environment: [HookNoteSocket.overrideKey: "/tmp/n.sock"], home: home).path == "/tmp/n.sock")
        #expect(HookRequestSocket.helperURL(environment: [:], home: home) == home.requestsURL)
    }
}

struct HookCallerTests {
    private func agent(_ name: String?, _ environment: [String: String] = [:]) -> AgentKind? {
        HookCaller.agent(HookCaller.Signs(agentName: name, environment: environment))
    }

    /// The agent's process name decides first; then Claude's own marks; then Devin's; an unknown caller stays Claude's.
    @Test
    func theCallerIsNamedOnlyOnAPositiveSign() {
        #expect(agent("claude") == nil && agent("claude", ["DEVIN_PROJECT_DIR": "/tmp/p"]) == nil)
        #expect(agent("devin") == .devin && agent("grok") == .grok && agent("cursor-agent") == .cursor)
        #expect(agent("Cursor Helper (P") == .cursor && agent("Code Helper (Plu") == .copilot)
        #expect(agent("node", ["CLAUDE_CODE_ENTRYPOINT": "cli", "DEVIN_PROJECT_DIR": "/tmp/p"]) == nil)
        #expect(agent("node", ["CLAUDECODE": "1"]) == nil)
        #expect(agent("node", ["DEVIN_PROJECT_DIR": "/tmp/p"]) == .devin)
        #expect(agent(nil) == nil && agent("node") == nil && agent("zsh", ["DEVIN_PROJECT_DIR": ""]) == nil)
        // The Cursor CLI as it runs: `cursor-agent` is a script that execs its own Node, so the kernel names it `node`
        // and only its path says whose (P905). Any other Node stays Claude's.
        let cursorNode = "/Users/someone/.local/share/cursor-agent/versions/2025.10.02-bd871ac/node"
        #expect(HookCaller.agent(HookCaller.Signs(agentName: "node", agentPath: cursorNode, environment: ["CLAUDECODE": "1"])) == .cursor)
        #expect(HookCaller.agent(HookCaller.Signs(agentName: "node", agentPath: "/opt/homebrew/Cellar/node/24.1.0/bin/node",
                                                  environment: [:])) == nil)
        #expect(HookCaller.agent(HookCaller.Signs(agentName: "node", agentPath: "/Users/someone/cursor-agent/node", environment: [:])) == nil)
        #expect(HookCaller.answersThroughClaudeHook(.devin))
        #expect(![AgentKind.grok, .cursor, .copilot].contains(where: HookCaller.answersThroughClaudeHook))
    }

    /// An agent's own config with Juice's hooks for it: its copy of Claude's hooks then ends silent (P909).
    @Test
    func ownHooksAreSeenOnlyForThatAgent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ji-own-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!OwnAgentHooks.connected(.devin, home: home.path))
        let file = home.appendingPathComponent(".config/devin/config.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/tmp/h/bin/JuiceHooks' --source claude"}]}]}}"#.utf8).write(to: file)
        #expect(!OwnAgentHooks.connected(.devin, home: home.path))
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/tmp/h/bin/JuiceHooks' --source devin"}]}]}}"#.utf8).write(to: file)
        #expect(OwnAgentHooks.connected(.devin, home: home.path) && !OwnAgentHooks.connected(.cursor, home: home.path))
        #expect(!OwnAgentHooks.connected(.grok, home: home.path))
    }
}

struct ClaudeFamilyRunnerTests {
    typealias Box = EngineFixtures.Box

    private static func line(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

    /// Each agent's answer in its own words, one line, keys sorted; nothing for an acknowledgement.
    @Test
    func answersComeBackInEachAgentsWords() throws {
        let allow = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: nil, updatedPermissions: [])))
        let deny = BridgeResponse.claudeHookDirective(.permissionRequest(.deny(message: "Not now", interrupt: true)))
        #expect(Self.line(ClaudeFamilyRunner.output(for: allow, kind: .copilot)) == "{\"behavior\":\"allow\"}\n")
        #expect(Self.line(ClaudeFamilyRunner.output(for: deny, kind: .copilot)) == "{\"behavior\":\"deny\",\"interrupt\":true,\"message\":\"Not now\"}\n")
        #expect(Self.line(ClaudeFamilyRunner.output(for: allow, kind: .devin)) == "{\"decision\":\"approve\"}\n")
        #expect(Self.line(ClaudeFamilyRunner.output(for: deny, kind: .devin)) == "{\"decision\":\"block\",\"reason\":\"Not now\"}\n")
        let preAllow = BridgeResponse.claudeHookDirective(.preToolUse(ClaudePreToolUseDirective(permissionDecision: .allow)))
        let preAsk = BridgeResponse.claudeHookDirective(.preToolUse(ClaudePreToolUseDirective(permissionDecision: .ask)))
        #expect(Self.line(ClaudeFamilyRunner.output(for: preAllow, kind: .devin)) == "{\"decision\":\"approve\"}\n")
        #expect(ClaudeFamilyRunner.output(for: preAsk, kind: .devin) == nil)
        #expect(ClaudeFamilyRunner.output(for: preAllow, kind: .copilot) == nil)
        // Qwen reads Claude's own output, and never an `ask` (P921).
        let qwen = try #require(ClaudeFamilyRunner.output(for: allow, kind: .qwen))
        let decision = try #require(((try JSONSerialization.jsonObject(with: qwen) as? [String: Any])?["hookSpecificOutput"]
                                     as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect(ClaudeFamilyRunner.output(for: preAsk, kind: .qwen) == nil)
        for kind in [AgentKind.copilot, .devin, .qwen] {
            #expect(ClaudeFamilyRunner.output(for: .acknowledged, kind: kind) == nil)
        }
    }

    /// Upstream's decoder takes only Claude's words: Copilot's `new` start is a startup, an unknown mode is left out, and
    /// a missing folder comes from Devin's variable (P924).
    @Test
    func agentsWordsAreReadAsClaudesNearest() throws {
        let start = try #require(ClaudeFamilyRunner.payload(
            object: ["hook_event_name": "SessionStart", "session_id": "cp-1", "cwd": "/tmp/p", "source": "new", "permission_mode": "yolo"],
            kind: .copilot, environment: [:]))
        #expect(start.source == ClaudeSessionStartSource.startup && start.permissionMode == nil && start.hookSource == "codebuddy")
        let devin = try #require(ClaudeFamilyRunner.payload(object: ["hook_event_name": "Stop", "session_id": "d-1"], kind: .devin,
                                                            environment: ["DEVIN_PROJECT_DIR": "/tmp/project"]))
        #expect(devin.cwd == "/tmp/project")
        let qwen = try #require(ClaudeFamilyRunner.payload(object: ["hook_event_name": "Stop", "session_id": "q-1", "cwd": "/tmp/p"],
                                                           kind: .qwen, environment: [:]))
        #expect(qwen.hookSource == "qwen")
        #expect(ClaudeFamilyRunner.payload(object: ["hook_event_name": "Nope", "session_id": "x", "cwd": "/tmp"], kind: .copilot,
                                           environment: [:]) == nil)
    }

    /// The command and how long the helper waits: an approval up to just under the agent's own timeout.
    @Test
    func theBridgeIsAskedWithTheAgentsTimeout() {
        let asked = Box<[(BridgeCommand, TimeInterval)]>([])
        let send: ClaudeFamilyRunner.Send = { command, timeout in
            asked.update { $0.append((command, timeout)) }
            return .acknowledged
        }
        let request: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/tmp/p", "tool_name": "bash",
                                      "tool_input": ["command": "ls"]]
        for kind in [AgentKind.copilot, .qwen] {
            #expect(ClaudeFamilyRunner.run(object: request, kind: kind, environment: [:], send: send) == nil)
        }
        _ = ClaudeFamilyRunner.run(object: ["hook_event_name": "Stop", "session_id": "s", "cwd": "/tmp/p"], kind: .devin,
                                   environment: [:], send: send)
        let expected: [TimeInterval] = [ClaudeFamilyRunner.permissionTimeout, ClaudeFamilyRunner.qwenPermissionTimeout, 45]
        let timeouts = asked.current.map { $0.1 }
        #expect(timeouts == expected && ClaudeFamilyRunner.qwenPermissionTimeout < 900)
        #expect(asked.current.allSatisfy { if case .processClaudeHook = $0.0 { true } else { false } })
    }
}

/// The prelude's routes for the wave's agents, with stand-ins for every socket.
struct HookPreludeCallerTests {
    typealias Box = EngineFixtures.Box

    private struct Calls {
        let notes = Box<[URL]>([])
        let bridged = Box<[(BridgeCommand, URL)]>([])
        let brokered = Box(0)
    }

    private static func run(_ object: [String: Any], source: String, name: String? = nil, path: String? = nil,
                            environment: [String: String] = [:], connected: Bool = false, home: HookHome? = nil,
                            answer: BridgeResponse? = .acknowledged, calls: Calls) -> HookPrelude.Outcome {
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        let input = try! JSONSerialization.data(withJSONObject: object)
        let io = HookPrelude.IO(
            preparePipe: { StdinPipe.make(replacing: fd) }, readStandardInput: { input }, agentPID: { 4242 },
            send: { _, url in calls.notes.update { $0.append(url) } },
            broker: { _, _, _ in
                calls.brokered.update { $0 += 1 }
                return .noBroker
            },
            home: { home }, agentName: { _ in name }, agentPath: { _ in path }, ownHooksConnected: { _ in connected },
            bridge: { command, _, url in
                calls.bridged.update { $0.append((command, url)) }
                return answer
            })
        return HookPrelude.run(environment: environment, arguments: ["JuiceHooks", "--source", source], io: io)
    }

    private static var ask: [String: Any] {
        ["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/p", "tool_name": "Bash", "tool_input": ["command": "git push"]]
    }
    private static let allow = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: nil, updatedPermissions: [])))

    /// Devin through Claude's settings: its note names Devin, the helper's runner asks the bridge and answers in Devin's
    /// words; nothing reaches the broker.
    @Test
    func devinThroughClaudesHooksIsAnsweredInDevinsWords() {
        let calls = Calls()
        let outcome = Self.run(Self.ask, source: "claude", name: "devin", answer: Self.allow, calls: calls)
        guard case let .finished(note, output) = outcome else {
            Issue.record("not finished: \(outcome)")
            return
        }
        #expect(note?.agentSource == "devin" && output.map { String(decoding: $0, as: UTF8.self) } == "{\"decision\":\"approve\"}\n")
        #expect(calls.brokered.current == 0 && calls.bridged.current.count == 1)
    }

    /// Grok's approval through Claude's hook stays in Grok (it ignores verdicts); its other events still show.
    @Test
    func anApprovalFromAnAgentThatIgnoresTheAnswerEndsSilent() {
        let calls = Calls()
        #expect(Self.run(Self.ask, source: "claude", name: "grok", calls: calls) == .finished(note: HookContextNote.make(
            object: Self.ask, environment: [:], agentPID: 4242, source: "grok"), output: nil))
        #expect(calls.bridged.current.isEmpty && calls.brokered.current == 0 && calls.notes.current.count == 1)
        _ = Self.run(["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/p"], source: "claude", name: "grok", calls: calls)
        #expect(calls.bridged.current.count == 1)
    }

    /// Devin with its own config connected: the Claude copy of each event ends with nothing at all (P909).
    @Test
    func anAgentsOwnHooksSilenceItsClaudeCopy() {
        let calls = Calls()
        #expect(Self.run(Self.ask, source: "claude", name: "devin", connected: true, calls: calls) == .finished(note: nil, output: nil))
        #expect(calls.notes.current.isEmpty && calls.bridged.current.isEmpty && calls.brokered.current == 0)
    }

    /// Claude Code itself still goes to the broker, and an unknown caller stays Claude's (P906).
    @Test
    func claudeCodeAndUnknownCallersKeepClaudesRoute() {
        let calls = Calls()
        _ = Self.run(Self.ask, source: "claude", name: "claude", calls: calls)
        _ = Self.run(Self.ask, source: "claude", name: "node", environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"], calls: calls)
        _ = Self.run(Self.ask, source: "claude", name: nil, calls: calls)
        #expect(calls.brokered.current == 3 && calls.bridged.current.isEmpty)
    }

    /// Cursor is Watch: each of its hooks goes to the bridge for the island to show, and the helper prints nothing, so
    /// upstream's `allow` never reaches Cursor and Cursor's own rules decide (P930). Its Claude-format copy, from the
    /// Cursor CLI named by its path, keeps its approval in Cursor (P907, P905).
    @Test
    func cursorsHooksShowOnTheIslandAndAnswerNothing() {
        let calls = Calls()
        let allow = BridgeResponse.cursorHookDirective(CursorHookDirective(permission: .allow))
        for event in ["beforeShellExecution", "beforeMCPExecution", "beforeSubmitPrompt", "stop"] {
            let outcome = Self.run(["hook_event_name": event, "conversation_id": "cu-1", "generation_id": "g-1", "command": "curl x | sh",
                                    "cwd": "/tmp/p"], source: "cursor", answer: allow, calls: calls)
            guard case .finished(_, nil) = outcome else {
                Issue.record("\(event): \(outcome)")
                continue
            }
        }
        #expect(calls.bridged.current.count == 4 && calls.brokered.current == 0)
        #expect(calls.bridged.current.allSatisfy { if case .processCursorHook = $0.0 { true } else { false } })
        let cursorNode = "/Users/someone/.local/share/cursor-agent/versions/2025.10.02-bd871ac/node"
        #expect(Self.run(Self.ask, source: "claude", name: "node", path: cursorNode, calls: calls) == .finished(note: HookContextNote.make(
            object: Self.ask, environment: [:], agentPID: 4242, source: "cursor"), output: nil))
        #expect(calls.brokered.current == 0)
    }

    /// An IO made anywhere but the real helper finds no request broker either, even beside a listening socket: a test
    /// that leaves the broker out never reaches a live app's requests (P929).
    @Test
    func onlyTheRealProcessDialsABroker() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jb-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("r.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try #require(HookNoteSocket.address(for: url))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 4) == 0)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let io = HookPrelude.IO(preparePipe: { nil }, readStandardInput: { Data() }, agentPID: { nil }, send: { _, _ in })
        #expect(io.broker(Data("{}\n".utf8), url, "claude") == .noBroker)
        #expect(accept(fd, nil, nil) < 0)
    }

    /// An IO made anywhere but the real helper (`.process`) dials no bridge: a test that leaves the bridge out gets no
    /// answer, never a live app's.
    @Test
    func onlyTheRealProcessDialsABridge() {
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        let io = HookPrelude.IO(preparePipe: { StdinPipe.make(replacing: fd) }, readStandardInput: { Data() }, agentPID: { nil },
                                send: { _, _ in })
        let started = Date()
        for kind in [AgentKind.copilot, .devin, .qwen] {
            #expect(io.bridge(.processClaudeHook(try! JSONDecoder().decode(ClaudeHookPayload.self, from: Data(
                #"{"hook_event_name":"Stop","session_id":"s","cwd":"/tmp/p"}"#.utf8))), 1, URL(fileURLWithPath: "/tmp/none.sock")) == nil,
                "\(kind)")
        }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    /// A helper in its home sends its notes and its runner's commands to that home's sockets.
    @Test
    func aHelperInItsHomeUsesItsHomesSockets() {
        let calls = Calls()
        let home = HookHome(folder: URL(fileURLWithPath: "/tmp/ji-home"))
        _ = Self.run(["hook_event_name": "SessionStart", "session_id": "cp-1", "cwd": "/tmp/p"], source: "copilot", home: home,
                     calls: calls)
        #expect(calls.notes.current == [home.notesURL] && calls.bridged.current.map(\.1) == [home.bridgeURL])
    }
}

/// The agents table's file edits: Connect then Remove gives the bytes back, in every layout (P916).
struct HookFileEditsTests {
    static let helper = "/tmp/ji-home/bin/JuiceHooks"

    static func owners(_ spec: AgentHookSpec) -> HookFileEdits.Owners {
        let source = spec.kind.rawValue
        return HookFileEdits.Owners(isOurs: { AgentHookTable.isOurs($0, source: source, helperPath: helper) },
                                    isOld: { AgentHookTable.isOldIsland($0, source: source) })
    }

    static func connect(_ data: Data?, _ spec: AgentHookSpec) throws -> Data {
        try HookFileEdits.installing(data, layout: spec.layout, expected: spec.events, command: spec.command(helperPath: helper),
                                     owners: owners(spec))
    }

    @Test
    func connectThenRemoveGivesTheBytesBackInEveryLayout() throws {
        let samples: [(AgentHookSpec, String?)] = [
            (AgentHookTable.qwen, #"{"model":{"name":"qwen3-coder"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#),
            (AgentHookTable.qwen, "{\n    \"ui\": { \"theme\": \"Ünïcode\" }\n}\n"),
            (AgentHookTable.qwen, "{}"),
            (AgentHookTable.devin, "{\n  \"permissions\": {\"allow\": [\"Read\"]},\n  \"hooks\": {}\n}\n"),
            (AgentHookTable.cursor, "{\n  \"version\": 1,\n  \"hooks\": {\n    \"stop\": [{ \"command\": \"say done\" }]\n  }\n}\n"),
            // A file with no "version" gets none: Remove gives it back as it was (P916).
            (AgentHookTable.cursor, #"{"hooks":{"stop":[{"command":"say done"}]}}"#),
            (AgentHookTable.cursor, nil),
            (AgentHookTable.copilot, nil),
        ]
        for (spec, text) in samples {
            let data = text.map { Data($0.utf8) }
            let connected = try Self.connect(data, spec)
            let reading = try HookFileEdits.read(connected, layout: spec.layout, expected: spec.events, owners: Self.owners(spec))
            #expect(reading.complete.count == spec.events.count && reading.ours == spec.events.count, "\(spec.kind) \(text ?? "nil")")
            #expect(try Self.connect(connected, spec) == connected, "a second Connect changed \(spec.kind)")
            let removed = try HookFileEdits.removing(connected, layout: spec.layout, owners: Self.owners(spec))
            if text == "{}" {
                // A file left with nothing goes, as upstream's Remove does (P916).
                #expect(removed == nil)
            } else if text?.contains("\"hooks\": {}") == true {
                // An empty `hooks` Juice filled goes with Juice's last entry; everything else stays.
                #expect(removed.map { String(decoding: $0, as: UTF8.self).contains("permissions") && !String(decoding: $0, as: UTF8.self).contains("hooks") } == true)
            } else {
                #expect(removed == data, "\(spec.kind) \(text ?? "nil") came back as \(removed.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")
            }
        }
    }

    /// Open Island's helper's entries for this agent are replaced, a wrong one of Juice's is put right, everyone else's
    /// stays (P903).
    @Test
    func oldEntriesMoveAndWrongOnesArePutRight() throws {
        let spec = AgentHookTable.qwen
        let text = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/tmp/x/OpenIsland/bin/OpenIslandHooks' --source qwen"}]},{"hooks":[{"type":"command","command":"say done"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"'/tmp/ji-home/bin/JuiceHooks' --source qwen","timeout":86400}]}]}}"#
        let before = try HookFileEdits.read(Data(text.utf8), layout: spec.layout, expected: spec.events, owners: Self.owners(spec))
        #expect(before.old == 1 && before.ours == 1 && before.others == 1 && before.complete.isEmpty)
        let after = try HookFileEdits.read(try Self.connect(Data(text.utf8), spec), layout: spec.layout, expected: spec.events,
                                           owners: Self.owners(spec))
        #expect(after.old == 0 && after.others == 1 && after.complete.count == spec.events.count && after.ours == spec.events.count)
    }

    @Test
    func aFileWithCommentsOrNotJSONIsNeverEdited() {
        let spec = AgentHookTable.cursor
        #expect(throws: HookFileEdits.Problem.comments) { try Self.connect(Data("{ // mine\n \"hooks\": {} }".utf8), spec) }
        #expect(throws: HookFileEdits.Problem.invalid) { try Self.connect(Data("{\"hooks\": [".utf8), spec) }
        #expect(throws: HookFileEdits.Problem.invalid) { try Self.connect(Data("[]".utf8), spec) }
    }

    /// Juice's own command, exactly: its helper path and this agent's source. Another flavor's, Open Island's and
    /// Vibe Island's never are (P925).
    @Test
    func onlyJuicesOwnCommandIsOurs() {
        let ours = AgentHookTable.copilot.command(helperPath: Self.helper)
        #expect(ours == "'/tmp/ji-home/bin/JuiceHooks' --source copilot")
        #expect(AgentHookTable.isOurs(ours, source: "copilot", helperPath: Self.helper))
        #expect(!AgentHookTable.isOurs(ours, source: "cursor", helperPath: Self.helper))
        #expect(!AgentHookTable.isOurs("'/tmp/other/bin/JuiceHooks' --source copilot", source: "copilot", helperPath: Self.helper))
        #expect(!AgentHookTable.isOurs(ours + " --verbose", source: "copilot", helperPath: Self.helper))
        #expect(!AgentHookTable.isOurs("/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source copilot'", source: "copilot",
                                       helperPath: Self.helper))
        #expect(AgentHookTable.isOldIsland("'/tmp/x/OpenIslandHooks' --source cursor", source: "cursor"))
        #expect(AgentHookTable.isOldIsland("'/tmp/x/OpenIslandHooks'", source: nil))
        #expect(!AgentHookTable.isOldIsland("'/tmp/x/OpenIslandHooks' --source claude", source: "cursor"))
        #expect(!AgentHookTable.isOldIsland(ours, source: "copilot"))
        #expect(AgentHookTable.words(#"'/a b/it'\''s' --source "x y" z\ w"#) == ["/a b/it's", "--source", "x y", "z w"])
        #expect(AgentHookTable.words("'open") == nil)
    }

    /// The table as checked on 2026-10-02: Copilot without PreToolUse (it fails closed), Qwen's approval in seconds with
    /// no matcher, Cursor watched (upstream allows its calls at once).
    @Test
    func theTableKeepsEachAgentsRules() {
        #expect(!AgentHookTable.copilot.events.contains { $0.event == "PreToolUse" })
        #expect(AgentHookTable.copilot.events.first { $0.event == "PermissionRequest" }?.timeout == 3_600)
        #expect(AgentHookTable.qwen.events.allSatisfy { $0.matcher == nil })
        #expect(AgentHookTable.qwen.events.first { $0.event == "PermissionRequest" }?.timeout == 900)
        #expect(AgentHookTable.cursor.answers == .watch && AgentHookTable.cursor.approvalEvents.isEmpty)
        #expect(!AgentHookTable.cursor.events.contains { $0.event == "beforeReadFile" })
        #expect(AgentHookTable.copilot.file(stem: "juice") == "hooks/juice.json" && AgentHookTable.kilo.file(stem: "juice") == "plugin/juice.js")
        #expect(Array(AgentHookTable.wave1.map(\.kind).prefix(5)) == [.copilot, .cursor, .qwen, .devin, .kilo])
        // Wave 4's lane GEMINI (P1100): its three, in this order, each once.
        #expect(AgentHookTable.wave1.map(\.kind).filter { [.gemini, .antigravity, .grok].contains($0) } == [.gemini, .antigravity, .grok])
        #expect(Set(AgentHookTable.wave1.map(\.kind)).count == AgentHookTable.wave1.count)
    }
}

/// The installer over a scratch home: what each state reads, and that every write is a click's, backed up, and undone by
/// Remove.
struct AgentHookInstallerTests {
    final class Home {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-agents-\(UUID().uuidString)", isDirectory: true)
        lazy var installer = AgentHookInstaller(home: root, helperPath: "/tmp/ji-home/bin/JuiceHooks", bundledHelper: nil,
                                                ownFileStem: "juice-island", bridgeSocketPath: "/tmp/ji-home/bridge.sock")
        deinit { try? FileManager.default.removeItem(at: root) }

        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func folder(_ path: String) throws { try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(path))
        }
        func read(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
        func backups(_ folder: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []).filter { $0.contains(".backup.") }
        }
    }

    @Test
    func aSharedFileIsBackedUpEditedAndGivenBack() throws {
        let home = Home(), spec = AgentHookTable.cursor
        #expect(home.installer.status(spec) == .notFound)
        #expect(throws: AgentHookInstaller.Failure.folderMissing) { try home.installer.install(spec) }
        let text = "{\n  \"version\": 1,\n  \"hooks\": {\n    \"stop\": [{ \"command\": \"say done\" }]\n  }\n}\n"
        try home.write(".cursor/hooks.json", text)
        #expect(home.installer.status(spec) == .notConnected)
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected && home.backups(".cursor").count == 1)
        // One entry gone by hand: partial, and Repair puts it back.
        let partial = try #require(home.read(".cursor/hooks.json")).replacingOccurrences(of: "\"afterFileEdit\"", with: "\"afterFileEditX\"")
        try home.write(".cursor/hooks.json", partial)
        #expect(home.installer.status(spec) == .partial(installed: 4, expected: 5))
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected)
        // Remove takes every entry of Juice's, the one moved by hand too: the file is as it was before Connect.
        try home.installer.remove(spec)
        #expect(home.read(".cursor/hooks.json") == text)
    }

    @Test
    func connectThenRemoveIsByteForByte() throws {
        let home = Home()
        let qwen = #"{"model":{"name":"qwen3-coder"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try home.write(".qwen/settings.json", qwen)
        try home.folder(".copilot")
        try home.folder(".config/devin")
        for spec in [AgentHookTable.qwen, AgentHookTable.copilot, AgentHookTable.devin] {
            try home.installer.install(spec)
            #expect(home.installer.status(spec) == .connected, "\(spec.kind)")
            try home.installer.remove(spec)
            #expect(home.installer.status(spec) == .notConnected, "\(spec.kind)")
        }
        #expect(home.read(".qwen/settings.json") == qwen)
        // Juice's own file goes, and the folder Connect made for it (P916).
        #expect(!FileManager.default.fileExists(atPath: home.url(".copilot/hooks").path))
        #expect(FileManager.default.fileExists(atPath: home.url(".copilot").path))
        #expect(!FileManager.default.fileExists(atPath: home.url(".config/devin/config.json").path))
        // A folder with someone else's file in it stays.
        try home.write(".copilot/hooks/mine.json", #"{"version":1,"hooks":{}}"#)
        try home.installer.install(AgentHookTable.copilot)
        try home.installer.remove(AgentHookTable.copilot)
        #expect(home.read(".copilot/hooks/mine.json") != nil)
    }

    /// A link, comments or a file that is not JSON: never written, and the row shows the exact lines to add (P938).
    @Test
    func filesJuiceWillNotEditAreLeftAsTheyAre() throws {
        let home = Home(), spec = AgentHookTable.qwen
        try home.write(".qwen/real.json", "{}")
        try FileManager.default.createSymbolicLink(atPath: home.url(".qwen/settings.json").path, withDestinationPath: home.url(".qwen/real.json").path)
        guard case let .addByHand(file, snippet, replaces) = home.installer.status(spec) else {
            Issue.record("a link is not Add by hand")
            return
        }
        #expect(file == "settings.json" && snippet.hasPrefix("\"hooks\": {") && snippet.contains("JuiceHooks' --source qwen") && !replaces)
        #expect(throws: AgentHookInstaller.Failure.addByHand) { try home.installer.install(spec) }
        #expect(home.read(".qwen/real.json") == "{}")

        try FileManager.default.removeItem(at: home.url(".qwen/settings.json"))
        try home.write(".qwen/settings.json", "{ // mine\n}")
        if case .addByHand = home.installer.status(spec) {} else { Issue.record("comments are not Add by hand") }
        #expect(throws: AgentHookInstaller.Failure.addByHand) { try home.installer.install(spec) }
        try home.write(".qwen/settings.json", "{ nope")
        #expect(home.installer.status(spec) == .unreadable(file: "settings.json"))
        #expect(throws: AgentHookInstaller.Failure.unreadable) { try home.installer.install(spec) }
        #expect(home.read(".qwen/settings.json") == "{ nope" && home.backups(".qwen").isEmpty)
        #expect(home.installer.snippet(AgentHookTable.cursor).hasPrefix("\"version\": 1,\n\"hooks\": {"))
    }

    /// A linked file, or one with comments, is read (through the link, without the comments) and never written: once
    /// the owner pasted Juice's lines it reads Connected, and a file that has `"hooks"` already gets that whole member
    /// as Connect would leave it, to put in its place, never a second `"hooks"` (P938).
    @Test
    func aFileJuiceWillNotEditStillSaysWhatIsInIt() throws {
        let home = Home(), spec = AgentHookTable.cursor
        try home.folder(".cursor")
        let full = try HookFileEdits.installing(nil, layout: .cursor, expected: spec.events,
                                                command: spec.command(helperPath: home.installer.helperPath), owners: home.installer.owners(spec))
        try full.write(to: home.url("dotfiles-hooks.json"))
        try FileManager.default.createSymbolicLink(at: home.url(".cursor/hooks.json"), withDestinationURL: home.url("dotfiles-hooks.json"))
        #expect(home.installer.status(spec) == .connectedByHand)
        try FileManager.default.removeItem(at: home.url(".cursor/hooks.json"))
        try home.write(".cursor/hooks.json", "// my hooks\n" + String(decoding: full, as: UTF8.self))
        #expect(home.installer.status(spec) == .connectedByHand)

        let mine = "{\n  // mine\n  \"version\": 1,\n  \"hooks\": {\n    \"stop\": [{ \"command\": \"say done\" }]\n  }\n}\n"
        try home.write(".cursor/hooks.json", mine)
        guard case let .addByHand(file, snippet, replaces) = home.installer.status(spec) else {
            Issue.record("not Add by hand: \(home.installer.status(spec))")
            return
        }
        #expect(file == "hooks.json" && replaces && snippet.hasPrefix("\"hooks\": {") && !snippet.contains("\"version\""))
        let pasted = try #require(try JSONSerialization.jsonObject(with: Data(("{\"version\": 1, " + snippet + "}").utf8)) as? [String: Any])
        let hooks = try #require(pasted["hooks"] as? [String: [[String: Any]]])
        #expect(hooks["stop"]?.compactMap { $0["command"] as? String } == ["say done", spec.command(helperPath: home.installer.helperPath)])
        #expect(Set(hooks.keys) == Set(spec.events.map(\.event)))
        #expect(home.read(".cursor/hooks.json") == mine && home.backups(".cursor").isEmpty)
    }

    /// Vibe Island's hooks in the same file, or in a file of their own in the folder the agent loads: Connect waits until
    /// they are gone, as a profile's Install does; Remove still takes Juice's own (P933).
    @Test
    func vibeIslandsHooksHoldConnectBack() throws {
        let home = Home()
        let vibe = #"{"hooks":{"stop":[{"command":"~/.vibe-island/bin/vibe-island-bridge --source cursor"}]}}"#
        try home.write(".cursor/hooks.json", vibe)
        #expect(home.installer.status(AgentHookTable.cursor) == .vibeIsland(entries: 1, ours: 0))
        #expect(throws: AgentHookInstaller.Failure.vibeIsland) { try home.installer.install(AgentHookTable.cursor) }
        #expect(home.read(".cursor/hooks.json") == vibe && home.backups(".cursor").isEmpty)

        try home.folder(".copilot")
        try home.installer.install(AgentHookTable.copilot)
        try home.write(".copilot/hooks/vibe-island.json", #"{"version":1,"hooks":{"Stop":[{"type":"command","bash":"vibe-island-bridge --source copilot"}]}}"#)
        #expect(home.installer.status(AgentHookTable.copilot) == .connected)
        try home.installer.remove(AgentHookTable.copilot)
        #expect(home.installer.status(AgentHookTable.copilot) == .vibeIsland(entries: 1, ours: 0))
        #expect(throws: AgentHookInstaller.Failure.vibeIsland) { try home.installer.install(AgentHookTable.copilot) }
        try FileManager.default.removeItem(at: home.url(".copilot/hooks/vibe-island.json"))
        #expect(home.installer.status(AgentHookTable.copilot) == .notConnected)
    }

    /// Juice's own file name, already someone else's: refused. Juice's own file with another's entry added: Remove takes
    /// only Juice's.
    @Test
    func anOwnedFileIsJuicesAlone() throws {
        let home = Home(), spec = AgentHookTable.copilot
        try home.write(".copilot/hooks/juice-island.json", #"{"version":1,"hooks":{"Stop":[{"type":"command","bash":"say done"}]}}"#)
        #expect(throws: AgentHookInstaller.Failure.foreign) { try home.installer.install(spec) }
        try FileManager.default.removeItem(at: home.url(".copilot/hooks/juice-island.json"))
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected && home.backups(".copilot/hooks").isEmpty)
        let text = try #require(home.read(".copilot/hooks/juice-island.json"))
        try home.write(".copilot/hooks/juice-island.json", text.replacingOccurrences(
            of: "\"Stop\": [", with: "\"Stop\": [{\"type\": \"command\", \"bash\": \"say done\"}, "))
        try home.installer.remove(spec)
        #expect(home.read(".copilot/hooks/juice-island.json")?.contains("say done") == true)
        #expect(home.read(".copilot/hooks/juice-island.json")?.contains("JuiceHooks") == false)
    }

    /// Juice never wrote an agent's hooks of the table before its own helper: Open Island's helper's entries there are
    /// Open Island's own. Connect puts Juice's beside them, and Remove gives the file back as it was (P932).
    @Test
    func openIslandsOwnHooksAreLeftAlone() throws {
        let home = Home(), spec = AgentHookTable.cursor
        let text = #"{"version":1,"hooks":{"stop":[{"command":"'/tmp/x/OpenIsland/bin/OpenIslandHooks' --source cursor"}]}}"#
        try home.write(".cursor/hooks.json", text)
        #expect(home.installer.status(spec) == .notConnected)
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected && home.read(".cursor/hooks.json")?.contains("OpenIslandHooks") == true)
        try home.installer.remove(spec)
        #expect(home.read(".cursor/hooks.json") == text)
    }

    /// Kilo's plugin: Juice's whole file, dialing the helper home's bridge with Kilo's session names; an older one of
    /// Juice's reads as outdated, anyone else's is never replaced (P923).
    @Test
    func kilosPluginIsJuicesOwnFile() throws {
        let home = Home(), spec = AgentHookTable.kilo
        try home.folder(".config/kilo")
        try home.installer.install(spec)
        let plugin = try #require(home.read(".config/kilo/plugin/juice-island.js"))
        #expect(plugin.contains("const SOCKET_PATH = \"/tmp/ji-home/bridge.sock\";") && plugin.contains("`kilo-${sessionID}`"))
        #expect(home.installer.status(spec) == .connected && home.installer.snippet(spec).isEmpty)
        try home.write(".config/kilo/plugin/juice-island.js", plugin.replacingOccurrences(of: "revision \(OpenCodePlugin.revision).",
                                                                                          with: "revision 1."))
        #expect(home.installer.status(spec) == .outdated)
        try home.installer.remove(spec)
        #expect(home.installer.status(spec) == .notConnected)
        try home.write(".config/kilo/plugin/juice-island.js", "export const Mine = async () => ({})\n")
        #expect(throws: AgentHookInstaller.Failure.foreign) { try home.installer.install(spec) }
        #expect(throws: AgentHookInstaller.Failure.foreign) { try home.installer.remove(spec) }
    }
}

/// Open Island's socket relayed to the bridge, on scratch sockets only (P911).
struct LegacyBridgeRelayTests {
    /// A listener that writes back what it reads, until the other side ends.
    final class Echo {
        let fd: Int32
        init(_ url: URL) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = try #require(HookNoteSocket.address(for: url))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(bound == 0 && listen(fd, 4) == 0)
            let listener = fd
            Thread {
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    var buffer = [UInt8](repeating: 0, count: 1_024)
                    while true {
                        let count = read(client, &buffer, buffer.count)
                        guard count > 0 else { break }
                        _ = write(client, buffer, count)
                    }
                    close(client)
                }
            }.start()
        }
        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    static func exchange(_ url: URL, _ text: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try #require(HookNoteSocket.address(for: url))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        // Written on a thread of its own while this one reads: a large write would otherwise fill both directions.
        let bytes = Array(text.utf8)
        let written = DispatchSemaphore(value: 0)
        Thread {
            var offset = 0
            while offset < bytes.count {
                let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                offset += count
            }
            shutdown(fd, SHUT_WR)
            written.signal()
        }.start()
        defer { written.wait() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    @Test
    func bytesPassBothWaysAndOnlyItsOwnFileGoes() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("t.sock"), path = folder.appendingPathComponent("o.sock")
        let echo = try Echo(target)
        defer { echo.stop() }
        // A stale file at the path is replaced, as upstream's bridge replaces its own.
        try Data("stale".utf8).write(to: path)
        let relay = try LegacyBridgeRelay(path: path, target: target)
        #expect(try Self.exchange(path, "{\"type\":\"command\"}\n") == "{\"type\":\"command\"}\n")
        #expect(try Self.exchange(path, String(repeating: "x", count: 200_000)).count == 200_000)
        relay.stop()
        #expect(!FileManager.default.fileExists(atPath: path.path))

        // Another app bound the path after the relay: stopping leaves its file.
        let second = try LegacyBridgeRelay(path: path, target: target)
        unlink(path.path)
        let other = try Echo(path)
        defer { other.stop() }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    /// Wanted only while something of Juice's still dials Open Island's socket: a profile whose hooks Juice wrote before
    /// its own helper and has not moved, or Juice's first OpenCode plugin under Open Island's name. Open Island's own
    /// helper, hooks and plugin never make Juice take its socket (P932).
    @Test
    func theRelayIsWantedOnlyWhileSomethingOfJuicesDialsIt() throws {
        let home = URL(fileURLWithPath: ProfileHookTargets.normalized(
            FileManager.default.temporaryDirectory.appendingPathComponent("ji-relay-\(UUID().uuidString)").path))
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "ji.test.relay.\(UUID().uuidString)"
        let intents = ProfileHookIntentStore(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let managed = URL(fileURLWithPath: "/tmp/ji-home/bin/JuiceHooks")
        let folder = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = ProfileHookTarget(provider: .claude, folder: folder.path, alias: "work", isDefaultFolder: false, accountID: nil,
                                       isMonitored: true)
        func wanted() -> Bool { LegacyBridgeUse.wanted(home: home.path, targets: [target], intents: intents, managedHelperURL: managed) }
        // Open Island installed, its helper and its hooks there: Open Island's.
        let helper = LegacyHookHome.helperURL(home: home.path)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
        let old = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'\#(helper.path)' --source claude"}]}]}}"#
        try Data(old.utf8).write(to: folder.appendingPathComponent("settings.json"))
        #expect(!wanted())
        // Juice installed them before its own helper: Juice's, until moved.
        intents.setIntent(.installed, for: target.id)
        #expect(wanted())
        let moved = old.replacingOccurrences(of: helper.path, with: managed.path)
        try Data(moved.utf8).write(to: folder.appendingPathComponent("settings.json"))
        #expect(!wanted())

        let plugin = OpenCodePluginInstaller(configDirectory: OpenCodePluginInstaller.defaultConfigDirectory(home: home.path))
        try FileManager.default.createDirectory(at: plugin.legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// Open Island plugin for OpenCode\nexport default async () => ({})\n".utf8).write(to: plugin.legacyURL)
        #expect(!wanted())
        try Data(OpenCodePlugin.source(socketPath: "/tmp/b.sock")
            .replacingOccurrences(of: "// Juice plugin for OpenCode and Kilo, revision \(OpenCodePlugin.revision).",
                                  with: "// Juice Island plugin for OpenCode, revision 1.").utf8).write(to: plugin.legacyURL)
        #expect(wanted())
    }
}

/// The rows' agents: a note's label where it fits the session's tool, Kilo by its session id, kept across a relaunch.
@MainActor
struct AgentLabelTests {
    typealias F = EngineFixtures

    private func note(_ id: String, source: String, agent: String? = nil) -> HookContextNote {
        HookContextNote(event: "UserPromptSubmit", sessionID: id, agentID: agent, source: source)
    }

    @Test
    func aNoteLabelsOnlyASessionItFits() throws {
        let engine = F.engine()
        for (id, tool) in [("cp-1", AgentTool.codebuddy), ("s1", .claudeCode), ("qw-1", .qwenCode), ("kilo-k1", .openCode),
                           ("opencode-o1", .openCode), ("cb-1", .codebuddy)] {
            engine.ingest(F.started(id, tool: tool), ingress: .bridge)
        }
        engine.ingest(note: note("cp-1", source: "copilot"))
        engine.ingest(note: note("s1", source: "copilot"))
        engine.ingest(note: note("qw-1", source: "qwen"))
        engine.ingest(note: note("cb-1", source: "devin", agent: "worker-1"))
        func agent(_ id: String) throws -> AgentKind { engine.agent(of: try #require(engine.state.session(id: id))) }
        #expect(try agent("cp-1") == .copilot && agent("s1") == .claude && agent("qw-1") == .qwen)
        #expect(try agent("kilo-k1") == .kilo && agent("opencode-o1") == .opencode && agent("cb-1") == .codebuddy)
    }

    @Test
    func theLabelOutlivesARelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-labels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionLabelStore(url: folder.appendingPathComponent(SessionLabelStore.fileName))
        func engine() throws -> SessionEngine {
            var configuration = SessionEngine.Configuration.headless
            configuration.sessionLabels = store
            var dependencies = SessionEngine.Dependencies()
            dependencies.now = { EngineFixtures.now }
            dependencies.readPeek = nil
            dependencies.watchTranscript = { _, _, _ in nil }
            let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
            try engine.start()
            engine.ingest(F.started("cp-1", tool: .codebuddy), ingress: .bridge)
            return engine
        }
        let first = try engine()
        first.ingest(note: note("cp-1", source: "copilot"))
        store.flush()
        #expect(try String(contentsOf: store.url, encoding: .utf8).contains("copilot"))
        let second = try engine()
        #expect(second.agent(of: try #require(second.state.session(id: "cp-1"))) == .copilot)
    }
}
