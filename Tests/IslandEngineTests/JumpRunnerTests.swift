import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

struct JumpRunnerTests {
    private static let terminalTarget = JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "claude",
                                                   terminalTTY: "/dev/ttys003")

    private static func runner(appleScript: @escaping JumpRunner.AppleScript,
                               open: @escaping JumpRunner.Open = { _, _ in },
                               opened: OpenLog? = nil) -> JumpRunner {
        var runner = JumpRunner()
        runner.appURL = { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        runner.isAppRunning = { _ in true }
        runner.appleScript = appleScript
        runner.open = { arguments, timeout in
            opened?.append(arguments)
            try open(arguments, timeout)
        }
        runner.command = { _, _, _ in false }
        return runner
    }

    final class OpenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func append(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
        var all: [[String]] { lock.withLock { calls } }
    }

    @Test
    func anExactTerminalTabIsMatched() {
        let outcome = Self.runner(appleScript: { _, _ in "matched" }).run(sessionID: "s1", target: Self.terminalTarget)
        #expect(outcome.result == .matched)
        #expect(outcome.failure == nil)
        #expect(outcome.steps.count == 1)
        #expect(outcome.steps.first?.kind == .appleScript)
        #expect(outcome.steps.first?.detail == "osascript: tell application \"Terminal\"")
    }

    @Test
    func automationDeniedFallsBackToBringingTheHostForward() {
        let log = OpenLog()
        let denied = JumpRunnerError.appleScriptFailed("execution error: Not authorized to send Apple events to Terminal. (-1743)")
        let outcome = Self.runner(appleScript: { _, _ in throw denied }, opened: log).run(sessionID: "s1", target: Self.terminalTarget)
        #expect(outcome.result == .fallbackActivated)
        #expect(outcome.failure == .automationDenied)
        #expect(log.all == [["-b", "com.apple.Terminal"]])
        #expect(outcome.steps.map(\.succeeded) == [false, true])
    }

    @Test
    func aTimeoutIsNamedEvenWhenNothingCanBeBroughtForward() {
        let outcome = Self.runner(appleScript: { _, _ in throw JumpRunnerError.timedOut("osascript") },
                                  open: { arguments, _ in throw JumpRunnerError.openFailed(arguments) })
            .run(sessionID: "s1", target: Self.terminalTarget)
        #expect(outcome.result == .failed)
        #expect(outcome.failure == .timedOut)
    }

    @Test
    func aSessionWithoutATargetSaysSo() {
        let outcome = Self.runner(appleScript: { _, _ in "" }).run(sessionID: "s1", target: nil)
        #expect(outcome.result == .noTarget)
        #expect(outcome.steps.isEmpty)
    }

    @Test
    func unmatchedTabStillActivatesTheHost() {
        let log = OpenLog()
        let outcome = Self.runner(appleScript: { _, _ in "" }, opened: log).run(sessionID: "s1", target: Self.terminalTarget)
        #expect(outcome.result == .activatedOnly)
        #expect(log.all == [["-b", "com.apple.Terminal"]])
    }

    @Test
    func aHungJumpServiceEndsAtTheOverallDeadlineWithTheFallback() {
        let log = OpenLog()
        var runner = Self.runner(appleScript: { _, _ in
            Thread.sleep(forTimeInterval: 10)  // like a hung `tmux`, which upstream runs without a deadline
            return ""
        }, opened: log)
        runner.overallTimeout = 0.3
        let started = Date()
        let outcome = runner.run(sessionID: "s1", target: Self.terminalTarget)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(outcome.result == .fallbackActivated)
        #expect(outcome.failure == .timedOut)
        #expect(outcome.steps.map(\.detail) == ["jump service", "open -b com.apple.Terminal"])
        #expect(log.all == [["-b", "com.apple.Terminal"]])
    }

    @Test
    func timedProcessStopsASlowCommand() throws {
        let started = Date()
        let output = try TimedProcess.run("/bin/sleep", ["5"], timeout: 0.2)
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test
    func hostNamesMapToBundleIdentifiers() {
        #expect(JumpHosts.bundleIdentifier(forTerminalApp: "iTerm") == "com.googlecode.iterm2")
        #expect(JumpHosts.bundleIdentifier(forTerminalApp: "Ghostty") == "com.mitchellh.ghostty")
        #expect(JumpHosts.bundleIdentifier(forTerminalApp: "VS Code") == "com.microsoft.VSCode")
        #expect(JumpHosts.bundleIdentifier(forTerminalApp: "Trae CN") == "cn.trae.app")
        #expect(JumpHosts.bundleIdentifier(forTerminalApp: "unknown") == nil)
        // A running Zed Preview is the one brought forward, not an idle Zed.
        let zed = JumpHosts.fallbackBundleIdentifier(forTerminalApp: "Zed", isRunning: { $0 == "dev.zed.Zed-Preview" },
                                                     appURL: { _ in nil })
        #expect(zed == "dev.zed.Zed-Preview")
    }

    /// Reads upstream's host table from Vendor/ and checks every display name and alias has a fallback app.
    @Test
    func hostsCoverUpstreamsKnownApps() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/open-vibe-island/Sources/OpenIslandApp/TerminalJumpService.swift"), encoding: .utf8)
        let descriptor = #/displayName: "([^"]+)",\s*bundleIdentifier: "([^"]+)",\s*aliases: \[([^\]]*)\](?:,\s*alternateBundleIdentifiers: \[([^\]]*)\])?/#
        let quoted = #/"([^"]+)"/#
        let found = source.matches(of: descriptor)
        #expect(found.count >= 26)
        for match in found {
            let bundles = [String(match.output.2)] + (match.output.4.map { $0.matches(of: quoted).map { String($0.output.1) } } ?? [])
            let names = [String(match.output.1)] + match.output.3.matches(of: quoted).map { String($0.output.1) }
            for name in names {
                let mapped = JumpHosts.bundleIdentifiers(forTerminalApp: name)
                #expect(!mapped.isEmpty && Set(mapped).isSubset(of: Set(bundles)), "\(name) → \(mapped)")
            }
        }
    }
}
