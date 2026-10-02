import Darwin
import Foundation

/// A running tunnel process: ssh in the app, a local `jr.py serve` in tests.
public protocol TunnelProcess: AnyObject, Sendable {
    func write(_ data: Data)
    func terminate()
}

/// Starts a tunnel process with these arguments: its stdout to `onOutput`, and its end (status, last error lines) to
/// `onExit`, once.
public struct TunnelLauncher: Sendable {
    public var launch: @Sendable (_ arguments: [String], _ onOutput: @escaping @Sendable (Data) -> Void,
                                  _ onExit: @escaping @Sendable (Int32, String) -> Void) throws -> any TunnelProcess

    public init(launch: @escaping @Sendable (_ arguments: [String], _ onOutput: @escaping @Sendable (Data) -> Void,
                                             _ onExit: @escaping @Sendable (Int32, String) -> Void) throws -> any TunnelProcess) {
        self.launch = launch
    }

    /// `/usr/bin/ssh` with the arguments, in the app's own environment (launchd's agent socket; P746).
    public static let ssh = TunnelLauncher { arguments, onOutput, onExit in
        try PipedProcess.start(executable: SSHCommands.ssh, arguments: arguments, environment: nil, onOutput: onOutput, onExit: onExit)
    }

    /// Any program (tests: `python3 jr.py serve` with a scratch `HOME`), the arguments after its own.
    public static func program(_ executable: URL, prefix: [String], environment: [String: String]) -> TunnelLauncher {
        TunnelLauncher { arguments, onOutput, onExit in
            try PipedProcess.start(executable: executable, arguments: prefix + arguments, environment: environment,
                                   onOutput: onOutput, onExit: onExit)
        }
    }
}

/// A process on three pipes. Writing to its stdin after it ended fails quietly: the pipe never raises SIGPIPE.
final class PipedProcess: TunnelProcess, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var errors = Data()
    static let errorLimit = 4_096

    static func start(executable: URL, arguments: [String], environment: [String: String]?,
                      onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32, String) -> Void) throws -> PipedProcess {
        let piped = PipedProcess()
        let output = Pipe()
        let error = Pipe()
        piped.process.executableURL = executable
        piped.process.arguments = arguments
        if let environment { piped.process.environment = environment }
        piped.process.standardInput = piped.input
        piped.process.standardOutput = output
        piped.process.standardError = error
        _ = fcntl(piped.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let finished = DispatchGroup()
        finished.enter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finished.leave()
            } else {
                onOutput(data)
            }
        }
        error.fileHandleForReading.readabilityHandler = { [weak piped] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { piped?.noteError(data) }
        }
        piped.process.terminationHandler = { [weak piped] process in
            // Every byte of stdout first, so a helper's last frame is never read after its end.
            finished.notify(queue: .global()) {
                let text = piped?.errorText ?? ""
                onExit(process.terminationStatus, text)
            }
        }
        try piped.process.run()
        return piped
    }

    private func noteError(_ data: Data) {
        lock.withLock {
            errors.append(data)
            if errors.count > Self.errorLimit { errors = Data(errors.suffix(Self.errorLimit)) }
        }
    }

    var errorText: String { lock.withLock { String(decoding: errors, as: UTF8.self) } }

    func write(_ data: Data) {
        let fd = input.fileHandleForWriting.fileDescriptor
        lock.withLock {
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { buffer in Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset) }
                if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { return }
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }
}

/// One attempt at a host's tunnel: the process, the frames on its stdout, and the relay for its channels. A new attempt
/// is a new `RemoteTunnel`; the old one's late callbacks carry its generation and are ignored.
final class RemoteTunnel: @unchecked Sendable {
    private let queue: DispatchQueue
    private let relay: RemoteRelay
    private var decoder = MuxDecoder()
    private var process: (any TunnelProcess)?
    private var protocolFailure = false
    private var helloed = false
    private let onReady: @Sendable (Int) -> Void
    private let onExit: @Sendable (TunnelFailure) -> Void

    init(host: RemoteSessionDirectory.Entry, endpoints: RemoteRelay.Endpoints, directory: RemoteSessionDirectory,
         onReady: @escaping @Sendable (Int) -> Void, onExit: @escaping @Sendable (TunnelFailure) -> Void) {
        let queue = DispatchQueue(label: "RemoteTunnel.\(host.hostID)")
        self.queue = queue
        self.onReady = onReady
        self.onExit = onExit
        let box = WriterBox()
        relay = RemoteRelay(endpoints: endpoints, host: host, directory: directory, queue: queue) { frame in
            box.process?.write(frame.encoded())
        }
        writer = box
    }

    private final class WriterBox: @unchecked Sendable {
        var process: (any TunnelProcess)?
    }

    private let writer: WriterBox

    func start(_ launcher: TunnelLauncher, arguments: [String]) {
        do {
            let process = try launcher.launch(arguments, { [weak self] data in
                guard let self else { return }
                self.queue.async { self.read(data) }
            }, { [weak self] status, stderr in
                guard let self else { return }
                self.queue.async { self.ended(status: status, stderr: stderr) }
            })
            queue.sync {
                self.process = process
                writer.process = process
            }
        } catch {
            onExit(.unreachable)
        }
    }

    func stop() {
        queue.sync {
            relay.stop()
            process?.terminate()
        }
    }

    /// Asks the remote helper to show a tmux pane (best effort; nothing comes back).
    func selectTmuxPane(socket: String, pane: String) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["socket": socket, "pane": pane]) else { return }
        queue.async { self.process?.write(MuxFrame(.tmux, 0, body).encoded()) }
    }

    private func read(_ data: Data) {
        guard !protocolFailure else { return }
        do {
            for frame in try decoder.feed(data) {
                if frame.kind == .hello {
                    guard !helloed else { continue }
                    helloed = true
                    let version = (try? JSONSerialization.jsonObject(with: frame.body) as? [String: Any])?["v"] as? Int ?? 0
                    onReady(version)
                } else {
                    relay.receive(frame)
                }
            }
        } catch {
            protocolFailure = true
            relay.stop()
            process?.terminate()
        }
    }

    /// After the helper's hello the login, the host key and the helper were all fine: whatever ended it (a drop, a
    /// network change) may pass by itself, whatever the error lines hold (an rc file's noise is there too).
    private func ended(status: Int32, stderr: String) {
        relay.stop()
        onExit(protocolFailure ? .protocolError : helloed ? .unreachable : SSHCommands.failure(status: status, stderr: stderr))
    }
}
