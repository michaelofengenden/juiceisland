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
/// These hooks never reach upstream's helper:
/// - Cursor's own hooks (`--source cursor`): the helper sends each to the bridge and prints nothing, so no `allow` of
///   upstream's bridge ever reaches Cursor (Watch, P930);
/// - a Claude-format hook from GitHub Copilot CLI or Devin CLI, and a `--source claude` hook another agent ran
///   (`HookCaller`): `ClaudeFamilyRunner` sends it to the bridge and answers in the agent's own words, or, for an approval
///   the agent would not follow, ends silent (P905 to P909);
/// - a PermissionRequest from `--source claude` or `codex` goes to the engine's request broker
///   (`HookBrokerClient`), which says whether it is held and, on the owner's click only, what to answer; with no
///   broker socket at all, upstream's helper runs as before (C16);
/// - any other Codex hook from a subagent (`agent_id` set) sends its note and ends silent: upstream's payload drops
///   `agent_id` and its bridge would file the child's `transcript_path` and prompt under the root session, so the
///   root's rollout would no longer be followed (C5, P167). Upstream only acknowledges the events a child fires
///   (UserPromptSubmit; its PermissionRequest is the broker's), so nothing is lost;
/// - a Codex PreToolUse (never registered today) ends with its note too: upstream's bridge would hold every call as an
///   approval (P161);
/// - Gemini CLI's tool events (note only), Antigravity CLI's hooks (told to the bridge in Gemini CLI's words), a Claude
///   hook Grok Build ran (told to the bridge as Grok's) and a Cursor hook Grok ran (nothing): all Watch, nothing printed
///   (`watchAgent`, P1101, P1106, P1111).
///
/// A helper installed in a `HookHome` sends its notes and requests to its home's sockets, and `main` points upstream's
/// half at its home's bridge (P900).
public enum HookPrelude {
    public struct IO: Sendable {
        /// Prepares the pipe that will stand in for stdin; nil when it cannot, and then stdin is left alone.
        public var preparePipe: @Sendable () -> StdinPipe?
        public var readStandardInput: @Sendable () -> Data
        public var agentPID: @Sendable () -> Int32?
        public var send: @Sendable (Data, URL) -> Void
        /// Hands a request line to the broker at the URL and waits for its answer. Only `.process` dials the broker: an IO
        /// made any other way finds none unless it says otherwise, so no test reaches a live app's requests (P929).
        public var broker: @Sendable (Data, URL, String) -> HookBrokerClient.Outcome
        /// Whether the agent at the pid (or the helper, without one) has a controlling terminal.
        public var hasTerminal: @Sendable (Int32?) -> Bool
        /// The helper's home (`HookHome.of(helperExecutable:)`, P900): where its notes, requests and bridge go. nil for
        /// a helper at any other path, which keeps the sockets it always used.
        public var home: @Sendable () -> HookHome?
        /// The agent process's short name, for caller detection (P905).
        public var agentName: @Sendable (Int32?) -> String?
        /// The agent process's executable, for an agent whose process is a plain `node` (the Cursor CLI, P905).
        public var agentPath: @Sendable (Int32?) -> String?
        /// Whether this agent's own config carries Juice's hooks, so a Claude-format hook it also runs from Claude's
        /// settings would bring each event twice (P909).
        public var ownHooksConnected: @Sendable (AgentKind) -> Bool
        /// Sends one command to the bridge at the URL and returns its answer (`ClaudeFamilyRunner`). Only `.process`
        /// dials a socket: an IO made any other way answers nothing unless it says otherwise, so no test reaches a live
        /// bridge by default.
        public var bridge: @Sendable (BridgeCommand, TimeInterval, URL) -> BridgeResponse?

        public init(preparePipe: @escaping @Sendable () -> StdinPipe?, readStandardInput: @escaping @Sendable () -> Data,
                    agentPID: @escaping @Sendable () -> Int32?, send: @escaping @Sendable (Data, URL) -> Void,
                    broker: @escaping @Sendable (Data, URL, String) -> HookBrokerClient.Outcome = { _, _, _ in .noBroker },
                    hasTerminal: @escaping @Sendable (Int32?) -> Bool = { _ in false },
                    home: @escaping @Sendable () -> HookHome? = { nil },
                    agentName: @escaping @Sendable (Int32?) -> String? = { _ in nil },
                    agentPath: @escaping @Sendable (Int32?) -> String? = { _ in nil },
                    ownHooksConnected: @escaping @Sendable (AgentKind) -> Bool = { _ in false },
                    bridge: @escaping @Sendable (BridgeCommand, TimeInterval, URL) -> BridgeResponse? = { _, _, _ in nil }) {
            self.preparePipe = preparePipe
            self.readStandardInput = readStandardInput
            self.agentPID = agentPID
            self.send = send
            self.broker = broker
            self.hasTerminal = hasTerminal
            self.home = home
            self.agentName = agentName
            self.agentPath = agentPath
            self.ownHooksConnected = ownHooksConnected
            self.bridge = bridge
        }

        /// The real process: fd 0, `sysctl` for the agent, a non-blocking datagram, the broker's socket, the helper's own
        /// path for its home.
        public static let process = IO(
            preparePipe: { StdinPipe.make() },
            readStandardInput: { FileHandle.standardInput.readDataToEndOfFile() },
            agentPID: { ProcessTree.agentPID(startingAt: getppid(), table: SystemProcessTable()) },
            send: { data, url in HookNoteSender.send(data, to: url) },
            broker: { line, url, source in HookBrokerClient.run(line, to: url, source: source) },
            hasTerminal: { pid in ProcessTree.tty(forPID: pid ?? getpid(), table: SystemProcessTable()) != nil },
            home: { HookHome.ofCurrentHelper() },
            agentName: { pid in pid.flatMap { SystemProcessTable().entry(pid: $0)?.name } },
            agentPath: { pid in pid.flatMap(ProcessPath.of) },
            ownHooksConnected: { kind in
                OwnAgentHooks.connected(kind, home: ProcessInfo.processInfo.environment["HOME"] ?? HookHome.userHome())
            },
            bridge: { command, timeout, url in ClaudeFamilyRunner.live(bridgeURL: url)(command, timeout) })
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
        let named = Self.source(in: arguments) ?? HookContextNote.codexSource
        let parsed = input.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        // An agent's own words read as Claude's before the note is made, so the engine and the bridge see the same event
        // (Kimi's approval and the Qoder IDE's as "needs you", P1127, P1131).
        let object = parsed.map { raw in
            AgentKind(source: named).flatMap { Self.ownRunSources.contains($0) ? ClaudeFamilyRunner.shaped(raw, kind: $0, environment: environment) : nil }
                ?? raw
        }
        let pid = object == nil ? nil : io.agentPID()
        let home = io.home()
        // A Claude hook another agent ran is that agent's (P905): its note names it, and it never reaches the broker or
        // upstream's helper as Claude Code's.
        let caller = named == "claude" && object != nil
            ? HookCaller.agent(HookCaller.Signs(agentName: io.agentName(pid), agentPath: io.agentPath(pid), environment: environment)) : nil
        if let caller, io.ownHooksConnected(caller) { return .finished(note: nil, output: nil) }
        // Grok Build also runs Cursor's `~/.cursor/hooks.json`; its own hooks or its Claude copy already bring each event,
        // so that third copy ends with nothing (P1111).
        if object != nil, named == AgentKind.cursor.rawValue,
           HookCaller.agent(HookCaller.Signs(agentName: io.agentName(pid), agentPath: io.agentPath(pid), environment: environment)) == .grok {
            return .finished(note: nil, output: nil)
        }
        let source = caller?.rawValue ?? named
        let note = object.flatMap { HookContextNote.make(object: Self.noteObject($0, source: source), environment: environment,
                                                         agentPID: pid, source: source) }
        if let data = note?.encoded() { io.send(data, HookNoteSocket.helperURL(environment: environment, home: home)) }

        // Watch agents of wave 4 (P1100 to P1113): nothing they read is ever printed.
        if let object, let finished = Self.watchAgent(object, named: named, caller: caller, note: note, environment: environment,
                                                      home: home, io: io) {
            return finished
        }

        // Cursor is Watch (P919, P930): upstream's bridge answers its shell and MCP hooks `allow` at once, and Cursor runs
        // what a hook allows. So the helper tells the bridge itself, for the island to show the call, and prints nothing:
        // Cursor's own rules and prompt decide.
        if object != nil, caller == nil, named == AgentKind.cursor.rawValue {
            if let payload = try? JSONDecoder().decode(CursorHookPayload.self, from: input) {
                _ = io.bridge(.processCursorHook(payload), ClaudeFamilyRunner.eventTimeout, Self.bridgeURL(environment: environment, home: home))
            }
            return .finished(note: note, output: nil)
        }

        if let object, let kind = caller ?? AgentKind(source: named), caller != nil || Self.ownRunSources.contains(kind) {
            let event = object["hook_event_name"] as? String
            // An approval through Claude's hook from an agent that does not follow the answer stays in that agent.
            if caller != nil, event == "PermissionRequest", !HookCaller.answersThroughClaudeHook(kind) {
                return .finished(note: note, output: nil)
            }
            let bridgeURL = Self.bridgeURL(environment: environment, home: home)
            let output = ClaudeFamilyRunner.run(object: object, kind: kind, environment: environment) { command, timeout in
                io.bridge(command, timeout, bridgeURL)
            }
            return .finished(note: note, output: output)
        }

        if let object, object["hook_event_name"] as? String == "PermissionRequest", brokeredSources.contains(source) {
            let line = HookRequestLine(source: source, input: input,
                                       digest: object["tool_input"].flatMap(HookInputDigest.of),
                                       entrypoint: environment["CLAUDE_CODE_ENTRYPOINT"].flatMap { $0.isEmpty || $0.utf8.count > 32 ? nil : $0 },
                                       agentPID: pid, hostBundleID: note?.hostBundleID, hasTerminal: io.hasTerminal(pid))
            // Too large, or not an object: nothing is held and nothing decided; the agent's own prompt decides.
            guard input.count <= HookRequestLine.inputLimit, let data = line.encoded() else {
                return .finished(note: note, output: nil)
            }
            switch io.broker(data, HookRequestSocket.helperURL(environment: environment, home: home), source) {
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

    /// The hook's input as the note reads it: Grok Build's camelCase names and Antigravity CLI's fields in Claude's
    /// names (`GrokHookFields`, `AntigravityHooks`).
    static func noteObject(_ object: [String: Any], source: String) -> [String: Any] {
        switch source {
        case AgentKind.grok.rawValue: GrokHookFields.noteObject(object)
        case AgentKind.antigravity.rawValue: AntigravityHooks.noteObject(object) ?? [:]
        default: object
        }
    }

    /// Gemini CLI's tool events, Antigravity CLI's hooks, and Grok Build's hooks through Claude's settings: told to the
    /// bridge (or only noted) here, never handed to upstream's helper, and never answered (P1101, P1106, P1111). nil for
    /// any other hook.
    static func watchAgent(_ object: [String: Any], named: String, caller: AgentKind?, note: HookContextNote?,
                           environment: [String: String], home: HookHome?, io: IO) -> Outcome? {
        if caller == nil, named == AgentKind.gemini.rawValue, let event = object["hook_event_name"] as? String,
           GeminiHooks.toolEvents.contains(event) {
            return .finished(note: note, output: nil)
        }
        let bridgeURL = Self.bridgeURL(environment: environment, home: home)
        if caller == nil, named == AgentKind.antigravity.rawValue {
            if let payload = AntigravityHooks.payload(object) {
                _ = io.bridge(.processGeminiHook(payload.withRuntimeContext(environment: environment)), AntigravityHooks.bridgeTimeout,
                              bridgeURL)
            }
            return .finished(note: note, output: nil)
        }
        // Grok's own hooks go through upstream's helper as they always did; its copy of Claude's goes the same way here,
        // as Grok's (upstream's helper would file it under Claude Code), and prints nothing: Grok ignores a verdict.
        if caller == .grok {
            if let data = try? JSONSerialization.data(withJSONObject: GrokHookFields.payloadObject(object)),
               let payload = try? JSONDecoder().decode(GrokHookPayload.self, from: data) {
                _ = io.bridge(.processGrokHook(payload.withRuntimeContext(environment: environment)), Self.grokTimeout, bridgeURL)
            }
            return .finished(note: note, output: nil)
        }
        return nil
    }

    /// The wait for the bridge on Grok's copy of a Claude hook: under the 10 s Juice gives Grok's own entries
    /// (`AgentHookTable.grok`); Grok runs a Claude entry with no timeout for 5 s, and goes on without it (P1112).
    static let grokTimeout: TimeInterval = 8

    /// The agents whose Claude-format hooks this helper runs itself (`ClaudeFamilyRunner`): upstream's helper does not
    /// know Copilot's and Devin's `--source` and would read them as Codex (P908), and fails on Qwen's permission modes
    /// (P924), on CodeBuddy's and Factory Droid's (P1133) and on Kimi's own events (P1131); Qoder's IDE answers in other
    /// words (P1127).
    public static let ownRunSources: Set<AgentKind> = [.copilot, .devin, .qwen, .qoder, .codebuddy, .factory, .kimi]

    /// The bridge a helper dials: its home's, else the variable a test sets, else upstream's default (P900).
    public static func bridgeURL(environment: [String: String], home: HookHome?) -> URL {
        home?.bridgeURL ?? BridgeSocketLocation.currentURL(environment: environment)
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
