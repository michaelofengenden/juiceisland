import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The needs-you pipeline end to end without upstream's bridge (tier 1 of the design's §5.2): the **built helper**
/// (`OpenIslandHooks`) runs as a child process per hook with the fixture on stdin; the engine's real notes listener and
/// request broker listen on sockets in a scratch folder; a stand-in for upstream's bridge listens on its scratch path
/// and replays the `AgentEvent`s upstream emits for each hook to the engine's real observer connection; the engine and
/// `EngineSessionsModel` are the real ones. Safe while the owner's app runs: nothing here binds, dials or names any
/// socket outside the scratch folder (P164), no helper gets the runner's terminal variables (P168), and the jump
/// runner is a stand-in (no AppleScript, no `open`).
@MainActor
final class AttentionRig {
    typealias Box = EngineFixtureBox

    let folder: URL
    let bridgeURL: URL
    let notesURL: URL
    let requestsURL: URL
    let home: URL
    /// The helper's home when the rig runs helpers installed as the app installs them (`helperHome`): the engine listens
    /// on its sockets, and helpers get no socket variables, so each finds them from its own path (P900).
    let hookHome: HookHome?
    /// The scratch path the engine relays as Open Island's socket (`legacyRelay`).
    let legacyURL: URL?
    /// The engine's clock is `base` plus `offset`: it moves only when the test moves it on past windows and holds
    /// (`advance`), never with real time, so a slow run (every suite shares the main actor) never opens a window early.
    /// The helpers and the broker stamp real times, which run ahead of it; the engine opens a request at the earlier.
    let base = Date()
    let offset = Box<TimeInterval>(0)
    let scheduled = Box<[(at: Date, run: @MainActor @Sendable () -> Void)]>([])
    let front = Box<String?>(nil)
    /// Whether a session's own terminal tab is in front, as the foreground probe would say (no AppleScript runs).
    let frontTab = Box(false)
    let upstream = Box<UpstreamStandIn?>(nil)
    /// Every request the broker took, whether it held it: "the helper ends at once" is a request it did not hold, never
    /// a time (P293).
    let brokered = Box<[Bool]>([])
    /// Whether something of Juice's still dials the legacy socket, as the engine's relay asks it (P932).
    let relayWanted: Box<Bool>
    /// Notes the engine has taken, ignored ones too: each counts once its `ingest(note:)` has run.
    let notesHeard = Box(0)
    let engine: SessionEngine
    let model: EngineSessionsModel
    private(set) var signals: [EngineSignal] = []
    private var runs: [HelperRun] = []
    /// Notes the helpers started so far will send: one per hook whose input names its event and session.
    private(set) var notesSent = 0

    /// `broker: false` starts the app without its request broker (an older build, C16): the helper then runs
    /// upstream's helper for a PermissionRequest too. `realBridge`: upstream's own `BridgeServer` on the scratch path
    /// instead of the stand-in (tier 2); it also binds upstream's legacy /tmp socket, so only the gated suite asks for it.
    /// `subagentBackstop`: when the broker ends a subagent's hold by itself, in real seconds (P350). The engine's own end
    /// runs on the rig's clock, which moves only with `advance`, so a rig keeps the broker's out of the way (ten minutes)
    /// unless a test is about it: a loaded machine never ends a hold under a test that did not move the clock.
    /// `helperHome`: the sockets are a `HookHome`'s in the scratch folder, as the app's are its own home's.
    /// `legacyRelay`: the engine relays `legacyURL`, a scratch path standing in for Open Island's socket, to its bridge
    /// (P911).
    init(broker: Bool = true, suppress: Bool = false, realBridge: Bool = false, subagentBackstop: TimeInterval = 600,
         helperHome: Bool = false, legacyRelay: Bool = false) async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jie-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hookHome = helperHome ? HookHome(folder: folder.appendingPathComponent("h", isDirectory: true)) : nil
        if let hookHome { try FileManager.default.createDirectory(at: hookHome.folder, withIntermediateDirectories: true) }
        self.hookHome = hookHome
        bridgeURL = hookHome?.bridgeURL ?? folder.appendingPathComponent("b.sock")
        notesURL = hookHome?.notesURL ?? folder.appendingPathComponent("n.sock")
        requestsURL = hookHome?.requestsURL ?? folder.appendingPathComponent("r.sock")
        legacyURL = legacyRelay ? folder.appendingPathComponent("o.sock") : nil
        home = folder.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for url in [bridgeURL, notesURL, requestsURL] + (legacyURL.map { [$0] } ?? []) {
            precondition(url.path.hasPrefix(folder.path) && url.path.hasPrefix(NSTemporaryDirectory()), "scratch sockets only (P164)")
            precondition(HookHome.fitsSocketAddress(url), "scratch socket path too long")
        }
        let offset = offset, base = base
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        configuration.socketURL = bridgeURL
        configuration.hookNotesSocketURL = notesURL
        configuration.hookRequestsSocketURL = broker ? requestsURL : nil
        configuration.suppressWhenFrontmost = suppress
        configuration.excludedWorkingDirectories = []
        configuration.legacyBridgeURL = legacyURL
        var dependencies = SessionEngine.Dependencies()
        let relayWanted = Box(legacyRelay)
        self.relayWanted = relayWanted
        dependencies.legacyRelayWanted = { _ in relayWanted.current }
        let upstream = upstream, scheduled = scheduled, front = front, frontTab = frontTab
        if !realBridge {
            dependencies.startBridge = { url in
                let standIn = try UpstreamStandIn(url: url)
                upstream.update { $0 = standIn }
                return standIn
            }
            // The stand-in binds only its scratch path; upstream's legacy /tmp socket is never probed, bound or looked at.
            dependencies.socketHasOwner = { _ in false }
            dependencies.socketIdentity = { _ in nil }
        }
        // The real listener and broker, heard as they hand over: a note counts once the engine's own hop has taken it.
        let brokered = brokered, notesHeard = notesHeard
        dependencies.startHookNotes = { url, handler in
            try SessionEngine.startHookNoteListener(at: url) { note in
                handler(note)
                Task { @MainActor in notesHeard.update { $0 += 1 } }
            }
        }
        dependencies.subagentHoldBackstop = subagentBackstop
        dependencies.startHookRequests = { url, holds, onRequest, onEnded in
            try SessionEngine.startHookRequestBroker(at: url, holds: holds, onRequest: { request in
                brokered.update { $0.append(request.held) }
                onRequest(request)
            }, onEnded: onEnded)
        }
        dependencies.isOtherIslandRunning = { false }
        dependencies.startRuntime = { _ in }
        dependencies.updateProcessRoots = { _ in }
        dependencies.ttyForPID = { _ in nil }
        dependencies.appForPID = { _ in nil }
        dependencies.isSessionFrontmost = { _ in frontTab.current }
        dependencies.frontmostBundleID = { front.current }
        dependencies.now = { base.addingTimeInterval(offset.current) }
        dependencies.scheduleSignalCheck = { delay, check in
            scheduled.update { $0.append((base.addingTimeInterval(offset.current + delay), check)) }
        }
        dependencies.scheduleAttentionCheck = { delay, check in
            scheduled.update { $0.append((base.addingTimeInterval(offset.current + delay), check)) }
        }
        dependencies.notificationArming = { _ in true }
        var runner = JumpRunner()
        runner.appURL = { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        runner.isAppRunning = { _ in true }
        runner.appleScript = { _, _ in "matched" }
        runner.open = { _, _ in }
        runner.command = { _, _, _ in false }
        dependencies.jumpRunner = runner
        engine = SessionEngine(configuration: configuration, dependencies: dependencies)
        model = EngineSessionsModel(engine: engine, clock: { base.addingTimeInterval(offset.current) }, jumps: .live)
        engine.onSignal = { [weak self] in self?.signals.append($0) }
        try engine.start()
        // The engine registers as the bridge's observer on a hop of its own; a hook sent before that would lose
        // upstream's events for it. Two full runs on a Mac loaded by other builds (load 130 to 200) each had one rig
        // "wait past 30 s" for it: the main actor, which every suite shares, was held longer than the wait's deadline,
        // and the first look after it came a moment before the registration it had let through. The wait now counts
        // looks, not seconds (P293), and says what the engine saw if it looks in vain.
        let engine = engine
        if !(await waitUntil(120, { upstream.current?.hasObserver ?? engine.isBridgeReady })) {
            Issue.record("bridge observer: ready \(engine.isBridgeReady), stand-in clients \(upstream.current?.clientCount ?? -1), status \(engine.lastStatusMessage.isEmpty ? "none" : engine.lastStatusMessage)")
        }
    }

    func stop() {
        for run in runs { run.kill() }
        engine.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Time

    /// The engine's clock now.
    var now: Date { base.addingTimeInterval(offset.current) }

    /// Moves the engine's clock on by `seconds`, running every window and Done hold that falls due, in order.
    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = scheduled.current.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
            scheduled.update { $0.remove(at: next.offset) }
            let ahead = next.element.at.timeIntervalSince(now)
            if ahead > 0 { offset.update { $0 += ahead } }
            next.element.run()
        }
        let rest = end.timeIntervalSince(now)
        if rest > 0 { offset.update { $0 += rest } }
    }

    /// Waits for what the sockets hand to the main actor by looks, never by the clock (P293): the condition is looked
    /// at every `Looks.interval` until it holds, and only `limit` seconds' worth of looks that each found it false end
    /// the wait. A look the main actor could not make on time (a full run shares it with every other suite) counts once,
    /// so a busy machine makes the wait longer and never ends it early. Looking in vain is an issue of the test that
    /// waited; the result says whether it held.
    @discardableResult
    func waitUntil(_ limit: TimeInterval = 30, sourceLocation: SourceLocation = #_sourceLocation,
                   _ condition: () -> Bool) async -> Bool {
        guard await Looks.until(limit, condition) else {
            Issue.record("looked \(Looks.count(limit)) times in vain", sourceLocation: sourceLocation)
            return false
        }
        return true
    }

    // MARK: Hooks

    /// Variables every helper this rig starts gets besides its own: a profile folder's `CLAUDE_CONFIG_DIR` (P730).
    var extraEnvironment: [String: String] = [:]

    /// The environment a helper child gets: built from scratch, never the runner's (P168).
    func environment(entrypoint: String?) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        if hookHome == nil {
            environment.merge(["OPEN_ISLAND_SOCKET_PATH": bridgeURL.path, HookNoteSocket.overrideKey: notesURL.path,
                               HookRequestSocket.overrideKey: requestsURL.path]) { own, _ in own }
        }
        environment.merge(extraEnvironment) { own, _ in own }
        if let entrypoint { environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint }
        let forbidden = ["TERM_PROGRAM", "ITERM_SESSION_ID", "__CFBundleIdentifier"]
        let forbiddenPrefixes = ["TMUX", "CMUX_", "ZELLIJ", "WARP_"]
        precondition(environment.keys.allSatisfy { key in !forbidden.contains(key) && !forbiddenPrefixes.contains(where: key.hasPrefix) },
                     "a helper child never gets terminal variables (P168)")
        return environment
    }

    /// Starts one hook: the built helper with the input on stdin. `events`: what upstream's bridge emits for it, when
    /// it reaches upstream's helper. `source` nil runs it as upstream's installer writes Codex's hooks, with no
    /// `--source` (P290). `command`: a hook command as an installer wrote it, run as the agent would run it (its
    /// program and arguments) in place of the built helper and `source`.
    @discardableResult
    func hook(_ object: [String: Any], source: String? = "claude", entrypoint: String? = "cli", events: [AgentEvent] = [],
              command: String? = nil) -> HelperRun {
        let session = object["session_id"] as? String ?? object["conversation_id"] as? String
        if let event = object["hook_event_name"] as? String, let session {
            if !events.isEmpty { upstream.current?.plan(event: event, session: session, events: events) }
            if object["session_id"] != nil { notesSent += 1 }
        }
        let input = try! JSONSerialization.data(withJSONObject: object)
        let words = command.flatMap(AgentHookTable.words)
        let run = HelperRun(input: input, source: source, environment: environment(entrypoint: entrypoint),
                            executable: words?.first.map { URL(fileURLWithPath: $0) }, arguments: words.map { Array($0.dropFirst()) })
        runs.append(run)
        return run
    }

    /// A hook that returns at once: runs it and waits for it, and for the engine to take what it sent. Its own note,
    /// not merely a note: every hook started so far has sent one before this one's, so the wait is for all of them
    /// (a note an earlier hook sent late once stood in for this one's, and the test read the rows before it, P293).
    @discardableResult
    func finished(_ object: [String: Any], source: String? = "claude", entrypoint: String? = "cli", events: [AgentEvent] = [],
                  command: String? = nil, until condition: (() -> Bool)? = nil) async -> HelperRun.Result {
        let run = hook(object, source: source, entrypoint: entrypoint, events: events, command: command)
        let result = await run.result()
        let sent = notesSent
        await waitUntil { notesHeard.current >= sent && (condition?() ?? true) }
        await settle()
        return result
    }

    /// Whether the broker's `number`th request (1 is the first) was released at once, once the broker has handed it on
    /// (its reply to the helper goes first): its helper ends with no decision however long it took to run (P293).
    func released(_ number: Int, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await waitUntil(sourceLocation: sourceLocation) { brokered.current.count >= number }
        let taken = brokered.current
        return taken.count >= number && !taken[number - 1]
    }

    /// Lets the engine take what is on its way: every event the stand-in wrote to the observer, then notes and the
    /// hops they start.
    func settle() async {
        if let standIn = upstream.current {
            await waitUntil { engine.bridgeEventsTaken >= standIn.emittedCount }
        }
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Events upstream's bridge emits on its own (a SessionStart it saw, a prompt).
    func emit(_ events: AgentEvent...) async {
        upstream.current?.emit(events)
        await settle()
    }

    // MARK: What the owner sees

    func row(_ id: String) -> SessionRow? { model.row(id: id) }
    func card(_ id: String) -> SessionCard? { model.card(for: id) }
    var needsYou: [EngineSignal] { signals.filter { if case .needsYou = $0 { true } else { false } } }
    var dones: [EngineSignal] { signals.filter { if case .done = $0 { true } else { false } } }
}

/// How the end-to-end suites wait on sockets and processes: by looks, never by the clock (P293). A wait of `limit`
/// seconds ends after that many seconds' worth of looks found nothing, so a look the machine made late still counts once.
enum Looks {
    static let interval: Duration = .milliseconds(10)
    static func count(_ limit: TimeInterval) -> Int { max(1, Int((limit * 100).rounded(.up))) }

    /// Looks at `condition` every `interval` until it holds (true), or until `count(limit)` looks after the first found
    /// it false (false); a cancelled task stops looking. It runs where its caller runs, so a main-actor condition is
    /// looked at on the main actor.
    static func until(_ limit: TimeInterval, isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async -> Bool {
        var looks = count(limit)
        while !condition() {
            guard looks > 0, !Task.isCancelled else { return false }
            looks -= 1
            try? await Task.sleep(for: interval)
        }
        return true
    }
}

/// The tests' `Box` (EngineFixtures lives in the other test target).
final class EngineFixtureBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
    var current: Value { lock.withLock { value } }
}

/// One run of the built helper, `--source <source>`, stdin the hook's input, stdout collected.
final class HelperRun: @unchecked Sendable {
    struct Result: Equatable {
        var stdout: Data
        var status: Int32
        /// Seconds from start to exit.
        var elapsed: TimeInterval
        var printed: String { String(decoding: stdout, as: UTF8.self) }
    }

    static let binary: URL = {
        // The test bundle sits next to the package's built products.
        let products = Bundle(for: HelperRun.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("OpenIslandHooks")
        precondition(FileManager.default.isExecutableFile(atPath: url.path), "build the OpenIslandHooks product first")
        return url
    }()

    private let process = Process()
    private let output = Pipe()
    private let started = Date()
    private let done = EngineFixtureBox<Result?>(nil)
    private let collected = EngineFixtureBox(Data())

    /// `executable` and `arguments`, when given, run in place of the built helper and `--source <source>`.
    init(input: Data, source: String?, environment: [String: String], executable: URL? = nil, arguments: [String]? = nil) {
        process.executableURL = executable ?? Self.binary
        process.arguments = arguments ?? source.map { ["--source", $0] } ?? []
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let collected = collected
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.update { $0.append(data) } }
        }
        let started = started, done = done, output = output
        process.terminationHandler = { process in
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            collected.update { $0.append(rest) }
            done.update { $0 = Result(stdout: collected.current, status: process.terminationStatus,
                                      elapsed: Date().timeIntervalSince(started)) }
        }
        try! process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
    }

    var isRunning: Bool { done.current == nil }

    /// Waits for the helper to exit, by looks as `AttentionRig.waitUntil` does (`limit` seconds' worth that found it
    /// still running; nil if it still runs then): a process slow to start on a busy machine never ends it early.
    func result(within limit: TimeInterval = 10) async -> Result? {
        let done = done
        _ = await Looks.until(limit) { done.current != nil }
        return done.current
    }

    func result() async -> Result { await result(within: 30) ?? Result(stdout: Data(), status: -1, elapsed: .infinity) }

    func kill() {
        if process.isRunning { process.terminate() }
    }
}

/// Stands in for upstream's `BridgeServer` on its scratch path: it greets each connection, takes each helper's hook
/// command (holding a PermissionRequest as upstream does, until the island's `resolvePermission`), answers what the
/// helper waits for, and emits to the engine's observer the events the test planned for that hook (the ones upstream
/// emits for it). Commands it took are kept for the tests ("never reached upstream").
final class UpstreamStandIn: EngineBridge, @unchecked Sendable {
    struct Received: Equatable {
        var event: String
        var session: String
        var source: String
    }

    private let url: URL
    private let fd: Int32
    private let lock = NSLock()
    private var observers: [Int32] = []
    /// Every connection still served; each is closed by its own thread when it ends, never elsewhere (an fd number
    /// is reused at once), so ending one early is a `shutdown`.
    private var clients: Set<Int32> = []
    private var plans: [String: [[AgentEvent]]] = [:]
    private var held: [String: (fd: Int32, claude: ClaudeHookPayload?, codex: CodexHookPayload?, openCode: Bool)] = [:]
    private var received: [Received] = []
    private var emitted = 0
    private var stopped = false

    init(url: URL) throws {
        self.url = url
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        precondition(path.count <= MemoryLayout.size(ofValue: address.sun_path), "scratch path too long")
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.enumerated() { raw[index] = UInt8(bitPattern: byte) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let listener = fd
        Thread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard let self, self.lock.withLock({ () -> Bool in
                    guard !self.stopped else { return false }
                    self.clients.insert(client)
                    return true
                }) else {
                    close(client)
                    return
                }
                Thread { self.serve(client) }.start()
            }
        }.start()
    }

    func plan(event: String, session: String, events: [AgentEvent]) {
        lock.withLock { plans["\(event)|\(session)", default: []].append(events) }
    }

    var commands: [Received] { lock.withLock { received } }

    func emit(_ events: [AgentEvent]) {
        let fds = lock.withLock { observers }
        for event in events {
            guard let line = try? BridgeCodec.encodeLine(.event(event)) else { continue }
            for fd in fds { Self.write(line, to: fd) }
            if !fds.isEmpty { lock.withLock { emitted += 1 } }
        }
    }

    var hasObserver: Bool { lock.withLock { !observers.isEmpty } }

    /// Connections accepted and still open (the rig's diagnostics).
    var clientCount: Int { lock.withLock { clients.count } }

    /// Events written to the engine's observer connection so far (`SessionEngine.bridgeEventsTaken` catches up).
    var emittedCount: Int { lock.withLock { emitted } }

    func updateStateSnapshot(_ snapshot: SessionState) {}

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            held = [:]
            for client in clients { shutdown(client, SHUT_RDWR) }
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(url.path)
        }
    }

    private func serve(_ client: Int32) {
        if let hello = try? BridgeCodec.encodeLine(.hello(BridgeHello())) { Self.write(hello, to: client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            guard let envelopes = try? BridgeCodec.decodeLines(from: &buffer) else { break }
            for case let .command(command) in envelopes { handle(command, from: client) }
        }
        lock.withLock {
            observers.removeAll { $0 == client }
            held = held.filter { $0.value.fd != client }
            clients.remove(client)
        }
        close(client)
    }

    private func respond(_ response: BridgeResponse, to fd: Int32) {
        guard let line = try? BridgeCodec.encodeLine(.response(response)) else { return }
        Self.write(line, to: fd)
    }

    private func take(_ event: String, _ session: String, _ source: String) -> [AgentEvent] {
        lock.withLock {
            received.append(Received(event: event, session: session, source: source))
            let key = "\(event)|\(session)"
            guard var queue = plans[key], !queue.isEmpty else { return [] }
            let events = queue.removeFirst()
            plans[key] = queue
            return events
        }
    }

    private func handle(_ command: BridgeCommand, from client: Int32) {
        switch command {
        case .registerClient:
            lock.withLock { observers.append(client) }
            respond(.acknowledged, to: client)
        case let .processClaudeHook(payload):
            emit(take(payload.hookEventName.rawValue, payload.sessionID, payload.hookSource ?? "claude"))
            if payload.hookEventName == .permissionRequest {
                lock.withLock { held[payload.sessionID] = (client, payload, nil, false) }
            } else {
                respond(.acknowledged, to: client)
            }
        case let .processCodexHook(payload):
            emit(take(payload.hookEventName.rawValue, payload.sessionID, "codex"))
            if payload.hookEventName == .permissionRequest {
                lock.withLock { held[payload.sessionID] = (client, nil, payload, false) }
            } else {
                respond(.acknowledged, to: client)
            }
        case let .processCursorHook(payload):
            // As upstream's `handleCursorHook`: the shell and MCP calls are allowed at once, Cursor's prompt decides.
            emit(take(payload.hookEventName.rawValue, payload.conversationId, "cursor"))
            switch payload.hookEventName {
            case .beforeShellExecution, .beforeMCPExecution:
                respond(.cursorHookDirective(CursorHookDirective(permission: .allow)), to: client)
            default:
                respond(.acknowledged, to: client)
            }
        case let .processOpenCodeHook(payload):
            // As upstream's `handleOpenCodeHook`: a permission is held until the island's answer, the rest acknowledged.
            emit(take(payload.hookEventName.rawValue, payload.sessionID, "opencode"))
            if payload.hookEventName == .permissionRequest {
                lock.withLock { held[payload.sessionID] = (client, nil, nil, true) }
            } else {
                respond(.acknowledged, to: client)
            }
        case let .processGeminiHook(payload):
            // As upstream's `handleGeminiHook` (Gemini CLI, and Antigravity CLI in its words): told, never held.
            emit(take(payload.hookEventName.rawValue, payload.sessionID, "gemini"))
            respond(.acknowledged, to: client)
        case let .processGrokHook(payload):
            // As upstream's `handleGrokHook`: told, never held (Grok ignores verdicts).
            emit(take(payload.hookEventName.rawValue, payload.sessionID, "grok"))
            respond(.acknowledged, to: client)
        case let .resolvePermission(sessionID, resolution):
            // As upstream's `resolvePendingClaudeInteraction` and `resolvePendingApproval`: the decision to the held
            // helper, and the bridge's own echo to the observers.
            if let entry = lock.withLock({ held.removeValue(forKey: sessionID) }) {
                if entry.openCode {
                    switch resolution {
                    case .allowOnce: respond(.openCodeHookDirective(.allow), to: entry.fd)
                    case let .deny(message, _): respond(.openCodeHookDirective(.deny(reason: message)), to: entry.fd)
                    }
                } else if let claude = entry.claude {
                    respond(.claudeHookDirective(.permissionRequest(SessionEngine.decision(for: resolution, input: claude.toolInput))),
                            to: entry.fd)
                } else {
                    switch resolution {
                    case .allowOnce: respond(.codexHookDirective(.permissionRequest(.allow)), to: entry.fd)
                    case let .deny(message, _):
                        respond(.codexHookDirective(.permissionRequest(.deny(message: message ?? "Permission denied in Open Island."))),
                                to: entry.fd)
                    }
                }
                shutdown(entry.fd, SHUT_RDWR)
                switch resolution {
                case .allowOnce:
                    emit([.activityUpdated(SessionActivityUpdated(sessionID: sessionID, summary: "Permission approved.", phase: .running,
                                                                  timestamp: .now))])
                case let .deny(message, _):
                    emit([.sessionCompleted(SessionCompleted(sessionID: sessionID, summary: message ?? "Permission denied in Open Island.",
                                                             timestamp: .now))])
                }
            }
            respond(.acknowledged, to: client)
        default:
            respond(.acknowledged, to: client)
        }
    }

    private static func write(_ data: Data, to fd: Int32) {
        _ = data.withUnsafeBytes { buffer in Darwin.write(fd, buffer.baseAddress, buffer.count) }
    }
}
