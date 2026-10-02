import Darwin
import Foundation
import Testing
@testable import IslandEngine

/// The remote helper's install and remove (P749, P750), run for real under the system's Python 3 against fixture
/// homes in a short temp folder: nothing connects anywhere, and no file outside the fixture home is read or written.
@Suite(.serialized, .enabled(if: RemoteScript.pythonAvailable))
struct RemoteScriptTests {
    @Test func theSwiftVersionIsTheScripts() {
        #expect(RemoteHelperScript.source.contains("\nVERSION = \(RemoteHelperScript.version)\n"))
        #expect(RemoteHelperScript.source.hasPrefix("#!/usr/bin/env python3\n"))
    }

    static let ownSettings = """
    {
      "model": "opus",
      "env": {"API_TIMEOUT_MS": "60000"},
      "permissions": {"allow": ["Bash(ls:*)"]},
      "hooks": {
        "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh", "timeout": 5}]}],
        "Notification": []
      }
    }
    """

    @Test func installAddsOursAndKeepsEverythingElse() throws {
        let home = try RemoteScript.Home()
        try home.write(".claude/settings.json", Self.ownSettings)
        let run = try home.run("install")
        #expect(run.status == 0)
        let result = try #require(RemoteSetupResult.install(stdout: run.stdout))
        #expect(result.helper == RemoteHelperScript.version && result.claude && !result.codex && result.codexFeature == nil)
        #expect(result.script == home.url.path + "/.juice-island/jr.py" && result.python.hasPrefix("/"))
        let settings = try home.json(".claude/settings.json")
        #expect(settings["model"] as? String == "opus" && (settings["env"] as? [String: String])?["API_TIMEOUT_MS"] == "60000")
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == Set(ClaudeHookEvents.all))
        // The owner's own entries first, ours after, one per event.
        #expect(RemoteScript.commands(hooks["Stop"]).first == "say done" && RemoteScript.commands(hooks["Stop"]).count == 2)
        #expect(RemoteScript.isOurs(RemoteScript.commands(hooks["Stop"]).last))
        #expect(RemoteScript.commands(hooks["PreToolUse"]).first == "guard.sh" && RemoteScript.isOurs(RemoteScript.commands(hooks["PreToolUse"]).last))
        #expect(hooks["PreToolUse"]?.first?["matcher"] as? String == "Bash")
        let permission = try #require(hooks["PermissionRequest"]?.last?["hooks"] as? [[String: Any]])
        #expect(permission.first?["timeout"] as? Int == 86_400 && hooks["PermissionRequest"]?.last?["matcher"] as? String == "*")
        for event in ClaudeHookEvents.all {
            #expect(RemoteScript.commands(hooks[event]).filter { $0.contains("/.juice-island/jr.py") }.count == 1)
        }
        // The helper is in place, the staged copy gone, owner-only.
        #expect(home.exists(".juice-island/jr.py") && !home.exists(".juice-island/jr.py.new"))
        #expect(try home.mode(".juice-island/jr.py") == 0o700)
    }

    @Test func installAgainKeepsOneEntryPerEventAndRemoveTakesExactlyOursOut() throws {
        let home = try RemoteScript.Home()
        try home.write(".claude/settings.json", Self.ownSettings)
        let before = try home.json(".claude/settings.json")
        #expect(try home.run("install").status == 0)
        #expect(try home.run("install").status == 0)
        let hooks = try #require(try home.json(".claude/settings.json")["hooks"] as? [String: [[String: Any]]])
        for event in ClaudeHookEvents.all {
            #expect(RemoteScript.commands(hooks[event]).filter { $0.contains("/.juice-island/jr.py") }.count == 1)
        }
        // The owner adds a hook to an event only we had: Remove keeps it.
        var edited = try home.json(".claude/settings.json")
        var editedHooks = edited["hooks"] as! [String: Any]
        editedHooks["PreCompact"] = (editedHooks["PreCompact"] as! [Any]) + [["hooks": [["type": "command", "command": "mine.sh"]]]]
        edited["hooks"] = editedHooks
        try home.write(".claude/settings.json", String(decoding: try JSONSerialization.data(withJSONObject: edited), as: UTF8.self))
        let removed = try home.run("remove")
        #expect(removed.status == 0 && removed.stdout.contains(#"JR-RESULT {"v":\#(RemoteHelperScript.version),"removed":true}"#))
        var after = try home.json(".claude/settings.json")
        var afterHooks = try #require(after["hooks"] as? [String: Any])
        #expect(RemoteScript.commands(afterHooks["PreCompact"] as? [[String: Any]]) == ["mine.sh"])
        afterHooks["PreCompact"] = nil
        after["hooks"] = afterHooks
        // Everything else is as it was, the empty Notification list the owner had included.
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
        #expect(!home.exists(".juice-island"))
    }

    @Test func aSettingsFileSetUpCreatedGoesWithRemove() throws {
        let home = try RemoteScript.Home()
        #expect(try home.run("install").status == 0)
        #expect(home.exists(".claude/settings.json"))
        #expect(try home.mode(".claude/settings.json") == 0o600)
        #expect(try home.run("remove").status == 0)
        #expect(!home.exists(".claude/settings.json"))
    }

    @Test func aSettingsFileThatIsNotJSONIsRefusedAndLeftAlone() throws {
        let home = try RemoteScript.Home()
        try home.write(".claude/settings.json", "{ \"model\": \"opus\", // a comment\n}")
        let run = try home.run("install")
        #expect(run.status == 98 && run.stderr.contains("JR-ERROR settings.json is not valid JSON"))
        #expect(try home.read(".claude/settings.json") == "{ \"model\": \"opus\", // a comment\n}")
        #expect(RemoteSetupFailure.of(status: run.status, stderr: run.stderr, timedOut: false) == .refused("settings.json is not valid JSON"))
        // Nothing was put in place: the next Set up stages it again.
        #expect(!home.exists(".juice-island/jr.py"))
    }

    @Test func codexHooksAndItsFeatureLineComeAndGoExactly() throws {
        let home = try RemoteScript.Home()
        let config = "model = \"gpt\"\n\n[tui]\ntheme = \"dark\"\n"
        try home.write(".codex/config.toml", config)
        try home.write(".codex/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify.sh"}]}]}}"#)
        let run = try home.run("install")
        let result = try #require(RemoteSetupResult.install(stdout: run.stdout))
        #expect(result.codex && result.codexFeature == "added")
        #expect(try home.read(".codex/config.toml") == config + "\n[features]\nhooks = true\n")
        let hooks = try #require(try home.json(".codex/hooks.json")["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == Set(CodexHookEvents.all))
        #expect(RemoteScript.commands(hooks["Stop"]).first == "notify.sh")
        #expect(RemoteScript.isOurs(RemoteScript.commands(hooks["Stop"]).last, source: "codex"))
        #expect(hooks["SessionStart"]?.last?["matcher"] as? String == "startup|resume")
        #expect(try home.run("remove").status == 0)
        #expect(try home.read(".codex/config.toml") == config)
        #expect(try home.read(".codex/hooks.json").contains("notify.sh"))
        #expect(try home.json(".codex/hooks.json")["hooks"].flatMap { $0 as? [String: Any] }?.keys.sorted() == ["Stop"])
    }

    @Test func aFeatureTheOwnerSetIsLeftAsItIs() throws {
        for (config, word) in [("[features]\nhooks = false\n", "off"), ("[features]\ncodex_hooks = true\n", "on"),
                               ("features.hooks = true\n", "unknown"), ("features = { hooks = true }\n", "unknown")] {
            let home = try RemoteScript.Home()
            try home.write(".codex/config.toml", config)
            let result = try #require(RemoteSetupResult.install(stdout: try home.run("install").stdout))
            #expect(result.codexFeature == word)
            #expect(try home.read(".codex/config.toml") == config)
            #expect(try home.run("remove").status == 0)
            #expect(try home.read(".codex/config.toml") == config)
        }
    }

    @Test func aHookWithNoTunnelEndsAtOnceAndPrintsNothing() throws {
        let home = try RemoteScript.Home()
        let started = Date()
        let run = try home.run("hook", "--source", "claude", stdin: #"{"hook_event_name":"PermissionRequest","session_id":"s1"}"#)
        #expect(run.status == 0 && run.stdout.isEmpty)
        #expect(Date().timeIntervalSince(started) < 5)
        // A stale socket in this host's folder (no one listens) is cleared on the way.
        let folder = try home.runDir()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stale = folder + "/s-0badc0de.sock"
        RemoteScript.leaveStaleSocket(at: stale)
        #expect(FileManager.default.fileExists(atPath: stale))
        #expect(try home.run("hook", "--source", "claude", stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#).stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stale))
    }

    /// M1: a refusal of any file (here Codex's config.toml, a dotfiles link) leaves every file as it was, and the helper
    /// is not put in place: no hook entry is ever left naming a script that is not there.
    @Test func aRefusalAnywhereLeavesEveryFileAsItWas() throws {
        let home = try RemoteScript.Home()
        try home.write(".claude/settings.json", Self.ownSettings)
        let codexHooks = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify.sh"}]}]}}"#
        try home.write(".codex/hooks.json", codexHooks)
        try home.write("dotfiles/config.toml", "model = \"gpt\"\n")
        try FileManager.default.createSymbolicLink(atPath: home.url.appendingPathComponent(".codex/config.toml").path,
                                                   withDestinationPath: home.url.appendingPathComponent("dotfiles/config.toml").path)
        let run = try home.run("install")
        #expect(run.status == 98 && run.stderr.contains("JR-ERROR config.toml is a link"))
        #expect(try home.read(".claude/settings.json") == Self.ownSettings)
        #expect(try home.read(".codex/hooks.json") == codexHooks)
        #expect(try home.read("dotfiles/config.toml") == "model = \"gpt\"\n")
        #expect(!home.exists(".juice-island/jr.py") && !home.exists(".juice-island/installed.json"))
    }

    /// M1: an entry whose helper is gone (a Set up cut short, the folder deleted by hand) ends quietly with status 0, never
    /// Python's 2, which Claude Code and Codex read as a block.
    @Test func anEntryWhoseHelperIsGoneEndsQuietly() throws {
        let home = try RemoteScript.Home()
        try home.write(".codex/config.toml", "")
        #expect(try home.run("install").status == 0)
        try FileManager.default.removeItem(at: home.url.appendingPathComponent(".juice-island/jr.py"))
        let claude = try #require(try home.json(".claude/settings.json")["hooks"] as? [String: [[String: Any]]])
        let codex = try #require(try home.json(".codex/hooks.json")["hooks"] as? [String: [[String: Any]]])
        let commands = RemoteScript.commands(claude["PreToolUse"]) + RemoteScript.commands(codex["PermissionRequest"])
        #expect(commands.count == 2)
        for command in commands {
            let ran = try RemoteScript.shell(command, home: home.url, stdin: #"{"hook_event_name":"PreToolUse","session_id":"s1"}"#)
            #expect(ran.status == 0 && ran.stdout.isEmpty && ran.stderr.isEmpty)
        }
    }

    /// S1: a tunnel whose Mac side went quiet (asleep, off the network: sshd has not noticed) keeps a hook a few seconds at
    /// most, then its serve takes the socket away and ends, so later hooks end at once.
    @Test func aServeWhoseMacIsSilentLetsItsHooksGo() throws {
        let home = try RemoteScript.Home()
        let serve = try RemoteScript.Serve(home: home)
        defer { serve.stop() }
        RemoteScript.wait { home.sockets().count == 1 }
        #expect(home.sockets().count == 1)
        let started = Date()
        let run = try home.run("hook", "--source", "claude",
                               stdin: #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash"}"#)
        #expect(run.status == 0 && run.stdout.isEmpty)
        #expect(Date().timeIntervalSince(started) < 15)
        RemoteScript.wait { !serve.isRunning }
        #expect(!serve.isRunning && home.sockets().isEmpty)
        let again = Date()
        #expect(try home.run("hook", "--source", "claude", stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#).stdout.isEmpty)
        #expect(Date().timeIntervalSince(again) < 3)
    }

    /// N5: hosts that share one home folder (NFS) each keep their own sockets: a socket another host made, which this
    /// one cannot reach, is never swept by this one's hook or serve.
    @Test func hostsSharingAHomeNeverSweepEachOthersSockets() throws {
        let home = try RemoteScript.Home()
        // gpu2's serve makes its socket; seen from gpu1 it is a file nobody answers on, as an NFS socket is.
        let other = try RemoteScript.Serve(home: home, hostname: "gpu2")
        RemoteScript.wait { home.sockets().count == 1 }
        let socket = try #require(home.sockets().first)
        other.kill()
        #expect(FileManager.default.fileExists(atPath: socket))
        let run = try home.run("hook", "--source", "claude", stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#,
                               hostname: "gpu1")
        #expect(run.status == 0 && run.stdout.isEmpty)
        #expect(FileManager.default.fileExists(atPath: socket))
        let mine = try RemoteScript.Serve(home: home, hostname: "gpu1")
        defer { mine.stop() }
        RemoteScript.wait { home.sockets().count == 2 }
        #expect(home.sockets().contains(socket) && home.sockets().count == 2)
    }

    @Test func skipVariablesKeepTheHookQuiet() throws {
        let home = try RemoteScript.Home()
        let run = try home.run("hook", "--source", "claude", stdin: #"{"hook_event_name":"Stop","session_id":"s1"}"#,
                               extra: ["OPEN_ISLAND_SKIP_HOOKS": "1"])
        #expect(run.status == 0 && run.stdout.isEmpty)
    }
}

/// Runs the remote helper locally with a fixture home.
enum RemoteScript {
    static let python = "/usr/bin/python3"
    static var pythonAvailable: Bool { FileManager.default.isExecutableFile(atPath: python) }
    /// The hook commands of an event's groups, in order.
    static func commands(_ groups: [[String: Any]]?) -> [String] {
        (groups ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
    }

    static func isOurs(_ command: String?, source: String = "claude") -> Bool {
        guard let command else { return false }
        return command.contains("/.juice-island/jr.py") && command.hasSuffix(" hook --source \(source)")
    }

    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    final class Home {
        let url: URL

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            precondition(url.path.hasPrefix(NSTemporaryDirectory()), "fixture homes only")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ path: String, _ text: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func read(_ path: String) throws -> String { try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) }
        func json(_ path: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent(path))) as? [String: Any] ?? [:]
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path) }
        func mode(_ path: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)[.posixPermissions] as? Int) ?? -1
        }

        /// The helper, staged as Set up stages it (`jr.py.new` for install and remove; `jr.py` for anything else).
        /// `hostname`: the machine's name as the helper reads it, for hosts that share this home.
        func run(_ arguments: String..., stdin: String = "", extra: [String: String] = [:], hostname: String? = nil) throws -> Output {
            let staged = arguments.first == "install" || arguments.first == "remove"
            let script = try stage(staged ? "jr.py.new" : "jr.py")
            return try RemoteScript.run(RemoteScript.pythonArguments(script: script.path, hostname: hostname) + arguments, home: url,
                                        stdin: stdin, extra: extra)
        }

        @discardableResult
        func stage(_ name: String = "jr.py") throws -> URL {
            let folder = url.appendingPathComponent(".juice-island")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let script = folder.appendingPathComponent(name)
            if name != "jr.py" || !FileManager.default.fileExists(atPath: script.path) {
                try RemoteHelperScript.source.write(to: script, atomically: true, encoding: .utf8)
            }
            return script
        }

        /// This machine's socket folder, as the helper names it.
        func runDir() throws -> String {
            let script = try stage()
            let output = try RemoteScript.run(["-c", "import runpy, sys; print(runpy.run_path(sys.argv[1])['run_dir']())", script.path],
                                              home: url)
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Every socket under the helper's run folder, whichever host made it.
        func sockets() -> [String] {
            let run = url.appendingPathComponent(".juice-island/run").path
            let found = FileManager.default.enumerator(atPath: run)?.compactMap { $0 as? String } ?? []
            return found.filter { $0.hasSuffix(".sock") }.map { run + "/" + $0 }.sorted()
        }
    }

    /// `python3 <script>`, or, for another machine's name, the script run with `socket.gethostname` saying that name.
    static func pythonArguments(script: String, hostname: String?) -> [String] {
        guard let hostname else { return [script] }
        let code = "import runpy, socket, sys; name = sys.argv[2]; socket.gethostname = lambda: name; "
            + "sys.argv = [sys.argv[1]] + sys.argv[3:]; runpy.run_path(sys.argv[0], run_name='__main__')"
        return ["-c", code, script, hostname]
    }

    /// A tunnel's far end, its Mac side silent: stdin open and never written.
    final class Serve {
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        init(home: Home, hostname: String? = nil) throws {
            let script = try home.stage()
            process.executableURL = URL(fileURLWithPath: RemoteScript.python)
            process.arguments = RemoteScript.pythonArguments(script: script.path, hostname: hostname) + ["serve"]
            process.environment = ["HOME": home.url.path, "PATH": "/usr/bin:/bin"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        var isRunning: Bool { process.isRunning }

        /// Gone with no chance to clean up, as a socket on another machine looks from here.
        func kill() {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        func stop() {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }

    static func wait(_ condition: () -> Bool) {
        for _ in 0..<300 where !condition() { usleep(20_000) }
    }

    /// A socket file nobody listens on.
    static func leaveStaleSocket(at path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
    }

    /// A hook entry's command as an agent runs it: `/bin/sh -c`.
    static func shell(_ command: String, home: URL, stdin: String) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        return try collect(process, stdin: stdin)
    }

    static func run(_ arguments: [String], home: URL, stdin: String = "", extra: [String: String] = [:]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
        return try collect(process, stdin: stdin)
    }

    static func collect(_ process: Process, stdin: String) throws -> Output {
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                      stderr: String(decoding: err, as: UTF8.self))
    }
}
