import Foundation

/// One git run's result. `launchFailed` means git itself could not start (not installed, not executable).
struct GitOutput: Equatable, Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var launchFailed = false

    var ok: Bool { !launchFailed && status == 0 }
    var firstLine: String { stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? "" }

    static func success(_ stdout: String = "") -> GitOutput { GitOutput(status: 0, stdout: stdout, stderr: "") }
    static func failure(_ stderr: String, status: Int32 = 128) -> GitOutput { GitOutput(status: status, stdout: "", stderr: stderr) }
    static let notLaunched = GitOutput(status: -1, stdout: "", stderr: "", launchFailed: true)
}

/// Runs `git <arguments>`. The checker takes one of these so tests never touch a real repository.
protocol GitRunning: Sendable {
    func run(_ arguments: [String], timeout: TimeInterval) async -> GitOutput
}

/// The real runner: the first git found (Homebrew's, then Apple's), no terminal prompt, no optional locks (a check
/// never writes the index), stdin closed, killed at its timeout. P117: a fetch's ssh runs in BatchMode, as
/// update-app.sh's does, so a locked key or an unknown host fails at once instead of waiting out the timeout or asking
/// through a prompt; an ssh command the environment or git's config already sets is kept.
struct ProcessGitRunner: GitRunning {
    static let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
    static let batchSSH = "ssh -o BatchMode=yes"
    /// The verbs that may reach a remote, and so start ssh.
    static let remoteVerbs: Set<String> = ["fetch", "pull", "ls-remote", "push", "clone"]

    var executable: String? = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    /// The environment git starts from; nil is this process's (tests pass their own).
    var baseEnvironment: [String: String]?

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitOutput {
        guard let executable else { return .notLaunched }
        let base = baseEnvironment ?? ProcessInfo.processInfo.environment
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let configured = Self.remoteVerbs.contains(Self.verb(of: arguments) ?? "")
                    ? Self.sshCommandConfigured(executable, options: Self.options(of: arguments), base: base) : true
                let environment = Self.environment(base, sshCommandConfigured: configured)
                continuation.resume(returning: Self.runBlocking(executable, arguments, environment: environment, timeout: timeout))
            }
        }
    }

    /// git's environment: no prompt, no optional locks, C messages, and ssh in BatchMode unless an ssh command is set
    /// already (`GIT_SSH_COMMAND` or `GIT_SSH` in the environment, or `core.sshCommand`).
    static func environment(_ base: [String: String], sshCommandConfigured: Bool) -> [String: String] {
        var environment = base
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        if !sshCommandConfigured, environment["GIT_SSH_COMMAND"] == nil, environment["GIT_SSH"] == nil {
            environment["GIT_SSH_COMMAND"] = batchSSH
        }
        return environment
    }

    /// The verb after git's own options (`-C <path>`, `-c <name>=<value>`).
    static func verb(of arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-C" || argument == "-c" { index += 2; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            return argument
        }
        return nil
    }

    /// git's own options before the verb, so the config asked is the same repository's.
    static func options(of arguments: [String]) -> [String] {
        guard let verb = verb(of: arguments), let index = arguments.firstIndex(of: verb) else { return arguments }
        return Array(arguments[..<index])
    }

    /// Whether git's config sets `core.sshCommand` for that repository (`git config --get`, a read).
    static func sshCommandConfigured(_ executable: String, options: [String], base: [String: String]) -> Bool {
        let output = runBlocking(executable, options + ["config", "--get", "core.sshCommand"],
                                 environment: environment(base, sshCommandConfigured: true), timeout: 10)
        return output.ok && !output.firstLine.isEmpty
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], environment: [String: String],
                                    timeout: TimeInterval) -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return .notLaunched }

        // Read both pipes as data arrives; after git exits, wait at most 2 s for their ends, so a helper that keeps
        // a pipe open (an ssh control master, say) can never hang the check.
        let collected = PipeCollector()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            let fd = pipe.fileHandleForReading.fileDescriptor
            // Never a read that waits: a handler that runs late finds nothing rather than blocking (P293).
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if collected.take(fd, stdout: isOut) == .end {
                    handle.readabilityHandler = nil
                    group.leave()
                }
            }
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        if group.wait(timeout: .now() + 2) == .timedOut {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            // What git wrote before it exited is in the pipes already, whether or not a busy machine ran the handlers
            // yet (P293): read it now, without waiting on a helper that keeps a pipe open. A handler already under way
            // finishes first, and one that runs after reads nothing, so the output keeps its order.
            collected.drain(out: out.fileHandleForReading.fileDescriptor, err: err.fileHandleForReading.fileDescriptor)
        }
        let (stdout, stderr) = collected.values
        return GitOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Everything a pipe holds now, never waiting for more: its end, or nothing left to read yet.
    static func drain(_ fd: Int32) -> Data {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                data.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return data
            }
        }
    }

    /// Both pipes' output as it is read, by the pipes' handlers and, once they are late, by one drain. The handlers and
    /// the drain take turns under one lock; once the drain has run, a handler that still comes reads nothing. Reads are
    /// plain `read(2)`s on non-blocking pipes: `FileHandle.availableData` raises an Objective-C exception when a
    /// non-blocking pipe has nothing to read (`EAGAIN`), which nothing here could catch (P293).
    final class PipeCollector: @unchecked Sendable {
        enum Take: Equatable { case data, end, drained }

        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var drained = false

        /// One read of what `fd` holds now, for its handler: `.end` at its end (or an error), `.drained` once the drain
        /// took over; nothing to read yet is `.data` with nothing added.
        func take(_ fd: Int32, stdout: Bool) -> Take {
            lock.withLock {
                guard !drained else { return .drained }
                var chunk = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = read(fd, &chunk, chunk.count)
                    if count > 0 {
                        if stdout { out.append(contentsOf: chunk[0..<count]) } else { err.append(contentsOf: chunk[0..<count]) }
                        return .data
                    }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN { return .data }
                    return .end
                }
            }
        }

        /// Reads what both pipes hold now, after anything a handler already read, and ends the handlers' turn.
        func drain(out outFD: Int32, err errFD: Int32) {
            lock.withLock {
                drained = true
                out.append(ProcessGitRunner.drain(outFD))
                err.append(ProcessGitRunner.drain(errFD))
            }
        }

        var values: (String, String) {
            lock.withLock { (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
        }
    }
}

/// Renders' and tests' runner: git never runs.
struct NoGitRunner: GitRunning {
    func run(_ arguments: [String], timeout: TimeInterval) async -> GitOutput { .notLaunched }
}
