import Foundation
import IslandHookNotes
import OpenIslandCore

/// One agent's hooks as Juice installs them (P915 to P934): where its config is, how entries sit in it, which events go
/// in, which of them carries an approval, the timeouts, how to find the agent on this Mac, and whether Juice can answer
/// it (Approve) or only show it and jump there (Watch). `AgentHookInstaller` writes and removes exactly these entries,
/// on a click only.
public struct AgentHookSpec: Sendable, Identifiable {
    /// How an entry sits in the file.
    public enum Layout: Sendable, Equatable {
        /// Claude Code's shape under `"hooks"`: `{"Event": [{"matcher"?, "hooks": [{"type": "command", "command",
        /// "timeout"?}]}]}`. Qwen Code and Devin CLI use it too.
        case claudeGroups
        /// GitHub Copilot CLI: `{"version": 1, "hooks": {"Event": [{"type": "command", "bash", "timeoutSec"?}]}}`.
        case copilot
        /// Cursor: `{"version": 1, "hooks": {"event": [{"command"}]}}`.
        case cursor
        /// A plugin file Juice writes whole (`AgentPlugins`): Kilo's copy of our OpenCode plugin, Pi's and Oh My Pi's
        /// extension, Amp's plugin.
        case plugin
        /// Antigravity CLI's `hooks.json`: hooks by name, each name holding its events; Juice's own name is the flavor's
        /// (`AgentHookSpec.hooksKey`). A tool event's entry is `{"matcher", "hooks": [{"type": "command", "command",
        /// "timeout"}]}`, any other event's the handler itself (P1105).
        case antigravity
        /// Factory Droid's `hooks.json`: Claude's groups keyed by event at the top of the file, no `"hooks"` around them
        /// (P1126).
        case claudeEvents
        /// Kimi's `config.toml`: one `[[hooks]]` table per entry, with `event`, `command` and `timeout` (P1130,
        /// `TOMLHookEdits`).
        case kimiToml
    }

    /// Whether the island can answer this agent's approvals, or only show its sessions and jump to them.
    public enum Answers: String, Sendable {
        case approve, watch
    }

    /// Where the config is, inside the agent's folder.
    public enum Place: Sendable, Equatable {
        /// A file the agent and others share (Cursor's `hooks.json`): Juice adds and removes its own entries only.
        case shared(String)
        /// A file only Juice writes, in a folder the agent loads every file of: named per flavor
        /// (`AgentHookInstaller.ownFileStem`), so the private app's and a public Juice's never meet (P925).
        case owned(folder: String, fileExtension: String)
    }

    public let kind: AgentKind
    /// The name the pane shows ("Copilot CLI").
    public let name: String
    /// The agent's own folder, from the home folder. It must exist before Connect: Juice never makes an agent's folder,
    /// so it never makes an agent look installed (P22).
    public let folder: String
    public let place: Place
    public let layout: Layout
    public let events: [HookEntrySpec]
    /// The events whose hook the agent waits on for a decision; empty for Watch.
    public let approvalEvents: [String]
    public let answers: Answers
    /// Its commands, any of which on this Mac says the agent is installed (P937).
    public let executables: [String]
    /// Where every path and event above was checked, and when.
    public let sources: [String]
    public let checked: String
    /// When the agent reads this place rather than the next of `elsewhere` (P1126, P1132).
    public var readWhen: ReadWhen = .always
    /// Where else the agent reads its hooks, in its own order: Factory Droid reads `hooks.json`, else its older
    /// `hooks/hooks.json`, else `settings.json`'s `"hooks"`; Kimi Code reads `~/.kimi-code`, the older Kimi CLI `~/.kimi`.
    /// The first place whose rule holds is the one Connect writes and the row shows (`AgentHookInstaller.resolved`);
    /// Remove takes Juice's entries out of every one.
    public var elsewhere: [AgentHookSpec] = []

    /// The rule that makes a place the one the agent reads.
    public enum ReadWhen: Sendable, Equatable {
        case always
        /// Its folder is there.
        case folderExists
        /// Its file is there.
        case fileExists
        /// Its file is there and has hook entries.
        case fileHasHooks
    }

    /// Where else a sign of the agent may be, from the home folder, when its folder alone would say another agent is
    /// here too (Gemini CLI's `~/.gemini` holds Antigravity CLI's files): nil for the folder itself (P1100).
    public var presenceFolders: [String]? = nil
    /// Shell words after the helper's arguments: Gemini CLI reads a failed hook's stderr as a deny (any exit but 0 and
    /// 1), and agy does not say what it does with one, so their commands end `2>/dev/null || true` (P1102).
    public var shellTail: [String] = []
    /// Where Approve holds for only part of the agent, the part that is Watch, in a few words: the Agents pane, the
    /// welcome and the READMEs' grids show it beside the tag (Qoder's IDE, P1190).
    public var reachNote: String? = nil
    /// Homebrew formulae that ship a command of one of `executables`' names that is another program (`amp`, a text
    /// editor; `cln`'s `pi`; AWS's `copilot`): a command that resolves into one of their Cellar folders does not say the
    /// agent is here (P1187).
    public var namesakeFormulae: [String] = []

    public var id: AgentKind { kind }

    /// The folders whose presence says the agent is on this Mac.
    public var footprintFolders: [String] { presenceFolders ?? [folder] }

    /// The member Juice's entries go under: `"hooks"`, or for Antigravity CLI the hook name that is Juice's own, the
    /// flavor's (`juice-island`, `juice`), so two flavors never take each other's (P925, P1105).
    public func hooksKey(stem: String) -> String { layout == .antigravity ? stem : "hooks" }

    /// The config file, from the agent's folder: the shared file, or Juice's own file for this flavor.
    public func file(stem: String) -> String {
        switch place {
        case let .shared(file): file
        case let .owned(folder, fileExtension): "\(folder)/\(stem).\(fileExtension)"
        }
    }

    /// The hook command for this agent: the helper, shell-quoted as upstream quotes it, `--source <kind>`, and its
    /// shell tail where it has one.
    public func command(helperPath: String) -> String {
        (["\(AgentHookTable.shellQuote(helperPath)) --source \(kind.rawValue)"] + shellTail).joined(separator: " ")
    }
}

public enum AgentHookTable {
    /// The agents a click connects through the table: wave 1's, then each later wave's. Claude Code and Codex keep their
    /// per-profile rows (`ProfileHookManager`), OpenCode its plugin row.
    public static let wave1: [AgentHookSpec] = [copilot, cursor, qwen, devin, kilo, gemini, antigravity, grok] + claudeFormat + plugins

    public static func spec(_ kind: AgentKind) -> AgentHookSpec? { wave1.first { $0.kind == kind } }

    /// GitHub Copilot CLI. User hooks are every `*.json` in `~/.copilot/hooks/`. PascalCase event names make Copilot
    /// send Claude's snake_case payload, which upstream's Claude decoder reads (`ClaudeFamilyRunner`). Its
    /// PermissionRequest answers `{"behavior": "allow" | "deny"}`; a timeout lets the call go on to Copilot's own prompt,
    /// and the default is 30 s, so ours waits an hour (P917). PreToolUse is left out: a hook that exits non-zero there
    /// denies the tool (fail closed), so a helper that is gone would block every tool call (P918).
    public static let copilot = AgentHookSpec(
        kind: .copilot, name: "Copilot CLI", folder: ".copilot", place: .owned(folder: "hooks", fileExtension: "json"),
        layout: .copilot,
        events: [
            HookEntrySpec(event: "SessionStart", matcher: nil, timeout: nil),
            HookEntrySpec(event: "UserPromptSubmit", matcher: nil, timeout: nil),
            HookEntrySpec(event: "PermissionRequest", matcher: nil, timeout: 3_600),
            HookEntrySpec(event: "PostToolUse", matcher: nil, timeout: nil),
            HookEntrySpec(event: "PostToolUseFailure", matcher: nil, timeout: nil),
            HookEntrySpec(event: "SubagentStop", matcher: nil, timeout: nil),
            HookEntrySpec(event: "PreCompact", matcher: nil, timeout: nil),
            HookEntrySpec(event: "Stop", matcher: nil, timeout: nil),
            HookEntrySpec(event: "SessionEnd", matcher: nil, timeout: nil),
        ],
        approvalEvents: ["PermissionRequest"], answers: .approve, executables: ["copilot"],
        sources: ["https://docs.github.com/en/copilot/reference/hooks-configuration",
                  "https://docs.github.com/en/copilot/reference/hooks-reference",
                  "https://formulae.brew.sh/formula/copilot (AWS Copilot CLI, another `copilot`)"],
        checked: "2026-10-02", namesakeFormulae: ["copilot"])

    /// Cursor, the editor's agent and `cursor-agent`, in `~/.cursor/hooks.json`. The events upstream's Cursor decoder reads,
    /// as Open Island installs them, but `beforeReadFile`, which fires on every read and asks nothing (P919). Watch:
    /// upstream's bridge answers the shell and MCP hooks `allow` at once, so the island shows the call and Cursor's own
    /// prompt decides (P919).
    public static let cursor = AgentHookSpec(
        kind: .cursor, name: "Cursor", folder: ".cursor", place: .shared("hooks.json"), layout: .cursor,
        events: [
            HookEntrySpec(event: "beforeSubmitPrompt", matcher: nil, timeout: nil),
            HookEntrySpec(event: "beforeShellExecution", matcher: nil, timeout: nil),
            HookEntrySpec(event: "beforeMCPExecution", matcher: nil, timeout: nil),
            HookEntrySpec(event: "afterFileEdit", matcher: nil, timeout: nil),
            HookEntrySpec(event: "stop", matcher: nil, timeout: nil),
        ],
        approvalEvents: [], answers: .watch, executables: ["cursor-agent", "cursor"],
        sources: ["https://cursor.com/docs/agent/hooks"], checked: "2026-10-02")

    /// Qwen Code: Claude's events under `"hooks"` in `~/.qwen/settings.json`. A matcher is a regular expression there,
    /// so Claude's `*` is left out (no matcher matches every tool). A timeout of 1000 or more is read as milliseconds,
    /// so the approval waits 900 s, not Claude's 86 400 (which Qwen would read as 86 s, P920). The island never answers
    /// `ask`: Qwen's bug #6321 turns it into a deny (P921).
    public static let qwen = AgentHookSpec(
        kind: .qwen, name: "Qwen Code", folder: ".qwen", place: .shared("settings.json"), layout: .claudeGroups,
        events: ClaudeHookEvents.all.map { HookEntrySpec(event: $0, matcher: nil, timeout: $0 == "PermissionRequest" ? 900 : nil) },
        approvalEvents: ["PermissionRequest"], answers: .approve, executables: ["qwen"],
        sources: ["https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/",
                  "https://github.com/QwenLM/qwen-code/issues/6321"],
        checked: "2026-10-02")

    /// Devin CLI: Claude-shaped groups under `"hooks"` in `~/.config/devin/config.json`. Only the events upstream's
    /// Claude decoder reads (PostCompaction is Devin's own). It answers `{"decision": "approve" | "block"}`. Devin also
    /// runs `~/.claude/settings.json`'s hooks by default; once its own config carries ours, the helper ends that copy
    /// silent (P909, P922).
    public static let devin = AgentHookSpec(
        kind: .devin, name: "Devin", folder: ".config/devin", place: .shared("config.json"), layout: .claudeGroups,
        events: [
            HookEntrySpec(event: "SessionStart", matcher: nil, timeout: nil),
            HookEntrySpec(event: "UserPromptSubmit", matcher: nil, timeout: nil),
            HookEntrySpec(event: "PermissionRequest", matcher: nil, timeout: 3_600),
            HookEntrySpec(event: "PostToolUse", matcher: nil, timeout: nil),
            HookEntrySpec(event: "Stop", matcher: nil, timeout: nil),
            HookEntrySpec(event: "SessionEnd", matcher: nil, timeout: nil),
        ],
        approvalEvents: ["PermissionRequest"], answers: .approve, executables: ["devin"],
        sources: ["https://docs.devin.ai/cli/extensibility/hooks/overview"], checked: "2026-10-02")

    /// Kilo CLI: every `.js` in `~/.config/kilo/plugin/` loads at start, with OpenCode's plugin API ("behavior is
    /// identical to OpenCode"), so it runs our OpenCode plugin under Kilo's name, its sessions `kilo-…` (P923).
    public static let kilo = AgentHookSpec(
        kind: .kilo, name: "Kilo", folder: ".config/kilo", place: .owned(folder: "plugin", fileExtension: "js"), layout: .plugin,
        events: [], approvalEvents: ["permission.asked"], answers: .approve, executables: ["kilo"],
        sources: ["https://kilo.ai/docs/automate/extending/plugins"], checked: "2026-10-02")

    // MARK: Wave 4, lane GEMINI: Gemini CLI, Antigravity CLI and Grok Build, all Watch (P1100 to P1124)

    /// Gemini CLI: Claude-shaped groups under `"hooks"` in `~/.gemini/settings.json`, which may carry comments (then Add
    /// by hand). Watch: BeforeTool can only block, and its ToolPermission notification only says a prompt shows, which
    /// the island shows as needs you (P1103). Its timeouts are milliseconds (default 60 000); the Notification hook is
    /// awaited before Gemini shows its prompt, so each waits 10 s at most. BeforeTool is left out: it fires before the
    /// permission check and adds a helper run to every call. Found by `gemini` or `~/.gemini/tmp`, never by `~/.gemini`
    /// alone, which Antigravity CLI keeps too (P1100).
    public static let gemini = AgentHookSpec(
        kind: .gemini, name: "Gemini CLI", folder: ".gemini", place: .shared("settings.json"), layout: .claudeGroups,
        events: [
            HookEntrySpec(event: "SessionStart", matcher: nil, timeout: 10_000),
            HookEntrySpec(event: "BeforeAgent", matcher: nil, timeout: 10_000),
            HookEntrySpec(event: "AfterTool", matcher: "*", timeout: 10_000),
            HookEntrySpec(event: "Notification", matcher: nil, timeout: 10_000),
            HookEntrySpec(event: "AfterAgent", matcher: nil, timeout: 10_000),
            HookEntrySpec(event: "SessionEnd", matcher: nil, timeout: 10_000),
        ],
        approvalEvents: [], answers: .watch, executables: ["gemini"],
        sources: ["https://geminicli.com/docs/hooks/reference/",
                  "https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/hooks/types.ts",
                  "https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/hooks/hookRunner.ts"],
        checked: "2026-10-03", presenceFolders: [".gemini/tmp"], shellTail: ["2>/dev/null", "||", "true"])

    /// Antigravity (`agy`, its CLI): Juice's own hook name in `~/.gemini/config/hooks.json`, the file agy 1.1 and later
    /// reads, and Antigravity 2.0 and its IDE with it, so the row is the product's (P1191);
    /// `~/.gemini/antigravity-cli/settings.json` is read no more. Watch: a
    /// PreToolUse answer decides the call and nothing says one would have prompted, so PreToolUse is never registered,
    /// and no hook of Juice's prints a verdict (P1105, P1106). Timeouts in seconds (default 30). Found by `agy` or
    /// `~/.gemini/antigravity-cli` (P1100).
    public static let antigravity = AgentHookSpec(
        kind: .antigravity, name: "Antigravity", folder: ".gemini/config", place: .shared("hooks.json"), layout: .antigravity,
        events: [
            HookEntrySpec(event: "PreInvocation", matcher: nil, timeout: 10),
            HookEntrySpec(event: "PostToolUse", matcher: "*", timeout: 10),
            HookEntrySpec(event: "Stop", matcher: nil, timeout: 10),
        ],
        approvalEvents: [], answers: .watch, executables: ["agy"],
        sources: ["https://antigravity.google/docs/hooks/",
                  "https://github.com/google-antigravity/antigravity-cli/blob/main/CHANGELOG.md",
                  "https://github.com/google-antigravity/antigravity-cli/issues/925",
                  "https://github.com/google-antigravity/antigravity-cli/issues/1005"],
        checked: "2026-10-03", presenceFolders: [".gemini/antigravity-cli"], shellTail: ["2>/dev/null", "||", "true"])

    /// Grok Build: Juice's own file in `~/.grok/hooks/`, every `*.json` of which Grok loads; Claude's group shape,
    /// timeouts in seconds (default 5). Watch: PreToolUse can only deny, an allow goes on to Grok's own prompt, and
    /// its permission_prompt notification says that prompt shows (needs you); done on Stop, StopCancelled and the
    /// idle_prompt notification. PreToolUse is left out: it tells nothing PostToolUse does not and runs before every call.
    /// Grok also runs Claude's `~/.claude/settings.json` hooks: the helper files those as Grok's, and ends them silent
    /// once this file is in (P1110, P1111). Found by the folders its installer always makes, never by a `grok` command:
    /// Homebrew's `grok` is a regex tool (P1187).
    public static let grok = AgentHookSpec(
        kind: .grok, name: "Grok Build", folder: ".grok", place: .owned(folder: "hooks", fileExtension: "json"), layout: .claudeGroups,
        events: [
            HookEntrySpec(event: "SessionStart", matcher: nil, timeout: 10),
            HookEntrySpec(event: "UserPromptSubmit", matcher: nil, timeout: 10),
            HookEntrySpec(event: "PostToolUse", matcher: "*", timeout: 10),
            HookEntrySpec(event: "PostToolUseFailure", matcher: "*", timeout: 10),
            HookEntrySpec(event: "PermissionDenied", matcher: nil, timeout: 10),
            HookEntrySpec(event: "Notification", matcher: nil, timeout: 10),
            HookEntrySpec(event: "SubagentStart", matcher: nil, timeout: 10),
            HookEntrySpec(event: "SubagentStop", matcher: nil, timeout: 10),
            HookEntrySpec(event: "PreCompact", matcher: nil, timeout: 10),
            HookEntrySpec(event: "PostCompact", matcher: nil, timeout: 10),
            HookEntrySpec(event: "Stop", matcher: nil, timeout: 10),
            HookEntrySpec(event: "StopFailure", matcher: nil, timeout: 10),
            HookEntrySpec(event: "StopCancelled", matcher: nil, timeout: 10),
            HookEntrySpec(event: "SessionEnd", matcher: nil, timeout: 10),
        ],
        approvalEvents: [], answers: .watch, executables: [],
        sources: ["https://docs.x.ai/build/features/hooks",
                  "https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-hooks/src/event.rs",
                  "https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-hooks/src/discovery.rs"],
        checked: "2026-10-03", presenceFolders: [".grok/bin", ".grok/hooks", ".grok/downloads"])

    // MARK: Wave 4, plugins of Juice's own (P1150 to P1174)

    /// Pi, Oh My Pi and Amp: a file of Juice's own in each agent's plugin folder, written on Connect and deleted on
    /// Remove (`AgentPlugins`). All three are Watch.
    public static let plugins: [AgentHookSpec] = [pi, ohMyPi, amp]

    /// Pi: every `.ts` and `.js` in `~/.pi/agent/extensions/` loads at start, through `jiti`, with no build step. Juice's
    /// extension reports the session to the app's socket and never waits on it (`PiExtension`). Watch: Pi has no
    /// permission prompts by design (P1150). Homebrew's `cln` ships a `pi` too (P1187).
    public static let pi = AgentHookSpec(
        kind: .pi, name: "Pi", folder: ".pi/agent", place: .owned(folder: "extensions", fileExtension: "ts"), layout: .plugin,
        events: [], approvalEvents: [], answers: .watch, executables: ["pi"],
        sources: ["https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md",
                  "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md",
                  "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/extensions/types.ts",
                  "https://formulae.brew.sh/formula/cln"],
        checked: "2026-10-03", namesakeFormulae: ["cln"])

    /// Oh My Pi: the same extension in `~/.omp/agent/extensions/` (the default profile's agent folder), loaded by Bun.
    /// Watch: its approval mode is off (`yolo`) by default, and when on, its prompt is its own; an extension cannot answer
    /// it (P1152, P1153).
    public static let ohMyPi = AgentHookSpec(
        kind: .ohmypi, name: "Oh My Pi", folder: ".omp/agent", place: .owned(folder: "extensions", fileExtension: "ts"),
        layout: .plugin, events: [], approvalEvents: [], answers: .watch, executables: ["omp"],
        sources: ["https://github.com/can1357/oh-my-pi/blob/main/docs/extension-loading.md",
                  "https://github.com/can1357/oh-my-pi/blob/main/docs/approval-mode.md",
                  "https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/extensibility/extensions/types.ts"],
        checked: "2026-10-03")

    /// Amp: every `.ts` and `.js` in `~/.config/amp/plugins/` runs under Amp's own Bun. Juice's plugin reports its threads
    /// in OpenCode's payload as `amp-…` sessions, and shows a thread Amp says waits for an approval as waiting, read-only
    /// (`AmpPlugin`). Watch: Amp asks about no call, and its plugin API cannot say which calls another plugin will ask
    /// about (P1157, P1158). Homebrew's `amp` is a text editor (P1187).
    public static let amp = AgentHookSpec(
        kind: .amp, name: "Amp", folder: ".config/amp", place: .owned(folder: "plugins", fileExtension: "ts"), layout: .plugin,
        events: [], approvalEvents: [], answers: .watch, executables: ["amp"],
        sources: ["https://ampcode.com/docs/customize/plugins", "https://ampcode.com/docs/plugin-api",
                  "https://ampcode.com/docs/tools#permissions", "https://formulae.brew.sh/formula/amp"],
        checked: "2026-10-03", namesakeFormulae: ["amp"])

    /// Upstream's quoting (ClaudeHookInstaller.swift `shellQuote`), so a path with a space or a quote stays one word.
    public static func shellQuote(_ string: String) -> String {
        guard !string.isEmpty else { return "''" }
        return "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// The command's words, as a shell would split it (single quotes, the `'\''` escape, double quotes and
    /// backslashes); nil for anything else.
    public static func words(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(command).makeIterator()
        var quote: Character?
        while let character = iterator.next() {
            if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "\\", let next = iterator.next() {
                    current.append(next)
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                if let next = iterator.next() { current.append(next) }
                inWord = true
            case " ", "\t":
                if inWord { words.append(current) }
                current = ""
                inWord = false
            default:
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(current) }
        return words
    }

    /// Whether `command` runs exactly this helper with this source (nil: none, Codex's) and this shell tail: Juice's own
    /// entry. Another flavor's helper, Open Island's, Vibe Island's and anyone else's are never ours (P925).
    public static func isOurs(_ command: String, source: String?, helperPath: String, tail: [String] = []) -> Bool {
        guard let words = words(command), let program = words.first,
              URL(fileURLWithPath: program).standardizedFileURL.path == URL(fileURLWithPath: helperPath).standardizedFileURL.path
        else { return false }
        return Array(words.dropFirst()) == (source.map { ["--source", $0] } ?? []) + tail
    }

    /// Whether `command` runs Open Island's helper (any install of it) with this source: what Juice wrote before its own
    /// helper, and what Open Island writes. Codex's carry no source (nil, P290). Connect and Move replace these (P903).
    public static func isOldIsland(_ command: String, source: String?) -> Bool {
        guard let words = words(command), let program = words.first,
              (program as NSString).lastPathComponent == LegacyHookHome.helperName else { return false }
        let arguments = Array(words.dropFirst())
        guard let source, source != HookContextNote.codexSource else {
            return arguments.isEmpty || arguments == ["--source", HookContextNote.codexSource]
        }
        return arguments == ["--source", source]
    }
}
