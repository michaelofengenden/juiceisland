import Darwin
import Foundation
import OpenIslandCore

/// What the superset helper does before it hands over to upstream's helper, unchanged (spec §3.2, §3.8).
///
/// Upstream's `OpenIslandHooksCLI.main()` reads the hook's input from stdin itself. So the prelude reads it first,
/// sends the context note, and puts the same bytes back on stdin through a pipe; upstream then reads, decodes, waits
/// for the bridge and writes stdout exactly as it would alone. When hooks are skipped (`OPEN_ISLAND_SKIP_HOOKS`,
/// `VIBE_ISLAND_SKIP`) the prelude touches nothing, and upstream returns before reading, as before.
///
/// Three kinds of hook never reach upstream's helper (the needs-you pipeline):
/// - a PermissionRequest from `--source claude` or `codex` goes to the engine's request broker
///   (`HookBrokerClient`), which says whether it is held and, on the owner's click only, what to answer; with no
///   broker socket at all, upstream's helper runs as before (C16);
/// - any other Codex hook from a subagent (`agent_id` set) sends its note and ends silent: upstream's payload drops
///   `agent_id` and its bridge would file the child's `transcript_path` and prompt under the root session, so the
///   root's rollout would no longer be followed (C5, P167). Upstream only acknowledges the events a child fires
///   (UserPromptSubmit; its PermissionRequest is the broker's), so nothing is lost;
/// - a Codex PreToolUse (never registered today) ends with its note too: upstream's bridge would hold every call as an
///   approval (P161).
public enum HookPrelude {
    public struct IO: Sendable {
        /// Prepares the pipe that will stand in for stdin; nil when it cannot, and then stdin is left alone.
        public var preparePipe: @Sendable () -> StdinPipe?
        public var readStandardInput: @Sendable () -> Data
        public var agentPID: @Sendable () -> Int32?
        public var send: @Sendable (Data, URL) -> Void
        /// Hands a request line to the broker at the URL and waits for its answer.
        public var broker: @Sendable (Data, URL, String) -> HookBrokerClient.Outcome
        /// Whether the agent at the pid (or the helper, without one) has a controlling terminal.
        public var hasTerminal: @Sendable (Int32?) -> Bool

        public init(preparePipe: @escaping @Sendable () -> StdinPipe?, readStandardInput: @escaping @Sendable () -> Data,
                    agentPID: @escaping @Sendable () -> Int32?, send: @escaping @Sendable (Data, URL) -> Void,
                    broker: @escaping @Sendable (Data, URL, String) -> HookBrokerClient.Outcome = { line, url, source in
                        HookBrokerClient.run(line, to: url, source: source)
                    },
                    hasTerminal: @escaping @Sendable (Int32?) -> Bool = { _ in false }) {
            self.preparePipe = preparePipe
            self.readStandardInput = readStandardInput
            self.agentPID = agentPID
            self.send = send
            self.broker = broker
            self.hasTerminal = hasTerminal
        }

        /// The real process: fd 0, `sysctl` for the agent, a non-blocking datagram, the broker's socket.
        public static let process = IO(
            preparePipe: { StdinPipe.make() },
            readStandardInput: { FileHandle.standardInput.readDataToEndOfFile() },
            agentPID: { ProcessTree.agentPID(startingAt: getppid(), table: SystemProcessTable()) },
            send: { data, url in HookNoteSender.send(data, to: url) },
            hasTerminal: { pid in ProcessTree.tty(forPID: pid ?? getpid(), table: SystemProcessTable()) != nil })
    }

    public enum Outcome: Equatable, Sendable {
        /// Hooks are skipped for this process: stdin untouched, no note.
        case skipped
        /// No pipe could be made: stdin untouched, no note.
        case untouched
        /// stdin was read and put back for upstream's helper; `note` is what was sent, nil when the input named no
        /// event and session.
        case forwarded(note: HookContextNote?)
        /// Upstream's helper must not run: print `output` when there is one, and exit 0.
        case finished(note: HookContextNote?, output: Data?)
    }

    /// The sources whose PermissionRequest goes to the broker; every other source keeps upstream's path.
    public static let brokeredSources: Set<String> = ["claude", "codex"]

    @discardableResult
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment,
                           arguments: [String] = CommandLine.arguments, io: IO = .process) -> Outcome {
        if HookSkipConfiguration.shouldSkipHooks(environment: environment) { return .skipped }
        guard let pipe = io.preparePipe() else { return .untouched }
        let input = io.readStandardInput()
        // Upstream's helper takes a missing `--source` as Codex, and upstream's installer writes none for Codex's hooks:
        // the note says so, so the engine's Codex checks match Codex's own notes (P290).
        let source = Self.source(in: arguments) ?? HookContextNote.codexSource
        let object = input.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        let pid = object == nil ? nil : io.agentPID()
        let note = object.flatMap { HookContextNote.make(object: $0, environment: environment, agentPID: pid, source: source) }
        if let data = note?.encoded() { io.send(data, HookNoteSocket.helperURL(environment: environment)) }

        if let object, object["hook_event_name"] as? String == "PermissionRequest", brokeredSources.contains(source) {
            let line = HookRequestLine(source: source, input: input,
                                       digest: object["tool_input"].flatMap(HookInputDigest.of),
                                       entrypoint: environment["CLAUDE_CODE_ENTRYPOINT"].flatMap { $0.isEmpty || $0.utf8.count > 32 ? nil : $0 },
                                       agentPID: pid, hostBundleID: note?.hostBundleID, hasTerminal: io.hasTerminal(pid))
            // Too large, or not an object: nothing is held and nothing decided; the agent's own prompt decides.
            guard input.count <= HookRequestLine.inputLimit, let data = line.encoded() else {
                return .finished(note: note, output: nil)
            }
            switch io.broker(data, HookRequestSocket.helperURL(environment: environment), source) {
            case .noBroker:
                break
            case .silent:
                return .finished(note: note, output: nil)
            case let .output(output):
                return .finished(note: note, output: output)
            }
        }
        if let object, source == "codex", let agent = object["agent_id"] as? String, !agent.isEmpty {
            return .finished(note: note, output: nil)
        }
        // Upstream's bridge turns a Codex PreToolUse into a held "Run Bash command" approval for every call (P161): it
        // is never registered today, and should it ever be, it ends with its note (no decision: Codex goes on).
        if let object, source == "codex", object["hook_event_name"] as? String == "PreToolUse" {
            return .finished(note: note, output: nil)
        }
        pipe.refill(with: input)
        return .forwarded(note: note)
    }

    /// The value after `--source`, as upstream's helper reads it.
    static func source(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--source"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// A pipe that takes the place of stdin (fd 0, or `target` in tests) once the original input has been read. A
/// writer thread fills it and closes it, so input of any size reaches the reader, followed by end of file.
public final class StdinPipe: @unchecked Sendable {
    private let readEnd: Int32
    private let writeEnd: Int32
    private let target: Int32

    private init(readEnd: Int32, writeEnd: Int32, target: Int32) {
        self.readEnd = readEnd
        self.writeEnd = writeEnd
        self.target = target
    }

    /// Made before stdin is read, so a failure leaves stdin as it was. nil when the target is not open: the pipe's
    /// read end would then take its number, and reading "stdin" would wait on this pipe forever.
    public static func make(replacing target: Int32 = STDIN_FILENO) -> StdinPipe? {
        guard target >= 0, fcntl(target, F_GETFD) != -1 else { return nil }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        // Both ends above the standard descriptors, so a closed stdout or stderr never becomes this pipe.
        let readEnd = fcntl(fds[0], F_DUPFD_CLOEXEC, 3)
        let writeEnd = fcntl(fds[1], F_DUPFD_CLOEXEC, 3)
        close(fds[0])
        close(fds[1])
        guard readEnd >= 0, writeEnd >= 0 else {
            if readEnd >= 0 { close(readEnd) }
            if writeEnd >= 0 { close(writeEnd) }
            return nil
        }
        // Upstream always reads to the end, but a write to a closed pipe must never raise SIGPIPE in a hook.
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        return StdinPipe(readEnd: readEnd, writeEnd: writeEnd, target: target)
    }

    /// Puts the pipe in place of the target descriptor and starts the writer.
    public func refill(with data: Data) {
        var placed: Int32
        repeat { placed = dup2(readEnd, target) } while placed < 0 && errno == EINTR
        close(readEnd)
        let writeEnd = self.writeEnd
        let writer = Thread {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(writeEnd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            close(writeEnd)
        }
        writer.name = "HookPrelude.stdin"
        writer.start()
    }
}
