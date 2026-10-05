import Foundation
import IslandHookNotes

/// Wave 4's Claude-format agents (P1125 to P1149): Qoder, CodeBuddy, Factory Droid and Kimi Code. Each speaks Claude's
/// hook payload, and the helper runs each one's hooks itself (`ClaudeFamilyRunner`), so an agent's own words (a
/// permission mode or an event Claude does not have) never make upstream's decoder drop a hook.
extension AgentHookTable {
    /// In the Agents pane's order, after wave 1's.
    public static let claudeFormat: [AgentHookSpec] = [qoder, codebuddy, factory, kimi]

    /// Every event of Claude's, the approval waiting an hour: what Qoder and CodeBuddy read in `settings.json`.
    static func claudeEvents(approvalTimeout: Int) -> [HookEntrySpec] {
        ClaudeHookEvents.all.map { HookEntrySpec(event: $0, matcher: nil, timeout: $0 == "PermissionRequest" ? approvalTimeout : nil) }
    }

    /// Qoder: Claude's groups under `"hooks"` in `~/.qoder/settings.json`, which its CLI and its IDE both read. The CLI
    /// takes Claude's PermissionRequest answer (`hookSpecificOutput.decision.behavior`, its own schema) and races it with
    /// its own prompt: the first answer decides (P1125). The IDE documents another answer (`permissionDecision`), so an
    /// approval there stays in the IDE and shows as "needs you" (P1127), and the row and the grids say so (P1190). No
    /// matcher: Qoder's matches every tool then.
    public static let qoder = AgentHookSpec(
        kind: .qoder, name: "Qoder", folder: ".qoder", place: .shared("settings.json"), layout: .claudeGroups,
        events: claudeEvents(approvalTimeout: 3_600),
        approvalEvents: ["PermissionRequest"], answers: .approve, executables: ["qodercli", "qoder"],
        sources: ["https://docs.qoder.com/cli/hooks", "https://docs.qoder.com/extensions/hooks",
                  "https://registry.npmjs.org/@qoder-ai/qodercli/-/qodercli-1.1.65.tgz (bundle/qodercli.js)"],
        checked: "2026-10-03", reachNote: "Qoder CLI; the Qoder IDE is Watch")

    /// CodeBuddy Code: Claude's groups under `"hooks"` in `~/.codebuddy/settings.json`. Its PermissionRequest hook runs
    /// before its own prompt and an `allow` or `deny` in `hookSpecificOutput.decision` ends the call there, so it shows no
    /// prompt while the island holds the call; a timeout lets it go on to its own, so ours waits an hour (P1128). Found
    /// by `codebuddy` only: Homebrew's `cbc` is a solver (P1187).
    public static let codebuddy = AgentHookSpec(
        kind: .codebuddy, name: "CodeBuddy", folder: ".codebuddy", place: .shared("settings.json"), layout: .claudeGroups,
        events: claudeEvents(approvalTimeout: 3_600),
        approvalEvents: ["PermissionRequest"], answers: .approve, executables: ["codebuddy"],
        sources: ["https://www.codebuddy.ai/docs/cli/hooks",
                  "https://registry.npmjs.org/@tencent-ai/codebuddy-code/-/codebuddy-code-2.161.1.tgz (dist/codebuddy.js)"],
        checked: "2026-10-03")

    /// Factory Droid: Claude's groups keyed by event in `~/.factory/hooks.json`. Droid reads that file when it is there,
    /// else its older `hooks/hooks.json`, else `settings.json`'s `"hooks"` (where Open Island writes), so Connect writes
    /// the one Droid reads and never makes a `hooks.json` that would switch off hooks the owner keeps in `settings.json`
    /// (P1126). Watch: Droid has no PermissionRequest, and a PreToolUse `allow` would skip its prompt, so neither is
    /// registered; its `permission_prompt` notification says "needs you" and `elicitation_dialog` shows a question
    /// (P1129).
    public static let factory = AgentHookSpec(
        kind: .factory, name: "Factory Droid", folder: ".factory", place: .shared("hooks.json"), layout: .claudeEvents,
        events: factoryEvents, approvalEvents: [], answers: .watch, executables: ["droid"],
        sources: ["https://docs.factory.com/reference/hooks-reference", "https://docs.factory.com/cli/configuration/hooks-guide"],
        checked: "2026-10-03", readWhen: .fileExists,
        elsewhere: [
            AgentHookSpec(kind: .factory, name: "Factory Droid", folder: ".factory", place: .shared("hooks/hooks.json"),
                          layout: .claudeEvents, events: factoryEvents, approvalEvents: [], answers: .watch, executables: ["droid"],
                          sources: ["https://docs.factory.com/cli/configuration/hooks-guide"], checked: "2026-10-03",
                          readWhen: .fileExists),
            AgentHookSpec(kind: .factory, name: "Factory Droid", folder: ".factory", place: .shared("settings.json"),
                          layout: .claudeGroups, events: factoryEvents, approvalEvents: [], answers: .watch, executables: ["droid"],
                          sources: ["https://docs.factory.com/cli/configuration/hooks-guide"], checked: "2026-10-03",
                          readWhen: .fileHasHooks),
        ])

    static let factoryEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SubagentStop",
                                "PreCompact", "SessionEnd"].map { HookEntrySpec(event: $0, matcher: nil, timeout: nil) }

    /// Kimi Code: `[[hooks]]` tables in `~/.kimi-code/config.toml`. Watch: every Kimi hook but PreToolUse, Stop and
    /// UserPromptSubmit fires and is forgotten, and its PreToolUse can only block. Only events its issue 3888 found safe:
    /// a PreToolUse or SessionHeartbeat hook hides the approval in Kimi's web, desktop and VS Code clients and lets the
    /// call through (P1131). Its PermissionRequest says "needs you", PermissionResult that it was answered; Stop,
    /// StopFailure and Interrupt end the turn. No prompt event: both fire before an approval, so a Kimi Code session
    /// shows once it first waits on you. The older Kimi CLI (`~/.kimi/config.toml`, the same tables) knows only its own
    /// thirteen events and has no approval hook, so it gets those of the list it has, and its UserPromptSubmit (issue
    /// 3888 is Kimi Code's) so its sessions show at all (P1132).
    public static let kimi = AgentHookSpec(
        kind: .kimi, name: "Kimi Code", folder: ".kimi-code", place: .shared("config.toml"), layout: .kimiToml,
        events: ["SessionStart", "PermissionRequest", "PermissionResult", "Stop", "StopFailure", "Interrupt", "SessionEnd"]
            .map { HookEntrySpec(event: $0, matcher: nil, timeout: kimiTimeout) },
        approvalEvents: [], answers: .watch, executables: ["kimi"],
        sources: ["https://moonshotai.github.io/kimi-code/en/customization/hooks.html",
                  "https://github.com/MoonshotAI/kimi-code (packages/agent-core-v2/src/features/externalHooks, 21406fb)",
                  "https://github.com/MoonshotAI/kimi-code/issues/3888"],
        checked: "2026-10-03", readWhen: .folderExists,
        elsewhere: [
            AgentHookSpec(kind: .kimi, name: "Kimi CLI", folder: ".kimi", place: .shared("config.toml"), layout: .kimiToml,
                          events: ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]
                              .map { HookEntrySpec(event: $0, matcher: nil, timeout: kimiTimeout) },
                          approvalEvents: [], answers: .watch, executables: ["kimi"],
                          sources: ["https://github.com/MoonshotAI/kimi-cli (src/kimi_cli/hooks, 9ab1286)"], checked: "2026-10-03",
                          readWhen: .folderExists),
        ])

    /// Kimi waits on its SessionStart and Stop hooks: a hung bridge holds a turn's end this long at most.
    static let kimiTimeout = 10
}
