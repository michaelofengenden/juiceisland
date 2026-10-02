import Foundation

/// A child process whose stdout is delivered line by line as an `AsyncStream`. One consumer only.
/// Both pipes are drained continuously so a chatty child can never dead-lock against a parent that reads late.
///
/// `interactive` is for a CLI that talks with a person (a login). Such a CLI writes its prompt without a newline and
/// then waits on stdin, so an unfinished last line that ends like a prompt (`>`, `:` or `?`, with or without the usual
/// trailing space) is delivered on `lines` as soon as it arrives; and stderr is delivered line by line on `errorLines`
/// too, while the child runs.
public final class CLIProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private let interactive: Bool
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stderrText = ""
    private var finished = false
    private let continuation: AsyncStream<String>.Continuation
    private let errorContinuation: AsyncStream<String>.Continuation
    public let lines: AsyncStream<String>
    /// stderr line by line, for an `interactive` process only (`stderrOutput` keeps the tail either way). Ends with
    /// `lines`; a process that is not interactive ends it at once.
    public let errorLines: AsyncStream<String>

    public init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil,
                interactive: Bool = false) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.lines = stream
        self.continuation = continuation
        let (errors, errorContinuation) = AsyncStream<String>.makeStream()
        self.errorLines = errors
        self.errorContinuation = errorContinuation
        self.interactive = interactive
        if !interactive { errorContinuation.finish() }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(from: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(from: handle)
        }
        process.terminationHandler = { [weak self] _ in self?.drainAndFinish() }
        do {
            try process.run()
        } catch {
            // The termination handler never fires if run() throws, so finish the stream ourselves
            // or a consumer iterating `lines` would wait forever.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lock.withLock { finished = true }
            continuation.finish()
            errorContinuation.finish()
            throw error
        }
        // Writing to stdin after the child has exited otherwise raises SIGPIPE and kills the host process;
        // this makes write(line:) throw instead.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // The child owns the write ends now; keeping ours open would make EOF impossible to observe.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
    }

    /// Must be called while `lock` is held.
    private func extractCompleteLines() -> [String] {
        Self.extractLines(from: &stdoutBuffer)
    }

    private static func extractLines(from buffer: inout Data) -> [String] {
        var newLines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let slice = buffer[buffer.startIndex..<newline]
            newLines.append(String(decoding: slice, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return newLines
    }

    /// An interactive process's unfinished last line, taken out of the buffer when it ends like a prompt. Trailing
    /// white space is not needed: a CLI build that drops the space after `>` still gets its prompt read. Must be called
    /// while `lock` is held.
    private func extractPrompt() -> String? {
        guard interactive, !stdoutBuffer.isEmpty else { return nil }
        let text = String(decoding: stdoutBuffer, as: UTF8.self)
        guard let end = text.last(where: { !$0.isWhitespace }), Self.promptEndings.contains(end) else { return nil }
        stdoutBuffer.removeAll()
        return text
    }

    private static let promptEndings: Set<Character> = [">", ":", "?"]

    // The fd read and the resulting yields happen inside the same lock as `drainAndFinish`, so a read
    // here can never interleave with the drain's final read, and `finished` guarantees no handler
    // reads or yields after the stream has been finished.
    private func consumeStdout(from handle: FileHandle) {
        lock.withLock {
            guard !finished else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
            for line in extractCompleteLines() { continuation.yield(line) }
            if let prompt = extractPrompt() { continuation.yield(prompt) }
        }
    }

    private func consumeStderr(from handle: FileHandle) {
        lock.withLock {
            guard !finished else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            appendStderr(data)
        }
    }

    /// Must be called while `lock` is held.
    private func appendStderr(_ data: Data) {
        stderrText += String(decoding: data, as: UTF8.self)
        if stderrText.count > 8_000 { stderrText = String(stderrText.suffix(8_000)) }
        guard interactive else { return }
        stderrBuffer.append(data)
        for line in Self.extractLines(from: &stderrBuffer) { errorContinuation.yield(line) }
        if stderrBuffer.count > 8_000 { stderrBuffer = Data(stderrBuffer.suffix(8_000)) }
    }

    /// Everything already sitting in `fd`, without waiting for EOF. `readDataToEndOfFile()` waits for the write end
    /// to be closed everywhere, and a grandchild that inherited it (Claude starts MCP servers that do) may hold it
    /// for minutes — the termination handler's thread and `lock` would wedge with it. The child has exited by the
    /// time this runs, so whatever it wrote is already in the pipe buffer and this collects all of it.
    private static func drainWithoutBlocking(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { break }                 // EOF: no one holds the write end any more
            if errno == EINTR { continue }
            break                                   // EAGAIN/EWOULDBLOCK, or a real error: nothing more to take
        }
        return collected
    }

    private func drainAndFinish() {
        lock.withLock {
            guard !finished else { return }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stdoutTail = Self.drainWithoutBlocking(stdoutPipe.fileHandleForReading.fileDescriptor)
            if !stdoutTail.isEmpty { stdoutBuffer.append(stdoutTail) }
            let stderrTail = Self.drainWithoutBlocking(stderrPipe.fileHandleForReading.fileDescriptor)
            if !stderrTail.isEmpty { appendStderr(stderrTail) }
            for line in extractCompleteLines() { continuation.yield(line) }
            if !stdoutBuffer.isEmpty {
                continuation.yield(String(decoding: stdoutBuffer, as: UTF8.self))
                stdoutBuffer.removeAll()
            }
            if !stderrBuffer.isEmpty {
                errorContinuation.yield(String(decoding: stderrBuffer, as: UTF8.self))
                stderrBuffer.removeAll()
            }
            finished = true
            continuation.finish()
            errorContinuation.finish()
        }
    }

    public func write(line: String) throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func closeInput() { try? stdinPipe.fileHandleForWriting.close() }
    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }
    public var stderrOutput: String { lock.withLock { stderrText } }

    public func terminate() { if process.isRunning { process.terminate() } }
    public func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    /// Polls, because `Process` has no async wait; 50 ms granularity is fine for a CLI that runs for seconds.
    /// Returns `-1` if this task is cancelled before the child exits; the child is left running for the
    /// caller to `terminate()` or `kill()`.
    public func waitForExit() async -> Int32 {
        while process.isRunning {
            if Task.isCancelled { return -1 }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return process.terminationStatus
    }
}
