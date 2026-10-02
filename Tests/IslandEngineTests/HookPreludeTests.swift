import Darwin
import Foundation
import IslandHookNotes
import Testing

/// What the superset helper does before upstream's helper runs: stdin read once and put back byte for byte, one
/// allowlisted note, and nothing at all when hooks are skipped.
struct HookPreludeTests {
    typealias Box = EngineFixtures.Box

    /// A descriptor standing in for fd 0: /dev/null until the prelude puts its pipe there.
    private static func scratchDescriptor() -> Int32 { open("/dev/null", O_RDONLY) }

    private static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer[0..<count]) } else if count < 0 && errno == EINTR { continue } else { break }
        }
        return data
    }

    private static func io(fd: Int32, input: Data, reads: Box<Int>, sent: Box<[(Data, URL)]>, pipes: Box<Int>,
                           makePipe: Bool = true) -> HookPrelude.IO {
        HookPrelude.IO(
            preparePipe: {
                pipes.update { $0 += 1 }
                return makePipe ? StdinPipe.make(replacing: fd) : nil
            },
            readStandardInput: {
                reads.update { $0 += 1 }
                return input
            },
            agentPID: { 4242 },
            send: { data, url in sent.update { $0.append((data, url)) } })
    }

    @Test
    func skippedHooksTouchNothing() {
        let reads = Box(0), pipes = Box(0), sent = Box<[(Data, URL)]>([])
        for key in ["OPEN_ISLAND_SKIP_HOOKS", "VIBE_ISLAND_SKIP"] {
            let outcome = HookPrelude.run(environment: [key: "1"], io: Self.io(fd: -1, input: HookContextNoteTests.stopInput,
                                                                                  reads: reads, sent: sent, pipes: pipes))
            #expect(outcome == .skipped)
        }
        #expect(reads.current == 0 && pipes.current == 0 && sent.current.isEmpty)
    }

    @Test
    func withoutAPipeStdinIsLeftAlone() {
        let reads = Box(0), pipes = Box(0), sent = Box<[(Data, URL)]>([])
        let outcome = HookPrelude.run(environment: [:], io: Self.io(fd: -1, input: HookContextNoteTests.stopInput, reads: reads,
                                                                    sent: sent, pipes: pipes, makePipe: false))
        #expect(outcome == .untouched)
        #expect(reads.current == 0 && sent.current.isEmpty)
    }

    /// Upstream reads exactly what the agent wrote, however large, and the note goes to the helper's socket.
    @Test
    func stdinIsPutBackByteForByteAndOneNoteIsSent() throws {
        var input = HookContextNoteTests.stopInput
        input.removeLast()  // the closing brace, to add a large field before it
        input.append(Data(#","tool_response":""#.utf8))
        input.append(Data(repeating: UInt8(ascii: "a"), count: 2_000_000))
        input.append(Data(#""}"#.utf8))
        let fd = Self.scratchDescriptor()
        defer { close(fd) }
        let reads = Box(0), pipes = Box(0), sent = Box<[(Data, URL)]>([])
        var environment = HookContextNoteTests.fullEnvironment
        environment[HookNoteSocket.overrideKey] = "/tmp/jin-test.sock"
        let outcome = HookPrelude.run(environment: environment, io: Self.io(fd: fd, input: input, reads: reads, sent: sent, pipes: pipes))
        #expect(Self.readAll(fd) == input)
        #expect(reads.current == 1)
        guard case let .forwarded(note?) = outcome else {
            Issue.record("no note: \(outcome)")
            return
        }
        #expect(note.event == "Stop" && note.sessionID == "sess-1" && note.agentPID == 4242)
        #expect(sent.current.count == 1)
        #expect(sent.current.first?.1.path == "/tmp/jin-test.sock")
        #expect(sent.current.first.flatMap { HookContextNote.decode($0.0) } == note)
    }

    @Test
    func emptyOrForeignInputIsPutBackWithNoNote() throws {
        for input in [Data(), Data("[1,2,3]".utf8)] {
            let fd = Self.scratchDescriptor()
            defer { close(fd) }
            let reads = Box(0), pipes = Box(0), sent = Box<[(Data, URL)]>([])
            #expect(HookPrelude.run(environment: [:], io: Self.io(fd: fd, input: input, reads: reads, sent: sent, pipes: pipes))
                    == .forwarded(note: nil))
            #expect(Self.readAll(fd) == input)
            #expect(sent.current.isEmpty)
        }
    }

    /// A helper started with stdin closed: no pipe, so the prelude leaves it alone. Otherwise the pipe's read end would
    /// take fd 0's number and reading "stdin" would wait on the prelude's own pipe forever.
    @Test
    func aClosedStdinGetsNoPipe() {
        // A number no test opens (closing a real one would race with other tests that open files meanwhile).
        let fd: Int32 = 9_999
        #expect(fcntl(fd, F_GETFD) == -1)
        #expect(StdinPipe.make(replacing: fd) == nil)
        let reads = Box(0), pipes = Box(0), sent = Box<[(Data, URL)]>([])
        #expect(HookPrelude.run(environment: [:], io: Self.io(fd: fd, input: HookContextNoteTests.stopInput, reads: reads,
                                                              sent: sent, pipes: pipes)) == .untouched)
        #expect(reads.current == 0 && sent.current.isEmpty)
    }
}

/// The built helper itself (`.build/…/OpenIslandHooks`), run as a hook would run it, with a scrubbed environment: its
/// bridge socket and note socket both point into a scratch folder (nothing listens on the bridge path), no terminal
/// is named that upstream would query, and nothing else of this process's environment is passed on.
struct SupersetHelperProcessTests {
    struct Run {
        var status: Int32
        var stdout: Data
        var stderr: String
        var duration: TimeInterval
    }

    static var helperURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/OpenIslandHooks")
    }

    static func run(input: Data, environment: [String: String]) throws -> Run {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--source", "claude"]
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let started = Date()
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: out, stderr: String(decoding: err, as: UTF8.self),
                   duration: Date().timeIntervalSince(started))
    }

    static func environment(scratch: URL, notes: URL, extra: [String: String] = [:]) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": scratch.path,
         "OPEN_ISLAND_SOCKET_PATH": scratch.appendingPathComponent("bridge.sock").path,
         HookNoteSocket.overrideKey: notes.path,
         "TERM_PROGRAM": "WezTerm", "TMUX_PANE": "%9", "SECRET_TOKEN": "xyz"].merging(extra) { $1 }
    }

    /// Upstream's code runs on the same stdin (it names the Stop it decoded), writes nothing to stdout with no bridge,
    /// exits 0, and the note carries only the allowlist.
    @Test
    func theHelperSendsTheNoteAndThenRunsUpstreamUnchanged() throws {
        let helper = Self.helperURL
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "build the helper first: \(helper.path)")
        let receiver = try ScratchReceiver()
        let run = try Self.run(input: HookContextNoteTests.stopInput,
                               environment: Self.environment(scratch: receiver.folder, notes: receiver.url))
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains("[OpenIslandHooks] bridge unavailable for claude hook (Stop)"))
        #expect(run.duration < 5)
        let data = try #require(receiver.receive())
        let note = try #require(HookContextNote.decode(data))
        #expect(note.event == "Stop" && note.sessionID == "sess-1" && note.stopHookActive == true)
        #expect(note.tmuxPane == "%9" && note.termProgram == "WezTerm" && note.itermSessionID == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("xyz"))
    }

    /// Skipped hooks: no note and nothing from upstream either (it returns before reading stdin).
    @Test
    func aSkippedHookSendsNothing() throws {
        let helper = Self.helperURL
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "build the helper first: \(helper.path)")
        let receiver = try ScratchReceiver()
        let run = try Self.run(input: HookContextNoteTests.stopInput,
                               environment: Self.environment(scratch: receiver.folder, notes: receiver.url,
                                                             extra: ["OPEN_ISLAND_SKIP_HOOKS": "1"]))
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty && run.stderr.isEmpty)
        #expect(receiver.receive(timeout: 0.3) == nil)
    }

    /// A receiver that never reads: the helper still finishes promptly.
    @Test
    func aHungNoteReceiverNeverSlowsTheHook() throws {
        let helper = Self.helperURL
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "build the helper first: \(helper.path)")
        let receiver = try ScratchReceiver()
        let flood = try #require(HookContextNote(event: "PostToolUse", sessionID: "s").encoded())
        while HookNoteSender.send(flood, to: receiver.url) == .sent {}
        let run = try Self.run(input: HookContextNoteTests.stopInput,
                               environment: Self.environment(scratch: receiver.folder, notes: receiver.url))
        #expect(run.status == 0)
        #expect(run.duration < 5)
    }
}
