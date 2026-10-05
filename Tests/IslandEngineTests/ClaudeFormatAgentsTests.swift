import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Wave 4's Claude-format agents one piece at a time (P1125 to P1149): Qoder, CodeBuddy, Factory Droid and Kimi Code.
/// Scratch folders and made-up paths only; nothing here opens a socket. Every hook input below follows its agent's
/// current docs and source, named beside it.
enum ClaudeFormatFixtures {
    static let helper = "/tmp/ji-home/bin/JuiceHooks"

    /// As the installer has them: an entry on Open Island's helper in a table agent's file is Open Island's (P932).
    static func owners(_ spec: AgentHookSpec) -> HookFileEdits.Owners {
        let source = spec.kind.rawValue
        return HookFileEdits.Owners(isOurs: { AgentHookTable.isOurs($0, source: source, helperPath: helper) })
    }

    /// Qoder CLI's PermissionRequest as `firePermissionRequestEvent` builds it: `createBaseInput` (session, transcript,
    /// cwd, event, permission mode) and the tool, with no `tool_use_id`.
    /// Source: https://registry.npmjs.org/@qoder-ai/qodercli/-/qodercli-1.1.65.tgz (bundle/qodercli.js), and
    /// https://docs.qoder.com/cli/hooks ("PermissionRequest" input).
    nonisolated(unsafe) static let qoderAsk: [String: Any] = [
        "session_id": "qd-1", "transcript_path": "/tmp/project/.qoder/qd-1.jsonl", "cwd": "/tmp/project",
        "hook_event_name": "PermissionRequest", "permission_mode": "default", "tool_name": "Bash",
        "tool_input": ["command": "git push origin main"], "permission_suggestions": [] as [Any],
    ]

    /// CodeBuddy Code's PermissionRequest as `executePermissionRequestHooks` builds it: the call's id as both `call_id`
    /// and `tool_use_id`, and its own permission mode `fullAccess`, which Claude does not have.
    /// Source: https://registry.npmjs.org/@tencent-ai/codebuddy-code/-/codebuddy-code-2.161.1.tgz (dist/codebuddy.js),
    /// https://www.codebuddy.ai/docs/cli/hooks (common input fields).
    nonisolated(unsafe) static let codebuddyAsk: [String: Any] = [
        "session_id": "cb-1", "transcript_path": "/tmp/project/.codebuddy/cb-1.jsonl", "cwd": "/tmp/project",
        "hook_event_name": "PermissionRequest", "permission_mode": "fullAccess", "tool_name": "Bash",
        "tool_input": ["command": "git push origin main"], "call_id": "call_9", "tool_use_id": "call_9",
    ]

    /// Factory Droid's Notification when it shows its own prompt: Droid's permission modes (`auto-low`) and `message_id`.
    /// Source: https://docs.factory.com/reference/hooks-reference (common input, Notification types).
    static func factoryNotice(_ type: String) -> [String: Any] {
        ["session_id": "fd-1", "transcript_path": "/tmp/project/.factory/fd-1.jsonl", "cwd": "/tmp/project",
         "permission_mode": "auto-low", "hook_event_name": "Notification", "message_id": "m-3",
         "message": type == "permission_prompt" ? "Droid needs your permission to use Execute" : "Droid has a question",
         "notification_type": type]
    }

    /// Kimi Code's PermissionRequest: `PermissionApprovalRequestedPayload` in snake case, with the runner's
    /// `client_type`, the session title, and the main agent's id `main`.
    /// Source: https://github.com/MoonshotAI/kimi-code (21406fb) packages/agent-core-v2/src/agent/toolApproval/
    /// toolApprovalService.ts, features/externalHooks/internal/matchHooks.ts; https://moonshotai.github.io/kimi-code/en/
    /// customization/hooks.html ("Event Data Format").
    nonisolated(unsafe) static let kimiAsk: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "km-1", "cwd": "/tmp/project", "client_type": "kimi_code_cli",
        "session_title": "Fix the login page", "id": "apr-1", "agent_id": "main", "turn_id": 3, "tool_call_id": "call_1",
        "tool_name": "Shell", "action": "run command", "display": ["kind": "command", "command": "git push"],
        "tool_input": ["command": "git push"],
    ]

    /// Kimi Code's Interrupt (Esc), in place of Stop. Source: as above, agent/agentExternalHooksService.ts
    /// `notifyTurnEnded`.
    nonisolated(unsafe) static let kimiInterrupt: [String: Any] = [
        "hook_event_name": "Interrupt", "session_id": "km-1", "cwd": "/tmp/project", "client_type": "kimi_code_cli",
        "session_title": "Fix the login page", "turn_id": 3, "reason": "cancelled",
    ]

    /// Kimi Code's StopFailure. Source: as above, `notifyStopFailure`.
    nonisolated(unsafe) static let kimiFailure: [String: Any] = [
        "hook_event_name": "StopFailure", "session_id": "km-1", "cwd": "/tmp/project", "client_type": "kimi_code_cli",
        "error_type": "APIConnectionError", "error_message": "Connection reset",
    ]
}

struct ClaudeFormatTableTests {
    /// Each agent's mark and rules as checked on 2026-10-03 (P1125 to P1132).
    @Test
    func theTableKeepsEachAgentsRules() throws {
        #expect(AgentHookTable.claudeFormat.map(\.kind) == [.qoder, .codebuddy, .factory, .kimi])
        // In the table once each, in this order, wherever later lanes' agents go (the wave 4 integration).
        #expect(AgentHookTable.wave1.map(\.kind).filter { [.qoder, .codebuddy, .factory, .kimi].contains($0) } == [.qoder, .codebuddy, .factory, .kimi])
        for spec in [AgentHookTable.qoder, AgentHookTable.codebuddy] {
            #expect(spec.answers == .approve && spec.approvalEvents == ["PermissionRequest"] && spec.layout == .claudeGroups)
            #expect(spec.events.first { $0.event == "PermissionRequest" }?.timeout == 3_600)
            #expect(spec.events.allSatisfy { $0.matcher == nil })
            #expect(spec.place == .shared("settings.json") && spec.elsewhere.isEmpty)
        }
        // Watch: no approval of theirs reaches the island as one it could answer.
        let factory = AgentHookTable.factory, kimi = AgentHookTable.kimi
        for spec in [factory, kimi] + factory.elsewhere + kimi.elsewhere {
            #expect(spec.answers == .watch && spec.approvalEvents.isEmpty)
            // A PreToolUse `allow` skips Droid's prompt, and any PreToolUse hides Kimi's in its other clients (#3888).
            #expect(!spec.events.contains { $0.event == "PreToolUse" })
        }
        #expect(factory.events.contains { $0.event == "Notification" } && !factory.events.contains { $0.event == "PermissionRequest" })
        #expect(factory.place == .shared("hooks.json") && factory.layout == .claudeEvents && factory.readWhen == .fileExists)
        #expect(factory.elsewhere.map(\.place) == [.shared("hooks/hooks.json"), .shared("settings.json")])
        #expect(factory.elsewhere.map(\.readWhen) == [.fileExists, .fileHasHooks])
        // Only the events issue 3888's reporter found safe, and those after the answer; never SessionHeartbeat or a
        // prompt's events, which come before one.
        let safe: Set = ["SessionStart", "SessionEnd", "PermissionRequest", "PermissionResult", "Stop", "StopFailure", "Interrupt"]
        #expect(Set(kimi.events.map(\.event)).isSubset(of: safe) && kimi.events.count == 7)
        #expect(kimi.events.allSatisfy { $0.timeout == AgentHookTable.kimiTimeout && $0.matcher == nil })
        // The older Kimi CLI rejects a config naming an event it does not know: only its own (kimi_cli/hooks/config.py),
        // and its prompt (issue 3888 is Kimi Code's; Kimi CLI has no approval hook), so its sessions show.
        let oldEvents: Set = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "StopFailure",
                              "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Notification"]
        let old = try #require(kimi.elsewhere.first)
        #expect(old.name == "Kimi CLI" && old.folder == ".kimi")
        #expect(Set(old.events.map(\.event)) == oldEvents.intersection(safe.union(["UserPromptSubmit"])))
        #expect(kimi.folder == ".kimi-code" && kimi.layout == .kimiToml && kimi.readWhen == .folderExists)
        // The helper runs each one's hooks itself, and answers only the Approve ones.
        #expect(HookPrelude.ownRunSources.isSuperset(of: [.qoder, .codebuddy, .factory, .kimi]))
        #expect(ClaudeFamilyRunner.answering.isSuperset(of: [.qoder, .codebuddy]))
        #expect(ClaudeFamilyRunner.answering.isDisjoint(with: [.factory, .kimi]))
    }
}

/// Kimi's `config.toml`: Juice's tables go in at the end and come out with the blank line before them, byte for byte;
/// a file it could not give back exactly is never written (P1130).
struct TOMLHookEditsTests {
    typealias F = ClaudeFormatFixtures
    static let spec = AgentHookTable.kimi

    static func connect(_ text: String?) throws -> Data {
        try HookFileEdits.installing(text.map { Data($0.utf8) }, layout: .kimiToml, expected: spec.events,
                                     command: spec.command(helperPath: F.helper), owners: F.owners(spec))
    }

    static func read(_ data: Data) throws -> HookFileEdits.Reading {
        try HookFileEdits.read(data, layout: .kimiToml, expected: spec.events, owners: F.owners(spec))
    }

    /// Kimi Code's own config sample (docs/en/customization/hooks.md), a table after the hooks, Open Island's managed
    /// block with its marker comment (KimiHookInstaller.swift), and a multi-line string whose lines look like headers.
    static let samples: [String?] = [
        nil,
        "",
        "default_model = \"kimi-k2\"\n",
        """
        # Written in ~/.kimi-code/config.toml
        [[hooks]]
        event = "Notification"           # Trigger: when a background task status changes
        matcher = "task\\\\.completed"     # Only care about "completed" notifications
        command = "terminal-notifier -title Kimi -message 'Task done'"

        [loop]
        max_steps = 50

        """,
        """
        default_model = "kimi-k2"

        # open-island: managed hook — do not edit
        [[hooks]]
        event = "Stop"
        command = "'/tmp/x/OpenIsland/bin/OpenIslandHooks' --source kimi"
        timeout = 45


        """,
        """
        system_prompt = \"\"\"
        [[hooks]]
        event = "Stop"
        \"\"\"
        paths = [
          "[not a header]",
          ['nested', "]"],
        ]
        inline = { a = 1, b = "[x]" }

        """,
    ]

    @Test
    func connectThenRemoveGivesTheBytesBack() throws {
        for text in Self.samples {
            let connected = try Self.connect(text)
            let reading = try Self.read(connected)
            #expect(reading.complete.count == Self.spec.events.count && reading.ours == Self.spec.events.count, "\(text ?? "nil")")
            #expect(try Self.connect(String(decoding: connected, as: UTF8.self)) == connected, "a second Connect changed it")
            let removed = try HookFileEdits.removing(connected, layout: .kimiToml, owners: F.owners(Self.spec))
            if text == nil || text == "" {
                #expect(removed == nil)
            } else {
                #expect(removed.map { String(decoding: $0, as: UTF8.self) } == text, "\(text!)")
            }
        }
        // Juice's tables as they sit in the file: four lines each, a blank line between.
        let made = String(decoding: try Self.connect("a = 1\n"), as: UTF8.self)
        #expect(made.hasPrefix("a = 1\n\n[[hooks]]\nevent = \"SessionStart\"\ncommand = \"'/tmp/ji-home/bin/JuiceHooks' --source kimi\"\ntimeout = 10\n\n[[hooks]]\n"))
    }

    /// Smol-toml (Kimi Code) and tomllib (Kimi CLI) read Juice's tables after another table as more `hooks`; here the
    /// scan finds them there and leaves every other table's keys alone.
    @Test
    func theScanKnowsWhichLinesAreWhose() throws {
        let file = try TOMLHookEdits.Scan(Data(Self.samples[5]!.utf8))
        #expect(file.tables.isEmpty && file.writable)
        let mixed = try TOMLHookEdits.Scan(Data(String(decoding: try Self.connect(Self.samples[3]), as: UTF8.self).utf8))
        #expect(mixed.tables.count == 1 + Self.spec.events.count)
        #expect(mixed.tables.first?.command == "terminal-notifier -title Kimi -message 'Task done'")
        #expect(mixed.tables.first?.matcher == "task\\.completed" && mixed.tables.first?.event == "Notification")
        let open = try Self.read(Data(Self.samples[4]!.utf8))
        #expect(open.ours == 0 && open.others == 1 && open.old == 0)
    }

    /// One of Juice's tables changed by hand (its timeout): Repair puts the whole set back at the end, the owner's lines
    /// untouched; Open Island's managed table is never Juice's.
    @Test
    func aWrongTableIsPutRightAndOpenIslandsStays() throws {
        let owner = Self.samples[4]!
        let connected = String(decoding: try Self.connect(owner), as: UTF8.self)
        let edited = connected.replacingOccurrences(of: "timeout = 10\n\n[[hooks]]\nevent = \"StopFailure\"", with: "timeout = 99\n\n[[hooks]]\nevent = \"StopFailure\"")
        let before = try Self.read(Data(edited.utf8))
        #expect(before.complete.count == Self.spec.events.count - 1 && before.ours == Self.spec.events.count)
        let repaired = try Self.connect(edited)
        #expect(try Self.read(repaired).complete.count == Self.spec.events.count)
        #expect(String(decoding: repaired, as: UTF8.self).contains("OpenIslandHooks' --source kimi\"\ntimeout = 45"))
        #expect(try HookFileEdits.removing(repaired, layout: .kimiToml, owners: F.owners(Self.spec)).map { String(decoding: $0, as: UTF8.self) } == owner)
    }

    /// Never written: no final newline, a carriage return, `hooks` as something else. Read all the same, so a line pasted
    /// by hand still says Connected (P938).
    @Test
    func aFileItCannotGiveBackIsNeverWritten() throws {
        for text in ["model = \"k2\"", "model = \"k2\"\r\n", "hooks = []\n", "[hooks]\nx = 1\n", "[hooks.extra]\nx = 1\n", "hooks.x = 1\n"] {
            #expect(throws: HookFileEdits.Problem.unwritable, "\(text)") { try Self.connect(text) }
            #expect(!TOMLHookEdits.canWrite(Data(text.utf8)))
        }
        #expect(TOMLHookEdits.namesHooksOtherwise(Data("hooks = []\n".utf8)) && !TOMLHookEdits.namesHooksOtherwise(Data("x = 1\n".utf8)))
        // `hooks` inside another table is that table's key, not Kimi's hooks.
        #expect(TOMLHookEdits.canWrite(Data("[loop]\nhooks = 1\n".utf8)))
        let pasted = "model = \"k2\"\n\n" + TOMLHookEdits.tables(Self.spec.events, command: Self.spec.command(helperPath: F.helper))
        let unfinished = String(pasted.dropLast())
        #expect(try Self.read(Data(unfinished.utf8)).complete.count == Self.spec.events.count)
        for broken in ["a = \"open\n", "a = [\n1,\n", "a = \"\"\"\nnever closed\n", "[[hooks\n", "= 1\n"] {
            #expect(throws: HookFileEdits.Problem.invalid, "\(broken)") { try Self.read(Data(broken.utf8)) }
        }
    }

    /// A command with a quote, a backslash and a space comes back as written.
    @Test
    func quotedCommandsReadBack() throws {
        let command = AgentHookTable.shellQuote("/Users/test/Library/Application Support/Juice \"Q\" \\ Island/bin/JuiceHooks") + " --source kimi"
        let text = TOMLHookEdits.tables([HookEntrySpec(event: "Stop", matcher: nil, timeout: 10)], command: command)
        let file = try TOMLHookEdits.Scan(Data(text.utf8))
        #expect(file.tables.first?.command == command)
        let literal = try TOMLHookEdits.Scan(Data("[[hooks]]\nevent = 'Stop'\ncommand = 'say \"done\"'\n".utf8))
        #expect(literal.tables.first?.command == "say \"done\"" && literal.tables.first?.event == "Stop")
        let escaped = try TOMLHookEdits.Scan(Data("[[hooks]]\ncommand = \"a\\u00e9\\tb\"\n".utf8))
        #expect(escaped.tables.first?.command == "a\u{e9}\tb")
    }
}

/// Factory Droid's `hooks.json`: the events at the top of the file (P1126).
struct FactoryHooksFileTests {
    typealias F = ClaudeFormatFixtures

    static func connect(_ text: String?) throws -> Data {
        let spec = AgentHookTable.factory
        return try HookFileEdits.installing(text.map { Data($0.utf8) }, layout: .claudeEvents, expected: spec.events,
                                            command: spec.command(helperPath: F.helper), owners: F.owners(spec))
    }

    @Test
    func connectThenRemoveGivesTheBytesBack() throws {
        let spec = AgentHookTable.factory
        // The reference's own example, keyed by event.
        // Source: https://docs.factory.com/reference/hooks-reference ("Standalone hooks.json files are keyed by event name").
        let samples: [String?] = [
            """
            {
              "PreToolUse": [
                {
                  "matcher": "Execute",
                  "commandRegex": "^git ",
                  "hooks": [
                    { "type": "command", "command": "/usr/local/bin/audit-git-command.sh", "timeout": 30 }
                  ]
                }
              ]
            }

            """,
            #"{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}"#,
            nil,
        ]
        for text in samples {
            let connected = try Self.connect(text)
            let object = try #require(try JSONSerialization.jsonObject(with: connected) as? [String: Any])
            #expect(object["hooks"] == nil, "hooks.json has no \"hooks\" around its events")
            let reading = try HookFileEdits.read(connected, layout: .claudeEvents, expected: spec.events, owners: F.owners(spec))
            #expect(reading.complete.count == spec.events.count && reading.ours == spec.events.count)
            #expect(try Self.connect(String(decoding: connected, as: UTF8.self)) == connected)
            let removed = try HookFileEdits.removing(connected, layout: .claudeEvents, owners: F.owners(spec))
            // A file Connect began is left `{}`: the installer decides whether it goes (P1188).
            #expect(removed.map { String(decoding: $0, as: UTF8.self) } == text ?? "{}\n", "\(text ?? "nil")")
        }
    }
}

/// The installer over a scratch home for these four: where each writes, Connect then Remove, and what a file it will
/// not edit shows (P1126, P1130, P1132).
struct ClaudeFormatInstallerTests {
    typealias Home = AgentHookInstallerTests.Home

    @Test
    func qoderAndCodeBuddyConnectAndRemoveByteForByte() throws {
        let home = Home()
        // Qoder's settings with a hook of the owner's, CodeBuddy's with none: both come back as they were.
        let qoder = "{\n  \"model\": \"auto\",\n  \"hooks\": {\n    \"Stop\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"say done\" }] }]\n  }\n}\n"
        let codebuddy = "{\n  \"permissions\": { \"allow\": [\"Read\"] }\n}\n"
        try home.write(".qoder/settings.json", qoder)
        try home.write(".codebuddy/settings.json", codebuddy)
        for spec in [AgentHookTable.qoder, AgentHookTable.codebuddy] {
            #expect(home.installer.status(spec) == .notConnected)
            try home.installer.install(spec)
            #expect(home.installer.status(spec) == .connected, "\(spec.kind)")
            #expect(home.backups(spec.folder).count == 1)
            try home.installer.remove(spec)
            #expect(home.installer.status(spec) == .notConnected)
        }
        #expect(home.read(".qoder/settings.json") == qoder && home.read(".codebuddy/settings.json") == codebuddy)
        #expect(home.installer.shownPath(AgentHookTable.qoder) == "~/.qoder/settings.json")
    }

    /// Droid reads `hooks.json` when it is there, else `hooks/hooks.json`, else `settings.json`'s hooks: Connect writes
    /// that one, never a `hooks.json` that would switch the owner's `settings.json` hooks off; Remove takes Juice's out
    /// of every one.
    @Test
    func factoryWritesTheFileDroidReads() throws {
        let spec = AgentHookTable.factory
        let home = Home()
        #expect(home.installer.status(spec) == .notFound)
        // Only settings.json, with the owner's hook: Droid reads it, so Connect writes it.
        let settings = #"{"model":"claude-opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try home.write(".factory/settings.json", settings)
        #expect(home.installer.resolved(spec).place == .shared("settings.json"))
        #expect(home.installer.shownPath(spec) == "~/.factory/settings.json")
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected && !FileManager.default.fileExists(atPath: home.url(".factory/hooks.json").path))
        // Droid's /hooks moved everything to hooks.json: that is the one read now; Remove takes Juice's from both, and
        // leaves the owner's hooks.json, which keeps settings.json's hooks off (P1188).
        try home.write(".factory/hooks.json", "{}\n")
        #expect(home.installer.status(spec) == .notConnected)
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected)
        try home.installer.remove(spec)
        #expect(home.read(".factory/settings.json") == settings && home.read(".factory/hooks.json") == "{}\n")
        try FileManager.default.removeItem(at: home.url(".factory/hooks.json"))
        for name in home.backups(".factory") { try FileManager.default.removeItem(at: home.url(".factory/" + name)) }
        // settings.json without hooks: Connect makes hooks.json, and Remove takes it away again.
        try home.write(".factory/settings.json", #"{"model":"claude-opus"}"#)
        #expect(home.installer.resolved(spec).place == .shared("hooks.json"))
        try home.installer.install(spec)
        let made = try #require(home.read(".factory/hooks.json"))
        #expect(made.hasPrefix("{") && made.contains("\"SessionStart\"") && !made.contains("\"hooks\": {\n    \"Session"))
        try home.installer.remove(spec)
        #expect(home.read(".factory/hooks.json") == nil && home.read(".factory/settings.json") == #"{"model":"claude-opus"}"#)
        // The older hooks/hooks.json, still loaded: written there while it is the one.
        try home.write(".factory/hooks/hooks.json", "{\n}\n")
        #expect(home.installer.shownPath(spec) == "~/.factory/hooks/hooks.json")
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected)
        try home.installer.remove(spec)
        // The owner's own file stays, `{}` again.
        #expect(home.read(".factory/hooks/hooks.json").map { $0.filter { !$0.isWhitespace } } == "{}")
    }

    /// Droid reads `settings.json`'s hooks only while `hooks.json` is absent, so the owner's own empty `hooks.json` keeps
    /// them off. Remove leaves that file as it was, and they stay off; a `hooks.json` Connect made, with no hooks after
    /// it to switch on, goes again (P1188).
    @Test
    func factorysRemoveNeverSwitchesTheOwnersSettingsHooksOn() throws {
        let spec = AgentHookTable.factory
        let home = Home()
        // Source: https://docs.factory.com/cli/configuration/hooks-guide ("If hooks.json is absent, Droid also reads hook
        // declarations from the hooks key in the matching settings.json").
        let settings = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say mine"}]}]}}"#
        try home.write(".factory/settings.json", settings)
        try home.write(".factory/hooks.json", "{}\n")
        #expect(home.installer.resolved(spec).place == .shared("hooks.json"))
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected && home.read(".factory/settings.json") == settings)
        try home.installer.remove(spec)
        #expect(home.read(".factory/hooks.json") == "{}\n")
        #expect(home.read(".factory/settings.json") == settings)
        #expect(home.installer.status(spec) == .notConnected)

        // The owner's own empty hooks.json stays whatever the files after it hold, as `{}` (an empty object's inner
        // spaces are not kept by Connect's edit).
        try home.write(".factory/settings.json", #"{"model":"claude-opus"}"#)
        try home.write(".factory/hooks.json", "{\n}\n")
        try home.installer.install(spec)
        try home.installer.remove(spec)
        #expect(home.read(".factory/hooks.json").map { $0.filter { !$0.isWhitespace } } == "{}")
        try home.installer.install(spec)
        try home.installer.remove(spec)
        #expect(home.read(".factory/hooks.json").map { $0.filter { !$0.isWhitespace } } == "{}")
        // Backups of earlier rounds (each Remove backs up the file with Juice's entries in it) never make one Connect
        // made look like the owner's.
        for name in home.backups(".factory") { try FileManager.default.removeItem(at: home.url(".factory/" + name)) }

        // One Connect made, with nothing after it that has hooks: gone again.
        try FileManager.default.removeItem(at: home.url(".factory/hooks.json"))
        try home.installer.install(spec)
        #expect(home.read(".factory/hooks.json") != nil)
        try home.installer.remove(spec)
        #expect(home.read(".factory/hooks.json") == nil && home.read(".factory/settings.json") == #"{"model":"claude-opus"}"#)
    }

    /// A hooks.json Juice will not edit gets the whole file as Connect would leave it, to put in its place.
    @Test
    func factorysLinkedHooksFileGetsTheWholeFile() throws {
        let spec = AgentHookTable.factory
        let home = Home()
        try home.write("dotfiles/droid-hooks.json", #"{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}"#)
        try home.folder(".factory")
        try FileManager.default.createSymbolicLink(at: home.url(".factory/hooks.json"), withDestinationURL: home.url("dotfiles/droid-hooks.json"))
        guard case let .addByHand(file, snippet, replaces) = home.installer.status(spec) else {
            Issue.record("not Add by hand: \(home.installer.status(spec))")
            return
        }
        #expect(file == "hooks.json" && replaces && snippet.hasPrefix("{"))
        let pasted = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: [[String: Any]]])
        #expect(Set(pasted.keys) == Set(spec.events.map(\.event)))
        #expect(pasted["Stop"]?.count == 2)
        #expect(throws: AgentHookInstaller.Failure.addByHand) { try home.installer.install(spec) }
        // Nothing of Juice's in it: Remove has nothing to take out and says nothing.
        try home.installer.remove(spec)
    }

    /// Kimi Code's folder first; the older Kimi CLI's when it is the only one. Connect then Remove, byte for byte; a
    /// config.toml without a final newline is by hand (P1130, P1132).
    @Test
    func kimiWritesItsTablesAndTheOlderCLIsOwn() throws {
        let spec = AgentHookTable.kimi
        let home = Home()
        #expect(home.installer.status(spec) == .notFound)
        let old = "default_model = \"kimi-k2\"\n\n[loop_control]\nmax_steps_per_turn = 100\n"
        try home.write(".kimi/config.toml", old)
        #expect(home.installer.resolved(spec).name == "Kimi CLI" && home.installer.shownPath(spec) == "~/.kimi/config.toml")
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected)
        let written = try #require(home.read(".kimi/config.toml"))
        #expect(written.hasPrefix(old) && !written.contains("PermissionRequest") && !written.contains("Interrupt"))
        #expect(written.contains("event = \"UserPromptSubmit\""))
        // Kimi Code installed beside it: its folder is the one now.
        try home.folder(".kimi-code")
        #expect(home.installer.resolved(spec).name == "Kimi Code" && home.installer.status(spec) == .notConnected)
        try home.installer.install(spec)
        #expect(home.installer.status(spec) == .connected)
        #expect(home.read(".kimi-code/config.toml")?.hasPrefix("[[hooks]]\nevent = \"SessionStart\"") == true)
        #expect(home.read(".kimi-code/config.toml")?.contains("UserPromptSubmit") == false)
        try home.installer.remove(spec)
        #expect(home.read(".kimi/config.toml") == old && home.read(".kimi-code/config.toml") == nil)
        // No final newline: never written; the row has the tables to paste.
        try home.write(".kimi-code/config.toml", "default_model = \"kimi-k2\"")
        guard case let .addByHand(file, snippet, replaces) = home.installer.status(spec) else {
            Issue.record("not Add by hand: \(home.installer.status(spec))")
            return
        }
        #expect(file == "config.toml" && !replaces && snippet.hasPrefix("[[hooks]]\nevent = \"SessionStart\""))
        let backups = home.backups(".kimi-code").count
        #expect(throws: AgentHookInstaller.Failure.addByHand) { try home.installer.install(spec) }
        #expect(home.read(".kimi-code/config.toml") == "default_model = \"kimi-k2\"" && home.backups(".kimi-code").count == backups)
        // Pasted by hand: Connected, and taken out by hand too.
        try home.write(".kimi-code/config.toml", "default_model = \"kimi-k2\"\n\n" + String(snippet.dropLast()))
        #expect(home.installer.status(spec) == .connectedByHand)
    }

    /// Vibe Island's tables in Kimi's file hold Connect back, as its JSON entries do (P933); Switch to Juice finds them.
    @Test
    func vibeIslandsKimiTablesHoldConnectBack() throws {
        let spec = AgentHookTable.kimi
        let home = Home()
        let vibe = "[[hooks]]\nevent = \"Stop\"\ncommand = \"/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source kimi'\"\n"
        try home.write(".kimi-code/config.toml", vibe)
        #expect(home.installer.status(spec) == .vibeIsland(entries: 1, ours: 0))
        #expect(throws: AgentHookInstaller.Failure.vibeIsland) { try home.installer.install(spec) }
        let places = VibeIslandHooks.places(home: home.root, profiles: [])
        #expect(places.contains { $0.url.path.hasSuffix(".kimi-code/config.toml") && $0.layout == .kimiToml })
        #expect(places.contains { $0.url.path.hasSuffix(".kimi/config.toml") && $0.agent == "Kimi CLI" })
        #expect(places.contains { $0.url.path.hasSuffix(".factory/settings.json") && $0.layout == .claudeGroups })
        let found = VibeIslandHooks.scan(places)
        #expect(found.map(\.entries) == [1] && found.first?.refused == false)
        let outcomes = VibeIslandHooks.remove(found)
        guard case .removed? = outcomes.values.first else {
            Issue.record("not removed: \(outcomes)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: home.url(".kimi-code/config.toml").path))
        #expect(home.installer.status(spec) == .notConnected)
    }
}

/// The helper's own runner for the four (P1127 to P1133).
struct ClaudeFormatRunnerTests {
    typealias F = ClaudeFormatFixtures
    typealias Box = EngineFixtures.Box

    /// Qoder's CLI and CodeBuddy read Claude's own answer; Factory Droid and Kimi are never answered.
    @Test
    func answersComeBackInClaudesWordsForTheApproveOnes() throws {
        let allow = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: nil, updatedPermissions: [])))
        let deny = BridgeResponse.claudeHookDirective(.permissionRequest(.deny(message: "Not now", interrupt: false)))
        for kind in [AgentKind.qoder, .codebuddy] {
            let output = try #require(ClaudeFamilyRunner.output(for: allow, kind: kind))
            let specific = try #require((try JSONSerialization.jsonObject(with: output) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])
            #expect(specific["hookEventName"] as? String == "PermissionRequest")
            #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == "allow")
            let denied = try #require(ClaudeFamilyRunner.output(for: deny, kind: kind))
            let decision = ((try JSONSerialization.jsonObject(with: denied) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
            #expect(decision?["behavior"] as? String == "deny" && decision?["message"] as? String == "Not now")
        }
        for kind in [AgentKind.factory, .kimi] {
            #expect(ClaudeFamilyRunner.output(for: allow, kind: kind) == nil)
        }
    }

    /// Kimi's own events, read as Claude's: its approval is "needs you", its Esc ends the turn, its main agent is no
    /// subagent, its failure keeps its message.
    @Test
    func kimisEventsAreReadAsClaudes() throws {
        let ask = ClaudeFamilyRunner.shaped(F.kimiAsk, kind: .kimi, environment: [:])
        #expect(ask["hook_event_name"] as? String == "Notification" && ask["notification_type"] as? String == "permission_prompt")
        #expect(ask["message"] as? String == "Kimi needs your permission to use Shell" && ask["agent_id"] == nil)
        let note = try #require(HookContextNote.make(object: ask, environment: [:], agentPID: 7, source: "kimi"))
        #expect(note.event == "Notification" && note.notificationType == "permission_prompt" && note.agentID == nil)
        let payload = try #require(ClaudeFamilyRunner.payload(object: ask, kind: .kimi, environment: [:]))
        #expect(payload.hookEventName == .notification && payload.hookSource == "kimi")
        let interrupt = try #require(ClaudeFamilyRunner.payload(object: ClaudeFamilyRunner.shaped(F.kimiInterrupt, kind: .kimi, environment: [:]),
                                                                kind: .kimi, environment: [:]))
        #expect(interrupt.hookEventName == .stop && interrupt.isInterrupt == true)
        let failure = try #require(ClaudeFamilyRunner.payload(object: ClaudeFamilyRunner.shaped(F.kimiFailure, kind: .kimi, environment: [:]),
                                                              kind: .kimi, environment: [:]))
        #expect(failure.hookEventName == .stopFailure && failure.error == "Connection reset")
        // Kimi Code's prompt is a list of parts, not text: left out, the rest read.
        let parts: [String: Any] = ["hook_event_name": "Stop", "session_id": "km-1", "cwd": "/tmp/p", "prompt": [["type": "text", "text": "hi"]]]
        #expect(ClaudeFamilyRunner.payload(object: ClaudeFamilyRunner.shaped(parts, kind: .kimi, environment: [:]), kind: .kimi,
                                           environment: [:]) != nil)
        // A subagent's id stays.
        #expect(ClaudeFamilyRunner.shaped(F.kimiAsk.merging(["agent_id": "sub-2"]) { $1 }, kind: .kimi, environment: [:])["agent_id"] as? String == "sub-2")
    }

    /// Qoder's CLI marks its hooks `QODER_HOOK_SOURCE=cli`: its approval is the island's to answer. Without it (the IDE,
    /// whose answer has other words) it is "needs you".
    @Test
    func qodersCLIIsAnsweredAndItsIDEIsWatched() {
        let cli = ClaudeFamilyRunner.shaped(F.qoderAsk, kind: .qoder, environment: ["QODER_HOOK_SOURCE": "cli"])
        #expect(cli["hook_event_name"] as? String == "PermissionRequest")
        #expect(ClaudeFamilyRunner.shaped(F.qoderAsk, kind: .qoder, environment: ["QODER_HOOK_SOURCE": "qoderwork"])["hook_event_name"] as? String
                == "PermissionRequest")
        let ide = ClaudeFamilyRunner.shaped(F.qoderAsk, kind: .qoder, environment: [:])
        #expect(ide["hook_event_name"] as? String == "Notification" && ide["message"] as? String == "Qoder needs your permission to use Bash")
        // Qoder's `error_details` may be an object.
        let failure: [String: Any] = ["hook_event_name": "StopFailure", "session_id": "qd-1", "cwd": "/tmp/p", "error": "rate limited",
                                      "error_details": ["status": 429]]
        #expect(ClaudeFamilyRunner.payload(object: ClaudeFamilyRunner.shaped(failure, kind: .qoder, environment: [:]), kind: .qoder,
                                           environment: [:])?.error == "rate limited")
    }

    /// Factory Droid's and CodeBuddy's own permission modes would fail upstream's decoder: left out, the rest read.
    @Test
    func agentsOwnModesAreLeftOut() throws {
        let factory = try #require(ClaudeFamilyRunner.payload(object: F.factoryNotice("permission_prompt"), kind: .factory, environment: [:]))
        #expect(factory.permissionMode == nil && factory.notificationType == "permission_prompt" && factory.hookSource == "factory")
        let codebuddy = try #require(ClaudeFamilyRunner.payload(object: F.codebuddyAsk, kind: .codebuddy, environment: [:]))
        #expect(codebuddy.permissionMode == nil && codebuddy.toolUseID == "call_9" && codebuddy.hookSource == "codebuddy")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ClaudeHookPayload.self, from: JSONSerialization.data(withJSONObject: F.codebuddyAsk)) }
    }

    /// An approval of a Watch agent never reaches the bridge; an Approve one's waits just under its hook's hour.
    @Test
    func onlyApproveAgentsAskTheBridge() {
        let asked = Box<[(BridgeCommand, TimeInterval)]>([])
        let send: ClaudeFamilyRunner.Send = { command, timeout in
            asked.update { $0.append((command, timeout)) }
            return .acknowledged
        }
        let ask: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/tmp/p", "tool_name": "Execute",
                                  "tool_input": ["command": "ls"]]
        for kind in [AgentKind.factory, .kimi] {
            #expect(ClaudeFamilyRunner.run(object: ask, kind: kind, environment: [:], send: send) == nil)
        }
        #expect(asked.current.isEmpty)
        for kind in [AgentKind.qoder, .codebuddy] {
            _ = ClaudeFamilyRunner.run(object: ask, kind: kind, environment: [:], send: send)
        }
        #expect(asked.current.map(\.1) == [ClaudeFamilyRunner.permissionTimeout, ClaudeFamilyRunner.permissionTimeout])
        #expect(ClaudeFamilyRunner.permissionTimeout < 3_600)
    }
}

/// The prelude's routes for the four, with stand-ins for every socket.
struct ClaudeFormatPreludeTests {
    typealias F = ClaudeFormatFixtures
    typealias Box = EngineFixtures.Box

    private struct Calls {
        let notes = Box<[Data]>([])
        let bridged = Box<[BridgeCommand]>([])
        let brokered = Box(0)
    }

    private static func run(_ object: [String: Any], source: String, environment: [String: String] = [:],
                            answer: BridgeResponse? = .acknowledged, calls: Calls) -> HookPrelude.Outcome {
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        let input = try! JSONSerialization.data(withJSONObject: object)
        let io = HookPrelude.IO(
            preparePipe: { StdinPipe.make(replacing: fd) }, readStandardInput: { input }, agentPID: { 4242 },
            send: { data, _ in calls.notes.update { $0.append(data) } },
            broker: { _, _, _ in
                calls.brokered.update { $0 += 1 }
                return .noBroker
            },
            bridge: { command, _, _ in
                calls.bridged.update { $0.append(command) }
                return answer
            })
        return HookPrelude.run(environment: environment, arguments: ["JuiceHooks", "--source", source], io: io)
    }

    private static func note(_ data: Data?) -> HookContextNote? { data.flatMap { try? JSONDecoder().decode(HookContextNote.self, from: $0) } }

    /// Kimi's approval: the note and the bridge both say Notification `permission_prompt`, nothing is held or printed.
    @Test
    func kimisApprovalIsNeedsYouAndNothingElse() {
        let calls = Calls()
        guard case let .finished(note, output) = Self.run(F.kimiAsk, source: "kimi", calls: calls) else {
            Issue.record("not finished")
            return
        }
        #expect(output == nil && note?.event == "Notification" && note?.notificationType == "permission_prompt")
        #expect(Self.note(calls.notes.current.first)?.notificationType == "permission_prompt")
        guard case let .processClaudeHook(payload)? = calls.bridged.current.first else {
            Issue.record("nothing bridged")
            return
        }
        #expect(payload.hookEventName == .notification && payload.hookSource == "kimi" && calls.brokered.current == 0)
    }

    /// Factory Droid's notices go to the engine as its notes say; its hooks print nothing, whatever the bridge says.
    @Test
    func factorysNoticesShowAndNothingIsPrinted() {
        let calls = Calls()
        let allow = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: nil, updatedPermissions: [])))
        for type in ["permission_prompt", "elicitation_dialog"] {
            guard case let .finished(note, output) = Self.run(F.factoryNotice(type), source: "factory", answer: allow, calls: calls) else {
                Issue.record("not finished")
                continue
            }
            #expect(output == nil && note?.notificationType == type && note?.agentSource == "factory")
        }
        #expect(calls.bridged.current.count == 2 && calls.brokered.current == 0)
        // Upstream's `droid` word for Factory is Factory's too.
        guard case .finished = Self.run(F.factoryNotice("permission_prompt"), source: "droid", calls: calls) else {
            Issue.record("droid not run by the helper")
            return
        }
    }

    /// Qoder's CLI and CodeBuddy: the bridge holds the approval and its answer comes back in Claude's output.
    @Test
    func qoderAndCodeBuddyAreAnswered() {
        let allow = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: nil, updatedPermissions: [])))
        let cases: [([String: Any], String, [String: String])] = [(F.qoderAsk, "qoder", ["QODER_HOOK_SOURCE": "cli"]),
                                                                  (F.codebuddyAsk, "codebuddy", [:])]
        for (object, source, environment) in cases {
            let calls = Calls()
            let outcome = Self.run(object, source: source, environment: environment, answer: allow, calls: calls)
            guard case let .finished(_, output?) = outcome else {
                Issue.record("\(source) not answered: \(outcome) \(calls.bridged.current)")
                continue
            }
            let text = String(decoding: output, as: UTF8.self)
            #expect(text.contains("\"behavior\":\"allow\"") && text.contains("\"hookEventName\":\"PermissionRequest\""), "\(source)")
            #expect(calls.brokered.current == 0)
        }
        // The Qoder IDE's approval: a notice, which the bridge only acknowledges; nothing printed.
        let calls = Calls()
        guard case let .finished(note, nil) = Self.run(F.qoderAsk, source: "qoder", calls: calls) else {
            Issue.record("the IDE's approval printed something")
            return
        }
        #expect(note?.notificationType == "permission_prompt")
        guard case let .processClaudeHook(payload)? = calls.bridged.current.first else {
            Issue.record("nothing bridged")
            return
        }
        #expect(payload.hookEventName == .notification && payload.hookSource == "qoder")
    }
}
