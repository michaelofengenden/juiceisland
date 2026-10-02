import Foundation
@testable import IslandEngine
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// An SSH host end to end, with no ssh at all (P740 to P745): the tunnel's process is the remote helper's own `serve`
/// run here under the system's Python 3 with a scratch home, and each remote hook is the helper's `hook` run the same
/// way. Between them run the real frames, relay, request broker, engine and sessions model, with the rig's stand-in for
/// upstream's bridge (`AttentionRig`): a remote session shows tagged with its host, its request waits on the island, and
/// the island's Allow is what the remote helper prints.
@MainActor
@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
struct RemoteEndToEndTests {
    /// The remote's home: short, so `serve`'s socket path fits (P164: scratch only).
    static func remoteHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jrt-\(UUID().uuidString.prefix(6))", isDirectory: true)
        precondition(home.path.hasPrefix(NSTemporaryDirectory()), "scratch only")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".juice-island"), withIntermediateDirectories: true)
        try RemoteHelperScript.source.write(to: home.appendingPathComponent(".juice-island/jr.py"), atomically: true, encoding: .utf8)
        return home
    }

    /// The remote helper's `hook`, as Claude Code on the host would run it.
    static func remoteHook(_ object: [String: Any], home: URL, extra: [String: String] = [:]) -> Task<String, Never> {
        let input = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let script = home.appendingPathComponent(".juice-island/jr.py").path
        return Task.detached {
            let output = try? RemotePython.run([script, "hook", "--source", "claude"], home: home, stdin: input,
                                               extra: ["CLAUDE_CODE_ENTRYPOINT": "cli"].merging(extra) { $1 })
            return output?.stdout ?? ""
        }
    }

    @Test func aRemoteSessionShowsWithItsHostAndTheIslandAnswersItsRequest() async throws {
        let rig = try await AttentionRig()
        let home = try Self.remoteHome()
        defer {
            rig.stop()
            try? FileManager.default.removeItem(at: home)
        }
        let script = home.appendingPathComponent(".juice-island/jr.py")
        let launcher = TunnelLauncher.program(URL(fileURLWithPath: RemotePython.path), prefix: [script.path],
                                              environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let tunnels = RemoteTunnels(endpoints: RemoteRelay.Endpoints(bridge: rig.bridgeURL, broker: rig.requestsURL),
                                    directory: rig.engine.remoteSessions, launcher: launcher, arguments: { _ in ["serve"] })
        defer { tunnels.stopAll() }
        tunnels.update([RemoteTunnels.Host(id: "h1", destination: "ubuntu@gpu1", python: RemotePython.path, script: script.path)])
        await rig.waitUntil { tunnels.states["h1"] == .connected(helper: RemoteHelperScript.version) }

        // A prompt on the host: upstream's bridge (the stand-in) makes the session, and the engine files it under gpu1.
        let session = "remote-1"
        let started = Date()
        rig.upstream.current?.plan(event: "UserPromptSubmit", session: session, events: [
            .sessionStarted(SessionStarted(sessionID: session, title: "train", tool: .claudeCode, origin: .live, initialPhase: .running,
                                           summary: "", timestamp: started,
                                           jumpTarget: JumpTarget(terminalApp: "Unknown", workspaceName: "train", paneTitle: "train",
                                                                  workingDirectory: "/home/ubuntu/train"))),
            .activityUpdated(SessionActivityUpdated(sessionID: session, summary: "Prompt: train the model", phase: .running,
                                                    timestamp: started)),
        ])
        let prompt = Self.remoteHook(["hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": "/home/ubuntu/train",
                                      "prompt": "train the model", "transcript_path": "/home/ubuntu/.claude/projects/t/remote-1.jsonl"],
                                     home: home, extra: ["TMUX": "/tmp/tmux-1000/default,77,0", "TMUX_PANE": "%5"])
        #expect(await prompt.value.isEmpty)
        await rig.waitUntil { rig.row(session) != nil }
        await rig.settle()
        #expect(rig.engine.state.session(id: session)?.isRemote == true)
        #expect(rig.engine.remoteHost(for: session)?.hostName == "gpu1")
        #expect(rig.engine.remoteHost(for: session)?.context.tmuxPane == "%5")
        let row = try #require(rig.row(session))
        #expect(row.host == "gpu1" && row.folder == nil && row.branch == nil && row.accountAlias == nil)
        #expect(rig.upstream.current?.commands.contains { $0.session == session && $0.event == "UserPromptSubmit" } == true)

        // A request on the host: the broker holds it, the island shows it once its window passes, and Allow is printed there.
        let request = Self.remoteHook(["hook_event_name": "PermissionRequest", "session_id": session, "cwd": "/home/ubuntu/train",
                                       "tool_name": "Bash", "tool_input": ["command": "nvidia-smi"], "permission_mode": "default"],
                                      home: home)
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        rig.advance(9)
        await rig.waitUntil { rig.engine.attentionHead(for: session) != nil }
        let head = try #require(rig.engine.attentionHead(for: session))
        #expect(head.isAnswerable && head.agentPID == nil)
        _ = await rig.engine.approve(sessionID: session, decision: .allowOnce)
        let printed = await request.value
        #expect(printed.contains(#""behavior":"allow""#))
        #expect(printed.contains("nvidia-smi") || printed.contains("PermissionRequest"))

        // The tunnel stops: its far end goes, and so does its socket.
        let run = home.appendingPathComponent(".juice-island/run").path
        let sockets = { (FileManager.default.enumerator(atPath: run)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".sock") } }
        #expect(sockets().count == 1)
        tunnels.stopAll()
        await rig.waitUntil { sockets().isEmpty }
        #expect(sockets().isEmpty && tunnels.states["h1"] == .stopped)
    }
}

/// The system's Python 3 with a scratch home (the engine suite has its own copy, `RemoteScript`).
enum RemotePython {
    static let path = "/usr/bin/python3"

    struct Output {
        var status: Int32
        var stdout: String
    }

    static func run(_ arguments: [String], home: URL, stdin: String, extra: [String: String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self))
    }
}
