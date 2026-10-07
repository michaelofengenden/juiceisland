import AppKit
import Foundation
import IslandHookNotes
import JuiceCore

/// The agent's own app a session can go on in (wave 8, P1510 to P1529): Open in Claude, Open in Codex, Open in <App>.
/// Claude and Codex continue the same conversation by its id; the rest list the CLI's sessions from the store they share
/// with it, and the owner picks the session there (no link names one).
public enum HandoffApp: String, Equatable, Sendable, CaseIterable {
    /// Claude's desktop app (`com.anthropic.claudefordesktop`): `/desktop` in the CLI, or `claude --desktop --resume <id>`.
    case claude
    /// The Codex app, now installed as ChatGPT.app (`com.openai.codex`): `codex://threads/<id>` (P660).
    case codex
    /// VS Code: Copilot CLI's sessions in its Chat view, Kilo's in its extension's history.
    case vscode
    /// Kimi Code Desktop: the same session list as the CLI.
    case kimi
    /// OpenCode Desktop: the same database as the CLI.
    case opencode

    /// The name the card and the menu say: "Open in Claude".
    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .vscode: "VS Code"
        case .kimi: "Kimi Code"
        case .opencode: "OpenCode"
        }
    }

    /// It goes on with the same conversation by its id; the others show it in their list, where the owner picks it.
    public var continuesByID: Bool { self == .claude || self == .codex }

    /// The app's bundle ids, the likeliest first: only to find where it is installed (it is opened by its path, P708).
    var bundleIDs: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: [ExactJump.codexBundleID]
        case .vscode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        // Kimi Code Desktop publishes none: it is found by its name.
        case .kimi: []
        case .opencode: ["ai.opencode.desktop"]
        }
    }

    /// The bundle names to look for in /Applications and ~/Applications when no bundle id finds it.
    var appNames: [String] {
        switch self {
        case .claude: ["Claude.app"]
        case .codex: ["ChatGPT.app", "Codex.app"]
        case .vscode: ["Visual Studio Code.app"]
        case .kimi: ["Kimi Code.app", "Kimi Code Desktop.app"]
        case .opencode: ["OpenCode.app"]
        }
    }

    /// What is typed at the CLI's prompt, on the owner's click, to hand the session over: Claude Code's `/desktop` saves
    /// the session, opens it in Claude and exits the CLI; Codex's `/quit` and the others' `/exit` end the CLI, so no
    /// terminal copy is left when the app takes the session.
    var tabCommand: String {
        switch self {
        case .claude: "/desktop"
        case .codex: "/quit"
        case .vscode, .kimi, .opencode: "/exit"
        }
    }

    /// The app for a session's agent; nil for an agent with no app that shares its store (P1514).
    public static func of(_ agent: AgentKind) -> HandoffApp? {
        switch agent {
        case .claude: .claude
        case .codex: .codex
        case .copilot, .kilo: .vscode
        case .kimi: .kimi
        case .opencode: .opencode
        default: nil
        }
    }

    /// The provider whose profile folder decides whether the app can open it: Claude's and Codex's apps read the default
    /// folder only (P1512). nil: the others have no profile folder of Juice's.
    var provider: Provider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        default: nil
        }
    }
}

/// Where a session's hand-over to its app stands (`SessionHandoff`).
public enum HandoffState: Equatable, Sendable {
    /// A folded session whose turn runs: it goes when the turn ends ("Opens in Claude when this turn ends").
    case pending(HandoffApp)
    /// On its way: the CLI told to quit, the source being stopped, the app's command running.
    case opening(HandoffApp)
    /// The app has the conversation (Claude, Codex): the island sends it no reply, and Open in terminal asks first whether
    /// the app still holds it. `note`: why the last Open in terminal did not go ("Quit Claude first").
    case inApp(HandoffApp, note: String?)
    /// The app was opened; the owner picks the session in its list.
    case pick(HandoffApp)
    /// It did not go, and why, in one line.
    case blocked(HandoffApp, String)

    public var app: HandoffApp {
        switch self {
        case let .pending(app), let .opening(app), let .inApp(app, _), let .pick(app), let .blocked(app, _): app
        }
    }

    /// The app may hold the conversation now, or will in a moment: no reply and no Continue from the island.
    public var holds: Bool {
        switch self {
        case .opening, .inApp, .pick: true
        case .pending, .blocked: false
        }
    }
}

/// What a session offers: "Open in Claude".
public struct HandoffOffer: Equatable, Sendable {
    public var app: HandoffApp
    public var title: String { "Open in \(app.name)" }

    public init(app: HandoffApp) {
        self.app = app
    }
}

/// The card's words (P1513 to P1519).
public enum HandoffWords {
    public static func pending(_ app: HandoffApp) -> String { "Opens in \(app.name) when this turn ends" }
    public static func opening(_ app: HandoffApp) -> String { "Opening in \(app.name)…" }
    public static func inApp(_ app: HandoffApp) -> String { "In \(app.name)" }
    public static func pick(_ app: HandoffApp) -> String { "Pick this session in \(app.name)" }
    public static let updateClaude = "Update Claude Code to open this in Claude"
    public static func quitApp(_ name: String) -> String { "Quit \(name) first" }
    public static let stillRuns = "Not opened · it still runs in a terminal"
    public static let stayedInTab = "Not opened · it stayed open in its tab"
    public static let notTyped = "Not opened · its tab took nothing"
    public static let tabInFront = "Not opened · its tab was in front"
    public static let working = "Not opened · it is working; try when this turn ends"
    public static let backgroundStayed = "Not opened · its background copy did not stop"
    public static let attached = "Not opened · close the window attached to it first"
    public static let claudeMissing = "Not opened · Claude Code not found"
    public static let noList = "Not opened · Claude Code did not list its sessions"
    public static func appMissing(_ app: HandoffApp) -> String { "Not opened · \(app.name) is not installed" }
    public static func didNotOpen(_ app: HandoffApp) -> String { "Not opened · \(app.name) did not open" }
}

// MARK: Claude Code's own list and version

/// A row of Claude Code's own list (`ClaudeBackgroundEntry`, the one parser of `claude agents --json`, P1531), as a
/// hand-over reads it.
extension ClaudeBackgroundEntry {
    /// It holds the conversation: its process is alive, or (a background session) it is still working or blocked.
    public var isLive: Bool { pid != nil || state == "working" || state == "blocked" }

    /// A turn of it runs now: busy, waiting on someone, or a background session working or blocked.
    public var isWorking: Bool { status == "busy" || status == "waiting" || state == "working" || state == "blocked" }
}

/// Claude Code's version, from `claude --version` ("2.1.280 (Claude Code)").
public struct ClaudeVersion: Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `claude --desktop` came in 2.1.285 (its CLI reference).
    public static let desktopFlag = ClaudeVersion(2, 1, 285)

    /// The first `x.y.z` in the output; nil when there is none.
    public static func parse(_ output: String) -> ClaudeVersion? {
        for word in output.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let parts = word.split(separator: ".")
            guard parts.count >= 3, let major = Int(parts[0]), let minor = Int(parts[1]),
                  let patch = Int(parts[2].prefix { $0.isNumber }) else { continue }
            return ClaudeVersion(major, minor, patch)
        }
        return nil
    }

    public static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

// MARK: Running a CLI

/// One run of an agent's CLI for a hand-over (P1511): `claude --version` and `claude --desktop --resume <id>`. Claude
/// Code's background family (`claude agents --json --all`, `claude stop <id>`) goes through the engine's
/// `ClaudeBackgrounder` and its own command (P1520, P1531). Never the owner's text: nothing here takes any; stdin is empty.
public struct HandoffCommand: Equatable, Sendable {
    public var tool: String
    public var arguments: [String]
    /// The whole environment but PATH, which the live run adds (the login shell's).
    public var environment: [String: String]
    /// Its current folder; nil: the app's.
    public var folder: String?
    /// How long it may take before it is ended.
    public var timeout: TimeInterval

    public init(tool: String, arguments: [String], environment: [String: String], folder: String? = nil, timeout: TimeInterval) {
        self.tool = tool
        self.arguments = arguments
        self.environment = environment
        self.folder = folder
        self.timeout = timeout
    }

    /// A Claude Code command against the default profile (the only one Claude's app opens, P1512). `--version` and
    /// `--desktop` start no session the island should see: `CLIEnvironment.make`, the island's skip switches on.
    static func claude(_ arguments: [String], folder: String? = nil, timeout: TimeInterval) -> HandoffCommand {
        var environment = CLIEnvironment.make(provider: .claude, folder: NSHomeDirectory() + "/.claude", basePATH: "")
        environment["PATH"] = nil
        return HandoffCommand(tool: "claude", arguments: arguments, environment: environment, folder: folder, timeout: timeout)
    }
}

/// How a run ended.
public struct HandoffResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var error: String
    /// The CLI is not on the login shell's PATH.
    public var missing = false
    public var timedOut = false

    public init(status: Int32, output: String = "", error: String = "", missing: Bool = false, timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.error = error
        self.missing = missing
        self.timedOut = timedOut
    }

    public static let notFound = HandoffResult(status: -1, missing: true)

    public var succeeded: Bool { status == 0 && !missing && !timedOut }

    /// The first line it said, stderr first, cut to the card's line.
    var said: String? {
        ResumeExit.firstLine(error).map { ResumeExit.cut($0, limit: 80) } ?? ResumeExit.firstLine(output).map { ResumeExit.cut($0, limit: 80) }
    }
}

enum HandoffRun {
    /// Not in a test process (`TestProcess`, the one check the background family and the daemon link use too).
    static let allowed: Bool = !TestProcess.isRunning

    /// The live run: the CLI on the login shell's PATH, stdin empty, stdout and stderr kept, ended at its timeout
    /// (SIGTERM to that child, which the app started, and 2 s more at most), through the background family's own runner
    /// (`ClaudeCommandRun.run`, P1531). Off the main thread only.
    static let live: @Sendable (HandoffCommand) -> HandoffResult = { command in
        guard allowed, let executable = ToolLocator.locate(command.tool) else { return .notFound }
        var environment = command.environment
        if environment["PATH"] == nil { environment["PATH"] = ToolLocator.loginShellPATH() }
        guard let result = ClaudeCommandRun.run(executable: executable, arguments: command.arguments, environment: environment,
                                                folder: command.folder, timeout: command.timeout) else {
            return HandoffResult(status: -1, error: "it could not start")
        }
        return HandoffResult(status: result.status, output: result.output, error: result.errorTail)
    }
}

// MARK: The apps on this Mac

enum HandoffApps {
    /// Where the app is installed: by its bundle ids (Launch Services), else by its name in /Applications or
    /// ~/Applications. nil: not installed.
    static func url(_ app: HandoffApp, workspace: NSWorkspace = .shared, home: String = NSHomeDirectory()) -> URL? {
        for id in app.bundleIDs {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) { return url }
        }
        for folder in ["/Applications", home + "/Applications"] {
            for name in app.appNames {
                let path = folder + "/" + name
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// Whether any of its bundle ids runs now.
    static func isRunning(_ app: HandoffApp) -> Bool {
        app.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// The installed app's own name ("ChatGPT"), for "Quit ChatGPT first"; its own name when not installed.
    static func displayName(_ app: HandoffApp) -> String {
        guard let url = url(app) else { return app.name }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Opens the app by its path (never by bundle id, P708), with `folder` when given (VS Code opens it as its workspace).
    static func open(_ url: URL, folder: String?) -> Bool {
        let arguments = ["-a", url.path] + (folder.map { [$0] } ?? [])
        return (try? JumpRunner.openCommand(arguments, 10)) != nil
    }

    /// Opens a link (`codex://threads/<id>`) with the app that owns its scheme.
    static func openLink(_ link: String) -> Bool {
        (try? JumpRunner.openCommand([link], 10)) != nil
    }
}
