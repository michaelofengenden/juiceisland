import AppKit
import Foundation
import IslandHookNotes
import OpenIslandCore

/// Runs a process with a deadline. Output is read after exit, which is enough for osascript and `open`.
enum TimedProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            exited.wait()
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus, stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                      stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines), timedOut: timedOut)
    }
}

enum JumpRunnerError: Error, LocalizedError {
    case timedOut(String)
    case appleScriptFailed(String)
    case openFailed([String])
    case scriptFailed(String)
    /// A command-line tool the jump needs is not installed where the app can find it.
    case cliMissing(String)
    /// The tmux session has no client (P47).
    case detached
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let what): "Timed out: \(what)"
        case .appleScriptFailed(let message): "Terminal automation failed: \(message)"
        case .openFailed(let arguments): "open failed: \(arguments.joined(separator: " "))"
        case .scriptFailed(let message): message
        case .cliMissing(let tool): "\(tool) was not found."
        case .detached: "No tmux client is attached to that session."
        case .commandFailed(let what): "Failed: \(what)"
        }
    }
}

/// Collects the steps of one jump. The jump service calls its runners synchronously on one thread.
final class JumpRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [JumpStep] = []
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    var recorded: [JumpStep] { lock.withLock { steps } }

    func record<T>(_ kind: JumpStep.Kind, _ detail: String, _ body: () throws -> T) throws -> T {
        let start = clock()
        do {
            let value = try body()
            append(JumpStep(kind: kind, detail: detail, succeeded: true, error: nil, duration: clock().timeIntervalSince(start)))
            return value
        } catch {
            append(JumpStep(kind: kind, detail: detail, succeeded: false, error: error.localizedDescription,
                            duration: clock().timeIntervalSince(start)))
            throw error
        }
    }

    func recordBool(_ kind: JumpStep.Kind, _ detail: String, _ body: () -> Bool) -> Bool {
        let start = clock()
        let ok = body()
        append(JumpStep(kind: kind, detail: detail, succeeded: ok, error: nil, duration: clock().timeIntervalSince(start)))
        return ok
    }

    func recordFailure(_ kind: JumpStep.Kind, _ detail: String, error: String, duration: TimeInterval) {
        append(JumpStep(kind: kind, detail: detail, succeeded: false, error: error, duration: duration))
    }

    private func append(_ step: JumpStep) {
        lock.withLock { steps.append(step) }
    }
}

/// The jump service's answer, handed from the thread that runs it to the caller that waits for it.
final class JumpServiceResult: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: Result<JumpAnswer, Error>?

    func finish(_ result: Result<JumpAnswer, Error>) {
        lock.withLock { value = result }
        done.signal()
    }

    /// nil when the service has not answered within `timeout`.
    func wait(timeout: TimeInterval) -> Result<JumpAnswer, Error>? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { value }
    }
}

/// The first tool a jump found missing, set on the worker thread.
final class ToolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    func set(_ value: String) { lock.withLock { if name == nil { name = value } } }
    var value: String? { lock.withLock { name } }
}

/// Wraps Open Island's `TerminalJumpService` so every jump has a deadline, a trace, a named result and a fallback
/// that brings the host app forward when the exact jump fails.
///
/// Two deadlines apply. Each osascript, `open` and CLI call made through the injected runners gets `stepTimeout`
/// and a trace step. Some hosts' steps are run by upstream itself, with no deadline and no trace step (tmux, Zellij,
/// WezTerm and Kaku through `Process`, and Warp's tab cycling). `overallTimeout` bounds the whole jump, so a hung
/// `tmux` still ends in a recorded outcome and the fallback.
struct JumpRunner: Sendable {
    typealias AppleScript = @Sendable (_ script: String, _ timeout: TimeInterval) throws -> String
    typealias Open = @Sendable (_ arguments: [String], _ timeout: TimeInterval) throws -> Void
    typealias Command = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> Bool
    /// Runs a tool by its absolute path and returns its output; throws when it fails or times out.
    typealias Capture = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> String

    var stepTimeout: TimeInterval = 3
    var overallTimeout: TimeInterval = 6
    var appURL: @Sendable (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    var isAppRunning: @Sendable (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    var appleScript: AppleScript = JumpRunner.osascript
    var open: Open = JumpRunner.openCommand
    var command: Command = JumpRunner.envCommand
    var capture: Capture = JumpRunner.captureCommand
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var frontmostBundleID: @Sendable () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// The app a process belongs to: its own bundle id or its nearest ancestor's (a tmux client's terminal).
    var appForPID: @Sendable (Int32) -> String? = { JumpRunner.owningApp(of: $0) }
    var pause: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// How long a match waits for its host to come forward before it is checked (P43).
    var verifyWindow: TimeInterval = 0.6
    var clock: @Sendable () -> Date = { Date() }

    /// When the whole jump is over: `run` sets it for its worker. A step that would start after it throws instead,
    /// so a worker still running past the overall deadline never selects a tab or switches a client after the
    /// fallback has answered.
    var deadline: Date?

    /// A tool's absolute path, found without the GUI app's PATH (P48); nil when it is not installed.
    func resolveTool(_ name: String) -> String? {
        JumpTools.resolve(name, appURL: appURL, isExecutable: isExecutable)
    }

    /// Throws once the overall deadline has passed.
    func checkDeadline(_ what: String) throws {
        if let deadline, clock() >= deadline { throw JumpRunnerError.timedOut(what) }
    }

    func run(sessionID: String, target: JumpTarget?, context: JumpContext? = nil) -> JumpOutcome {
        let started = clock()
        guard let target else {
            return JumpOutcome(id: UUID(), sessionID: sessionID, host: "unknown", startedAt: started, duration: 0,
                               result: .noTarget, failure: nil, message: "No jump target yet.", steps: [])
        }
        let recorder = JumpRecorder(clock: clock)
        let timeout = stepTimeout
        func outcome(_ result: JumpResult, _ failure: JumpFailure?, _ message: String, tool: String? = nil) -> JumpOutcome {
            JumpOutcome(id: UUID(), sessionID: sessionID, host: target.terminalApp, startedAt: started,
                        duration: clock().timeIntervalSince(started), result: result, failure: failure,
                        message: message, steps: recorder.recorded, tool: tool)
        }

        // Verified jumps (M5): a host that is not running is named and never launched; an unknown host brings
        // forward only the app that started the agent, never some other terminal (P49).
        switch precheck(target: target, context: context) {
        case .proceed:
            break
        case .hostNotRunning:
            return outcome(.failed, .hostNotRunning, "\(target.terminalApp) is not running.")
        case let .unknownHost(bundleID):
            if let bundleID, isAppRunning(bundleID),
               (try? recorder.record(.open, "open -b \(bundleID)", { try open(["-b", bundleID], timeout) })) != nil {
                return outcome(.fallbackActivated, .unknownHost, "Brought the host app forward; it has no exact jump.")
            }
            return outcome(.failed, .unknownHost, "No jump for \(target.terminalApp).")
        }

        let answer = JumpServiceResult()
        let missingTool = ToolBox()
        var bounded = self
        bounded.deadline = started.addingTimeInterval(overallTimeout)
        let runner = bounded
        let worker = Thread {
            answer.finish(Result { try runner.attempt(target: target, context: context, recorder: recorder, missingTool: missingTool) })
        }
        worker.name = "JumpRunner"
        worker.start()

        let serviceResult: Result<JumpAnswer, Error>
        if let finished = answer.wait(timeout: overallTimeout) {
            serviceResult = finished
        } else {
            // The worker keeps running until upstream's call returns; its late steps are not part of this outcome.
            recorder.recordFailure(.process, "jump service", error: "Timed out after \(overallTimeout) s",
                                   duration: clock().timeIntervalSince(started))
            serviceResult = .failure(JumpRunnerError.timedOut("jump service"))
        }

        switch serviceResult {
        case .success(let found):
            return outcome(found.result, found.failure, found.message, tool: found.tool)
        case .failure(let error):
            let failure = Self.classify(error)
            let tool: String? = if case let JumpRunnerError.cliMissing(name) = error { name } else { nil }
            if failure == .detached { return outcome(.failed, failure, error.localizedDescription) }
            if let bundleID = fallbackBundleIdentifier(target: target, context: context),
               (try? recorder.record(.open, "open -b \(bundleID)", { try open(["-b", bundleID], timeout) })) != nil {
                return outcome(.fallbackActivated, failure, "\(error.localizedDescription) Brought \(target.terminalApp) forward instead.",
                               tool: tool)
            }
            return outcome(.failed, failure, error.localizedDescription, tool: tool)
        }
    }

    enum Precheck: Equatable {
        case proceed
        case hostNotRunning
        /// No exact jump for this host; the app that started the agent, when the note named one.
        case unknownHost(bundleID: String?)
    }

    /// Runs before any step. A tmux pane is checked by tmux itself, and the Codex app's thread link opens the thread
    /// even when the app is not running.
    func precheck(target: JumpTarget, context: JumpContext?) -> Precheck {
        if context?.hasTmuxPane == true { return .proceed }
        if let thread = target.codexThreadID, !thread.isEmpty { return .proceed }
        let named = JumpHosts.bundleIdentifiers(forTerminalApp: target.terminalApp)
        if let noted = context?.hostBundleID {
            // P49: the app that started the agent is the host. One with no exact jump is only brought forward.
            if !JumpHosts.isKnown(bundleID: noted) {
                return isAppRunning(noted) ? .unknownHost(bundleID: noted) : .hostNotRunning
            }
            return isAppRunning(noted) ? .proceed : .hostNotRunning
        }
        if named.isEmpty {
            // Upstream's own names without an app (Zellij) and its "Unknown" sentinel keep upstream's handling:
            // Zellij's own jump, or the working folder in Finder.
            let name = target.terminalApp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["zellij", "unknown", ""].contains(name) ? .proceed : .unknownHost(bundleID: nil)
        }
        return named.contains(where: isAppRunning) ? .proceed : .hostNotRunning
    }

    /// One attempt, on the worker thread: the exact jump when the notes give one, else upstream's service.
    func attempt(target: JumpTarget, context: JumpContext?, recorder: JumpRecorder, missingTool: ToolBox) throws -> JumpAnswer {
        if let exact = try ExactJump(runner: self, recorder: recorder).jump(target: target, context: context) { return exact }
        let timeout = stepTimeout
        let open = self.open
        let appleScript = self.appleScript
        let command = self.command
        let runner = self
        let service = TerminalJumpService(
            applicationResolver: appURL,
            appRunningChecker: isAppRunning,
            openAction: { arguments in
                try runner.checkDeadline("jump service")
                try recorder.record(.open, "open " + arguments.joined(separator: " ")) { try open(arguments, timeout) }
            },
            appleScriptRunner: { script in
                try runner.checkDeadline("jump service")
                return try recorder.record(.appleScript, Self.summary(of: script)) { try appleScript(script, timeout) }
            },
            processRunner: { executable, arguments in
                if (try? runner.checkDeadline("jump service")) == nil { return false }
                let detail = ([executable] + arguments).joined(separator: " ")
                // P48: the editor's CLI from its install folder or its bundle, never the GUI app's PATH.
                guard let resolved = runner.resolveTool(executable) else {
                    missingTool.set(executable)
                    recorder.recordFailure(.process, detail, error: "\(executable) was not found", duration: 0)
                    return false
                }
                return recorder.recordBool(.process, detail) { command(resolved, arguments, timeout) }
            }
        )
        let text = try service.jump(to: target)
        // Upstream's last resort, for a target that names no app it knows: the working folder in Finder. Only a session
        // with no app and no terminal gets here (a Codex app thread never does, `ExactJump`), and Last jump says so (P660).
        if Self.openedFolder(text) {
            return JumpAnswer(result: .folderOpened, failure: nil,
                              message: "Opened \(target.workspaceName) in Finder: no app or terminal is known for this session.")
        }
        var found = JumpAnswer(result: text.hasPrefix("Focused") ? .matched : .activatedOnly, failure: nil, message: text)
        if found.result != .matched, let tool = missingTool.value {
            found.failure = .cliMissing
            found.tool = tool
        }
        return found
    }

    /// P49: the app that started the agent when the note named it and it runs; else upstream's rule (a running
    /// build first, then an installed one).
    func fallbackBundleIdentifier(target: JumpTarget, context: JumpContext?) -> String? {
        if let noted = context?.hostBundleID, context?.hasTmuxPane != true {
            return isAppRunning(noted) ? noted : nil
        }
        // A tmux pane skips the host check (tmux answers for itself), so its fallback never launches a terminal.
        if context?.hasTmuxPane == true {
            return JumpHosts.bundleIdentifiers(forTerminalApp: target.terminalApp).first(where: isAppRunning)
        }
        return JumpHosts.fallbackBundleIdentifier(forTerminalApp: target.terminalApp, isRunning: isAppRunning, appURL: appURL)
    }

    static func classify(_ error: Error) -> JumpFailure {
        switch error {
        case JumpRunnerError.timedOut:
            return .timedOut
        case JumpRunnerError.appleScriptFailed(let message):
            // -1743 is errAEEventNotPermitted: this app is not allowed to automate that app.
            return message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized")
                ? .automationDenied : .scriptFailed
        case JumpRunnerError.openFailed:
            return .openFailed
        case JumpRunnerError.cliMissing:
            return .cliMissing
        case JumpRunnerError.detached:
            return .detached
        case JumpRunnerError.scriptFailed, JumpRunnerError.commandFailed:
            return .scriptFailed
        case TerminalJumpError.unsupportedTerminal:
            return .unknownHost
        case TerminalJumpError.openFailed:
            return .openFailed
        default:
            return .scriptFailed
        }
    }

    /// Upstream's answer for the folder it opened in Finder (`TerminalJumpService.jump`, "Opened … in Finder because no
    /// supported terminal app could be resolved.").
    static func openedFolder(_ text: String) -> Bool {
        text.hasPrefix("Opened ") && text.contains(" in Finder ")
    }

    static func summary(of script: String) -> String {
        let first = script.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return "osascript: " + String(first.prefix(60))
    }

    static let osascript: AppleScript = { script, timeout in
        let output = try TimedProcess.run("/usr/bin/osascript", ["-e", script], timeout: timeout)
        if output.timedOut { throw JumpRunnerError.timedOut(summary(of: script)) }
        guard output.status == 0 else { throw JumpRunnerError.appleScriptFailed(output.stderr) }
        return output.stdout
    }

    static let openCommand: Open = { arguments, timeout in
        let output = try TimedProcess.run("/usr/bin/open", arguments, timeout: timeout)
        if output.timedOut { throw JumpRunnerError.timedOut("open " + arguments.joined(separator: " ")) }
        guard output.status == 0 else { throw JumpRunnerError.openFailed(arguments) }
    }

    static let envCommand: Command = { executable, arguments, timeout in
        guard let output = try? TimedProcess.run("/usr/bin/env", [executable] + arguments, timeout: timeout) else { return false }
        return !output.timedOut && output.status == 0
    }

    static let captureCommand: Capture = { executable, arguments, timeout in
        let output = try TimedProcess.run(executable, arguments, timeout: timeout)
        let what = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        if output.timedOut { throw JumpRunnerError.timedOut(what) }
        guard output.status == 0 else { throw JumpRunnerError.commandFailed(what) }
        return output.stdout
    }

    /// The bundle id of the app that owns a process: the process itself or its nearest ancestor that is an app.
    static func owningApp(of pid: Int32, table: any ProcessTable = SystemProcessTable(), maxHops: Int = 8) -> String? {
        var current = pid
        for _ in 0..<maxHops {
            guard current > 1 else { return nil }
            if let id = NSRunningApplication(processIdentifier: current)?.bundleIdentifier { return id }
            guard let parent = table.entry(pid: current)?.parentPID else { return nil }
            current = parent
        }
        return nil
    }
}

/// The app to bring forward when an exact jump fails, by the host name a jump target carries. Mirrors every host in
/// Open Island's `TerminalJumpService.knownApps` (1.2.1): the display name and each alias, trimmed and lowercased,
/// the way upstream matches them. `hostsCoverUpstreamsKnownApps` reads upstream's table and fails when one is missing.
enum JumpHosts {
    private struct Host {
        let bundleIdentifiers: [String]
        let names: [String]
        /// Aliases that name one particular build (Trae CN).
        var preferred: [String: String] = [:]
    }

    private static let hosts: [Host] = [
        Host(bundleIdentifiers: ["com.googlecode.iterm2"], names: ["iterm", "iterm2", "iterm.app"]),
        Host(bundleIdentifiers: ["com.cmuxterm.app"], names: ["cmux"]),
        Host(bundleIdentifiers: ["com.mitchellh.ghostty"], names: ["ghostty"]),
        Host(bundleIdentifiers: ["com.apple.Terminal"], names: ["terminal", "apple_terminal"]),
        Host(bundleIdentifiers: ["dev.warp.Warp-Stable"], names: ["warp", "warpterminal"]),
        Host(bundleIdentifiers: ["com.github.wez.wezterm"], names: ["wezterm"]),
        Host(bundleIdentifiers: ["com.openai.codex"], names: ["codex.app"]),
        Host(bundleIdentifiers: ["com.anthropic.claudefordesktop"], names: ["claude.app"]),
        Host(bundleIdentifiers: ["fun.tw93.kaku"], names: ["kaku"]),
        Host(bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"], names: ["cursor"]),
        Host(bundleIdentifiers: ["com.microsoft.VSCode"], names: ["vs code", "vscode", "code", "visual studio code"]),
        Host(bundleIdentifiers: ["com.microsoft.VSCodeInsiders"], names: ["vs code insiders", "vscode-insiders", "code-insiders"]),
        Host(bundleIdentifiers: ["com.exafunction.windsurf"], names: ["windsurf"]),
        Host(bundleIdentifiers: ["com.trae.app", "cn.trae.app"], names: ["trae", "trae cn", "trae-cn", "traecn"],
             preferred: ["trae cn": "cn.trae.app", "trae-cn": "cn.trae.app", "traecn": "cn.trae.app"]),
        Host(bundleIdentifiers: ["com.qoder.app", "com.qoder.qoder"], names: ["qoder"]),
        Host(bundleIdentifiers: ["dev.zed.Zed", "dev.zed.Zed-Preview"], names: ["zed"]),
        Host(bundleIdentifiers: ["com.conductor.app"], names: ["conductor"]),
        Host(bundleIdentifiers: ["com.jetbrains.intellij"], names: ["intellij idea", "intellij", "idea"]),
        Host(bundleIdentifiers: ["com.jetbrains.WebStorm"], names: ["webstorm"]),
        Host(bundleIdentifiers: ["com.jetbrains.pycharm"], names: ["pycharm"]),
        Host(bundleIdentifiers: ["com.jetbrains.goland"], names: ["goland"]),
        Host(bundleIdentifiers: ["com.jetbrains.CLion"], names: ["clion"]),
        Host(bundleIdentifiers: ["com.jetbrains.rubymine"], names: ["rubymine"]),
        Host(bundleIdentifiers: ["com.jetbrains.PhpStorm"], names: ["phpstorm"]),
        Host(bundleIdentifiers: ["com.jetbrains.rider"], names: ["rider"]),
        Host(bundleIdentifiers: ["com.jetbrains.rustrover"], names: ["rustrover"]),
    ]

    /// Candidate bundle identifiers for a host name, the preferred build first; empty for an unknown host.
    static func bundleIdentifiers(forTerminalApp name: String) -> [String] {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let host = hosts.first(where: { $0.names.contains(key) }) else { return [] }
        guard let preferred = host.preferred[key] else { return host.bundleIdentifiers }
        return [preferred] + host.bundleIdentifiers.filter { $0 != preferred }
    }

    static func bundleIdentifier(forTerminalApp name: String) -> String? {
        bundleIdentifiers(forTerminalApp: name).first
    }

    /// Whether a bundle id is one of upstream's hosts, which have an exact jump or a known fallback.
    static func isKnown(bundleID: String) -> Bool {
        hosts.contains { $0.bundleIdentifiers.contains(bundleID) }
    }

    /// The Codex app's own command-line helper, which runs its app-server (`ChatGPT.app/Contents/Resources/codex-cli/
    /// CodexCLI.app`, P660): a note that names it names the app.
    static let codexHelperBundleID = "com.openai.codex.cli"

    /// The app a note's bundle id stands for: the Codex app for its helper, else the id itself.
    static func canonical(bundleID: String) -> String {
        bundleID == codexHelperBundleID ? ExactJump.codexBundleID : bundleID
    }

    /// The host name a jump target carries for an app, from the note's bundle id; the id itself when unknown.
    static func name(forBundleID bundleID: String) -> String {
        displayNames[bundleID] ?? hosts.first { $0.bundleIdentifiers.contains(bundleID) }?.names.first ?? bundleID
    }

    private static let displayNames: [String: String] = [
        "com.googlecode.iterm2": "iTerm", "com.mitchellh.ghostty": "Ghostty", "com.apple.Terminal": "Terminal",
        "dev.warp.Warp-Stable": "Warp", "com.github.wez.wezterm": "WezTerm", "com.openai.codex": "Codex.app",
        "com.anthropic.claudefordesktop": "Claude.app", "com.microsoft.VSCode": "VS Code", "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders", "com.exafunction.windsurf": "Windsurf", "dev.zed.Zed": "Zed",
    ]

    /// Like upstream: a running build first, then an installed one, then the first candidate.
    static func fallbackBundleIdentifier(forTerminalApp name: String, isRunning: (String) -> Bool,
                                         appURL: (String) -> URL?) -> String? {
        let candidates = bundleIdentifiers(forTerminalApp: name)
        return candidates.first(where: isRunning) ?? candidates.first { appURL($0) != nil } ?? candidates.first
    }
}
