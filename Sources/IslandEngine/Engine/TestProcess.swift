import Foundation

/// Whether this process is a test run (xctest or swift-testing). The engine's live commands never run in one, whatever
/// its engine's kind: Claude Code's background family (`ClaudeLive`, P1475), the hand-over's CLI runs, opens and app
/// lookups (`HandoffRun`, P1510), and the link to Codex's shared daemon (`CodexDaemonLink`, P1496). Wiring rigs make an
/// engine of the app's kind (`startBridge`) whose other seams are stand-ins; none of them may reach a real CLI, app,
/// link or socket through a seam they did not stand in for. One check for all three (P1531).
enum TestProcess {
    static let isRunning: Bool = {
        let process = ProcessInfo.processInfo
        return process.processName == "xctest" || process.processName.hasPrefix("swiftpm-testing")
            || process.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }()
}
