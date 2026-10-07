import Foundation
import JuiceCore

/// Route (b)'s run (wave 6, P1325 to P1349): a folded session whose tab is gone goes on through its agent's own
/// print-mode resume, in the session's folder and profile, with hooks on, so the island follows the turn as it follows
/// any other (the same session id and transcript; approvals come as cards). Built only for the owner's Return in that
/// session's card (`SessionResumer`); nothing here starts by itself.
public struct ResumeCommand: Equatable, Sendable {
    public var provider: Provider
    /// The CLI's name, looked for on the login shell's PATH as the run starts (`ToolLocator`), never on the main thread.
    public var tool: String
    public var arguments: [String]
    /// The run's whole environment, but PATH, which the live start adds (the login shell's, asked once off the main
    /// thread). Never the island's skip switches: the island should see this turn (P1326).
    public var environment: [String: String]
    /// The session's working folder: the run's current directory.
    public var folder: String
    /// The owner's text, given on stdin and never on the command line: a reply that starts with "-" stays text, and the
    /// process list never shows it.
    public var input: String

    public init(provider: Provider, tool: String, arguments: [String], environment: [String: String], folder: String,
                input: String) {
        self.provider = provider
        self.tool = tool
        self.arguments = arguments
        self.environment = environment
        self.folder = folder
        self.input = input
    }

    /// The command for one reply (P1325). Claude Code: `claude -p --resume <id> --output-format json`, the text on stdin:
    /// print mode continues that session under the same id and transcript (no `--fork-session`), and its one JSON result
    /// gives the final text or the failure. Codex: `codex exec resume --json <id> -`, which resumes that thread and
    /// appends to its rollout; `-` reads the prompt from stdin, and its JSONL events give the final message or the
    /// failure. Codex's exec mode never asks before a command (its approval policy is never; its sandbox is its own):
    /// the card says so before the first send (`SessionResumer.codexNote`).
    ///
    /// The environment is a short allowlist, as `CLIEnvironment.make` builds one, without its skip switches:
    /// HOME, USER, LOGNAME, LANG, TMPDIR, TERM and SHELL, the ssh agent's socket when the app has one (so the agent's
    /// own `git push` works as it did in the tab), and the profile's folder variable unless the profile is the default
    /// folder (the CLI finds its login differently once the variable is set at all). Nothing else of the app's leaks in:
    /// no `__CFBundleIdentifier` (the hook would name the island as the session's terminal) and no
    /// `CLAUDE_CODE_ENTRYPOINT` (Codex's notes would read as run under Claude, P257).
    public static func make(provider: Provider, sessionID: String, text: String, folder: String, profile: String,
                            inherited: [String: String], home: String = NSHomeDirectory(), user: String = NSUserName(),
                            temporary: String = NSTemporaryDirectory()) -> ResumeCommand {
        var environment: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "LANG": "en_US.UTF-8",
            "TMPDIR": temporary,
            "TERM": "dumb",
            "SHELL": inherited["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh",
        ]
        if let socket = inherited["SSH_AUTH_SOCK"], !socket.isEmpty { environment["SSH_AUTH_SOCK"] = socket }
        if let variable = folderVariable(provider: provider, profile: profile, home: home) {
            environment[provider.folderEnvironmentKey] = variable
        }
        let arguments = provider == .claude
            ? ["-p", "--resume", sessionID, "--output-format", "json"]
            : ["exec", "resume", "--json", sessionID, "-"]
        return ResumeCommand(provider: provider, tool: provider == .claude ? "claude" : "codex", arguments: arguments,
                             environment: environment, folder: expanded(folder), input: text)
    }

    /// The shell line Open in terminal types into a new window for a session whose tab is gone (P1330): into the folder,
    /// then the interactive resume, `claude --resume '<id>'` or `codex resume '<id>'`, with the profile's folder variable
    /// unless it is the default folder. Each word single-quoted, as Open in quotes (P703). `prompt`, for a turn its
    /// window's close cut off, is the resume's first prompt, so the agent carries the turn on in the window (P1439):
    /// both CLIs take one after the id.
    public static func terminalLine(provider: Provider, sessionID: String, folder: String, profile: String,
                                    prompt: String? = nil, home: String = NSHomeDirectory()) -> String {
        let resume = provider == .claude ? "claude --resume" : "codex resume"
        let words = prompt.flatMap(ResumeOutput.nonEmpty).map { " " + FreshSessionLaunch.quoted($0) } ?? ""
        let run = "\(resume) \(FreshSessionLaunch.quoted(sessionID))\(words)"
        let withProfile = folderVariable(provider: provider, profile: profile, home: home)
            .map { "\(provider.folderEnvironmentKey)=\(FreshSessionLaunch.quoted($0)) \(run)" } ?? run
        return "cd \(FreshSessionLaunch.quoted(expanded(folder))) && \(withProfile)"
    }

    /// The profile's folder for its variable; nil for the provider's default folder.
    static func folderVariable(provider: Provider, profile: String, home: String) -> String? {
        let path = expanded(profile)
        return CLIEnvironment.isDefaultFolder(path, for: provider, home: home) ? nil : path
    }

    static func expanded(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

/// What a run printed that its card needs, read one line at a time and kept small: the final text and the failure.
/// Claude Code (`--output-format json`): one result object, `{"type":"result","is_error":false,"result":"…"}`.
/// Codex (`--json`, openai/codex `exec_events.rs`): `item.completed` whose item is an `agent_message` (its `text`),
/// `turn.completed`, `turn.failed` (`error.message`) and `error` (`message`; one a later `turn.completed` outlived was a
/// retry).
public struct ResumeOutput: Equatable, Sendable {
    public var provider: Provider
    /// The agent's final text this run, when it gave one.
    public var answer: String?
    /// What the run itself said went wrong.
    public var failure: String?
    /// The result (Claude) or the turn's end (Codex) was read.
    public var finished = false
    private var lastError: String?

    public init(provider: Provider) {
        self.provider = provider
    }

    public init(provider: Provider, lines: [String]) {
        self.provider = provider
        for line in lines { take(line) }
    }

    public mutating func take(_ line: String) {
        guard line.first == "{", let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch provider {
        case .claude:
            guard type == "result" else { return }
            finished = true
            let text = (object["result"] as? String).flatMap(Self.nonEmpty)
            if object["is_error"] as? Bool == true {
                failure = text ?? (object["errors"] as? [String])?.lazy.compactMap(Self.nonEmpty).first
                    ?? (object["subtype"] as? String).map { $0.replacingOccurrences(of: "_", with: " ") } ?? "error"
            } else {
                answer = text
            }
        case .codex:
            switch type {
            case "item.completed":
                guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                      let text = (item["text"] as? String).flatMap(Self.nonEmpty) else { return }
                answer = text
            case "turn.completed":
                finished = true
                lastError = nil
            case "turn.failed":
                finished = true
                failure = ((object["error"] as? [String: Any])?["message"] as? String).flatMap(Self.nonEmpty) ?? "turn failed"
            case "error":
                lastError = (object["message"] as? String).flatMap(Self.nonEmpty)
            default:
                return
            }
        }
    }

    /// The failure to tell: the run's own, else an `error` no turn end outlived.
    var reportedFailure: String? { failure ?? lastError }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// How a run ended.
public struct ResumeExit: Equatable, Sendable {
    public var status: Int32
    public var output: ResumeOutput
    /// The end of stderr (at most 4 KB), for a run whose stdout says nothing of its failure ("No conversation found…").
    public var errorTail: String

    public init(status: Int32, output: ResumeOutput, errorTail: String = "") {
        self.status = status
        self.output = output
        self.errorTail = errorTail
    }

    /// Codex refused the run because another process still writes the thread: Codex allows one writer per thread ("thread
    /// already has an active writer"), and its shared daemon keeps a thread up to 30 minutes after its tab closed
    /// (P1440). Read from what the run itself said, never by taking the lock.
    var heldElsewhere: Bool {
        guard output.provider == .codex, status != 0 || output.reportedFailure != nil else { return false }
        let said = [output.reportedFailure ?? "", errorTail].joined(separator: "\n")
        return said.range(of: "active writer", options: .caseInsensitive) != nil
    }

    /// The card's line when Codex still holds the conversation.
    public static let heldElsewhereWords = "Codex still holds this conversation; try again later"

    /// The card's line for a run that ended badly; nil for one that ended well (P1331).
    var problem: String? {
        if status == 0, output.reportedFailure == nil { return nil }
        if heldElsewhere { return Self.heldElsewhereWords }
        let reason = output.reportedFailure ?? Self.firstLine(errorTail) ?? "it stopped with an error (\(status))"
        return "Failed · " + Self.cut(reason)
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// One line of at most 120 characters.
    static func cut(_ text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

/// Why a run did not start.
public enum ResumeStartError: Error, Equatable, Sendable {
    /// The CLI is not on the login shell's PATH.
    case toolMissing(String)
    /// The process could not be started.
    case couldNotStart
}

/// One run, as the resumer drives it: the live process, or a test's stand-in.
public protocol ResumeProcess: AnyObject, Sendable {
    /// Its process id: the island tells its own runs' hook notes from the agent's own process by it.
    var pid: Int32 { get }
    var hasExited: Bool { get }
    /// SIGINT: Claude Code and Codex end the turn, then exit.
    func interrupt()
    /// SIGTERM.
    func terminate()
    /// How it ended, once it has.
    func exit() async -> ResumeExit
}

/// The live run: the CLI found on the login shell's PATH, in the session's folder, the text on stdin then EOF, stdout
/// read line by line into a `ResumeOutput` (a line over 8 MB is skipped) and the end of stderr kept. Only the app's own
/// resumer starts one (`SessionResumer`), on the owner's Return; a headless engine has none.
final class LiveResumeProcess: ResumeProcess, @unchecked Sendable {
    static let lineLimit = 8 * 1_024 * 1_024
    static let errorLimit = 4_096

    private let process = Process()
    private let lock = NSLock()
    private var output: ResumeOutput
    private var pending = Data()
    private var skippingLine = false
    private var errorTail = Data()
    private var ended: ResumeExit?
    private var waiters: [CheckedContinuation<ResumeExit, Never>] = []
    private(set) var pid: Int32 = 0

    private init(provider: Provider) {
        output = ResumeOutput(provider: provider)
    }

    /// Starts `command`. Runs off the main thread: the first search for the CLI asks the login shell.
    static let start: @Sendable (ResumeCommand) throws -> any ResumeProcess = { command in
        guard let executable = ToolLocator.locate(command.tool) else { throw ResumeStartError.toolMissing(command.tool) }
        var environment = command.environment
        if environment["PATH"] == nil { environment["PATH"] = ToolLocator.loginShellPATH() }
        return try start(command, executable: executable, environment: environment)
    }

    /// Starts `command` as `executable` with `environment` as given.
    static func start(_ command: ResumeCommand, executable: URL, environment: [String: String]) throws -> LiveResumeProcess {
        let run = LiveResumeProcess(provider: command.provider)
        try run.launch(executable: executable, command: command, environment: environment)
        return run
    }

    private func launch(executable: URL, command: ResumeCommand, environment: [String: String]) throws {
        let input = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = command.arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: command.folder, isDirectory: true)
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.readOutput(handle.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.readError(handle.availableData) }
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ResumeStartError.couldNotStart
        }
        pid = process.processIdentifier
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        // A child that exits before reading would raise SIGPIPE in the app; this makes the write fail instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForWriting.write(contentsOf: Data(command.input.utf8))
        try? input.fileHandleForWriting.close()
    }

    var hasExited: Bool { lock.withLock { ended != nil } }

    func interrupt() {
        guard !hasExited, process.isRunning else { return }
        process.interrupt()
    }

    func terminate() {
        guard !hasExited, process.isRunning else { return }
        process.terminate()
    }

    func exit() async -> ResumeExit {
        await withCheckedContinuation { continuation in
            let done: ResumeExit? = lock.withLock {
                if let ended { return ended }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    private func readOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { takeOutput(data) }
    }

    /// Must be called while `lock` is held.
    private func takeOutput(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if skippingLine {
                skippingLine = false
            } else {
                output.take(String(decoding: line, as: UTF8.self))
            }
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > Self.lineLimit {
            pending.removeAll()
            skippingLine = true
        }
    }

    private func readError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { keepError(data) }
    }

    /// Must be called while `lock` is held.
    private func keepError(_ data: Data) {
        errorTail.append(data)
        if errorTail.count > Self.errorLimit { errorTail = Data(errorTail.suffix(Self.errorLimit)) }
    }

    /// The child has exited: whatever it wrote is in the pipes already, so they are drained without waiting for an
    /// EOF a grandchild may hold off (an MCP server Claude started), and a last line with no newline is read too.
    private func finish(status: Int32, stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let rest = Self.drain(stdout.fileHandleForReading.fileDescriptor)
        let restError = Self.drain(stderr.fileHandleForReading.fileDescriptor)
        let (result, waiting): (ResumeExit, [CheckedContinuation<ResumeExit, Never>]) = lock.withLock {
            takeOutput(rest)
            if !skippingLine, !pending.isEmpty { output.take(String(decoding: pending, as: UTF8.self)) }
            pending.removeAll()
            keepError(restError)
            let result = ResumeExit(status: status, output: output, errorTail: String(decoding: errorTail, as: UTF8.self))
            ended = result
            let waiting = waiters
            waiters = []
            return (result, waiting)
        }
        for waiter in waiting { waiter.resume(returning: result) }
    }

    /// Everything already in `fd`, without waiting for EOF.
    private static func drain(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while collected.count < lineLimit {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        return collected
    }
}
