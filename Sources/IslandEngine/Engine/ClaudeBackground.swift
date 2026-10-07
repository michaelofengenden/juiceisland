import Darwin
import Foundation
import JuiceCore

/// Claude Code's own background sessions (wave 8, P1450 to P1484). A session moved there with `/background` (or started with
/// `claude --bg`) runs under Claude Code's supervisor, one per config folder, so it keeps working when its window closes.
/// The island follows it through its hooks, as any session, and through `claude agents --json`, the documented way to
/// read background sessions from outside Claude Code. Nothing here starts, attaches, stops or types into a session by
/// itself: every command but the list runs on the owner's click (`ClaudeBackgrounder`), and a headless engine runs only
/// injected stand-ins.

/// One row of `claude agents --json --all` (code.claude.com/docs/en/agent-view, "List sessions as JSON"): `cwd`, `kind`
/// and `startedAt` always; `id` (the short id `attach`, `logs` and `stop` take) and `state` for background sessions;
/// `pid` and `status` while the process lives; `waitingFor` while `status` is `waiting`; `sessionId` and `name` when set.
public struct ClaudeBackgroundEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case background
        case interactive
        case other(String)
    }

    public var id: String?
    /// The conversation's full id: the island's session id.
    public var sessionID: String?
    public var kind: Kind
    /// `working`, `blocked`, `done`, `failed` or `stopped`.
    public var state: String?
    /// `busy`, `waiting` or `idle`, while its process lives.
    public var status: String?
    public var waitingFor: String?
    public var pid: Int32?
    public var cwd: String?
    public var name: String?
    public var startedAt: Date?

    public init(id: String? = nil, sessionID: String? = nil, kind: Kind, state: String? = nil, status: String? = nil,
                waitingFor: String? = nil, pid: Int32? = nil, cwd: String? = nil, name: String? = nil, startedAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.state = state
        self.status = status
        self.waitingFor = waitingFor
        self.pid = pid
        self.cwd = cwd
        self.name = name
        self.startedAt = startedAt
    }

    public var isBackground: Bool { kind == .background }
    /// A turn runs in it right now.
    public var isBusy: Bool { status == "busy" }
    /// It waits on a person: a permission prompt, a question, a dialog. Typing into it would answer that, not reply.
    public var waitsOnSomeone: Bool { status == "waiting" || ExactJump.nonEmpty(waitingFor) != nil }
    /// Stopped or failed: its process is not coming back by itself.
    public var hasEnded: Bool { state == "stopped" || state == "failed" }
}

public enum ClaudeBackgroundList {
    /// The rows of `claude agents --json`, or nil when the output is not a JSON array (an older Claude Code, agent view
    /// turned off, an error). A row without a `kind` is skipped.
    public static func parse(_ data: Data) -> [ClaudeBackgroundEntry]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return rows.compactMap { row in
            guard let object = row as? [String: Any], let kind = object["kind"] as? String else { return nil }
            let started = (object["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1_000) }
            return ClaudeBackgroundEntry(
                id: (object["id"] as? String).flatMap(ExactJump.nonEmpty),
                sessionID: (object["sessionId"] as? String).flatMap(ExactJump.nonEmpty),
                kind: kind == "background" ? .background : kind == "interactive" ? .interactive : .other(kind),
                state: object["state"] as? String, status: object["status"] as? String,
                waitingFor: object["waitingFor"] as? String,
                pid: (object["pid"] as? NSNumber).map { Int32(truncating: $0) },
                cwd: object["cwd"] as? String, name: object["name"] as? String, startedAt: started)
        }
    }

    /// The text before the JSON: `--bg` may print "Starting background service…" first, and a list is read from its
    /// first `[`.
    public static func parse(output: String) -> [ClaudeBackgroundEntry]? {
        guard let start = output.firstIndex(of: "[") else { return nil }
        return parse(Data(output[start...].utf8))
    }

    /// The short id `claude --bg` printed ("backgrounded · 7c5dcf5d" or "backgrounded · 7c5dcf5d · name"), nil when it
    /// did not say it backgrounded anything.
    public static func backgroundedID(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            guard words.count >= 2, words[0].hasSuffix("backgrounded"), ClaudeBackgroundCommand.isShortID(words[1]) else { continue }
            return words[1]
        }
        return nil
    }
}

/// One command of Claude Code's background family, as the app runs it: `claude agents --json --all` (the list),
/// `claude attach <id>` (in a pseudo-terminal of the app's for a reply, or typed into a new window for Open in
/// terminal), `claude stop <id>`, and `claude --bg` (a session Juice starts). The owner's text is never an argument:
/// a reply is typed into the attached session.
///
/// The environment is the resume's allowlist (`ResumeCommand.make`, P1326), without the island's skip switches: the
/// first of these commands may start Claude Code's supervisor, whose background sessions would then skip the island's
/// hooks for good. HOME, USER, LOGNAME, LANG, TMPDIR, SHELL, the ssh agent's socket, `TERM=xterm-256color` (a session
/// the supervisor starts draws for the terminals that attach to it), PATH from the login shell (added as it starts, off
/// the main thread), and the profile's folder variable unless it is the default folder: the supervisor is per folder.
public struct ClaudeBackgroundCommand: Equatable, Sendable {
    public enum Verb: Equatable, Sendable {
        case list
        case attach(String)
        case stop(String)
        case start
    }

    public var verb: Verb
    public var tool = "claude"
    public var arguments: [String]
    public var environment: [String: String]
    /// The session's folder: attach and start run there (a stopped session wakes in the folder it runs in).
    public var folder: String?

    /// What a session Juice starts runs with: it edits the folder it was opened in, as `claude` there would, instead of a
    /// worktree of its own (Claude Code isolates `--bg` sessions by default; `worktree.bgIsolation`, any settings file).
    public static let startSettings = #"{"worktree":{"bgIsolation":"none"}}"#

    public static func make(_ verb: Verb, profile: String, folder: String? = nil, inherited: [String: String],
                            home: String = NSHomeDirectory(), user: String = NSUserName(),
                            temporary: String = NSTemporaryDirectory()) -> ClaudeBackgroundCommand {
        var environment: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "LANG": "en_US.UTF-8",
            "TMPDIR": temporary,
            "TERM": "xterm-256color",
            "SHELL": inherited["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh",
        ]
        if let socket = inherited["SSH_AUTH_SOCK"], !socket.isEmpty { environment["SSH_AUTH_SOCK"] = socket }
        if let variable = ResumeCommand.folderVariable(provider: .claude, profile: profile, home: home) {
            environment[Provider.claude.folderEnvironmentKey] = variable
        }
        let arguments: [String] = switch verb {
        case .list: ["agents", "--json", "--all"]
        case let .attach(id): ["attach", id]
        case let .stop(id): ["stop", id]
        case .start: ["--bg", "--settings", startSettings]
        }
        return ClaudeBackgroundCommand(verb: verb, arguments: arguments, environment: environment,
                                       folder: folder.map(ResumeCommand.expanded))
    }

    /// The line Open in terminal types into a new window for a background session (P703, P1330): into its folder, then
    /// `claude attach '<id>'` with the profile's folder variable unless it is the default folder. Closing that window
    /// detaches; the session keeps running ("The session keeps running either way", `claude attach --help`).
    public static func attachLine(shortID: String, folder: String, profile: String, home: String = NSHomeDirectory()) -> String {
        let run = "claude attach \(FreshSessionLaunch.quoted(shortID))"
        let withProfile = ResumeCommand.folderVariable(provider: .claude, profile: profile, home: home)
            .map { "\(Provider.claude.folderEnvironmentKey)=\(FreshSessionLaunch.quoted($0)) \(run)" } ?? run
        return "cd \(FreshSessionLaunch.quoted(ResumeCommand.expanded(folder))) && \(withProfile)"
    }

    /// A short id fit for a command line: letters, digits, `-` and `_` only, as `claude --bg` prints them.
    public static func isShortID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    /// Whether the profile's supervisor has kept a roster: it has run there at least once. Only the file's presence is
    /// looked at (`stat`), never what it holds; a list is read at launch only for such a profile.
    public static func hasRoster(profile: String) -> Bool {
        FileManager.default.fileExists(atPath: ResumeCommand.expanded(profile) + "/daemon/roster.json")
    }
}

/// How a command of the family ended: its exit status and what it printed (stdout whole up to 1 MB, the end of stderr).
public struct ClaudeCommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var errorTail: String

    public init(status: Int32, output: String, errorTail: String = "") {
        self.status = status
        self.output = output
        self.errorTail = errorTail
    }
}

/// Whether the live commands may run in this process: never in a test process, whatever its engine (P1475). Several
/// wiring rigs make an engine of the app's kind (`startBridge`) whose other seams are stand-ins; none of them may
/// reach a real `claude agents`, `attach`, `stop` or `--bg` through a backgrounder they did not give stand-ins.
enum ClaudeLive {
    static let allowed: Bool = !TestProcess.isRunning
}

/// Runs one command of the family to its end (the list, stop, start), never the attach: `claude` found on the login
/// shell's PATH, stdin closed, at most `timeout` seconds (then SIGTERM to that child, which the app started). Off the
/// main thread. Only the app's own `ClaudeBackgrounder` runs it; the hand-over's `claude --version` and `--desktop`
/// (`HandoffRun`) run through the same `run` (P1531).
enum ClaudeCommandRun {
    static let outputLimit = 1 << 20
    static let errorLimit = 4_096

    static let live: @Sendable (ClaudeBackgroundCommand, TimeInterval) -> ClaudeCommandResult? = { command, timeout in
        guard ClaudeLive.allowed, let executable = ToolLocator.locate(command.tool) else { return nil }
        var environment = command.environment
        if environment["PATH"] == nil { environment["PATH"] = ToolLocator.loginShellPATH() }
        return run(executable: executable, arguments: command.arguments, environment: environment, folder: command.folder,
                   timeout: timeout)
    }

    /// One CLI run to its end: nil when it could not start. What it wrote is drained without waiting for an end of file:
    /// a supervisor that `claude agents` started holds the pipes' other ends open long after the command has exited.
    static func run(executable: URL, arguments: [String], environment: [String: String], folder: String?,
                    timeout: TimeInterval) -> ClaudeCommandResult? {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let collected = LockedBytes(), errors = LockedBytes()
        stdout.fileHandleForReading.readabilityHandler = { collected.append($0.availableData, limit: outputLimit) }
        stderr.fileHandleForReading.readabilityHandler = { errors.append($0.availableData, limit: errorLimit, keepEnd: true) }
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = ended.wait(timeout: .now() + 2)
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        // Whatever it wrote is in the pipes: drained without waiting for an EOF the supervisor it started may hold off.
        collected.append(drain(stdout.fileHandleForReading.fileDescriptor), limit: outputLimit)
        errors.append(drain(stderr.fileHandleForReading.fileDescriptor), limit: errorLimit, keepEnd: true)
        return ClaudeCommandResult(status: process.isRunning ? -1 : process.terminationStatus,
                                   output: String(decoding: collected.bytes, as: UTF8.self),
                                   errorTail: String(decoding: errors.bytes, as: UTF8.self))
    }

    static func drain(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while collected.count < outputLimit {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        return collected
    }
}

/// Bytes collected from several threads, kept to a limit.
final class LockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data, limit: Int, keepEnd: Bool = false) {
        guard !more.isEmpty else { return }
        lock.withLock {
            if keepEnd {
                data.append(more)
                if data.count > limit { data = Data(data.suffix(limit)) }
            } else if data.count < limit {
                data.append(more.prefix(limit - data.count))
            }
        }
    }

    var bytes: Data { lock.withLock { data } }
}

// MARK: The attach a reply goes through

/// What an attached session showed so far: how many bytes came, and the end of them as plain text (escape sequences
/// dropped), for a line that says why it did not go.
public struct AttachSeen: Equatable, Sendable {
    public var bytes: Int
    public var tail: String

    public init(bytes: Int = 0, tail: String = "") {
        self.bytes = bytes
        self.tail = tail
    }
}

/// `claude attach <id>` in a pseudo-terminal the app owns, no window anywhere: the live one, or a test's stand-in.
public protocol ClaudeAttachTerminal: AnyObject, Sendable {
    var pid: Int32 { get }
    var hasExited: Bool { get }
    func seen() -> AttachSeen
    /// Writes to the terminal, as keys typed into it. False when it could not.
    func write(_ bytes: [UInt8]) -> Bool
    /// Closes the terminal's side the app holds: the attach is hung up, as when its window closes.
    func hangUp()
    /// SIGTERM to the attach, the app's own child (and SIGCONT first, so a stopped one takes it).
    func terminate()
    /// SIGKILL to the attach, the app's own child, when nothing else ended it: never the session, which runs under
    /// Claude Code's supervisor.
    func kill()
}

/// How a reply through the attach went.
public enum AttachOutcome: Equatable, Sendable {
    /// The text and its Return were typed into the attached session, and the attach let go.
    case sent
    /// The session never settled at its prompt: nothing was typed.
    case notReady(String?)
    /// The attach ended before anything was typed (Claude Code refused it): its last words.
    case ended(String?)
    /// The terminal took no text.
    case notWritten
}

/// The reply's own steps through the attach (P1460): wait until the session has drawn itself and gone quiet, type the
/// line (one line, no control character: `ReplySender.line`), a short pause, Return as a key of its own (a burst that
/// ends in a line end reads as pasted text), then let go with Ctrl+Z, which detaches an attach started from a shell and
/// leaves the session running (`claude attach --help`). An attach that does not end by itself is hung up, then
/// terminated: either way the session keeps running. Every wait is counted in looks of `tick`, never the wall clock, so
/// a loaded Mac makes it slower, never wrong (P293).
enum AttachReply {
    struct Timing: Equatable, Sendable {
        var tick: Duration = .milliseconds(100)
        /// Looks with no new output before the session counts as settled at its prompt.
        var settle = 12
        /// Looks before anything is typed, whatever it showed: a cold attach shows the transcript while its process
        /// starts.
        var minimum = 20
        /// Looks before it gives up waiting for the prompt.
        var readyLimit = 300
        /// Looks between the text and its Return.
        var pause = 3
        /// Looks it waits for the Return to show anything.
        var react = 30
        /// Looks it waits for the attach to end after Ctrl+Z, and again after the hang-up.
        var exit = 30
    }

    static let controlZ: UInt8 = 0x1A
    static let carriageReturn: UInt8 = 0x0D

    static func send(_ line: String, through terminal: any ClaudeAttachTerminal, timing: Timing = Timing(),
                     sleep: @Sendable (Duration) async -> Void) async -> AttachOutcome {
        var looks = 0, quiet = 0, last = -1
        while true {
            if terminal.hasExited { return .ended(ExactJump.nonEmpty(terminal.seen().tail)) }
            let seen = terminal.seen()
            if seen.bytes != last {
                last = seen.bytes
                quiet = 0
            } else {
                quiet += 1
            }
            if seen.bytes > 0, looks >= timing.minimum, quiet >= timing.settle { break }
            if looks >= timing.readyLimit {
                await letGo(terminal, timing: timing, sleep: sleep, detach: false)
                return .notReady(ExactJump.nonEmpty(seen.tail))
            }
            await sleep(timing.tick)
            looks += 1
        }
        guard terminal.write(Array(line.utf8)) else {
            await letGo(terminal, timing: timing, sleep: sleep, detach: false)
            return .notWritten
        }
        for _ in 0..<timing.pause { await sleep(timing.tick) }
        guard terminal.write([carriageReturn]) else {
            await letGo(terminal, timing: timing, sleep: sleep, detach: false)
            return .notWritten
        }
        let before = terminal.seen().bytes
        for _ in 0..<timing.react where terminal.seen().bytes == before && !terminal.hasExited { await sleep(timing.tick) }
        await letGo(terminal, timing: timing, sleep: sleep, detach: true)
        return .sent
    }

    /// Ctrl+Z (when `detach`; in `claude attach` it detaches back to the shell, agent-view docs), then a hang-up, then
    /// SIGTERM, then SIGKILL, each only while the attach still runs: no attach of the app's outlives its reply (P1460).
    static func letGo(_ terminal: any ClaudeAttachTerminal, timing: Timing, sleep: @Sendable (Duration) async -> Void,
                      detach: Bool) async {
        if detach, !terminal.hasExited, terminal.write([controlZ]) {
            for _ in 0..<timing.exit where !terminal.hasExited { await sleep(timing.tick) }
        }
        guard !terminal.hasExited else { return terminal.hangUp() }
        terminal.hangUp()
        for _ in 0..<timing.exit where !terminal.hasExited { await sleep(timing.tick) }
        guard !terminal.hasExited else { return }
        terminal.terminate()
        for _ in 0..<timing.exit where !terminal.hasExited { await sleep(timing.tick) }
        if !terminal.hasExited { terminal.kill() }
    }

    /// Plain text out of a terminal's bytes: escape sequences and control characters dropped, the last line kept.
    static func plainTail(_ bytes: Data, limit: Int = 160) -> String {
        let all = [UInt8](bytes)
        var kept: [UInt8] = []
        var index = 0
        while index < all.count {
            let byte = all[index]
            if byte == 0x1B {
                // CSI (ESC [ … final byte), OSC (ESC ] … BEL or ESC), or a two-byte escape.
                guard index + 1 < all.count else { break }
                var end = index + 2
                switch all[index + 1] {
                case 0x5B:
                    while end < all.count, !(0x40...0x7E).contains(all[end]) { end += 1 }
                    end += 1
                case 0x5D:
                    while end < all.count, all[end] != 0x07, all[end] != 0x1B { end += 1 }
                    end += 1
                default:
                    break
                }
                index = end
                continue
            }
            if byte == 0x0A || byte == 0x0D {
                kept.append(0x0A)
            } else if byte >= 0x20 || byte == 0x09 {
                kept.append(byte)
            }
            index += 1
        }
        let text = String(decoding: kept, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.suffix(limit)) : line
    }
}

/// The live attach: `claude attach <id>` on a pseudo-terminal (`openpty`, 120 by 40) whose other side the app reads
/// and writes, so no window shows. The child gets the terminal's side as its stdin, stdout and stderr and nothing else
/// of the app's (`Process` closes the rest). Its output is read and counted, the last 8 KB kept for its tail; nothing of
/// it is logged or stored. Only `ClaudeBackgrounder` starts one, for a reply the owner sent.
final class LiveAttachTerminal: ClaudeAttachTerminal, @unchecked Sendable {
    static let keep = 8 * 1_024
    static let queue = DispatchQueue(label: "juice-island.attach", qos: .userInitiated)

    private let process = Process()
    private let lock = NSLock()
    /// The app's side of the terminal; -1 once closed.
    private var master: Int32 = -1
    private var count = 0
    private var recent = Data()
    private var exited = false
    private var reader: (any DispatchSourceRead)?
    private(set) var pid: Int32 = 0

    /// Starts `command`. Off the main thread: the first search for the CLI asks the login shell.
    static let start: @Sendable (ClaudeBackgroundCommand) throws -> any ClaudeAttachTerminal = { command in
        guard ClaudeLive.allowed else { throw ResumeStartError.couldNotStart }
        guard let executable = ToolLocator.locate(command.tool) else { throw ResumeStartError.toolMissing(command.tool) }
        var environment = command.environment
        if environment["PATH"] == nil { environment["PATH"] = ToolLocator.loginShellPATH() }
        return try LiveAttachTerminal(executable: executable, arguments: command.arguments, environment: environment,
                                      folder: command.folder)
    }

    init(executable: URL, arguments: [String], environment: [String: String], folder: String?, rows: UInt16 = 40,
         columns: UInt16 = 120) throws {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ResumeStartError.couldNotStart }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let child = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        process.standardInput = child
        process.standardOutput = child
        process.standardError = child
        let lock = self.lock
        process.terminationHandler = { [weak self] _ in lock.withLock { self?.exited = true } }
        do {
            try process.run()
        } catch {
            close(slave)
            close(master)
            throw ResumeStartError.couldNotStart
        }
        close(slave)
        self.master = master
        pid = process.processIdentifier
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: Self.queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // The descriptor closes only once its reader is done with it.
        source.setCancelHandler { [weak self] in
            self?.lock.withLock { self?.master = -1 }
            close(master)
        }
        reader = source
        source.resume()
    }

    deinit { reader?.cancel() }

    private func readAvailable() {
        let fd = lock.withLock { master }
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard read > 0 else {
            // The child closed its side (it exited): nothing more comes.
            if read == 0 || errno != EAGAIN { reader?.cancel() }
            return
        }
        lock.withLock {
            count += read
            recent.append(contentsOf: buffer[0..<read])
            if recent.count > Self.keep { recent = Data(recent.suffix(Self.keep)) }
        }
    }

    var hasExited: Bool { lock.withLock { exited } }

    func seen() -> AttachSeen {
        let (bytes, recent) = lock.withLock { (count, self.recent) }
        return AttachSeen(bytes: bytes, tail: AttachReply.plainTail(recent))
    }

    func write(_ bytes: [UInt8]) -> Bool {
        let fd = lock.withLock { master }
        guard fd >= 0, !hasExited, !bytes.isEmpty else { return false }
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    func hangUp() { reader?.cancel() }

    func terminate() {
        guard !hasExited, process.isRunning, pid > 0 else { return }
        // A stopped process holds a SIGTERM until it runs again.
        _ = Darwin.kill(pid, SIGCONT)
        process.terminate()
    }

    func kill() {
        guard !hasExited, process.isRunning, pid > 0 else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }
}

/// The terminals attached to a background session: this user's processes running `claude attach <id>` (argv only,
/// through `sysctl`, as `AgentProcessScan` reads them; nothing kept). Off the main thread.
enum ClaudeAttachScan {
    static let live: @Sendable (String) -> [Int32] = { shortID in ClaudeLive.allowed ? pids(attaching: shortID) : [] }

    static func pids(attaching shortID: String) -> [Int32] {
        guard ClaudeBackgroundCommand.isShortID(shortID) else { return [] }
        var buffer = [UInt8](repeating: 0, count: AgentProcessScan.argumentLimit())
        let own = getpid()
        return AgentProcessScan.userPIDs().filter { pid in
            pid != own && (AgentProcessScan.arguments(of: pid, buffer: &buffer).map { attaches($0, shortID) } ?? false)
        }
    }

    /// `… claude attach <id>`: the word `attach` followed by the id.
    static func attaches(_ arguments: [String], _ shortID: String) -> Bool {
        guard arguments.count >= 2 else { return false }
        return zip(arguments, arguments.dropFirst()).contains { $0 == "attach" && $1 == shortID }
    }
}
