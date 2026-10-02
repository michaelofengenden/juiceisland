import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// SSH remote sessions (P740 to P748), headless: the tunnel's frames, the routing of a remote hook, every ssh argument
/// list, the tunnel state machine on a fake clock, the tunnels with a fake launcher, and the jump's search of a fixture
/// process list. Nothing here starts ssh or connects anywhere.
struct MuxFrameTests {
    @Test func framesSurviveNoiseBeforeThePreambleAndAnySplit() throws {
        let frames = [MuxFrame(.hello, 0, Data(#"{"v":1}"#.utf8)), MuxFrame(.open, 7), MuxFrame(.data, 7, Data("line\n".utf8)),
                      MuxFrame(.close, 7)]
        let stream = Data("Welcome to the GPU box\nlast login: today\n".utf8) + MuxDecoder.preamble + frames.map { $0.encoded() }.reduce(Data(), +)
        for size in [1, 3, 9, 64, stream.count] {
            var decoder = MuxDecoder()
            var read: [MuxFrame] = []
            var offset = 0
            while offset < stream.count {
                let end = min(stream.count, offset + size)
                read += try decoder.feed(stream.subdata(in: offset..<end))
                offset = end
            }
            #expect(read == frames)
        }
    }

    @Test func aStreamWithNoPreambleOrABadFrameFails() {
        var noise = MuxDecoder()
        #expect(throws: MuxDecoder.Failure.noPreamble) { _ = try noise.feed(Data(repeating: 0x41, count: MuxDecoder.noiseLimit + 1)) }
        var large = MuxDecoder()
        var header = MuxDecoder.preamble + Data([0x44, 0, 0, 0, 1])
        withUnsafeBytes(of: UInt32(MuxDecoder.bodyLimit + 1).bigEndian) { header.append(contentsOf: $0) }
        #expect(throws: MuxDecoder.Failure.tooLarge) { _ = try large.feed(header) }
        var unknown = MuxDecoder()
        #expect(throws: MuxDecoder.Failure.unknownKind(0x5A)) { _ = try unknown.feed(MuxDecoder.preamble + Data([0x5A, 0, 0, 0, 0, 0, 0, 0, 0])) }
    }
}

struct RemoteRoutingTests {
    static func line(_ input: [String: Any], source: String = "claude", entrypoint: String? = "cli", tty: Bool = true,
                     ctx: [String: Any] = [:]) -> RemoteHookLine {
        var object: [String: Any] = ["jr": 1, "v": 1, "source": source, "input": input, "tty": tty, "ctx": ctx]
        if let entrypoint { object["entrypoint"] = entrypoint }
        return RemoteHookLine.decode(try! JSONSerialization.data(withJSONObject: object))!
    }

    nonisolated(unsafe) static let permission: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "r1", "cwd": "/home/me/train", "tool_name": "Bash",
        "tool_input": ["command": "python train.py"], "permission_mode": "default",
        "transcript_path": "/home/me/.claude/projects/x/r1.jsonl", "terminal_tty": "/dev/pts/3", "terminal_app": "iTerm",
        "terminal_session_id": "w0t0p0:ABC", "agent_pid": 4242,
    ]

    @Test func aPermissionRequestGoesToTheBrokerWithNothingThatNamesTheRemotesFilesOrTerminals() throws {
        guard case let .broker(request, fallback) = RemoteRouting.route(Self.line(Self.permission)) else {
            Issue.record("not brokered")
            return
        }
        #expect(request.source == "claude" && request.entrypoint == "cli" && request.hasTerminal)
        #expect(request.agentPID == nil && request.hostBundleID == nil)
        #expect(request.digest == HookInputDigest.of(["command": "python train.py"]))
        let input = try #require(try JSONSerialization.jsonObject(with: request.input) as? [String: Any])
        for key in ["transcript_path", "terminal_tty", "terminal_app", "terminal_session_id"] { #expect(input[key] == nil) }
        #expect(input["remote"] as? Bool == true && input["cwd"] as? String == "/home/me/train")
        guard case let .processClaudeHook(payload) = fallback else {
            Issue.record("no Claude fallback")
            return
        }
        #expect(payload.remote == true && payload.transcriptPath == nil && payload.terminalTTY == nil && payload.hookSource == "claude")
    }

    @Test func otherHooksGoToTheBridgeAsUpstreamsHelperWouldSendThem() {
        var stop = Self.permission
        stop["hook_event_name"] = "Stop"
        guard case let .bridge(.processClaudeHook(payload), timeout) = RemoteRouting.route(Self.line(stop)) else {
            Issue.record("not to the bridge")
            return
        }
        #expect(payload.hookEventName == .stop && payload.remote == true && payload.terminalApp == nil)
        #expect(timeout < 40)
        let codex: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/srv", "model": "gpt",
                                    "permission_mode": "default", "prompt": "go"]
        guard case let .bridge(.processCodexHook(codexPayload), _) = RemoteRouting.route(Self.line(codex, source: "codex")) else {
            Issue.record("Codex not to the bridge")
            return
        }
        #expect(codexPayload.sessionID == "c1" && codexPayload.transcriptPath == nil)
    }

    @Test func whatALocalHelperWouldNotSendIsNotSent() {
        let subagent: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/", "agent_id": "a1",
                                       "model": "gpt", "permission_mode": "default"]
        var preTool = subagent
        preTool["agent_id"] = nil
        preTool["hook_event_name"] = "PreToolUse"
        for line in [Self.line(subagent, source: "codex"), Self.line(preTool, source: "codex"),
                     Self.line(Self.permission, source: "grok"), Self.line(["hook_event_name": "Stop"])] {
            guard case .end = RemoteRouting.route(line) else {
                Issue.record("routed: \(line.source) \(line.event ?? "")")
                continue
            }
        }
        // A line that is not ours is nothing at all.
        #expect(RemoteHookLine.decode(Data(#"{"type":"command","command":{"type":"registerClient"}}"#.utf8)) == nil)
    }

    @Test func theContextKeepsOnlyWhatAJumpCanUse() {
        let good = Self.line(Self.permission, ctx: ["tmux": "/tmp/tmux-1000/default,812,0", "pane": "%12",
                                                    "ssh": "203.0.113.9 52144 10.0.0.2 22"]).context
        #expect(good == RemoteContext(tmuxSocket: "/tmp/tmux-1000/default", tmuxPane: "%12", sshClientPort: 52_144))
        let bad = Self.line(Self.permission, ctx: ["tmux": "relative,1,0", "pane": "%1; rm -rf ~", "ssh": "1.2.3.4 99999 5.6.7.8 22"]).context
        #expect(bad == RemoteContext())
    }
}

struct SSHCommandsTests {
    @Test func everyRunUsesTheOwnersConfigWithTheSafeOptionsOverIt() throws {
        let arguments = try #require(SSHCommands.tunnel(destination: "gpu1", python: "/usr/bin/python3", script: "/home/me/.juice-island/jr.py"))
        let options = stride(from: 0, to: arguments.count, by: 1).filter { arguments[$0] == "-o" }.map { arguments[$0 + 1] }
        for option in ["BatchMode=yes", "ClearAllForwardings=yes", "ControlMaster=no", "ControlPath=none", "UpdateHostKeys=no",
                       "ForwardAgent=no", "PermitLocalCommand=no", "RemoteCommand=none", "RequestTTY=no", "ServerAliveInterval=60"] {
            #expect(options.contains(option))
        }
        // No config file of ours, no forward, no identity: the owner's own config, keys and agent.
        #expect(!arguments.contains("-F") && !arguments.contains("-R") && !arguments.contains("-L") && !arguments.contains("-i"))
        #expect(Array(arguments.suffix(3)) == ["--", "gpu1", "exec '/usr/bin/python3' '/home/me/.juice-island/jr.py' serve"])
    }

    @Test func aDestinationThatCouldBeAnOptionOrACommandIsRefused() {
        for bad in ["-oProxyCommand=sh", "", "gpu 1", "gpu1;ls", "me@gpu1'", "$(id)"] {
            #expect(SSHCommands.arguments(destination: bad, command: "true") == nil)
        }
        for good in ["gpu1", "ubuntu@203.0.113.9", "ssh://me@box:2222", "me@[2001:db8::1]"] {
            #expect(SSHCommands.arguments(destination: good, command: "true") != nil)
        }
        #expect(SSHCommands.tunnel(destination: "gpu1", python: "/usr/bin/python3", script: "/home/o'neil/jr.py") == nil)
    }

    @Test func setUpsShellLineReadsTheSameUnderAnyLoginShell() throws {
        for mode in [SSHCommands.SetupMode.install, .remove] {
            let command = try #require(SSHCommands.setup(destination: "gpu1", mode: mode)?.last)
            #expect(command.hasPrefix("sh -c '") && command.hasSuffix(" \(mode.rawValue)'"))
            let inner = command.dropFirst("sh -c '".count).dropLast()
            #expect(!inner.contains("'") && !inner.contains("!") && !inner.contains("\\"))
        }
    }

    @Test func failuresAreNamedFromSshsOwnWords() {
        #expect(SSHCommands.failure(status: 255, stderr: "me@gpu1: Permission denied (publickey,password).") == .needsKeyLogin)
        #expect(SSHCommands.failure(status: 255, stderr: "Host key verification failed.") == .hostKey)
        #expect(SSHCommands.failure(status: 255, stderr: "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @") == .hostKey)
        #expect(SSHCommands.failure(status: 255, stderr: "ssh: connect to host gpu1 port 22: Operation timed out") == .unreachable)
        #expect(SSHCommands.failure(status: 255, stderr: "Timeout, server gpu1 not responding.") == .unreachable)
        #expect(SSHCommands.failure(status: 127, stderr: "sh: 1: /usr/bin/python3: not found") == .notSetUp)
        #expect(SSHCommands.failure(status: 2, stderr: "python3: can't open file '/home/me/.juice-island/jr.py'") == .notSetUp)
        // S3: an rc file's noise is in the error lines too; its words count only with the status that goes with them.
        let conda = "bash: /home/u/miniconda3/etc/profile.d/conda.sh: No such file or directory\n"
        #expect(SSHCommands.failure(status: 255, stderr: conda + "client_loop: send disconnect: Broken pipe") == .unreachable)
        #expect(SSHCommands.failure(status: 1, stderr: "mesg: /dev/pts/3: Permission denied\nConnection closed") == .unreachable)
        #expect(SSHCommands.failure(status: 0, stderr: conda) == .unreachable)
        #expect(SSHCommands.failure(status: 255, stderr: conda + "me@gpu1: Permission denied (publickey).") == .needsKeyLogin)
        #expect(RemoteSetupFailure.of(status: 97, stderr: "", timedOut: false) == .noPython)
        #expect(RemoteSetupFailure.of(status: 0, stderr: "", timedOut: true) == .timedOut)
        #expect(RemoteSetupFailure.of(status: 255, stderr: "Permission denied (publickey).", timedOut: false)?.words == "Needs key login")
    }

    @Test func theResultLineIsFoundAmongAnRcFilesNoise() {
        let stdout = "conda activated\nJR-RESULT {\"v\":1,\"python\":\"/usr/bin/python3\",\"home\":\"/home/me\",\"script\":\"/home/me/.juice-island/jr.py\",\"claude\":true,\"codex\":true,\"codexFeature\":\"on\"}\n"
        #expect(RemoteSetupResult.install(stdout: stdout) == RemoteSetupResult(helper: 1, python: "/usr/bin/python3",
                                                                                script: "/home/me/.juice-island/jr.py", claude: true,
                                                                                codex: true, codexFeature: "on"))
        #expect(RemoteSetupResult.install(stdout: "JR-RESULT {\"v\":1,\"python\":\"python3\",\"script\":\"x\"}") == nil)
    }

    /// A host that stalls before it reads the helper (a hung `ProxyCommand`) still ends at the timeout: `sleep` stands
    /// in for ssh and never reads its stdin, which is larger than any pipe holds.
    @Test func aRunThatNeverReadsItsInputStillEndsAtTheTimeout() async {
        let started = Date()
        let output = await Task.detached {
            SSHRunner.runProcess(["20"], stdin: Data(repeating: 0x41, count: 1 << 20), timeout: 1,
                                 executable: URL(fileURLWithPath: "/bin/sleep"))
        }.value
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func rowsNameTheHostWithoutItsUser() {
        #expect(RemoteDestination.hostName("gpu1") == "gpu1")
        #expect(RemoteDestination.hostName("ubuntu@203.0.113.9") == "203.0.113.9")
        #expect(RemoteDestination.hostName("ssh://me@box:2222") == "box")
        #expect(RemoteDestination.hostName("me@[2001:db8::1]") == "2001:db8::1")
    }
}

struct TunnelMachineTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func upThenDownThenBackWithBackoff() {
        var machine = TunnelMachine()
        #expect(machine.handle(.start, now: Self.t0) == [.launch] && machine.state == .connecting)
        #expect(machine.handle(.ready(helper: 1), now: Self.t0).isEmpty && machine.state == .connected(helper: 1))
        // Dropped: 2 s, then 5 s, each due only on its own date.
        #expect(machine.handle(.exited(.unreachable), now: Self.t0) == [.schedule(Self.t0.addingTimeInterval(2))])
        #expect(machine.handle(.retryDue(Self.t0.addingTimeInterval(1)), now: Self.t0).isEmpty)
        #expect(machine.handle(.retryDue(Self.t0.addingTimeInterval(2)), now: Self.t0) == [.launch])
        #expect(machine.handle(.exited(.unreachable), now: Self.t0.addingTimeInterval(3)) == [.schedule(Self.t0.addingTimeInterval(8))])
        // Up again: the next drop starts from 2 s.
        _ = machine.handle(.retryDue(Self.t0.addingTimeInterval(8)), now: Self.t0.addingTimeInterval(8))
        _ = machine.handle(.ready(helper: 1), now: Self.t0.addingTimeInterval(9))
        #expect(machine.handle(.exited(.unreachable), now: Self.t0.addingTimeInterval(10)) == [.schedule(Self.t0.addingTimeInterval(12))])
    }

    @Test func aHostThatStaysDownGoesOfflineAfterAboutTwentyFiveMinutesAndWaits() {
        var machine = TunnelMachine()
        var clock = Self.t0
        _ = machine.handle(.start, now: clock)
        var waited: TimeInterval = 0
        for attempt in 1...TunnelMachine.delays.count {
            let effects = machine.handle(.exited(.unreachable), now: clock)
            guard case let .schedule(due)? = effects.first else {
                Issue.record("no retry at attempt \(attempt)")
                return
            }
            waited += due.timeIntervalSince(clock)
            clock = due
            #expect(machine.handle(.retryDue(due), now: clock) == [.launch])
        }
        #expect(machine.handle(.exited(.unreachable), now: clock).isEmpty && machine.state == .offline(.unreachable))
        #expect(waited > 20 * 60 && waited < 30 * 60)
        // Nothing more by itself; a wake tries at once.
        #expect(machine.handle(.retryDue(clock), now: clock).isEmpty)
        #expect(machine.handle(.wake, now: clock) == [.launch] && machine.state == .connecting)
    }

    @Test func aLoginOrHostKeyProblemWaitsForTheOwner() {
        for failure in [TunnelFailure.needsKeyLogin, .hostKey, .notSetUp, .protocolError] {
            var machine = TunnelMachine()
            _ = machine.handle(.start, now: Self.t0)
            #expect(machine.handle(.exited(failure), now: Self.t0).isEmpty && machine.state == .offline(failure))
            #expect(machine.handle(.start, now: Self.t0) == [.launch])
        }
    }

    @Test func stoppingEndsTheProcessAndIgnoresItsExit() {
        var machine = TunnelMachine()
        _ = machine.handle(.start, now: Self.t0)
        _ = machine.handle(.ready(helper: 1), now: Self.t0)
        #expect(machine.handle(.stop, now: Self.t0) == [.terminate] && machine.state == .stopped)
        #expect(machine.handle(.exited(.unreachable), now: Self.t0).isEmpty && machine.state == .stopped)
        #expect(machine.handle(.wake, now: Self.t0).isEmpty)
        // N3: a connected tunnel starts over on a wake, as one from before the sleep may be dead with nothing to say so.
        _ = machine.handle(.start, now: Self.t0)
        _ = machine.handle(.ready(helper: 1), now: Self.t0)
        #expect(machine.handle(.wake, now: Self.t0) == [.launch] && machine.state == .connecting)
    }

    /// N4: a network change starts every tunnel over, connected or waiting, but leaves a host that waits on the owner (a
    /// key login, a host key, Set up) for a click or a wake: a host's login rules may count every failed try.
    @Test func aNetworkChangeLeavesWhatWaitsOnTheOwner() {
        for failure in [TunnelFailure.needsKeyLogin, .hostKey, .notSetUp, .protocolError] {
            var machine = TunnelMachine()
            _ = machine.handle(.start, now: Self.t0)
            _ = machine.handle(.exited(failure), now: Self.t0)
            #expect(machine.handle(.networkChanged, now: Self.t0).isEmpty && machine.state == .offline(failure))
            #expect(machine.handle(.wake, now: Self.t0) == [.launch])
        }
        var machine = TunnelMachine()
        _ = machine.handle(.start, now: Self.t0)
        _ = machine.handle(.ready(helper: 1), now: Self.t0)
        #expect(machine.handle(.networkChanged, now: Self.t0) == [.launch] && machine.state == .connecting)
        _ = machine.handle(.exited(.unreachable), now: Self.t0)
        #expect(machine.handle(.networkChanged, now: Self.t0) == [.launch] && machine.failures == 0)
        #expect(machine.handle(.networkChanged, now: Self.t0).isEmpty)
    }
}

/// The tunnels with a fake launcher and a scheduler the test runs by hand.
@MainActor
struct RemoteTunnelsTests {
    final class FakeProcess: TunnelProcess, @unchecked Sendable {
        let arguments: [String]
        let onOutput: @Sendable (Data) -> Void
        let onExit: @Sendable (Int32, String) -> Void
        var terminated = false
        var written = Data()
        init(_ arguments: [String], _ onOutput: @escaping @Sendable (Data) -> Void, _ onExit: @escaping @Sendable (Int32, String) -> Void) {
            self.arguments = arguments
            self.onOutput = onOutput
            self.onExit = onExit
        }
        func write(_ data: Data) { written.append(data) }
        func terminate() { terminated = true }
    }

    final class Launches: @unchecked Sendable {
        var all: [FakeProcess] = []
    }

    static func make(_ launches: Launches, scheduled: EngineFixtures.Box<[(TimeInterval, @MainActor () -> Void)]>) -> RemoteTunnels {
        let launcher = TunnelLauncher { arguments, onOutput, onExit in
            let process = FakeProcess(arguments, onOutput, onExit)
            launches.all.append(process)
            return process
        }
        return RemoteTunnels(endpoints: RemoteRelay.Endpoints(bridge: URL(fileURLWithPath: "/nonexistent/b.sock"), broker: nil),
                             directory: RemoteSessionDirectory(), launcher: launcher,
                             schedule: { delay, work in scheduled.update { $0.append((delay, work)) } })
    }

    static let host = RemoteTunnels.Host(id: "h1", destination: "me@gpu1", python: "/usr/bin/python3", script: "/home/me/.juice-island/jr.py")

    func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aHostIsLaunchedConnectedAndRetriedAfterADrop() async {
        let launches = Launches()
        let scheduled = EngineFixtures.Box<[(TimeInterval, @MainActor () -> Void)]>([])
        let tunnels = Self.make(launches, scheduled: scheduled)
        tunnels.update([Self.host])
        #expect(launches.all.count == 1 && tunnels.states["h1"] == .connecting)
        #expect(launches.all[0].arguments.suffix(2) == ["me@gpu1", "exec '/usr/bin/python3' '/home/me/.juice-island/jr.py' serve"])
        launches.all[0].onOutput(MuxDecoder.preamble + MuxFrame(.hello, 0, Data(#"{"v":1}"#.utf8)).encoded())
        await until { tunnels.states["h1"] == .connected(helper: 1) }
        #expect(tunnels.states["h1"] == .connected(helper: 1))
        launches.all[0].onExit(255, "Connection to gpu1 closed by remote host.")
        await until { scheduled.current.count == 1 }
        #expect(abs((scheduled.current.first?.0 ?? 0) - 2) < 0.5)
        guard case .retrying = tunnels.states["h1"] else {
            Issue.record("not retrying: \(String(describing: tunnels.states["h1"]))")
            return
        }
        // The same hosts again change nothing; the retry falls due and launches anew.
        tunnels.update([Self.host])
        #expect(launches.all.count == 1)
        scheduled.current.first?.1()
        #expect(launches.all.count == 2 && tunnels.states["h1"] == .connecting)
        // Removing the host stops it, and its old process's late exit is ignored.
        tunnels.update([])
        #expect(launches.all[1].terminated && tunnels.states["h1"] == nil)
        launches.all[1].onExit(0, "")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(tunnels.states["h1"] == nil && launches.all.count == 2)
    }

    /// S3: once the helper said hello, the login, the host key and the helper were fine: an end then is a drop, whatever
    /// an rc file left in the error lines, and it is tried again.
    @Test func anEndAfterTheHelloIsADrop() async {
        let launches = Launches()
        let scheduled = EngineFixtures.Box<[(TimeInterval, @MainActor () -> Void)]>([])
        let tunnels = Self.make(launches, scheduled: scheduled)
        tunnels.update([Self.host])
        launches.all[0].onOutput(MuxDecoder.preamble + MuxFrame(.hello, 0, Data(#"{"v":1}"#.utf8)).encoded())
        await until { tunnels.states["h1"] == .connected(helper: 1) }
        launches.all[0].onExit(255, "bash: /home/u/miniconda3/etc/profile.d/conda.sh: No such file or directory\nPermission denied\n")
        await until { scheduled.current.count == 1 }
        guard case .retrying(_, .unreachable)? = tunnels.states["h1"] else {
            Issue.record("not retried: \(String(describing: tunnels.states["h1"]))")
            return
        }
    }

    @Test func needsKeyLoginWaitsForConnect() async {
        let launches = Launches()
        let scheduled = EngineFixtures.Box<[(TimeInterval, @MainActor () -> Void)]>([])
        let tunnels = Self.make(launches, scheduled: scheduled)
        tunnels.update([Self.host])
        launches.all[0].onExit(255, "me@gpu1: Permission denied (publickey).")
        await until { tunnels.states["h1"] == .offline(.needsKeyLogin) }
        #expect(tunnels.states["h1"] == .offline(.needsKeyLogin) && scheduled.current.isEmpty)
        tunnels.connect("h1")
        #expect(launches.all.count == 2)
        tunnels.stopAll()
        #expect(launches.all[1].terminated && tunnels.states["h1"] == .stopped)
        // Back live: a stopped host starts again.
        tunnels.update([Self.host])
        #expect(launches.all.count == 3)
    }
}

struct RemoteJumpTests {
    static let ps = """
      101 ttys001     02:10:05 -zsh
      202 ttys001     01:00:00 ssh gpu1
      303 ttys004        10:30 /usr/bin/ssh -p 2222 -o ServerAliveInterval=30 me@gpu1
      404 ??             20:00 /usr/bin/ssh -o BatchMode=yes -T -e none -- gpu1 exec python3 jr.py serve
      505 ttys005        05:00 ssh -W gpu1:22 jump
      606 ttys006        04:00 ssh -N -L 8888:localhost:8888 gpu1
      707 ttys007     1-02:00:00 ssh -l me trainer
      808 ttys008        00:30 ssh -O check gpu1
    """

    @Test func onlyInteractiveSshTabsToTheHostAreCandidates() {
        let processes = RemoteJump.sshProcesses(psOutput: Self.ps)
        #expect(processes.map(\.pid) == [202, 303, 505, 606, 707, 808])
        #expect(processes.first?.tty == "/dev/ttys001" && processes.first?.elapsed == 3_600)
        #expect(RemoteJump.destination(of: ["ssh", "-p", "2222", "-o", "X=1", "me@gpu1"]) == "me@gpu1")
        #expect(RemoteJump.destination(of: ["ssh", "-p2222", "-tt", "gpu1", "tmux", "attach"]) == "gpu1")
        #expect(RemoteJump.destination(of: ["ssh", "-l", "me", "trainer"]) == "trainer")
        #expect(RemoteJump.destination(of: ["ssh", "-W", "gpu1:22", "jump"]) == nil)
        #expect(RemoteJump.destination(of: ["ssh", "-N", "-L", "8888:localhost:8888", "gpu1"]) == nil)
        #expect(RemoteJump.elapsedSeconds("1-02:00:00") == 93_600 && RemoteJump.elapsedSeconds("10:30") == 630)
    }

    @Test func theNewestTabWinsUnlessTheClientPortSaysWhich() {
        let processes = RemoteJump.sshProcesses(psOutput: Self.ps)
        #expect(RemoteJump.pick(processes, destination: "gpu1", clientPort: nil, localPorts: { _ in [] })?.pid == 303)
        #expect(RemoteJump.pick(processes, destination: "me@gpu1", clientPort: 52_144,
                                localPorts: { $0 == 202 ? [52_144] : [60_000] })?.pid == 202)
        #expect(RemoteJump.pick(processes, destination: "me@trainer", clientPort: nil, localPorts: { _ in [] })?.pid == 707)
        #expect(RemoteJump.pick(processes, destination: "elsewhere", clientPort: nil, localPorts: { _ in [] }) == nil)
    }

    @Test func theTabsTtyAndAppMakeAnOrdinaryTarget() throws {
        let process = try #require(RemoteJump.sshProcesses(psOutput: Self.ps).first { $0.pid == 303 })
        let (target, context) = RemoteJump.target(for: process, workspace: "train", appForPID: { _ in "com.googlecode.iterm2" })
        #expect(target.terminalApp == "iTerm" && target.terminalTTY == "/dev/ttys004" && target.workspaceName == "train")
        #expect(context == JumpContext(hostBundleID: "com.googlecode.iterm2", agentPID: 303))
        #expect(RemoteJump.localPorts(of: getpid()).allSatisfy { $0 > 0 })
    }
}

/// The engine's side: a session the relay filed is remote, a removed host's sessions end, and a jump goes to the
/// local ssh tab, or says there is none.
@MainActor
struct RemoteEngineTests {
    static func start(_ id: String) -> AgentEvent {
        .sessionStarted(SessionStarted(sessionID: id, title: "train", tool: .claudeCode, origin: .live, initialPhase: .completed,
                                       summary: "", timestamp: EngineFixtures.now,
                                       jumpTarget: JumpTarget(terminalApp: "Unknown", workspaceName: "train", paneTitle: "train",
                                                              workingDirectory: "/home/me/train")))
    }

    @Test func aFiledSessionIsRemoteAndARemovedHostsSessionsEnd() {
        let engine = EngineFixtures.engine()
        engine.remoteSessions.record("r1", RemoteSessionDirectory.Entry(hostID: "h1", hostName: "gpu1", destination: "gpu1"))
        engine.ingest(Self.start("r1"), ingress: .bridge)
        engine.ingest(Self.start("l1"), ingress: .bridge)
        #expect(engine.state.session(id: "r1")?.isRemote == true && engine.state.session(id: "l1")?.isRemote == false)
        #expect(engine.remoteHost(for: "r1")?.hostName == "gpu1" && engine.remoteHost(for: "l1") == nil)
        // A limit's "Open in" never opens a remote session's folder here: it is the host's.
        #expect(engine.freshLaunch(sessionID: "r1", provider: .claude, profileFolder: "/Users/me/.claude-work") == nil)
        #expect(engine.freshLaunch(sessionID: "l1", provider: .claude, profileFolder: "/Users/me/.claude-work") != nil)
        engine.endRemoteSessions(hostID: "h1")
        #expect(engine.state.session(id: "r1")?.isSessionEnded != false && engine.remoteHost(for: "r1") == nil)
        #expect(engine.state.session(id: "l1")?.isSessionEnded == false)
    }

    /// S4: an SSH host's Codex approval opens no card, held or not: Codex's own prompt is in the ssh tab, and with no
    /// rollout on this Mac nothing here would see the call settled, so the card would sound at 8 s and stay for the turn.
    @Test func aRemoteCodexApprovalOpensNoCard() throws {
        for answersCodex in [false, true] {
            let s = AttentionScene()
            s.engine.answersCodex = answersCodex
            s.begin("c1", tool: .codex)
            s.engine.remoteSessions.record("c1", RemoteSessionDirectory.Entry(hostID: "h1", hostName: "gpu1", destination: "gpu1"))
            // As the relay hands it over: no rollout path, no pid, no host app.
            var object = AttentionScene.codex("PermissionRequest")
            object["transcript_path"] = nil
            object["remote"] = true
            let line = HookRequestLine(source: "codex", input: try JSONSerialization.data(withJSONObject: object),
                                       digest: object["tool_input"].flatMap(HookInputDigest.of), entrypoint: nil, agentPID: nil,
                                       hostBundleID: nil, hasTerminal: true)
            let hold = AttentionPolicy.brokerHold(line, object, answersSubagents: false, answersCodex: answersCodex)
            if hold.held { s.broker.held.update { _ = $0.insert("r1") } }
            s.engine.takeBrokeredRequest(BrokeredRequest(id: "r1", line: line, object: object, held: hold.held, at: s.clock.current,
                                                         bound: hold.bound))
            s.at(30)
            #expect(s.engine.openRequests.isEmpty && s.needsYou.isEmpty && s.broker.held.current.isEmpty)
            #expect(s.engine.attentionTally.notShown["remote"] == 1)
        }
    }

    @Test func aRemoteJumpGoesToTheLocalSshTabOrSaysThereIsNone() async {
        let opened = EngineFixtures.Box<[String]>([])
        let selected = EngineFixtures.Box<[String]>([])
        let processes = EngineFixtures.Box<String?>(RemoteJumpTests.ps)
        let engine = EngineFixtures.engine(configure: { dependencies in
            var runner = JumpRunner()
            runner.isAppRunning = { _ in true }
            runner.appURL = { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
            runner.appleScript = { script, _ in
                opened.update { $0.append(script) }
                if script.contains("set selected of aTab") { return "matched\u{1f}/dev/ttys004" }
                return script.contains("selected tab of front window") ? "/dev/ttys004" : ""
            }
            runner.open = { _, _ in }
            runner.frontmostBundleID = { "com.apple.Terminal" }
            runner.verifyWindow = 0
            dependencies.jumpRunner = runner
            dependencies.remoteProcesses = { processes.current }
            dependencies.localPorts = { _ in [] }
            dependencies.appForPID = { _ in "com.apple.Terminal" }
        })
        engine.onRemoteJump = { host, context in selected.update { $0.append("\(host) \(context.tmuxPane ?? "")") } }
        engine.remoteSessions.record("r1", RemoteSessionDirectory.Entry(hostID: "h1", hostName: "gpu1", destination: "gpu1",
                                                                        context: RemoteContext(tmuxSocket: "/tmp/tmux-1/default", tmuxPane: "%3")))
        engine.ingest(Self.start("r1"), ingress: .bridge)
        let outcome = await engine.jump(sessionID: "r1")
        #expect(outcome.host == "Terminal" && outcome.result == .matched)
        #expect(opened.current.contains { $0.contains("/dev/ttys004") })
        #expect(selected.current == ["h1 %3"])
        processes.update { $0 = "  1 ttys001 00:10 -zsh\n" }
        let none = await engine.jump(sessionID: "r1")
        #expect(none.result == .noTarget && none.message == "No ssh tab to gpu1 on this Mac.")
        #expect(selected.current.count == 1)
    }
}
