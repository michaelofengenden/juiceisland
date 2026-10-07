import Darwin
import Foundation
import JuiceCore

/// What Codex's shared background service says of one thread (`thread/read`, `includeTurns: false`; openai/codex
/// `app-server-protocol/schema/json/v2/ThreadReadResponse.json`, `ThreadStatus`): no side effect, nothing loaded.
public enum CodexDaemonStatus: Equatable, Sendable {
    /// No daemon for this home: no control socket, or a stale one nobody listens on. Never started by Juice.
    case noDaemon
    /// The daemon runs and has the thread on disk only (`notLoaded`), or does not know it: nobody holds it there.
    case notHeld
    /// Loaded, no turn running (`idle`, or `systemError`): a reply starts one there.
    case idle
    /// A turn runs (`active`); `waitsOnYou` when it waits on an approval or a question (`activeFlags`).
    case active(waitsOnYou: Bool)
    /// It could not be asked: what went wrong, in a few words.
    case failed(String)

    /// The daemon holds the thread: it is its one writer, so `codex exec resume` would be refused (P1440).
    public var holds: Bool {
        switch self {
        case .idle, .active: true
        default: false
        }
    }

    public var turnRuns: Bool {
        if case .active = self { return true }
        return false
    }
}

/// How a `turn/start` went.
public enum CodexDaemonStart: Equatable, Sendable {
    /// Sent: the turn the daemon started (or steered, when one had begun meanwhile).
    case started(turnID: String)
    /// The daemon no longer has the thread loaded ("thread not found"): nothing was sent.
    case notHeld
    case noDaemon
    case failed(String)
}

/// What the island asks of Codex's shared daemon (P1485 to P1509). The live one is `CodexDaemonLink`; tests give fixtures
/// of the daemon's JSON-RPC. Every call is one short connection, never subscribed to the thread: Juice gets none of the
/// thread's events, approvals or questions, and answers no request of the daemon's.
public protocol CodexDaemonReaching: Sendable {
    func status(of threadID: String, home: String) async -> CodexDaemonStatus
    /// The owner's text as the turn's input, inside the JSON-RPC message: never on a command line (P1325).
    func startTurn(on threadID: String, home: String, text: String) async -> CodexDaemonStart
    /// Ends a turn the island started (`turn/interrupt`), on the owner's Stop. True once the daemon took it.
    func interrupt(turn turnID: String, on threadID: String, home: String) async -> Bool
}

/// One JSON-RPC conversation over a daemon connection: `initialize`, `initialized`, then requests, each answered by id.
/// Notifications and the daemon's own requests on the way are skipped and never answered (an answer could settle another
/// client's request; the daemon routes thread requests only to subscribed clients, and this one never subscribes).
struct CodexDaemonConversation {
    /// The client name Juice gives the daemon: the one name Codex keeps from rewriting the daemon's process-wide
    /// originator and User-Agent, which every session's requests carry (`initialize_processor.rs`,
    /// `NON_ORIGINATING_CLIENT_NAMES`); any other name would make every Codex session on this Mac speak as Juice
    /// (P1489). The title says who it is.
    static let clientName = "codex_app_server_daemon"
    static let clientTitle = "Juice Island"
    /// Messages skipped while waiting for one answer before giving up.
    static let skipLimit = 500

    enum Failure: Error, Equatable {
        case rpc(code: Int?, message: String)
        case unexpected(String)
    }

    let send: (String) throws -> Void
    let receive: () throws -> String
    private var nextID = 1

    init(send: @escaping (String) throws -> Void, receive: @escaping () throws -> String) {
        self.send = send
        self.receive = receive
    }

    mutating func initialize(version: String) throws {
        _ = try call("initialize", params: ["clientInfo": ["name": Self.clientName, "title": Self.clientTitle, "version": version]])
        try send(JSONRPC.notification(method: "initialized"))
    }

    /// The result object of `method`, or the daemon's error.
    mutating func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(JSONRPC.request(id: id, method: method, params: params))
        for _ in 0..<Self.skipLimit {
            let text = try receive()
            let data = Data(text.utf8)
            guard let envelope = try? JSONRPC.Envelope.decode(data), envelope.method == nil, envelope.id == .number(id) else { continue }
            if let error = envelope.error { throw Failure.rpc(code: error.code, message: error.message ?? "error") }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let result = object["result"] as? [String: Any] else { throw Failure.unexpected("\(method): no result") }
            return result
        }
        throw Failure.unexpected("\(method): no answer")
    }

    // MARK: Reading the daemon's answers

    /// `thread.status` of a `thread/read` result.
    static func status(ofReadResult result: [String: Any]) -> CodexDaemonStatus {
        guard let thread = result["thread"] as? [String: Any], let status = thread["status"] as? [String: Any],
              let type = status["type"] as? String else { return .failed("no status") }
        switch type {
        case "notLoaded": return .notHeld
        case "idle", "systemError": return .idle
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            return .active(waitsOnYou: flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput"))
        default: return .failed("status \(type)")
        }
    }

    /// The daemon does not know the thread, or has it on disk only: `thread not loaded: <id>` from `thread/read`,
    /// `thread not found: <id>` from `turn/start` (`thread_processor.rs`, `turn_processor.rs`).
    static func isNotHeld(_ failure: Failure) -> Bool {
        guard case let .rpc(_, message) = failure else { return false }
        let said = message.lowercased()
        return said.contains("thread not loaded") || said.contains("thread not found")
    }
}

/// The live link to Codex's shared daemon for a home: one connection per call, made off the main thread, closed at its
/// end. Only the app's own resumer has one (`SessionResumer`); a headless engine has none.
public struct CodexDaemonLink: CodexDaemonReaching {
    /// Each read and write's limit, and so a call's: a few of them.
    var timeout: TimeInterval = 3
    var version: String = Juice.version

    public init() {}

    /// A test process (xctest or swift-testing): the app's resumer gets no live link there (P1496). Tests that reach a
    /// daemon make a link themselves, to a stand-in on a temporary socket.
    static var runningUnderTests: Bool { TestProcess.isRunning }

    /// The control socket Codex 0.158 serves for `home` (`app_server_control_socket_path`).
    public static func socketPath(home: String) -> String {
        (home as NSString).appendingPathComponent("app-server-control/app-server-control.sock")
    }

    public func status(of threadID: String, home: String) async -> CodexDaemonStatus {
        let timeout = timeout, version = version
        return await Task.detached(priority: .userInitiated) {
            Self.converse(home: home, timeout: timeout, version: version) { conversation -> CodexDaemonStatus in
                do {
                    let result = try conversation.call("thread/read", params: ["threadId": threadID, "includeTurns": false])
                    return CodexDaemonConversation.status(ofReadResult: result)
                } catch let failure as CodexDaemonConversation.Failure {
                    return CodexDaemonConversation.isNotHeld(failure) ? .notHeld : .failed(Self.words(failure))
                }
            } failed: { $0 }
        }.value
    }

    public func startTurn(on threadID: String, home: String, text: String) async -> CodexDaemonStart {
        let timeout = timeout, version = version
        return await Task.detached(priority: .userInitiated) {
            Self.converse(home: home, timeout: timeout, version: version) { conversation -> CodexDaemonStart in
                do {
                    let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": [Any]()]]
                    let result = try conversation.call("turn/start", params: ["threadId": threadID, "input": input])
                    guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else {
                        return .failed("no turn")
                    }
                    return .started(turnID: id)
                } catch let failure as CodexDaemonConversation.Failure {
                    return CodexDaemonConversation.isNotHeld(failure) ? .notHeld : .failed(Self.words(failure))
                }
            } failed: { status in
                if case .noDaemon = status { return .noDaemon }
                if case let .failed(words) = status { return .failed(words) }
                return .failed("not sent")
            }
        }.value
    }

    public func interrupt(turn turnID: String, on threadID: String, home: String) async -> Bool {
        let timeout = timeout, version = version
        return await Task.detached(priority: .userInitiated) {
            Self.converse(home: home, timeout: timeout, version: version) { conversation -> Bool in
                (try? conversation.call("turn/interrupt", params: ["threadId": threadID, "turnId": turnID])) != nil
            } failed: { _ in false }
        }.value
    }

    /// Connects, initializes, runs `body`, closes. A missing or stale socket is `.noDaemon`; anything else that went
    /// wrong before `body` is `.failed`.
    static func converse<T>(home: String, timeout: TimeInterval, version: String,
                            _ body: (inout CodexDaemonConversation) throws -> T,
                            failed: (CodexDaemonStatus) -> T) -> T {
        let socket: UnixWebSocket
        do {
            socket = try UnixWebSocket.open(path: socketPath(home: home), timeout: timeout)
        } catch let failure as UnixWebSocket.Failure {
            switch failure {
            case .noSocket, .refused: return failed(.noDaemon)
            default: return failed(.failed(words(failure)))
            }
        } catch {
            return failed(.failed("could not connect"))
        }
        defer { socket.close() }
        var conversation = CodexDaemonConversation(send: { try socket.send($0) }, receive: { try socket.receive() })
        do {
            try conversation.initialize(version: version)
            return try body(&conversation)
        } catch let failure as CodexDaemonConversation.Failure {
            return failed(.failed(words(failure)))
        } catch let failure as UnixWebSocket.Failure {
            return failed(.failed(words(failure)))
        } catch {
            return failed(.failed("it did not answer"))
        }
    }

    static func words(_ failure: CodexDaemonConversation.Failure) -> String {
        switch failure {
        case let .rpc(_, message): ResumeExit.cut(message, limit: 80)
        case let .unexpected(what): what
        }
    }

    static func words(_ failure: UnixWebSocket.Failure) -> String {
        switch failure {
        case .noSocket, .refused: "no background service"
        case .notOurs: "its socket is not this user's"
        case .pathTooLong: "its socket's path is too long"
        case .handshake: "it did not take the connection"
        case .closed: "it closed the connection"
        case .timedOut: "it did not answer"
        case .tooLarge: "its answer was too large"
        case .io: "the connection failed"
        }
    }
}

/// Whether a process is a Codex app-server: Codex's shared daemon (`codex app-server --listen unix://`), the Codex app's
/// or an editor's own (`codex app-server` over stdio). Such a process runs threads for clients; it is never a tab's agent,
/// whatever terminal its parent holds (P1485). Read from its arguments (`sysctl` `KERN_PROCARGS2`, argv only, never its
/// environment), nothing kept.
enum CodexServerProcess {
    static let live: @Sendable (Int32) -> Bool = { pid in
        var buffer = [UInt8](repeating: 0, count: AgentProcessScan.argumentLimit())
        return AgentProcessScan.arguments(of: pid, buffer: &buffer).map(isAppServer) ?? false
    }

    /// The flags of Codex's root command that take a value, so `codex -c k=v app-server` is read right.
    static let valueFlags: Set<String> = ["-c", "--config", "--enable", "--disable", "-p", "--profile", "--remote",
                                          "--remote-auth-token-env", "-C", "--cd", "-m", "--model", "-s", "--sandbox",
                                          "-a", "--ask-for-approval", "--local-provider", "--add-dir", "-i", "--image"]

    /// A `codex` executable whose subcommand is `app-server`.
    static func isAppServer(_ arguments: [String]) -> Bool {
        guard let executable = arguments.first, URL(fileURLWithPath: executable).lastPathComponent.hasPrefix("codex") else { return false }
        var index = 1
        while index < arguments.count {
            let word = arguments[index]
            if valueFlags.contains(word) {
                index += 2
                continue
            }
            if word.hasPrefix("-") {
                index += 1
                continue
            }
            return word == "app-server"
        }
        return false
    }
}
