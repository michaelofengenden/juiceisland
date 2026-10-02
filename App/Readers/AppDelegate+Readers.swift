import AppKit

extension AppDelegate {
    /// How long a quit waits for the Codex app-servers to go.
    static let quitDeadline: TimeInterval = 3

    /// Quitting while the release build reads: the readers stop at once and the Codex app-servers are shut down before
    /// the app goes, raced against a 3 s deadline so a CLI that stopped answering never holds the quit (as standalone
    /// Juice). The answer comes through the main run loop (`TerminationReply`), never a main actor job: a quit asked
    /// from inside one waited forever for an answer sent from a `Task`, so the update's restart never came (P98). Any
    /// other usage source, or nothing to shut down, quits at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown = env.liveUsage?.stopForQuit() else { return .terminateNow }
        TerminationReply().start(deadline: Self.quitDeadline, work: shutdown)
        return .terminateLater
    }
}
