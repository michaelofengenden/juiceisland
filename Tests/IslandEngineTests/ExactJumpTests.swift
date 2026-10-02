import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Exact jumps with the context notes' handles (spec §3.8, P17, P43, P46, P47, P49, P50) and the verified-jump
/// failures, over fake runners: no osascript, no `open`, no tmux and no process lookup ever runs.
struct ExactJumpTests {
    /// Every call a jump made, in order.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var scripts: [String] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        func addScript(_ script: String) { lock.withLock { scripts.append(script) } }
        var all: [String] { lock.withLock { entries } }
        var allScripts: [String] { lock.withLock { scripts } }
    }

    /// A runner whose every seam is a fake. `script` answers osascript by what the script is for; `tmux` answers
    /// tmux by its subcommand. Every app is installed; `running` says which run; the frontmost app is `frontmost`.
    static func runner(calls: Calls, running: Set<String>, frontmost: String? = nil,
                       script: @escaping @Sendable (String) throws -> String = { _ in "" },
                       tmux: @escaping @Sendable ([String]) throws -> String = { _ in "" },
                       executables: Set<String> = ["/opt/homebrew/bin/tmux"],
                       appForPID: @escaping @Sendable (Int32) -> String? = { _ in nil }) -> JumpRunner {
        var runner = JumpRunner()
        runner.appURL = { URL(fileURLWithPath: "/Applications/\($0).app") }
        runner.isAppRunning = { running.contains($0) }
        runner.appleScript = { source, _ in
            calls.addScript(source)
            calls.add("osascript")
            return try script(source)
        }
        runner.open = { arguments, _ in calls.add("open " + arguments.joined(separator: " ")) }
        runner.command = { executable, arguments, _ in
            calls.add(([executable] + arguments).joined(separator: " "))
            return false
        }
        runner.capture = { executable, arguments, timeout in
            calls.add("capture \(URL(fileURLWithPath: executable).lastPathComponent) " + arguments.joined(separator: " "))
            #expect(timeout == 3)
            return try tmux(Array(arguments.dropFirst(2)))
        }
        runner.isExecutable = { executables.contains($0) }
        runner.frontmostBundleID = { frontmost }
        runner.appForPID = appForPID
        runner.pause = { _ in }
        return runner
    }

    static let iterm = "com.googlecode.iterm2"
    static let terminal = "com.apple.Terminal"
    static let ghostty = "com.mitchellh.ghostty"

    static func target(_ app: String, tty: String? = nil, id: String? = nil, cwd: String? = nil, thread: String? = nil) -> JumpTarget {
        JumpTarget(terminalApp: app, workspaceName: "project", paneTitle: "claude", workingDirectory: cwd,
                   terminalSessionID: id, terminalTTY: tty, codexThreadID: thread)
    }

    // MARK: iTerm (P17)

    /// With ITERM_SESSION_ID=w0t1p2:ABC while XYZ is focused, the jump targets ABC; the tty is tried first, so an id
    /// pointing to split A and a tty pointing to split B picks B.
    @Test
    func itermJumpsBySessionTTYThenItsOwnID() throws {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.iterm], frontmost: Self.iterm, script: { source in
            if source.contains("repeat with passIndex") { return "matched\u{1f}ABC" }
            return "ABC\u{1f}/dev/ttys007"  // the focus probe
        })
        let outcome = runner.run(sessionID: "s1", target: Self.target("iTerm", tty: "/dev/ttys007", id: "ABC"),
                                 context: JumpContext(hostBundleID: Self.iterm, itermSessionID: "ABC"))
        #expect(outcome.result == .matched)
        let jump = try #require(calls.allScripts.first)
        #expect(jump.hasPrefix(#"tell application id "com.googlecode.iterm2""#))
        let ttyPass = try #require(jump.range(of: #"if passIndex is 1 and "/dev/ttys007" is not """#))
        let idPass = try #require(jump.range(of: #"if passIndex is 2 and "ABC" is not """#))
        #expect(ttyPass.lowerBound < idPass.lowerBound)
        // Selected before the app is activated (P44's order), and un-minimized (P45).
        let select = try #require(jump.range(of: "select aSession"))
        let activate = try #require(jump.range(of: "activate", range: select.upperBound..<jump.endIndex))
        #expect(select.lowerBound < activate.lowerBound)
        #expect(jump.contains("set miniaturized of aWindow to false"))
        #expect(outcome.steps.first?.detail == #"osascript: tell application id "com.googlecode.iterm2""#)
    }

    /// P43: a jump whose focus check finds another session never reports matched; it is tried once more.
    @Test
    func aMatchWithAnotherTabFocusedIsNotMatched() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.iterm], frontmost: Self.iterm, script: { source in
            source.contains("repeat with passIndex") ? "matched\u{1f}ABC" : "XYZ\u{1f}/dev/ttys001"
        })
        let outcome = runner.run(sessionID: "s1", target: Self.target("iTerm", id: "ABC"),
                                 context: JumpContext(hostBundleID: Self.iterm, itermSessionID: "ABC"))
        #expect(outcome.result == .activatedOnly)
        #expect(outcome.failure == .wrongTab)
        #expect(calls.allScripts.filter { $0.contains("repeat with passIndex") }.count == 2)
    }

    /// P43: the host must come forward too.
    @Test
    func aMatchWhoseHostNeverCameForwardIsNotMatched() {
        let runner = Self.runner(calls: Calls(), running: [Self.terminal], frontmost: "com.apple.finder", script: { _ in "matched\u{1f}/dev/ttys003" })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal", tty: "/dev/ttys003"),
                                 context: JumpContext(hostBundleID: Self.terminal))
        #expect(outcome.result == .activatedOnly)
        #expect(outcome.failure == .wrongTab)
    }

    // MARK: Terminal

    @Test
    func terminalJumpsByTheAgentsTTY() throws {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.terminal], frontmost: Self.terminal, script: { source in
            source.contains("repeat with aTab") ? "matched\u{1f}/dev/ttys044" : "/dev/ttys044"
        })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal", tty: "/dev/ttys044"),
                                 context: JumpContext(hostBundleID: Self.terminal, agentPID: 900))
        #expect(outcome.result == .matched)
        let jump = try #require(calls.allScripts.first)
        #expect(jump.contains(#"(tty of aTab as text) is "/dev/ttys044""#))
        #expect(jump.hasPrefix(#"tell application id "com.apple.Terminal""#))
        #expect(calls.all == ["osascript", "osascript"])
    }

    @Test
    func aTabThatIsGoneBringsTheHostForwardOnly() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.terminal], frontmost: Self.terminal)
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal", tty: "/dev/ttys044"),
                                 context: JumpContext(hostBundleID: Self.terminal))
        #expect(outcome.result == .activatedOnly)
        #expect(outcome.failure == nil)
        #expect(calls.all == ["osascript", "open -b com.apple.Terminal"])
    }

    // MARK: Ghostty (P46)

    /// Three terminals share a cwd and a title: never matched, Ghostty only comes forward.
    @Test
    func ghosttyNeverPicksOneOfSeveralMatches() throws {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.ghostty], frontmost: Self.ghostty, script: { _ in "ambiguous" })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Ghostty", cwd: "/tmp/project"),
                                 context: JumpContext(hostBundleID: Self.ghostty))
        #expect(outcome.result == .activatedOnly)
        #expect(outcome.failure == .ambiguous)
        let jump = try #require(calls.allScripts.first)
        #expect(jump.contains("if (count of idMatches) is 1 then"))
        #expect(jump.contains("(count of idMatches) is 0 and (count of directoryMatches) is 1"))
        #expect(jump.contains(#"return "ambiguous""#))
    }

    @Test
    func ghosttyMatchesAUniqueTerminalAndChecksItHasFocus() {
        let runner = Self.runner(calls: Calls(), running: [Self.ghostty], frontmost: Self.ghostty, script: { source in
            source.contains("idMatches") ? "matched\u{1f}T-1" : "T-1"
        })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Ghostty", id: "T-1"), context: JumpContext(hostBundleID: Self.ghostty))
        #expect(outcome.result == .matched)
    }

    // MARK: tmux (P47)

    /// A jump to a pane of session s2 switches client B, which is on s2, never client A, which was active last.
    @Test
    func tmuxSwitchesTheClientAlreadyOnTheSession() throws {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [], frontmost: Self.terminal, script: { source in
            source.contains("repeat with aTab") ? "matched\u{1f}/dev/ttys020" : "/dev/ttys020"
        }, tmux: { arguments in
            switch arguments.first {
            case "display-message": return "s2"
            case "list-clients": return "/dev/ttys010\ts1\t900\t71\n/dev/ttys020\ts2\t100\t72"
            default: return ""
            }
        }, appForPID: { $0 == 72 ? Self.terminal : Self.iterm })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal"),
                                 context: JumpContext(hostBundleID: Self.iterm, tmuxSocketPath: "/tmp/tmux-501/default", tmuxPane: "%3"))
        #expect(outcome.result == .matched)
        let tmuxCalls = calls.all.filter { $0.hasPrefix("capture") }
        #expect(tmuxCalls == [
            "capture tmux -S /tmp/tmux-501/default display-message -p -t %3 #{session_name}",
            "capture tmux -S /tmp/tmux-501/default list-clients -F #{client_tty}\t#{client_session}\t#{client_activity}\t#{client_pid}",
            "capture tmux -S /tmp/tmux-501/default select-window -t %3",
            "capture tmux -S /tmp/tmux-501/default select-pane -t %3",
        ])
        #expect(!calls.all.contains { $0.contains("switch-client") })
        #expect(try #require(calls.allScripts.first).contains(#"(tty of aTab as text) is "/dev/ttys020""#))
    }

    @Test
    func tmuxWithNoClientOnTheSessionSwitchesTheLatestClient() {
        #expect(ExactJump.pickClient(ExactJump.parseClients("/dev/ttys010\ts1\t100\t1\n/dev/ttys011\ts3\t900\t2"), session: "s2")?.tty
                == "/dev/ttys011")
        #expect(ExactJump.pickClient([], session: "s2") == nil)
    }

    /// No client at all: "detached", no success, nothing brought forward.
    @Test
    func aDetachedTmuxSessionIsNamed() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.terminal], tmux: { $0.first == "display-message" ? "s2" : "" })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal"),
                                 context: JumpContext(tmuxSocketPath: "/tmp/tmux-501/default", tmuxPane: "%3"))
        #expect(outcome.result == .failed)
        #expect(outcome.failure == .detached)
        #expect(!calls.all.contains { $0.hasPrefix("open") })
    }

    @Test
    func tmuxMissingIsNamedAndTheHostComesForward() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.terminal], executables: [])
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal"),
                                 context: JumpContext(tmuxSocketPath: "/tmp/tmux-501/default", tmuxPane: "%3"))
        #expect(outcome.result == .fallbackActivated)
        #expect(outcome.failure == .cliMissing)
        #expect(outcome.tool == "tmux")
        #expect(calls.all == ["open -b com.apple.Terminal"])
    }

    /// tmux answers for itself, so its jump skips the host check; a terminal that is not running is then never
    /// brought forward (that would launch it), neither after the pane is selected nor as the fallback.
    @Test
    func aTmuxJumpNeverLaunchesATerminal() {
        let calls = Calls()
        let selected = Self.runner(calls: calls, running: [], tmux: { arguments in
            switch arguments.first {
            case "display-message": return "s2"
            case "list-clients": return "/dev/ttys020\ts2\t100\t72"
            default: return ""
            }
        })
        let outcome = selected.run(sessionID: "s1", target: Self.target("iTerm"),
                                   context: JumpContext(tmuxSocketPath: "/tmp/tmux-501/default", tmuxPane: "%3"))
        #expect(outcome.result == .activatedOnly)
        #expect(!calls.all.contains { $0.hasPrefix("open") })

        let failing = Self.runner(calls: calls, running: [], tmux: { _ in throw JumpRunnerError.commandFailed("tmux display-message") })
        let failed = failing.run(sessionID: "s1", target: Self.target("iTerm"),
                                 context: JumpContext(tmuxSocketPath: "/tmp/tmux-501/default", tmuxPane: "%3"))
        #expect(failed.result == .failed)
        #expect(!calls.all.contains { $0.hasPrefix("open") })
    }

    /// Past the overall deadline the worker starts no further step: the retry after a wrong-tab check never runs
    /// behind the fallback's back.
    @Test
    func nothingRunsAfterTheOverallDeadline() {
        let calls = Calls()
        var runner = Self.runner(calls: calls, running: [Self.terminal], frontmost: "com.apple.finder", script: { _ in
            Thread.sleep(forTimeInterval: 0.4)
            return "matched\u{1f}/dev/ttys003"
        })
        runner.overallTimeout = 0.2
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal", tty: "/dev/ttys003"),
                                 context: JumpContext(hostBundleID: Self.terminal))
        #expect(outcome.failure == .timedOut)
        #expect(outcome.result == .fallbackActivated)
        Thread.sleep(forTimeInterval: 0.8)
        #expect(calls.allScripts.count == 1)
        #expect(calls.all == ["osascript", "open -b com.apple.Terminal"])
    }

    /// Deadlines: a hung tmux ends at the overall deadline, named timedOut, with the fallback.
    @Test
    func aHungTmuxEndsAtTheOverallDeadline() {
        var runner = Self.runner(calls: Calls(), running: [Self.terminal], tmux: { _ in
            Thread.sleep(forTimeInterval: 5)
            return ""
        })
        runner.overallTimeout = 0.3
        let started = Date()
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal"),
                                 context: JumpContext(tmuxSocketPath: "/tmp/tmux-501/default", tmuxPane: "%3"))
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(outcome.failure == .timedOut)
        #expect(outcome.result == .fallbackActivated)
        #expect(outcome.steps.map(\.detail).contains("jump service"))
    }

    @Test
    func stepAndOverallDeadlinesAreThreeAndSixSeconds() {
        let runner = JumpRunner()
        #expect(runner.stepTimeout == 3)
        #expect(runner.overallTimeout == 6)
    }

    // MARK: Verified hosts (P49)

    /// The session's host is not running: named, and nothing is launched.
    @Test
    func aHostThatIsNotRunningIsNamedAndNotLaunched() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [])
        let outcome = runner.run(sessionID: "s1", target: Self.target("iTerm", id: "ABC"))
        #expect(outcome.result == .failed)
        #expect(outcome.failure == .hostNotRunning)
        #expect(calls.all.isEmpty)
        let noted = runner.run(sessionID: "s1", target: Self.target("Terminal", tty: "/dev/ttys001"), context: JumpContext(hostBundleID: Self.iterm))
        #expect(noted.failure == .hostNotRunning)
        #expect(calls.all.isEmpty)
    }

    /// Host "Hyper" with iTerm installed and running: unknownHost, and iTerm never comes forward.
    @Test
    func anUnknownHostNeverBringsUpAnotherTerminal() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.iterm])
        let outcome = runner.run(sessionID: "s1", target: Self.target("Hyper"))
        #expect(outcome.result == .failed)
        #expect(outcome.failure == .unknownHost)
        #expect(calls.all.isEmpty)
        // With the note naming Hyper's own app, that app, and only it, comes forward.
        let hyper = "co.zeit.hyper"
        let noted = Self.runner(calls: calls, running: [Self.iterm, hyper])
            .run(sessionID: "s1", target: Self.target("Hyper"), context: JumpContext(hostBundleID: hyper))
        #expect(noted.result == .fallbackActivated)
        #expect(noted.failure == .unknownHost)
        #expect(calls.all == ["open -b co.zeit.hyper"])
    }

    /// The fallback brings forward the app that started the agent, not the first build found.
    @Test
    func theFallbackIsTheNotedHost() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.terminal], script: { _ in
            throw JumpRunnerError.appleScriptFailed("Not authorized to send Apple events to Terminal. (-1743)")
        })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal", tty: "/dev/ttys003"),
                                 context: JumpContext(hostBundleID: Self.terminal))
        #expect(outcome.result == .fallbackActivated)
        #expect(outcome.failure == .automationDenied)
        #expect(calls.all == ["osascript", "open -b com.apple.Terminal"])
    }

    // MARK: Codex app (P50)

    @Test
    func aCodexThreadLinkThatDidNotBringTheAppForwardIsNamed() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [], frontmost: Self.terminal)
        let outcome = runner.run(sessionID: "s1", target: Self.target("Codex.app", thread: "T-9"))
        #expect(outcome.result == .activatedOnly)
        #expect(outcome.failure == .threadLinkFailed)
        #expect(calls.all == ["open codex://threads/T-9", "open -b com.openai.codex"])
        let forward = Self.runner(calls: Calls(), running: [], frontmost: "com.openai.codex")
            .run(sessionID: "s1", target: Self.target("Codex.app", thread: "T-9"))
        #expect(forward.result == .matched)
    }

    // MARK: CLI missing (P48)

    /// VS Code's CLI is not where a GUI app can find it: named, and VS Code comes forward.
    @Test
    func aMissingEditorCLIIsNamed() {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: ["com.microsoft.VSCode"], executables: [])
        let outcome = runner.run(sessionID: "s1", target: Self.target("VS Code", cwd: NSTemporaryDirectory()))
        #expect(outcome.result == .activatedOnly)
        #expect(outcome.failure == .cliMissing)
        #expect(outcome.tool == "code")
        #expect(calls.all == ["open -b com.microsoft.VSCode"])
    }

    /// The CLI inside the editor's bundle is used when no install folder has it.
    @Test
    func theEditorsBundledCLIIsFound() {
        let bundled = "/Applications/com.microsoft.VSCode.app/Contents/Resources/app/bin/code"
        #expect(JumpTools.resolve("code", appURL: { URL(fileURLWithPath: "/Applications/\($0).app") }, isExecutable: { $0 == bundled }) == bundled)
        #expect(JumpTools.resolve("code", appURL: { _ in nil }, isExecutable: { $0 == "/usr/local/bin/code" }) == "/usr/local/bin/code")
        #expect(JumpTools.resolve("nope", appURL: { _ in nil }, isExecutable: { _ in false }) == nil)
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: ["com.microsoft.VSCode"], executables: [bundled])
        _ = runner.run(sessionID: "s1", target: Self.target("VS Code", cwd: NSTemporaryDirectory()))
        #expect(calls.all.first?.hasPrefix(bundled + " -r ") == true)
    }

    // MARK: Without notes

    /// A session with no note keeps upstream's jump unchanged.
    @Test
    func withoutANoteUpstreamsJumpRuns() throws {
        let calls = Calls()
        let runner = Self.runner(calls: calls, running: [Self.terminal], script: { _ in "matched" })
        let outcome = runner.run(sessionID: "s1", target: Self.target("Terminal", tty: "/dev/ttys003"))
        #expect(outcome.result == .matched)
        #expect(try #require(calls.allScripts.first).hasPrefix(#"tell application "Terminal""#))
    }
}
