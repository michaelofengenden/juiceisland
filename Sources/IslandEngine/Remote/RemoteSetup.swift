import Foundation
import IslandHookNotes

/// What one ssh run returned.
public struct SSHRunOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs ssh once with stdin: the app's is `/usr/bin/ssh`; tests give a fake that never connects.
public struct SSHRunner: Sendable {
    public var run: @Sendable (_ arguments: [String], _ stdin: Data, _ timeout: TimeInterval) async -> SSHRunOutput

    public init(run: @escaping @Sendable (_ arguments: [String], _ stdin: Data, _ timeout: TimeInterval) async -> SSHRunOutput) {
        self.run = run
    }

    public static let ssh = SSHRunner { arguments, stdin, timeout in
        await Task.detached(priority: .userInitiated) { Self.runProcess(arguments, stdin: stdin, timeout: timeout) }.value
    }

    /// The helper goes in on its own thread: ssh reads stdin only once it is logged in, so a host that stalls before
    /// that (a `ProxyCommand` that hangs) must not hold the write past the timeout.
    static func runProcess(_ arguments: [String], stdin: Data, timeout: TimeInterval,
                           executable: URL = SSHCommands.ssh) -> SSHRunOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return SSHRunOutput(status: -1, stdout: "", stderr: "ssh could not start") }
        let collected = SSHOutputs()
        let reads = DispatchGroup()
        for (pipe, isError) in [(output, false), (error, true)] {
            reads.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(data, error: isError)
                reads.leave()
            }
        }
        let writer = input.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: stdin)
            try? writer.close()
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            exited.wait()
        }
        reads.wait()
        return SSHRunOutput(status: process.terminationStatus, stdout: collected.stdout, stderr: collected.stderr, timedOut: timedOut)
    }
}

private final class SSHOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func set(_ data: Data, error: Bool) { lock.withLock { if error { err = data } else { out = data } } }
    var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var stderr: String { lock.withLock { String(decoding: err.suffix(4_096), as: UTF8.self) } }
}

/// Set up and Remove on a host, on the owner's click only (P749): one ssh each, the helper on its stdin.
public enum RemoteSetup {
    /// Long enough for a slow first login through a jump host; a host that says nothing is not waited on longer.
    public static let timeout: TimeInterval = 60

    /// The app's list of hosts, in its own support folder (no secret in it).
    public static var hostsFile: URL {
        HookNoteSocket.defaultURL.deletingLastPathComponent().appendingPathComponent("remote-hosts.json")
    }

    public static func install(_ destination: String, runner: SSHRunner) async -> Result<RemoteSetupResult, RemoteSetupFailure> {
        guard let arguments = SSHCommands.setup(destination: destination, mode: .install) else { return .failure(.invalidDestination) }
        let output = await runner.run(arguments, Data(RemoteHelperScript.source.utf8), timeout)
        if let failure = RemoteSetupFailure.of(status: output.status, stderr: output.stderr, timedOut: output.timedOut) {
            return .failure(failure)
        }
        guard let result = RemoteSetupResult.install(stdout: output.stdout) else { return .failure(.unreadable) }
        return .success(result)
    }

    public static func remove(_ destination: String, runner: SSHRunner) async -> Result<Void, RemoteSetupFailure> {
        guard let arguments = SSHCommands.setup(destination: destination, mode: .remove) else { return .failure(.invalidDestination) }
        let output = await runner.run(arguments, Data(RemoteHelperScript.source.utf8), timeout)
        if let failure = RemoteSetupFailure.of(status: output.status, stderr: output.stderr, timedOut: output.timedOut) {
            return .failure(failure)
        }
        guard RemoteSetupResult.parse(output.stdout)?["removed"] as? Bool == true else { return .failure(.unreadable) }
        return .success(())
    }
}
