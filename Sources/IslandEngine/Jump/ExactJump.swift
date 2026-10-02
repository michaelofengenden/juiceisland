import AppKit
import Foundation
import IslandHookNotes
import OpenIslandCore

/// What one attempt at a jump came to, before the fallback.
struct JumpAnswer: Equatable, Sendable {
    var result: JumpResult
    var failure: JumpFailure?
    var message: String
    var tool: String?

    static func matched(_ message: String) -> JumpAnswer { JumpAnswer(result: .matched, failure: nil, message: message) }
}

/// The jumps that use the context notes' exact handles (spec §3.8), in front of upstream's `TerminalJumpService`:
/// - tmux by pane id, on the client already showing that session or else the most recently active one (P47);
/// - iTerm by the session's tty, else its `ITERM_SESSION_ID` UUID (P17: the tty wins when they disagree);
/// - Terminal by the agent's tty;
/// - Ghostty only on a unique id, else a unique working directory, else a unique title (P46);
/// - the Codex app's thread link, checked for the app coming forward (P50).
/// Scripts address the app by bundle id (P49), select the tab before activating (P44's order) and un-minimize its
/// window (P45, Terminal and iTerm). A match is checked against the focused tab once, and tried once more (P43).
/// Every osascript, `open` and tmux call is one trace step with the step deadline.
struct ExactJump {
    let runner: JumpRunner
    let recorder: JumpRecorder

    static let separator = "\u{1f}"
    static let itermBundleID = "com.googlecode.iterm2"
    static let terminalBundleID = "com.apple.Terminal"
    static let ghosttyBundleID = "com.mitchellh.ghostty"
    static let codexBundleID = "com.openai.codex"

    /// The answer, or nil when no exact path applies and upstream's service should run.
    ///
    /// A Codex app thread never reaches upstream's service, whose last resort is the working folder in Finder (P660): a
    /// target with a thread id goes to that thread when its host is the Codex app or no host is known at all, and a
    /// Codex app target whose thread is not known brings the app forward.
    func jump(target: JumpTarget, context: JumpContext?) throws -> JumpAnswer? {
        let host = host(target, context)
        let inTmux = context?.hasTmuxPane == true
        if let thread = Self.nonEmpty(target.codexThreadID) {
            if host == Self.codexBundleID || (host == nil && !inTmux) { return try codexThread(thread) }
        } else if host == Self.codexBundleID, !inTmux {
            return try codexApp()
        }
        guard let context else { return nil }
        if context.hasTmuxPane { return try tmux(target: target, context: context) }
        switch host {
        case Self.itermBundleID:
            guard context.itermSessionID != nil || Self.nonEmpty(target.terminalTTY) != nil else { return nil }
            return try verified(bundleID: Self.itermBundleID, host: "iTerm") {
                try iterm(tty: target.terminalTTY, sessionID: context.itermSessionID)
            }
        case Self.terminalBundleID:
            guard let tty = Self.nonEmpty(target.terminalTTY) else { return nil }
            return try verified(bundleID: Self.terminalBundleID, host: "Terminal") { try terminal(tty: tty) }
        case Self.ghosttyBundleID:
            return try verified(bundleID: Self.ghosttyBundleID, host: "Ghostty") { try ghostty(target) }
        default:
            return nil
        }
    }

    /// The host's bundle id: the context's (the app that started the agent) outside tmux, else the target's name.
    func host(_ target: JumpTarget, _ context: JumpContext?) -> String? {
        if let context, !context.hasTmuxPane, let id = context.hostBundleID { return JumpHosts.canonical(bundleID: id) }
        return JumpHosts.bundleIdentifier(forTerminalApp: target.terminalApp)
    }

    // MARK: One host's match, checked

    /// A focus probe's answer: the handle that is focused now, to compare with the one matched.
    enum Match: Equatable {
        case matched(handle: String?)
        case ambiguous
        case notFound
    }

    private func verified(bundleID: String, host: String, _ attempt: () throws -> Match) throws -> JumpAnswer {
        for round in 0..<2 {
            switch try attempt() {
            case .notFound:
                try open(["-b", bundleID])
                return JumpAnswer(result: .activatedOnly, failure: nil, message: "Activated \(host); no tab matched.")
            case .ambiguous:
                return JumpAnswer(result: .activatedOnly, failure: .ambiguous, message: "Activated \(host); several tabs match.")
            case let .matched(handle):
                if isFocused(bundleID: bundleID, handle: handle) != false {
                    return .matched("Focused the matching \(host) tab.")
                }
                if round == 1 {
                    return JumpAnswer(result: .activatedOnly, failure: .wrongTab, message: "Activated \(host); another tab has focus.")
                }
            }
        }
        return JumpAnswer(result: .activatedOnly, failure: .wrongTab, message: "Activated \(host); another tab has focus.")
    }

    /// P43: within the verify window the host must be in front and its focused tab must be the matched one. nil when
    /// that cannot be told (the probe failed); then the match stands.
    func isFocused(bundleID: String, handle: String?) -> Bool? {
        guard waitForFrontmost(bundleID) else { return false }
        guard let handle, let focused = focusedHandles(bundleID: bundleID) else { return nil }
        return focused.contains(handle)
    }

    func waitForFrontmost(_ bundleID: String) -> Bool {
        let steps = max(1, Int((runner.verifyWindow / 0.1).rounded()))
        for step in 0...steps {
            if runner.frontmostBundleID() == bundleID { return true }
            if step < steps { runner.pause(0.1) }
        }
        return false
    }

    private func focusedHandles(bundleID: String) -> [String]? {
        let body: String
        switch bundleID {
        case Self.itermBundleID:
            body = "tell current session of current window to return (id as text) & (ASCII character 31) & (tty as text)"
        case Self.terminalBundleID:
            body = "return tty of selected tab of front window as text"
        case Self.ghosttyBundleID:
            body = "return id of focused terminal of selected tab of front window as text"
        default:
            return nil
        }
        let script = """
        tell application id "\(bundleID)"
            if not (it is running) then return ""
            \(body)
        end tell
        """
        guard let output = try? self.script(script), !output.isEmpty else { return nil }
        return output.components(separatedBy: Self.separator).filter { !$0.isEmpty }
    }

    // MARK: Hosts

    func iterm(tty: String?, sessionID: String?) throws -> Match {
        let tty = Self.escape(Self.nonEmpty(tty))
        let id = Self.escape(sessionID)
        let script = """
        tell application id "\(Self.itermBundleID)"
            if not (it is running) then return ""
            repeat with passIndex from 1 to 2
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            set matched to false
                            if passIndex is 1 and "\(tty)" is not "" and (tty of aSession as text) is "\(tty)" then set matched to true
                            if passIndex is 2 and "\(id)" is not "" and (id of aSession as text) is "\(id)" then set matched to true
                            if matched then
                                try
                                    if miniaturized of aWindow then set miniaturized of aWindow to false
                                end try
                                select aWindow
                                tell aWindow to select aTab
                                select aSession
                                activate
                                return "matched" & (ASCII character 31) & (id of aSession as text)
                            end if
                        end repeat
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """
        return Self.match(try self.script(script))
    }

    func terminal(tty: String) throws -> Match {
        let tty = Self.escape(tty)
        let script = """
        tell application id "\(Self.terminalBundleID)"
            if not (it is running) then return ""
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if (tty of aTab as text) is "\(tty)" then
                        try
                            if miniaturized of aWindow then set miniaturized of aWindow to false
                        end try
                        set selected of aTab to true
                        set frontmost of aWindow to true
                        activate
                        return "matched" & (ASCII character 31) & "\(tty)"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
        return Self.match(try self.script(script))
    }

    func ghostty(_ target: JumpTarget) throws -> Match {
        let id = Self.escape(Self.nonEmpty(target.terminalSessionID))
        let directory = Self.escape(Self.nonEmpty(target.workingDirectory))
        let title = Self.escape(Self.nonEmpty(target.paneTitle))
        let script = """
        tell application id "\(Self.ghosttyBundleID)"
            if not (it is running) then return ""
            set idMatches to {}
            set directoryMatches to {}
            set titleMatches to {}
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aTerminal in terminals of aTab
                        if "\(id)" is not "" and (id of aTerminal as text) is "\(id)" then set end of idMatches to {aWindow, aTab, aTerminal}
                        if "\(directory)" is not "" and (working directory of aTerminal as text) is "\(directory)" then set end of directoryMatches to {aWindow, aTab, aTerminal}
                        if "\(title)" is not "" and (name of aTerminal as text) contains "\(title)" then set end of titleMatches to {aWindow, aTab, aTerminal}
                    end repeat
                end repeat
            end repeat
            set chosen to missing value
            if (count of idMatches) is 1 then
                set chosen to item 1 of idMatches
            else if (count of idMatches) is 0 and (count of directoryMatches) is 1 then
                set chosen to item 1 of directoryMatches
            else if (count of idMatches) is 0 and (count of directoryMatches) is 0 and (count of titleMatches) is 1 then
                set chosen to item 1 of titleMatches
            end if
            if chosen is missing value then
                if ((count of idMatches) + (count of directoryMatches) + (count of titleMatches)) is 0 then return ""
                activate
                return "ambiguous"
            end if
            set targetWindow to item 1 of chosen
            set targetTab to item 2 of chosen
            set targetTerminal to item 3 of chosen
            activate window targetWindow
            select tab targetTab
            focus targetTerminal
            activate
            return "matched" & (ASCII character 31) & (id of targetTerminal as text)
        end tell
        return ""
        """
        return Self.match(try self.script(script))
    }

    /// P50: the thread link, then the Codex app must come forward; if it does not, it is brought forward by id. The link
    /// is the app's own scheme: `codex` is the one `CFBundleURLTypes` of `com.openai.codex` names, the app now installed
    /// as ChatGPT.app (P660).
    func codexThread(_ thread: String) throws -> JumpAnswer {
        try open([Self.codexThreadLink(thread)])
        if waitForFrontmost(Self.codexBundleID) { return .matched("Focused the Codex.app conversation.") }
        try open(["-b", Self.codexBundleID])
        return JumpAnswer(result: .activatedOnly, failure: .threadLinkFailed, message: "Activated Codex.app; the thread link did not open.")
    }

    /// A Codex app thread with no id to link to (P660): the app comes forward, the thread is not promised.
    func codexApp() throws -> JumpAnswer {
        try open(["-b", Self.codexBundleID])
        return JumpAnswer(result: .activatedOnly, failure: .threadUnknown, message: "Activated Codex.app; the thread is not known.")
    }

    /// `codex://threads/<id>`: Codex's thread ids are UUIDs, kept as they are; anything but letters, digits, `-`, `_` and
    /// `.` is percent-encoded, so an id can never add a path, a query or a second link.
    static func codexThreadLink(_ thread: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return "codex://threads/" + (thread.addingPercentEncoding(withAllowedCharacters: allowed) ?? thread)
    }

    // MARK: tmux (P47)

    struct TmuxClient: Equatable {
        var tty: String
        var session: String
        var activity: Int
        var pid: Int32?
    }

    func tmux(target: JumpTarget, context: JumpContext) throws -> JumpAnswer {
        guard let pane = context.tmuxPane, let socket = context.tmuxSocketPath else { throw JumpRunnerError.scriptFailed("no tmux pane") }
        guard let tmux = runner.resolveTool("tmux") else { throw JumpRunnerError.cliMissing("tmux") }
        func run(_ arguments: [String]) throws -> String {
            try runner.checkDeadline("jump")
            return try recorder.record(.process, (["tmux"] + arguments).joined(separator: " ")) {
                try runner.capture(tmux, ["-S", socket] + arguments, runner.stepTimeout)
            }
        }
        let session = try run(["display-message", "-p", "-t", pane, "#{session_name}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clients = Self.parseClients(try run(["list-clients", "-F", "#{client_tty}\t#{client_session}\t#{client_activity}\t#{client_pid}"]))
        guard let client = Self.pickClient(clients, session: session) else { throw JumpRunnerError.detached }
        if client.session != session { _ = try run(["switch-client", "-c", client.tty, "-t", pane]) }
        _ = try run(["select-window", "-t", pane])
        _ = try run(["select-pane", "-t", pane])

        // The terminal that shows the client: its app, found from the client's process, then its tab by the client's tty.
        let hostID = client.pid.flatMap(runner.appForPID)
        switch hostID {
        case Self.itermBundleID:
            if case .matched = try iterm(tty: client.tty, sessionID: nil) { return .matched("Focused the tmux pane in iTerm.") }
        case Self.terminalBundleID:
            if case .matched = try terminal(tty: client.tty) { return .matched("Focused the tmux pane in Terminal.") }
        default:
            break
        }
        // Other terminals cannot be asked which tab holds a tty: the app comes forward, the tab is not promised. Only
        // a running one: a terminal that is not running shows no client, and nothing is launched.
        if let id = hostID ?? JumpHosts.bundleIdentifiers(forTerminalApp: target.terminalApp).first(where: runner.isAppRunning) {
            try open(["-b", id])
            return JumpAnswer(result: .activatedOnly, failure: nil, message: "Selected the tmux pane and activated its terminal.")
        }
        return JumpAnswer(result: .activatedOnly, failure: nil, message: "Selected the tmux pane; its terminal is unknown.")
    }

    static func parseClients(_ output: String) -> [TmuxClient] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { return nil }
            return TmuxClient(tty: fields[0], session: fields[1], activity: fields.count > 2 ? Int(fields[2]) ?? 0 : 0,
                              pid: fields.count > 3 ? Int32(fields[3]) : nil)
        }
    }

    /// The client already on the pane's session, the most recently active of those; else the most recently active.
    static func pickClient(_ clients: [TmuxClient], session: String) -> TmuxClient? {
        let latest: (TmuxClient, TmuxClient) -> Bool = { $0.activity < $1.activity }
        return clients.filter { $0.session == session }.max(by: latest) ?? clients.max(by: latest)
    }

    // MARK: Steps

    private func script(_ source: String) throws -> String {
        try runner.checkDeadline("jump")
        return try recorder.record(.appleScript, JumpRunner.summary(of: source)) { try runner.appleScript(source, runner.stepTimeout) }
    }

    private func open(_ arguments: [String]) throws {
        try runner.checkDeadline("jump")
        try recorder.record(.open, "open " + arguments.joined(separator: " ")) { try runner.open(arguments, runner.stepTimeout) }
    }

    static func match(_ output: String) -> Match {
        if output == "ambiguous" { return .ambiguous }
        let parts = output.components(separatedBy: separator)
        guard parts.first == "matched" else { return .notFound }
        return .matched(handle: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func escape(_ value: String?) -> String {
        (value ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Where a GUI app finds the command-line tools a jump runs: its PATH is only /usr/bin:/bin:/usr/sbin:/sbin, so
/// `env code` fails from a Finder launch (P48). Known install folders first, then the CLI inside the editor's bundle.
enum JumpTools {
    static func folders(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin", home + "/.local/bin",
         home + "/Library/Application Support/JetBrains/Toolbox/scripts"]
    }

    /// The VS Code family's CLIs inside their app bundles (`Contents/Resources/app/bin/<cli>`).
    static let bundledCLIs: [String: [String]] = [
        "code": ["com.microsoft.VSCode"],
        "code-insiders": ["com.microsoft.VSCodeInsiders"],
        "cursor": ["com.todesktop.230313mzl4w4u92"],
        "windsurf": ["com.exafunction.windsurf"],
        "trae": ["com.trae.app", "cn.trae.app"],
        "qoder": ["com.qoder.app", "com.qoder.qoder"],
    ]

    static func resolve(_ name: String, appURL: (String) -> URL?, isExecutable: (String) -> Bool,
                        home: String = NSHomeDirectory()) -> String? {
        if name.contains("/") { return isExecutable(name) ? name : nil }
        for folder in folders(home: home) where isExecutable(folder + "/" + name) { return folder + "/" + name }
        for bundleID in bundledCLIs[name] ?? [] {
            if let app = appURL(bundleID) {
                let path = app.appendingPathComponent("Contents/Resources/app/bin/\(name)").path
                if isExecutable(path) { return path }
            }
        }
        return nil
    }
}
