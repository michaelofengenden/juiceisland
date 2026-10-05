import Foundation
import JuiceCore
import OpenIslandCore

/// A new terminal window running the agent's CLI under another account, in the folder a session stopped in on a limit
/// (P703). Opened only by the owner's click ("Open in <account>"), never by itself: a fresh session, which never resumes
/// or copies the conversation, and never carries the island's hook-skip switches (it is the owner's own session, which
/// the island should see), so `CLIEnvironment.make` is not what it runs under.
public struct FreshSessionLaunch: Equatable, Sendable {
    /// The terminal the window opens in: the session's own when it is one of these, else Terminal.
    public enum Host: String, Equatable, Sendable {
        case terminal, iterm, ghostty

        public var name: String {
            switch self {
            case .terminal: "Terminal"
            case .iterm: "iTerm"
            case .ghostty: "Ghostty"
            }
        }

        var bundleID: String {
            switch self {
            case .terminal: ExactJump.terminalBundleID
            case .iterm: ExactJump.itermBundleID
            case .ghostty: ExactJump.ghosttyBundleID
            }
        }
    }

    public var host: Host
    /// The session's working folder.
    public var folder: String
    /// The shell line typed into the new window: into the folder, then the CLI with the account's folder variable.
    public var line: String

    public init(host: Host, folder: String, line: String) {
        self.host = host
        self.folder = folder
        self.line = line
    }

    /// `cd '<folder>' && CLAUDE_CONFIG_DIR='<profile>' claude` (or `CODEX_HOME=… codex`); the provider's default folder
    /// runs with no variable, as the CLI finds its login differently once the variable is set at all
    /// (`CLIEnvironment.make`). Each path in single quotes, so a space or a quote in it stays one argument.
    public static func line(provider: Provider, profileFolder: String, folder: String, home: String = NSHomeDirectory()) -> String {
        let profile = (profileFolder as NSString).expandingTildeInPath
        let cli = provider == .claude ? "claude" : "codex"
        let run = CLIEnvironment.isDefaultFolder(profile, for: provider, home: home)
            ? cli : "\(provider.folderEnvironmentKey)=\(quoted(profile)) \(cli)"
        return "cd \(quoted((folder as NSString).expandingTildeInPath)) && \(run)"
    }

    /// A POSIX shell word: single quotes, each quote inside closed, escaped and reopened.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The host for a session's terminal (its context note's bundle id, else its jump target's app name).
    static func host(bundleID: String?) -> Host {
        switch bundleID {
        case ExactJump.itermBundleID: .iterm
        case ExactJump.ghosttyBundleID: .ghostty
        default: .terminal
        }
    }

    /// The script that opens one new window running `line`, addressed by bundle id (P49), and brings the app forward.
    /// Terminal's `do script` and iTerm's `write text` type the line into the window's own shell; Ghostty's surface
    /// configuration starts its window in the folder and sends the line as its first input. `cold`: the app was opened
    /// just now, by its path (P708), so Terminal and iTerm type into the window they opened by themselves when there is
    /// one, never into a window of the owner's (a running app always gets a new window). Ghostty has no such door: a
    /// cold start can show its own first window beside the new one.
    static func script(_ launch: FreshSessionLaunch, cold: Bool = false) -> String {
        let line = ExactJump.escape(launch.line)
        switch launch.host {
        case .terminal:
            let run = cold ? """
                    if (count of windows) > 0 then
                        do script "\(line)" in window 1
                    else
                        do script "\(line)"
                    end if
                """ : """
                    do script "\(line)"
                """
            return """
            tell application id "\(ExactJump.terminalBundleID)"
            \(run)
                activate
            end tell
            return "opened"
            """
        case .iterm:
            let window = cold ? """
                    if (count of windows) > 0 then
                        set newWindow to window 1
                    else
                        set newWindow to (create window with default profile)
                    end if
                """ : """
                    set newWindow to (create window with default profile)
                """
            return """
            tell application id "\(ExactJump.itermBundleID)"
            \(window)
                tell current session of newWindow to write text "\(line)"
                activate
            end tell
            return "opened"
            """
        case .ghostty:
            return """
            tell application id "\(ExactJump.ghosttyBundleID)"
                set config to new surface configuration
                set initial working directory of config to "\(ExactJump.escape(launch.folder))"
                set initial input of config to "\(line)" & linefeed
                new window with configuration config
                activate
            end tell
            return "opened"
            """
        }
    }

    /// Opens the window; true when the app said it did. A terminal that is not running is opened by its path first,
    /// never launched by its bundle id (P708, as a jump never launches its host); one not installed opens nothing.
    static func run(_ launch: FreshSessionLaunch, isAppRunning: (String) -> Bool, appURL: (String) -> URL?,
                    openPath: (String) throws -> Void, appleScript: (String) throws -> String) -> Bool {
        let cold = !isAppRunning(launch.host.bundleID)
        if cold {
            guard let app = appURL(launch.host.bundleID), (try? openPath(app.path)) != nil else { return false }
        }
        return (try? appleScript(script(launch, cold: cold))) == "opened"
    }

    /// The live run. Waits up to 30 s for the script: a first use may wait on the owner's Automation prompt.
    static let live: @Sendable (FreshSessionLaunch) -> Bool = { launch in
        let runner = JumpRunner()
        return run(launch, isAppRunning: runner.isAppRunning, appURL: runner.appURL,
                   openPath: { try JumpRunner.openCommand([$0], 10) },
                   appleScript: { try JumpRunner.osascript($0, 30) })
    }
}

extension FreshSessionLaunch {
    /// The first run's Start (P960): a new window in the owner's usual terminal, in `folder` (the latest session's) while
    /// it is still a folder, else in the home folder, running the agent's own command as the owner would type it (no
    /// account variable, no skip switch: it is the owner's session, which the island should see). Opened only by that
    /// click.
    public static func firstSession(command: String, host: Host, folder: String? = nil, home: String = NSHomeDirectory(),
                                    isFolder: (String) -> Bool = FreshSessionLaunch.isFolder) -> FreshSessionLaunch {
        let start = folder.flatMap { !$0.isEmpty && isFolder($0) ? $0 : nil } ?? home
        return FreshSessionLaunch(host: host, folder: start, line: command)
    }

    /// A folder there now (a link to one counts).
    public static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    /// The terminal the owner most likely uses: one running now (Ghostty, then iTerm, then Terminal), else an installed
    /// Ghostty or iTerm, else Terminal. Asks only whether each app runs or is installed.
    public static func usualHost(isRunning: (String) -> Bool, isInstalled: (String) -> Bool) -> Host {
        let order: [Host] = [.ghostty, .iterm, .terminal]
        if let running = order.first(where: { isRunning($0.bundleID) }) { return running }
        return order.first { $0 != .terminal && isInstalled($0.bundleID) } ?? .terminal
    }

    /// This Mac's usual terminal (`usualHost`).
    public static func liveUsualHost() -> Host {
        let runner = JumpRunner()
        return usualHost(isRunning: runner.isAppRunning, isInstalled: { runner.appURL($0) != nil })
    }

    /// Opens `launch` on the owner's click, off the main thread (the first use waits on macOS's Automation prompt). Only
    /// the app calls it; tests and renders inject their own opener.
    public static func openLive(_ launch: FreshSessionLaunch) async -> Bool {
        await Task.detached(priority: .userInitiated) { live(launch) }.value
    }
}

extension SessionEngine {
    /// What "Open in <account>" would open for the session (P703): its own terminal app when it is Terminal, iTerm or
    /// Ghostty (a tmux pane's host included), else Terminal; nil when its folder is not known.
    public func freshLaunch(sessionID: String, provider: Provider, profileFolder: String) -> FreshSessionLaunch? {
        // An SSH host's session runs there: its folder is the host's, never one to open on this Mac (P745).
        guard let session = state.session(id: sessionID), remoteSessions.entry(for: sessionID) == nil,
              let folder = ExactJump.nonEmpty(session.jumpTarget?.workingDirectory) else { return nil }
        let bundleID = hookNotes.contexts[sessionID]?.hostBundleID
            ?? session.jumpTarget.flatMap { JumpHosts.bundleIdentifier(forTerminalApp: $0.terminalApp) }
        return FreshSessionLaunch(host: FreshSessionLaunch.host(bundleID: bundleID), folder: folder,
                                  line: FreshSessionLaunch.line(provider: provider, profileFolder: profileFolder, folder: folder))
    }

    /// Opens it, off the main thread. The app's own engine runs the script; a headless one (tests, the demo) only an
    /// injected launcher, so nothing here can open a window or type into a terminal. Once it opened, the failed turn no
    /// longer needs the owner (they went on elsewhere); its row still says why it stopped.
    public func openFresh(sessionID: String, provider: Provider, profileFolder: String) async -> Bool {
        guard let launch = freshLaunch(sessionID: sessionID, provider: provider, profileFolder: profileFolder),
              let launcher = dependencies.openFresh ?? (configuration.startBridge ? FreshSessionLaunch.live : nil) else { return false }
        let opened = await ReplySender.run { launcher(launch) }
        if opened { clearTurnFailure(sessionID) }
        return opened
    }
}
