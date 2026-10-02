import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine

/// The needs-you truth tables (§2 of the design) as the policy's table tests: what is held, released, shown, and
/// where Open goes.
struct AttentionPolicyTests {
    typealias Decision = AttentionPolicy.ClaudeDecision

    /// CL15, CL16, CL27 and the main-thread and subagent rows (C10).
    @Test
    func claudeIsHeldOnlyOnTheMainThreadOfTheFourInteractiveSurfaces() {
        let rows: [(entrypoint: String?, terminal: Bool, agent: String?, mode: String?, expected: Decision)] = [
            ("cli", false, nil, "default", Decision(hold: true, show: true, place: .terminal)),
            ("claude-desktop", false, nil, "default", Decision(hold: true, show: true, place: .claudeApp)),
            ("claude-desktop-3p", false, nil, "acceptEdits", Decision(hold: true, show: true, place: .claudeApp)),
            ("claude-vscode", false, nil, "plan", Decision(hold: true, show: true, place: .ide)),
            // AskUserQuestion is asked in bypass too: the mode does not release it.
            ("cli", true, nil, "bypassPermissions", Decision(hold: true, show: true, place: .terminal)),
            // A subagent: released at once, shown read-only on its parent.
            ("cli", true, "a1b2", "default", Decision(hold: false, show: true, place: .terminal)),
            ("claude-desktop", false, "a1b2", nil, Decision(hold: false, show: true, place: .claudeApp)),
            // local-agent, an unknown value, missing with no terminal: released, read-only.
            ("local-agent", false, nil, "default", Decision(hold: false, show: true, place: .claudeApp)),
            ("some-new-host", true, nil, "default", Decision(hold: false, show: true, place: .terminal)),
            (nil, false, nil, "default", Decision(hold: false, show: true, place: .terminal)),
            ("", false, nil, "default", Decision(hold: false, show: true, place: .terminal)),
            // Missing with a terminal counts as the terminal.
            (nil, true, nil, "default", Decision(hold: true, show: true, place: .terminal)),
            // Headless or dontAsk: released and not shown.
            ("sdk-cli", false, nil, "default", Decision(hold: false, show: false, place: .terminal)),
            ("sdk-ts", false, nil, "default", Decision(hold: false, show: false, place: .terminal)),
            ("sdk-py", true, nil, "default", Decision(hold: false, show: false, place: .terminal)),
            ("cli", true, nil, "dontAsk", Decision(hold: false, show: false, place: .terminal)),
        ]
        for row in rows {
            #expect(AttentionPolicy.claude(entrypoint: row.entrypoint, hasTerminal: row.terminal, agentID: row.agent,
                                           permissionMode: row.mode) == row.expected, "\(row)")
        }
        #expect(AttentionPolicy.claudeSurface(entrypoint: nil, hasTerminal: false) == "missing")
        #expect(AttentionPolicy.claudeSurface(entrypoint: nil, hasTerminal: true) == "cli")
    }

    /// The broker's reply comes from the request alone: Claude by the table above, Codex never held.
    @Test
    func theBrokerHoldsOnlyWhatTheTableHolds() {
        func line(_ source: String, _ entrypoint: String?, terminal: Bool = false) -> HookRequestLine {
            HookRequestLine(source: source, input: Data("{}".utf8), digest: nil, entrypoint: entrypoint, agentPID: 1,
                            hostBundleID: nil, hasTerminal: terminal)
        }
        #expect(AttentionPolicy.holds(line("claude", "cli"), [:]))
        #expect(!AttentionPolicy.holds(line("claude", "cli"), ["agent_id": "a1"]))
        #expect(AttentionPolicy.holds(line("claude", "cli"), ["agent_id": ""]))
        #expect(!AttentionPolicy.holds(line("claude", "sdk-cli"), [:]))
        #expect(!AttentionPolicy.holds(line("claude", "cli"), ["permission_mode": "dontAsk"]))
        #expect(!AttentionPolicy.holds(line("claude", nil), [:]))
        #expect(AttentionPolicy.holds(line("claude", nil, terminal: true), [:]))
        for entrypoint in [nil, "cli", "codex_desktop"] {
            #expect(!AttentionPolicy.holds(line("codex", entrypoint, terminal: true), [:]))
        }
        #expect(!AttentionPolicy.holds(line("qwen", "cli", terminal: true), [:]))
    }

    /// P350: with Answer subagents on the island off, a subagent's request is never held (P280); on, a subagent's tool
    /// approval from the four surfaces a main-thread request is held for is held, bounded by the broker's own end, and
    /// nothing else changes: not a question, a plan, `dontAsk`, a headless run, `local-agent`, an unknown surface, Codex;
    /// a main-thread hold is never bounded.
    @Test
    func answerSubagentsOnTheIslandHoldsOnlyASubagentsToolApprovalBounded() {
        func line(_ entrypoint: String?, source: String = "claude", terminal: Bool = false) -> HookRequestLine {
            HookRequestLine(source: source, input: Data("{}".utf8), digest: nil, entrypoint: entrypoint, agentPID: 1,
                            hostBundleID: nil, hasTerminal: terminal)
        }
        let bash: [String: Any] = ["agent_id": "wf-a", "agent_type": "workflow-subagent", "tool_name": "Bash",
                                   "permission_mode": "bypassPermissions"]
        for entrypoint in ["cli", "claude-desktop", "claude-desktop-3p", "claude-vscode"] {
            #expect(AttentionPolicy.brokerHold(line(entrypoint), bash, answersSubagents: false) == .released)
            #expect(AttentionPolicy.brokerHold(line(entrypoint), bash, answersSubagents: true, backstop: 15)
                == BrokerHold(held: true, bound: 15), "\(entrypoint)")
        }
        #expect(AttentionPolicy.brokerHold(line("cli"), bash, answersSubagents: true).bound
            == SubagentHold.limit + SubagentHold.backstopMargin)
        // Missing with a terminal is the terminal.
        #expect(AttentionPolicy.brokerHold(line(nil, terminal: true), bash, answersSubagents: true).held)
        var question = bash
        question["tool_name"] = "AskUserQuestion"
        var plan = bash
        plan["tool_name"] = "ExitPlanMode"
        var dontAsk = bash
        dontAsk["permission_mode"] = "dontAsk"
        var blank = bash
        blank["agent_id"] = ""
        for object in [question, plan, dontAsk] {
            #expect(AttentionPolicy.brokerHold(line("cli"), object, answersSubagents: true) == .released)
        }
        // An empty agent id is the main thread: held as ever, unbounded.
        #expect(AttentionPolicy.brokerHold(line("cli"), blank, answersSubagents: true) == BrokerHold(held: true))
        for entrypoint in ["sdk-cli", "local-agent", "some-new-host", nil] as [String?] {
            #expect(AttentionPolicy.brokerHold(line(entrypoint), bash, answersSubagents: true) == .released, "\(String(describing: entrypoint))")
        }
        #expect(AttentionPolicy.brokerHold(line(nil, source: "codex", terminal: true), bash, answersSubagents: true) == .released)
        // The main thread's hold never changes with the switch, and never has a bound.
        let main: [String: Any] = ["tool_name": "Bash", "permission_mode": "default"]
        #expect(AttentionPolicy.brokerHold(line("cli"), main, answersSubagents: true) == BrokerHold(held: true))
        #expect(AttentionPolicy.brokerHold(line("cli"), main, answersSubagents: false) == BrokerHold(held: true))
        #expect(!AttentionPolicy.holds(line("cli"), bash))
    }

    /// CX1, CX2, CX3, CX13, CX14: shown only when Codex will ask a person (C6).
    @Test
    func codexIsShownOnlyWhenItWillAskAPerson() {
        #expect(AttentionPolicy.codexShows(permissionMode: "default", reviewer: "user", strictAutoReview: false))
        #expect(AttentionPolicy.codexShows(permissionMode: "default", reviewer: nil, strictAutoReview: false))
        #expect(AttentionPolicy.codexShows(permissionMode: nil, reviewer: "something_new", strictAutoReview: false))
        #expect(!AttentionPolicy.codexShows(permissionMode: "bypassPermissions", reviewer: "user", strictAutoReview: false))
        #expect(!AttentionPolicy.codexShows(permissionMode: "default", reviewer: "auto_review", strictAutoReview: false))
        #expect(!AttentionPolicy.codexShows(permissionMode: "default", reviewer: "user", strictAutoReview: true))
    }

    @Test
    func codexOpenGoesToTheAppTheIDEOrTheTerminal() {
        #expect(AttentionPolicy.codexPlace(isCodexApp: true, hostBundleID: nil) == .codexApp)
        #expect(AttentionPolicy.codexPlace(isCodexApp: false, hostBundleID: ExactJump.codexBundleID) == .codexApp)
        #expect(AttentionPolicy.codexPlace(isCodexApp: false, hostBundleID: "com.microsoft.VSCode") == .ide)
        #expect(AttentionPolicy.codexPlace(isCodexApp: false, hostBundleID: "com.googlecode.iterm2") == .terminal)
        #expect(AttentionPolicy.codexPlace(isCodexApp: false, hostBundleID: nil) == .terminal)
    }

    /// C7: tool families, and the requests with no call of their own.
    @Test
    func codexToolFamiliesAndUnmatchedRequests() {
        #expect(AttentionPolicy.codexCallNames(forHookTool: "Bash")?.contains("exec_command") == true)
        #expect(AttentionPolicy.codexCallNames(forHookTool: "Bash")?.contains("local_shell_call") == true)
        // A patch can also come through a shell tool (intercepted) or a code-mode cell (P183).
        #expect(AttentionPolicy.codexCallNames(forHookTool: "apply_patch")?.isSuperset(of: ["apply_patch", "exec_command", "exec"]) == true)
        #expect(AttentionPolicy.codexCallNames(forHookTool: "Bash")?.contains("exec") == true)
        #expect(AttentionPolicy.codexCallNames(forHookTool: "mcp__docs__search") == ["mcp__docs__search"])
        #expect(AttentionPolicy.codexIsUnmatched(toolName: "Bash", description: "network-access example.org"))
        #expect(AttentionPolicy.codexIsUnmatched(toolName: "write_stdin", description: nil))
        #expect(AttentionPolicy.codexIsUnmatched(toolName: nil, description: nil))
        #expect(!AttentionPolicy.codexIsUnmatched(toolName: "Bash", description: "git push"))
    }
}
