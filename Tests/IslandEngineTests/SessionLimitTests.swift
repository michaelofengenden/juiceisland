import Foundation
import IslandHookNotes
import JuiceCore
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Limit warnings in the engine (P700 to P704): the agents' own words for a limit or an API error, read into a
/// `SessionLimit`; a Claude turn that failed on one, until it works again or its reset passes; a Codex turn whose rollout
/// says so; and "Open in <account>", which only an injected launcher ever runs here. Fixtures only.
@MainActor
struct SessionLimitTests {
    typealias F = EngineFixtures
    typealias R = RolloutFixtures

    nonisolated static let utc = TimeZone(identifier: "UTC")!
    /// 2027-01-15 08:00 UTC, midnight in Los Angeles.
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: P701 Claude's words

    @Test
    func claudesUsageLimitSaysWhenItResets() {
        func reset(_ message: String, at: Date = Self.now) -> Date? {
            LimitText.claude(error: "rate_limit", message: message, at: at, localZone: Self.utc)?.resetsAt
        }
        // Claude Code 2.1's `uh`: a time alone within a day, in the zone it names.
        #expect(reset("You've hit your session limit · resets 3pm (America/Los_Angeles)") == Self.date("2027-01-15T23:00:00Z"))
        #expect(reset("You've hit your session limit · resets 3:30pm (Europe/London) · progress saved") == Self.date("2027-01-15T15:30:00Z"))
        // Past that time today: tomorrow's.
        #expect(reset("You've hit your session limit · resets 3pm (America/Los_Angeles)", at: Self.now + 16 * 3_600)
                == Self.date("2027-01-16T23:00:00Z"))
        // Further out: a month and a day, and a year when it is another year's.
        #expect(reset("You've hit your weekly limit · resets Jan 20, 9am (UTC)") == Self.date("2027-01-20T09:00:00Z"))
        #expect(reset("You've hit your weekly limit · resets Jan 3, 2028, 9:15am (UTC)") == Self.date("2028-01-03T09:15:00Z"))
        // A zone the Mac does not know reads in its own; no time, no reset.
        #expect(reset("You've hit your Opus limit · resets 6pm (Nowhere/Land)") == Self.date("2027-01-15T18:00:00Z"))
        #expect(reset("You've hit your usage limit · contact your admin to increase it") == nil)
        #expect(LimitText.claude(error: "rate_limit", message: "You've hit your usage limit · contact your admin to increase it", at: Self.now)
                == SessionLimit(kind: .usageLimit))
        #expect(LimitText.claude(error: "rate_limit", message: "You're out of usage credits · resets 5pm (UTC)", at: Self.now)?.kind == .usageLimit)
    }

    /// Every opening on Claude Code 2.1.280's own list of the account's limits (its `fvr` and the Fable pattern beside
    /// it, which its `XZn` reads), and the service its org turned off: all sent as `rate_limit`, all the account's
    /// (P706). The CLI's warnings and notices on the same lists are not a limit.
    @Test
    func everyLimitClaudeCodeNamesIsTheAccounts() {
        func kind(_ message: String) -> SessionLimit.Kind? {
            LimitText.claude(error: "rate_limit", message: message, at: Self.now, localZone: Self.utc)?.kind
        }
        for message in [
            "You've reached your Fable limit. /model to switch models.",
            "You’ve reached your Fable limit. /model to switch models.",
            "Fable 5 requires usage credits. Run /usage-credits to turn them on.",
            "Fable requires usage credits. Run /usage-credits to turn them on.",
            "Fable 5 Preview requires usage credits.",
            "Your seat type doesn't include usage credits",
            "Your seat type doesn't include usage",
            "Your seat type doesn't include extra usage",
            "Your usage allocation has been disabled by your admin · ask your admin",
            "Your group's usage limit is set to $0 · ask your admin",
            "You're out of extra usage · resets 5pm (UTC)",
            "Your org is out of usage · add funds to continue",
            "Your org is out of usage · contact your admin",
            "This service is disabled for your org",
        ] {
            #expect(kind(message) == .usageLimit, "\(message)")
        }
        #expect(LimitText.claude(error: "rate_limit", message: "You're out of extra usage · resets 5pm (UTC)", at: Self.now,
                                 localZone: Self.utc)?.resetsAt == Self.date("2027-01-15T17:00:00Z"))
        for message in [
            "You've used 90% of your session limit · resets 3pm (UTC)",
            "You're close to your weekly limit",
            "You're now using usage credits",
            "Fable 5 is overloaded. Try again later.",
            "API Error: Fable requires usage credits.",
        ] {
            #expect(kind(message) == .rateLimited, "\(message)")
        }
    }

    @Test
    func claudesOtherErrorsAreTheProvidersOrNone() {
        func kind(_ error: String?, _ message: String? = nil) -> SessionLimit.Kind? {
            LimitText.claude(error: error, message: message, at: Self.now)?.kind
        }
        // A rate limit that is not the account's: the server's.
        #expect(kind("rate_limit", "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited") == .rateLimited)
        #expect(kind("rate_limit") == .rateLimited)
        #expect(kind("overloaded") == .overloaded)
        #expect(kind("server_error", "API Error: Repeated 529 Overloaded errors. The API is at capacity") == .serverError)
        // Every other failure keeps today's words (P132), and a Stop is never one.
        for other in ["authentication_failed", "billing_error", "invalid_request", "max_output_tokens", "unknown", "Done."] {
            #expect(kind(other, "You've hit your session limit · resets 3pm (UTC)") == nil, "\(other)")
        }
        #expect(kind(nil) == nil)
        // An API error has no reset, whatever its text says.
        #expect(SessionLimit(kind: .overloaded, resetsAt: Self.now).resetsAt == nil)
    }

    // MARK: P701 Codex's fields

    @Test
    func codexsTurnEndErrorNamesItsKind() {
        func limit(_ info: Any?, _ message: String = "") -> SessionLimit? {
            var error: [String: Any] = ["message": message]
            if let info { error["codex_error_info"] = info }
            return LimitText.codex(error: error, at: Self.now, localZone: Self.utc)
        }
        let today = "You've hit your usage limit. Upgrade to Pro (https://example.com/pro), or try again at 3:45 PM."
        #expect(limit("usage_limit_exceeded", today) == SessionLimit(kind: .usageLimit, resetsAt: Self.date("2027-01-15T15:45:00Z")))
        let later = "You've hit your usage limit. To get more access now, send a request to your admin or try again at Jan 17th, 2027 9:05 AM."
        #expect(limit("usage_limit_exceeded", later)?.resetsAt == Self.date("2027-01-17T09:05:00Z"))
        #expect(limit("usage_limit_exceeded", "You've hit your usage limit.") == SessionLimit(kind: .usageLimit))
        #expect(limit("rate_limit_exceeded")?.kind == .rateLimited)
        #expect(limit("server_overloaded")?.kind == .overloaded)
        #expect(limit("internal_server_error")?.kind == .serverError)
        // A kind that carries a status: an object keyed by its word.
        #expect(limit(["http_connection_failed": ["http_status_code": 503]])?.kind == .serverError)
        #expect(limit(["response_stream_disconnected": ["http_status_code": 429]])?.kind == .rateLimited)
        #expect(limit(["response_too_many_failed_attempts": ["http_status_code": 529]])?.kind == .overloaded)
        #expect(limit(["http_connection_failed": ["http_status_code": 400]]) == nil)
        #expect(limit(["response_stream_disconnected": [:]]) == nil)
        // Not a limit or an API error: the turn's own trouble, or none named.
        #expect(limit("context_window_exceeded") == nil)
        #expect(limit("sandbox_error") == nil)
        #expect(limit(nil, today) == nil)
    }

    @Test
    func aReadingThatReachedTheLimitLiftsWithItsFullWindows() {
        let primary: [String: Any] = ["used_percent": 100.0, "window_minutes": 300, "resets_at": 1_800_010_000]
        let secondary: [String: Any] = ["used_percent": 42.0, "window_minutes": 10_080, "resets_at": 1_800_400_000]
        let reached = LimitText.codexReading(["rate_limit_reached_type": "rate_limit_reached", "primary": primary, "secondary": secondary],
                                             at: Self.now)
        #expect(reached == SessionLimit(kind: .usageLimit, resetsAt: Date(timeIntervalSince1970: 1_800_010_000)))
        // Both full: the later.
        var both = secondary
        both["used_percent"] = 100
        #expect(LimitText.codexReading(["rate_limit_reached_type": "workspace_member_usage_limit_reached", "primary": primary,
                                        "secondary": both], at: Self.now)?.resetsAt == Date(timeIntervalSince1970: 1_800_400_000))
        // An older reading's `resets_in_seconds`, from the line's time.
        #expect(LimitText.codexReading(["rate_limit_reached_type": "rate_limit_reached",
                                        "primary": ["used_percent": 100, "resets_in_seconds": 600]], at: Self.now)?.resetsAt == Self.now + 600)
        // Not reached: no limit, however full.
        #expect(LimitText.codexReading(["primary": primary], at: Self.now) == nil)
        #expect(LimitText.codexReading(["rate_limit_reached_type": NSNull(), "primary": primary], at: Self.now) == nil)
    }

    /// The fold beside the rollout reader: the turn end's error, a reading that reached the limit, and the next turn's
    /// start or prompt, which ends it. Plain readings are never parsed.
    @Test
    func theRolloutFoldKeepsTheLatestTurnsLimit() {
        var attention = CodexAttention()
        let plain = R.event("token_count", ["rate_limits": ["primary": ["used_percent": 40, "resets_at": 1_800_010_000],
                                                             "rate_limit_reached_type": NSNull()]], at: 1)
        #expect(!CodexAttention.mayMatter(plain))
        attention.apply(R.event("task_started", ["turn_id": "t1"], at: 1))
        attention.apply(plain)
        #expect(attention.limit == nil)
        _ = attention.takeEvents()
        attention.apply(R.event("task_complete", ["turn_id": "t1", "last_agent_message": NSNull(),
                                                  "error": ["message": "You've hit your usage limit. Try again at 3:45 PM.",
                                                            "codex_error_info": "usage_limit_exceeded"]], at: 2))
        #expect(attention.limit?.kind == .usageLimit)
        #expect(attention.takeEvents().contains(.factsChanged))
        // The next prompt ends it.
        attention.apply(R.event("user_message", ["message": "go on", "images": []], at: 3))
        #expect(attention.limit == nil)
        // A reading that reached the limit stands when the turn ends with no error of its own.
        attention.apply(R.event("task_started", ["turn_id": "t2"], at: 4))
        let reached = R.event("token_count", ["rate_limits": ["primary": ["used_percent": 100, "resets_at": 1_800_010_000],
                                                               "rate_limit_reached_type": "rate_limit_reached"]], at: 5)
        #expect(CodexAttention.mayMatter(reached))
        attention.apply(reached)
        attention.apply(R.event("task_complete", ["turn_id": "t2", "last_agent_message": NSNull()], at: 6))
        #expect(attention.limit == SessionLimit(kind: .usageLimit, resetsAt: Date(timeIntervalSince1970: 1_800_010_000)))
        attention.apply(R.event("task_started", ["turn_id": "t3"], at: 7))
        #expect(attention.limit == nil)
        attention.apply(R.event("task_complete", ["turn_id": "t3", "error": ["message": "overloaded", "codex_error_info": "server_overloaded"]],
                                at: 8))
        #expect(attention.limit == SessionLimit(kind: .overloaded))
        // An interrupt names no error: the turn's limit stays as it was.
        attention.apply(R.event("turn_aborted", ["turn_id": "t3", "reason": "interrupted"], at: 9))
        #expect(attention.limit == SessionLimit(kind: .overloaded))
    }

    // MARK: P700, P702 The engine

    /// A Claude StopFailure as the bridge sends it: the hook's message as the session's last message, then the
    /// completion whose summary is the hook's `error`.
    static func claudeFailure(_ engine: SessionEngine, _ id: String, error: String, message: String) {
        engine.ingest(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(
            sessionID: id, claudeMetadata: ClaudeSessionMetadata(lastUserPrompt: "fix the tests", lastAssistantMessage: message),
            timestamp: now)), ingress: .bridge)
        engine.ingest(note: HookContextNote(event: "StopFailure", sessionID: id, source: "claude"))
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: id, summary: error, timestamp: now)), ingress: .bridge)
    }

    static func prompted(_ engine: SessionEngine, _ id: String = "s1") {
        engine.ingest(F.started(id), ingress: .bridge)
        engine.ingest(F.prompt(id), ingress: .bridge)
    }

    @Test
    func aClaudeTurnThatHitItsLimitNeedsYouUntilTheReset() throws {
        let clock = F.Box(Self.now)
        let engine = F.engine(clock: clock)
        Self.prompted(engine)
        Self.claudeFailure(engine, "s1", error: "rate_limit", message: "You've hit your session limit · resets 3pm (UTC)")
        var session = try #require(engine.state.session(id: "s1"))
        #expect(engine.limit(for: session) == SessionLimit(kind: .usageLimit, resetsAt: Self.date("2027-01-15T15:00:00Z")))
        #expect(engine.hasFailedTurn(session) && engine.needsYouCount == 1)
        // The reset passed: nothing needs the owner, and the limit still says why it stopped.
        clock.update { $0 = Self.date("2027-01-15T15:00:00Z") }
        session = try #require(engine.state.session(id: "s1"))
        #expect(!engine.hasFailedTurn(session) && engine.needsYouCount == 0)
        #expect(engine.limit(for: session)?.hasReset(at: clock.current) == true)
        // The session works again: no limit.
        engine.ingest(F.prompt("s1", "go on"), ingress: .bridge)
        #expect(engine.limit(for: try #require(engine.state.session(id: "s1"))) == nil)
        #expect(engine.turnLimits.isEmpty)
    }

    @Test
    func anAPIErrorStaysUntilTheSessionWorksAgainAndOutlivesADismiss() throws {
        let engine = F.engine()
        for id in ["a", "b"] { Self.prompted(engine, id) }
        Self.claudeFailure(engine, "a", error: "overloaded", message: "API Error: overloaded")
        Self.claudeFailure(engine, "b", error: "server_error", message: "API Error: Repeated 529 Overloaded errors")
        #expect(engine.limit(for: try #require(engine.state.session(id: "a"))) == SessionLimit(kind: .overloaded))
        // A dismiss ends the failed turn, not why it stopped (the row still says it, quietly).
        engine.clearTurnFailure("a")
        let a = try #require(engine.state.session(id: "a"))
        #expect(!engine.hasFailedTurn(a) && engine.limit(for: a)?.kind == .overloaded)
        // Claude went on by itself: activity ends it.
        engine.ingest(F.running("b"), ingress: .bridge)
        #expect(engine.limit(for: try #require(engine.state.session(id: "b"))) == nil)
        // A failure that is no limit or API error keeps today's words, and a normal Stop is never one.
        Self.prompted(engine, "c")
        Self.claudeFailure(engine, "c", error: "authentication_failed", message: "Please run /login")
        #expect(engine.limit(for: try #require(engine.state.session(id: "c"))) == nil)
        Self.prompted(engine, "d")
        engine.ingest(note: HookContextNote(event: "Stop", sessionID: "d", source: "claude"))
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "d", summary: "rate_limit", timestamp: Self.now)), ingress: .bridge)
        #expect(engine.limit(for: try #require(engine.state.session(id: "d"))) == nil)
    }

    @Test
    func aCodexTurnsLimitComesFromItsRollout() throws {
        let engine = SessionEngine.preview(clock: { Self.now + 60 })
        let rollout = "/tmp/juice-island-test/sessions/rollout-c1.jsonl"
        engine.loadPreviewEvents([.sessionStarted(SessionStarted(
            sessionID: "c1", title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: Self.now, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "codex",
                                                        workingDirectory: "/tmp/project"),
            codexMetadata: CodexSessionMetadata(transcriptPath: rollout, lastUserPrompt: "move the settings")))])
        engine.loadPreviewRollout(sessionID: "c1", transcriptPath: rollout, lines: [
            R.meta(id: "c1"),
            R.event("user_message", ["message": "move the settings", "images": []], at: 1),
            R.event("task_started", ["turn_id": "t1"], at: 2),
            R.event("task_complete", ["turn_id": "t1", "last_agent_message": NSNull(),
                                      "error": ["message": "You've hit your usage limit. Try again at 3:45 PM.",
                                                "codex_error_info": "usage_limit_exceeded"]], at: 3),
        ])
        let session = try #require(engine.state.session(id: "c1"))
        #expect(session.phase == .completed)
        #expect(engine.limit(for: session)?.kind == .usageLimit)
        // Never a failed turn: no sound or island open beyond today's rules (P700).
        #expect(!engine.hasFailedTurn(session) && engine.needsYouCount == 0)
    }

    // MARK: P703 Open in another account

    @Test
    func theNewSessionsLineRunsTheAccountsCLIInTheFolder() {
        let home = "/Users/demo"
        #expect(FreshSessionLaunch.line(provider: .claude, profileFolder: "/Users/demo/.claude-lab", folder: "/tmp/project", home: home)
                == "cd '/tmp/project' && CLAUDE_CONFIG_DIR='/Users/demo/.claude-lab' claude")
        #expect(FreshSessionLaunch.line(provider: .codex, profileFolder: "/Users/demo/.codex-side", folder: "/tmp/project", home: home)
                == "cd '/tmp/project' && CODEX_HOME='/Users/demo/.codex-side' codex")
        // The default folder runs with no variable (`CLIEnvironment.make`).
        #expect(FreshSessionLaunch.line(provider: .claude, profileFolder: "/Users/demo/.claude", folder: "/tmp/project", home: home)
                == "cd '/tmp/project' && claude")
        // A quote or a space in a path stays one word.
        #expect(FreshSessionLaunch.line(provider: .codex, profileFolder: "/Users/demo/.codex-side", folder: "/tmp/it's a dir", home: home)
                == #"cd '/tmp/it'\''s a dir' && CODEX_HOME='/Users/demo/.codex-side' codex"#)
        // Never the hook-skip switches: it is the owner's own session (P703).
        #expect(!FreshSessionLaunch.line(provider: .claude, profileFolder: "/Users/demo/.claude-lab", folder: "/tmp/p", home: home)
            .contains("SKIP"))
    }

    @Test
    func theWindowOpensInTheSessionsOwnTerminal() {
        #expect(FreshSessionLaunch.host(bundleID: "com.googlecode.iterm2") == .iterm)
        #expect(FreshSessionLaunch.host(bundleID: "com.mitchellh.ghostty") == .ghostty)
        #expect(FreshSessionLaunch.host(bundleID: "com.apple.Terminal") == .terminal)
        // Any other host (an editor, Warp, the Codex app) or none: Terminal.
        #expect(FreshSessionLaunch.host(bundleID: "com.microsoft.VSCode") == .terminal)
        #expect(FreshSessionLaunch.host(bundleID: nil) == .terminal)
        let line = #"cd '/tmp/a "b"' && claude"#
        let terminal = FreshSessionLaunch.script(FreshSessionLaunch(host: .terminal, folder: "/tmp/a \"b\"", line: line))
        #expect(terminal.contains(#"tell application id "com.apple.Terminal""#))
        #expect(terminal.contains(#"do script "cd '/tmp/a \"b\"' && claude""#))
        let iterm = FreshSessionLaunch.script(FreshSessionLaunch(host: .iterm, folder: "/tmp/p", line: "cd '/tmp/p' && claude"))
        #expect(iterm.contains("create window with default profile") && iterm.contains(#"write text "cd '/tmp/p' && claude""#))
        let ghostty = FreshSessionLaunch.script(FreshSessionLaunch(host: .ghostty, folder: "/tmp/p", line: "cd '/tmp/p' && claude"))
        #expect(ghostty.contains(#"set initial working directory of config to "/tmp/p""#))
        #expect(ghostty.contains(#"set initial input of config to "cd '/tmp/p' && claude" & linefeed"#))
        #expect(ghostty.contains("new window with configuration config"))
        // A terminal that is running gets a new window of its own, never one of the owner's.
        #expect(!terminal.contains("window 1") && !iterm.contains("window 1"))
    }

    /// A terminal that is not running is opened by its path, never by its bundle id (P708): then the script, which on
    /// that cold start types into the window the terminal opened by itself, so one window shows, not two.
    @Test
    func aClosedTerminalOpensByItsPathAndShowsOneWindow() {
        final class Calls: @unchecked Sendable {
            var opened: [String] = []
            var scripts: [String] = []
        }
        let launch = FreshSessionLaunch(host: .terminal, folder: "/tmp/p", line: "cd '/tmp/p' && claude")
        func run(_ launch: FreshSessionLaunch, running: Bool, installed: Bool = true, opens: Bool = true) -> (Bool, Calls) {
            let calls = Calls()
            let opened = FreshSessionLaunch.run(
                launch,
                isAppRunning: { _ in running },
                appURL: { installed ? URL(fileURLWithPath: "/Applications/\($0).app") : nil },
                openPath: { path in
                    calls.opened.append(path)
                    if !opens { throw JumpRunnerError.openFailed([path]) }
                },
                appleScript: { script in
                    calls.scripts.append(script)
                    return "opened"
                })
            return (opened, calls)
        }
        // Running: the script alone, a new window.
        var (opened, calls) = run(launch, running: true)
        #expect(opened && calls.opened.isEmpty && calls.scripts == [FreshSessionLaunch.script(launch)])
        // Closed: its path first, then the cold script, which uses the window the start opened when there is one.
        (opened, calls) = run(launch, running: false)
        #expect(opened && calls.opened == ["/Applications/com.apple.Terminal.app"])
        #expect(calls.scripts == [FreshSessionLaunch.script(launch, cold: true)])
        let cold = FreshSessionLaunch.script(launch, cold: true)
        #expect(cold.contains("if (count of windows) > 0 then") && cold.contains(#"do script "cd '/tmp/p' && claude" in window 1"#))
        let iterm = FreshSessionLaunch(host: .iterm, folder: "/tmp/p", line: "cd '/tmp/p' && claude")
        (opened, calls) = run(iterm, running: false)
        #expect(opened && calls.opened == ["/Applications/com.googlecode.iterm2.app"])
        #expect(calls.scripts.first?.contains("set newWindow to window 1") == true)
        // Not installed, or the path did not open: no script, nothing launched by its id.
        (opened, calls) = run(launch, running: false, installed: false)
        #expect(!opened && calls.opened.isEmpty && calls.scripts.isEmpty)
        (opened, calls) = run(launch, running: false, opens: false)
        #expect(!opened && calls.scripts.isEmpty)
    }

    @Test
    func openingIsTheInjectedLaunchersOnlyAndEndsTheFailedTurn() async throws {
        let launched = F.Box<[FreshSessionLaunch]>([])
        let engine = SessionEngine.preview(clock: { Self.now }, fresh: { launch in
            launched.update { $0.append(launch) }
            return true
        })
        engine.loadPreviewEvents([F.started("s1", cwd: "/tmp/project", terminal: "Terminal"), F.prompt("s1")])
        engine.loadPreviewNote(event: "StopFailure", sessionID: "s1")
        engine.ingest(note: HookContextNote(event: "PreToolUse", sessionID: "s1", hostBundleID: "com.mitchellh.ghostty", source: "claude"))
        engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "rate_limit", timestamp: Self.now))])
        #expect(engine.needsYouCount == 1)
        let opened = await engine.openFresh(sessionID: "s1", provider: .claude, profileFolder: "/demo/.claude-lab")
        #expect(opened)
        // The session's own terminal from its note, its folder, the account's folder.
        #expect(launched.current == [FreshSessionLaunch(host: .ghostty, folder: "/tmp/project",
                                                        line: "cd '/tmp/project' && CLAUDE_CONFIG_DIR='/demo/.claude-lab' claude")])
        #expect(engine.needsYouCount == 0)
        // A session with no folder known opens nothing.
        engine.loadPreviewEvents([.sessionStarted(SessionStarted(sessionID: "s2", title: "Claude · x", tool: .claudeCode, origin: .live,
                                                                 initialPhase: .running, summary: "Started.", timestamp: Self.now))])
        #expect(await engine.openFresh(sessionID: "s2", provider: .claude, profileFolder: "/demo/.claude-lab") == false)
        #expect(launched.current.count == 1)
    }

    /// A headless engine with no launcher given opens nothing: no test can open a window.
    @Test
    func aHeadlessEngineOpensNothing() async {
        let engine = F.engine()
        Self.prompted(engine)
        #expect(await engine.openFresh(sessionID: "s1", provider: .claude, profileFolder: "/demo/.claude-lab") == false)
    }
}
