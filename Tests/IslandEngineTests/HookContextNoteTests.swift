import Darwin
import Foundation
import IslandHookNotes
import Testing

/// The superset helper's context note: only the allowlist, never blocking (spec §3.8). Every socket here is a scratch
/// one in a temp folder; the real hook sockets and the app's own note socket are never bound or sent to.
struct HookContextNoteTests {
    static let stopInput = Data(#"""
    {"hook_event_name":"Stop","session_id":"sess-1","stop_hook_active":true,"cwd":"/tmp/project",
     "transcript_path":"/tmp/t.jsonl","prompt":"a secret prompt","tool_input":{"command":"cat notes"}}
    """#.utf8)

    static let fullEnvironment = [
        "ITERM_SESSION_ID": "w0t1p2:5F1B2C3D-0000-4000-8000-000000000001",
        "TMUX": "/private/tmp/tmux-501/default,4242,0",
        "TMUX_PANE": "%7",
        "TERM_PROGRAM": "iTerm.app",
        "__CFBundleIdentifier": "com.googlecode.iterm2",
        "HOME": "/Users/someone",
        "PATH": "/usr/bin:/bin",
        "ANTHROPIC_API_KEY": "sk-ant-api-not-a-real-key",
        "SECRET_TOKEN": "xyz",
        "CLAUDE_CONFIG_DIR": "/Users/someone/.claude-work",
        "CODEX_HOME": "/Users/someone/.codex-side",
    ]

    @Test
    func aNoteCarriesOnlyTheAllowlist() throws {
        let note = try #require(HookContextNote.make(input: Self.stopInput, environment: Self.fullEnvironment, agentPID: 321))
        #expect(note == HookContextNote(event: "Stop", sessionID: "sess-1", stopHookActive: true,
                                        itermSessionID: "w0t1p2:5F1B2C3D-0000-4000-8000-000000000001",
                                        tmux: "/private/tmp/tmux-501/default,4242,0", tmuxPane: "%7", agentPID: 321,
                                        hostBundleID: "com.googlecode.iterm2", termProgram: "iTerm.app"))
        let data = try #require(note.encoded())
        let text = try #require(String(data: data, encoding: .utf8))
        for secret in ["someone", "sk-ant", "xyz", "secret prompt", "cat notes", "/tmp/project", "t.jsonl", "claude-work", "codex-side", "PATH"] {
            #expect(!text.contains(secret), "\(secret) leaked into \(text)")
        }
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["v", "event", "session_id", "stop_hook_active", "iterm_session_id", "tmux", "tmux_pane",
                              "agent_pid", "host_bundle_id", "term_program"])
        #expect(HookContextNote.decode(data) == note)
    }

    @Test
    func stopHookActiveIsReadOnlyFromAStopAndOnlyAsABoolean() throws {
        let failure = Data(#"{"hook_event_name":"StopFailure","session_id":"s","stop_hook_active":true,"error":"rate_limit"}"#.utf8)
        #expect(try #require(HookContextNote.make(input: failure, environment: [:], agentPID: nil)).stopHookActive == nil)
        let number = Data(#"{"hook_event_name":"Stop","session_id":"s","stop_hook_active":1}"#.utf8)
        #expect(try #require(HookContextNote.make(input: number, environment: [:], agentPID: nil)).stopHookActive == nil)
        let off = Data(#"{"hook_event_name":"Stop","session_id":"s","stop_hook_active":false}"#.utf8)
        #expect(try #require(HookContextNote.make(input: off, environment: [:], agentPID: nil)).stopHookActive == false)
    }

    @Test
    func inputWithoutAnEventOrASessionGetsNoNote() {
        #expect(HookContextNote.make(input: Data("not json".utf8), environment: [:], agentPID: 9) == nil)
        #expect(HookContextNote.make(input: Data(#"{"session_id":"s"}"#.utf8), environment: [:], agentPID: 9) == nil)
        #expect(HookContextNote.make(input: Data(#"{"hook_event_name":"Stop"}"#.utf8), environment: [:], agentPID: 9) == nil)
        #expect(HookContextNote.make(input: Data(#"{"hook_event_name":7,"session_id":"s"}"#.utf8), environment: [:], agentPID: 9) == nil)
    }

    /// A value too long to be a handle is dropped whole, never cut, and the note stays one datagram.
    @Test
    func overlongValuesAreDroppedAndTheNoteFitsOneDatagram() throws {
        let long = String(repeating: "x", count: HookContextNote.fieldLimit + 1)
        let environment = ["ITERM_SESSION_ID": long, "TMUX": long, "TMUX_PANE": long, "TERM_PROGRAM": long, "__CFBundleIdentifier": long]
        let note = try #require(HookContextNote.make(input: Self.stopInput, environment: environment, agentPID: 1))
        #expect(note.itermSessionID == nil && note.tmux == nil && note.tmuxPane == nil && note.termProgram == nil && note.hostBundleID == nil)
        #expect(note.agentPID == nil)  // launchd is never an agent
        let limit = String(repeating: "y", count: HookContextNote.fieldLimit)
        let widest = HookContextNote(event: String(repeating: "E", count: 64), sessionID: String(repeating: "S", count: 128),
                                     stopHookActive: true, itermSessionID: limit, tmux: limit, tmuxPane: limit,
                                     agentPID: Int32.max, hostBundleID: limit, termProgram: limit)
        #expect(try #require(widest.encoded()).count <= HookContextNote.maximumSize)
        #expect(HookContextNote.decode(Data(repeating: 0x20, count: HookContextNote.maximumSize + 1)) == nil)
    }

    @Test
    func theDefaultSocketIsTheAppsOwnAndNeverAHookSocket() {
        let url = HookNoteSocket.defaultURL
        #expect(url.path.hasSuffix("/Library/Application Support/Juice Island/hook-notes.sock"))
        #expect(!url.path.contains("OpenIsland"))
        #expect(!url.path.hasPrefix("/tmp/open-island"))
        #expect(HookNoteSocket.address(for: url) != nil)
        #expect(HookNoteSocket.helperURL(environment: [:]) == url)
        #expect(HookNoteSocket.helperURL(environment: [HookNoteSocket.overrideKey: "/tmp/x.sock"]).path == "/tmp/x.sock")
    }
}

/// A scratch datagram receiver in a short temp folder (AF_UNIX paths are limited to 104 bytes).
final class ScratchReceiver: @unchecked Sendable {
    let folder: URL
    let url: URL
    let fd: Int32

    init(read: Bool = true) throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jin-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("n.sock")
        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        var address = try #require(HookNoteSocket.address(for: url))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
    }

    /// The next datagram, or nil after `timeout`.
    func receive(timeout: TimeInterval = 2) -> Data? {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1_000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }

    deinit {
        close(fd)
        try? FileManager.default.removeItem(at: folder)
    }
}

struct HookNoteSenderTests {
    @Test
    func aNoteReachesAReceiver() throws {
        let receiver = try ScratchReceiver()
        let note = HookContextNote(event: "PreToolUse", sessionID: "s1", tmuxPane: "%1", agentPID: 55)
        #expect(HookNoteSender.send(try #require(note.encoded()), to: receiver.url) == .sent)
        #expect(HookContextNote.decode(try #require(receiver.receive())) == note)
    }

    @Test
    func noReceiverIsNamedAtOnce() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jin-\(UUID().uuidString.prefix(8))")
        let started = Date()
        #expect(HookNoteSender.send(Data("{}".utf8), to: folder.appendingPathComponent("none.sock")) == .noReceiver)
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(HookNoteSender.send(Data("{}".utf8), to: URL(fileURLWithPath: "/" + String(repeating: "p", count: 200))) == .failed(errno: ENAMETOOLONG))
    }

    /// A receiver that never reads (a hung app): once its buffer is full, notes are dropped, and not one send waits.
    @Test
    func aHungReceiverNeverBlocksTheSender() throws {
        let receiver = try ScratchReceiver()
        let data = try #require(HookContextNote(event: "PostToolUse", sessionID: "s1").encoded())
        var results: [HookNoteSender.Result] = []
        let started = Date()
        for _ in 0..<5_000 { results.append(HookNoteSender.send(data, to: receiver.url)) }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(results.contains(.sent))
        #expect(results.contains(.dropped))
        #expect(!results.contains { if case .failed = $0 { true } else { false } })
    }
}

struct ProcessTreeTests {
    struct Table: ProcessTable {
        var entries: [Int32: ProcessEntry]
        func entry(pid: Int32) -> ProcessEntry? { entries[pid] }
    }

    /// Claude Code runs a hook through `/bin/sh -c`; the agent is the first process above the helper that is not a shell.
    @Test
    func theAgentIsTheFirstNonShellAncestor() {
        let table = Table(entries: [
            30: ProcessEntry(pid: 30, parentPID: 20, name: "sh", tty: nil),
            20: ProcessEntry(pid: 20, parentPID: 10, name: "claude", tty: nil),
            10: ProcessEntry(pid: 10, parentPID: 1, name: "zsh", tty: "/dev/ttys012"),
            40: ProcessEntry(pid: 40, parentPID: 1, name: "zsh", tty: nil),
        ])
        #expect(ProcessTree.agentPID(startingAt: 30, table: table) == 20)
        #expect(ProcessTree.agentPID(startingAt: 20, table: table) == 20)
        #expect(ProcessTree.agentPID(startingAt: 40, table: table) == nil)
        #expect(ProcessTree.agentPID(startingAt: 99, table: table) == nil)
    }

    /// P18: the parent shows `??` and the grandparent `ttys012`; the agent's terminal is /dev/ttys012.
    @Test
    func theTTYIsTheFirstOneUpTheTree() {
        let table = Table(entries: [
            20: ProcessEntry(pid: 20, parentPID: 15, name: "claude", tty: nil),
            15: ProcessEntry(pid: 15, parentPID: 10, name: "node", tty: nil),
            10: ProcessEntry(pid: 10, parentPID: 1, name: "zsh", tty: "/dev/ttys012"),
        ])
        #expect(ProcessTree.tty(forPID: 20, table: table) == "/dev/ttys012")
        #expect(ProcessTree.tty(forPID: 1, table: table) == nil)
    }

    /// P139: an agent holds its terminal while it runs and is its terminal's foreground job; a shell back at its
    /// prompt, the agent stopped (Ctrl-Z) or put in the background, or gone, and it does not.
    @Test
    func anAgentHoldsItsTerminalOnlyInTheForeground() {
        func table(agentRuns: Bool = true, foreground: Int32, agentTTY: String? = "/dev/ttys012") -> Table {
            Table(entries: [
                20: ProcessEntry(pid: 20, parentPID: 10, name: "claude", tty: agentTTY, group: 20,
                                 foregroundGroup: agentTTY == nil ? 0 : foreground, runs: agentRuns),
                10: ProcessEntry(pid: 10, parentPID: 1, name: "zsh", tty: "/dev/ttys012", group: 10, foregroundGroup: foreground),
            ])
        }
        #expect(ProcessTree.holdsItsTerminal(pid: 20, table: table(foreground: 20)))
        #expect(!ProcessTree.holdsItsTerminal(pid: 20, table: table(agentRuns: false, foreground: 20)))
        #expect(!ProcessTree.holdsItsTerminal(pid: 20, table: table(foreground: 10)))
        #expect(!ProcessTree.holdsItsTerminal(pid: 30, table: table(foreground: 20)))
        #expect(!ProcessTree.holdsItsTerminal(pid: 10, table: table(foreground: 20)))
        // P18: the agent has no terminal; the shell's has the agent's group in front, or the shell's own.
        #expect(ProcessTree.holdsItsTerminal(pid: 20, table: table(foreground: 20, agentTTY: nil)))
        #expect(!ProcessTree.holdsItsTerminal(pid: 20, table: table(foreground: 10, agentTTY: nil)))
        // Under a launcher that holds the terminal: the launcher's group in front counts; a shell's never does.
        let launched = Table(entries: [
            30: ProcessEntry(pid: 30, parentPID: 25, name: "claude", tty: nil, group: 30),
            25: ProcessEntry(pid: 25, parentPID: 10, name: "node", tty: "/dev/ttys012", group: 25, foregroundGroup: 25),
            10: ProcessEntry(pid: 10, parentPID: 1, name: "zsh", tty: "/dev/ttys012", group: 10, foregroundGroup: 25),
        ])
        #expect(ProcessTree.holdsItsTerminal(pid: 30, table: launched))
    }

    /// The kernel's own word: a child stopped with SIGSTOP (as Ctrl-Z stops the agent) does not run; continued, it
    /// does.
    @Test
    func theSystemTableSeesAStoppedProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer {
            kill(pid, SIGKILL)
            child.waitUntilExit()
        }
        #expect(SystemProcessTable().entry(pid: pid)?.runs == true)
        kill(pid, SIGSTOP)
        var stopped = false
        for _ in 0..<100 where !stopped {
            stopped = SystemProcessTable().entry(pid: pid)?.runs == false
            if !stopped { usleep(10_000) }
        }
        #expect(stopped)
        kill(pid, SIGCONT)
        var running = false
        for _ in 0..<100 where !running {
            running = SystemProcessTable().entry(pid: pid)?.runs == true
            if !running { usleep(10_000) }
        }
        #expect(running)
        let me = try #require(SystemProcessTable().entry(pid: getpid()))
        #expect(me.group == getpgrp())
    }

    @Test
    func theSystemTableReadsThisProcess() throws {
        let me = try #require(SystemProcessTable().entry(pid: getpid()))
        #expect(me.pid == getpid())
        #expect(me.parentPID == getppid())
        #expect(!me.name.isEmpty)
        #expect(SystemProcessTable().entry(pid: -5) == nil)
    }
}
