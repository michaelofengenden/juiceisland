import Foundation
@testable import IslandEngine
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// Settings › Agents › SSH hosts (P749, P751): the rows' words for every state, the `Host` names read from a fixture
/// config, and Set up and Remove through a fake ssh runner (no connection, no real `~/.ssh`, a scratch store).
@MainActor
@Suite(.serialized)
struct RemoteHostsTests {
    typealias Box = EngineFixtureBox

    static let setup = RemoteSetupResult(helper: RemoteHelperScript.version, python: "/usr/bin/python3",
                                         script: "/home/me/.juice-island/jr.py", claude: true, codex: true, codexFeature: "added")

    static func row(_ state: TunnelMachine.State?, setup: RemoteSetupResult? = setup, busy: RemoteHostBusy? = nil,
                    failure: RemoteSetupFailure? = nil, removeFailed: Bool = false) -> RemoteHostRow {
        RemoteHostText.row(RemoteHostRecord(id: "h", destination: "me@gpu1", setup: setup), state: state, busy: busy,
                           failure: failure, removeFailed: removeFailed)
    }

    @Test func eachStateSaysOneThingAndOffersOneButton() {
        let connected = Self.row(.connected(helper: 1))
        #expect(connected.word == "Connected" && connected.detail == "Claude Code, Codex (approve with /hooks)" && connected.action == nil)
        #expect(connected.removable && connected.name == "me@gpu1")
        #expect(Self.row(.connecting).word == "Connecting…")
        #expect(Self.row(.retrying(at: .distantFuture, after: .unreachable)).word == "Reconnecting")
        let offline = Self.row(.offline(.unreachable))
        #expect(offline.word == "Offline" && !offline.amber && offline.action == .connect && offline.actionTitle == "Connect")
        let key = Self.row(.offline(.needsKeyLogin))
        #expect(key.word == "Needs key login" && key.amber && key.action == .connect && key.detail?.contains("ssh-agent") == true)
        let hostKey = Self.row(.offline(.hostKey))
        #expect(hostKey.word == "Unknown host key" && hostKey.detail == "Connect once in Terminal to accept its key")
        let missing = Self.row(.offline(.notSetUp))
        #expect(missing.word == "Helper missing" && missing.action == .setUp && missing.actionTitle == "Set up")
        #expect(Self.row(nil).word == "Paused" && Self.row(nil).action == nil)
        var older = Self.setup
        older.helper = RemoteHelperScript.version - 1
        let update = Self.row(.connected(helper: older.helper), setup: older)
        #expect(update.word == "Connected" && update.actionTitle == "Update" && update.detail == "Helper older than this build")
    }

    @Test func aHostSetUpNeverFinishedOnSaysWhyAndCanBeTriedAgain() {
        let fresh = Self.row(nil, setup: nil)
        #expect(fresh.word == "Not set up" && fresh.action == .setUp && !fresh.amber)
        let python = Self.row(nil, setup: nil, failure: .noPython)
        #expect(python.word == "Needs Python 3" && python.amber && python.detail == "Install python3 there")
        let busy = Self.row(nil, setup: nil, busy: .settingUp)
        #expect(busy.word == "Setting up…" && busy.action == nil && !busy.removable)
        let failedRemove = Self.row(.offline(.unreachable), failure: .connection(.unreachable), removeFailed: true)
        #expect(failedRemove.word == "Not reachable" && failedRemove.detail?.contains("Remove again") == true && failedRemove.action == nil)
    }

    @Test func configHostsAreThePlainNamesOnly() throws {
        let config = """
        # work
        Host gpu1 gpu2
          HostName 203.0.113.9
          User ubuntu
        Host *.internal !bastion
        Host=trainer
        host "quoted-box" # trailing comment
        Match host gpu1
        Host *
          ServerAliveInterval 30
        Host -oProxyCommand=evil
        """
        #expect(SSHConfigHosts.names(in: config) == ["gpu1", "gpu2", "trainer", "quoted-box"])
        // Includes under ~/.ssh, one level, in a fixture home.
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jrc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        try "Include config.d/*\nHost gpu1\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host cloud-a100\n".write(to: ssh.appendingPathComponent("config.d/cloud"), atomically: true, encoding: .utf8)
        try "Host outside\n".write(to: home.appendingPathComponent("elsewhere"), atomically: true, encoding: .utf8)
        try "Include ~/elsewhere\n".write(to: ssh.appendingPathComponent("config.d/more"), atomically: true, encoding: .utf8)
        #expect(SSHConfigHosts.read(home: home) == ["gpu1", "cloud-a100"])
    }

    final class Runs: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(arguments: [String], stdin: Data)] = []
        var answers: [SSHRunOutput] = []
        func next(_ arguments: [String], _ stdin: Data) -> SSHRunOutput {
            lock.withLock {
                calls.append((arguments, stdin))
                return answers.isEmpty ? SSHRunOutput(status: 255, stdout: "", stderr: "unexpected") : answers.removeFirst()
            }
        }
    }

    static let installed = SSHRunOutput(status: 0, stdout: "Last login\nJR-RESULT {\"v\":\(RemoteHelperScript.version),\"python\":\"/usr/bin/python3\",\"home\":\"/home/me\",\"script\":\"/home/me/.juice-island/jr.py\",\"claude\":true,\"codex\":false}\n", stderr: "")

    func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func setUpAndRemoveRunOneSshEachAndKeepTheList() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jrh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("remote-hosts.json")
        let runs = Runs()
        runs.answers = [SSHRunOutput(status: 255, stdout: "", stderr: "me@gpu1: Permission denied (publickey)."), Self.installed]
        let hosts = RemoteHosts(store: store, runner: SSHRunner { arguments, stdin, _ in runs.next(arguments, stdin) },
                                home: folder, readConfig: { _ in ["gpu1", "trainer"] })
        hosts.refreshConfigHosts()
        await until { !hosts.configHosts.isEmpty }
        #expect(hosts.configHosts == ["gpu1", "trainer"])
        hosts.setUp("  me@gpu1 ")
        #expect(hosts.rows.first?.word == "Setting up…")
        await until { hosts.rows.first?.word != "Setting up…" }
        #expect(hosts.rows.first?.word == "Needs key login" && hosts.rows.first?.action == .setUp)
        // The helper went on stdin, the destination last but its command, and our options before it.
        let first = try #require(runs.calls.first)
        #expect(String(decoding: first.stdin, as: UTF8.self) == RemoteHelperScript.source)
        #expect(first.arguments.contains("BatchMode=yes") && first.arguments.suffix(2).first == "me@gpu1")
        #expect(first.arguments.last?.hasSuffix(" install'") == true)
        hosts.perform(.setUp, on: try #require(hosts.rows.first?.id))
        await until { hosts.records.first?.setup != nil }
        #expect(hosts.records.first?.setup?.script == "/home/me/.juice-island/jr.py")
        // No live engine here: the host waits for Live sessions.
        #expect(hosts.rows.first?.word == "Paused")
        // The list survives a relaunch; nothing secret is in it.
        let saved = try String(contentsOf: store, encoding: .utf8)
        #expect(saved.contains("me@gpu1") && !saved.contains("BEGIN") && !saved.contains("password"))
        #expect(RemoteHosts.load(store).map(\.destination) == ["me@gpu1"])
        // Remove: unreachable keeps the host and says so; the second Remove forgets it with no ssh.
        runs.answers = [SSHRunOutput(status: 255, stdout: "", stderr: "ssh: connect to host gpu1 port 22: Operation timed out")]
        let id = try #require(hosts.rows.first?.id)
        hosts.remove(id)
        await until { hosts.rows.first?.word != "Removing…" }
        #expect(hosts.rows.first?.detail?.contains("Remove again") == true)
        #expect(runs.calls.last?.arguments.last?.hasSuffix(" remove'") == true)
        let callsBefore = runs.calls.count
        hosts.remove(id)
        #expect(hosts.rows.isEmpty && runs.calls.count == callsBefore)
        #expect(RemoteHosts.load(store).isEmpty)
    }

    /// M1: a Set up the host refused (or one that timed out, or answered something not understood) may have left
    /// something there: Remove runs there too, and only then forgets the host. It is kept across a relaunch.
    @Test func aSetUpThatReachedTheHostIsRemovedThereToo() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jrh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("h.json")
        let runs = Runs()
        runs.answers = [SSHRunOutput(status: 98, stdout: "", stderr: "JR-ERROR config.toml is a link\n"),
                        SSHRunOutput(status: 0, stdout: "JR-RESULT {\"v\":2,\"removed\":true}\n", stderr: "")]
        let hosts = RemoteHosts(store: store, runner: SSHRunner { arguments, stdin, _ in runs.next(arguments, stdin) },
                                home: folder, readConfig: { _ in [] })
        hosts.setUp("gpu1")
        await until { hosts.rows.first?.word == "config.toml is a link" }
        #expect(hosts.rows.first?.word == "config.toml is a link" && hosts.rows.first?.action == .setUp)
        // After a relaunch, Remove still runs there.
        let id = try #require(hosts.rows.first?.id)
        let relaunched = RemoteHosts(store: store, runner: SSHRunner { arguments, stdin, _ in runs.next(arguments, stdin) },
                                     home: folder, readConfig: { _ in [] })
        relaunched.remove(id)
        await until { runs.calls.count == 2 && relaunched.rows.isEmpty }
        #expect(relaunched.rows.isEmpty && runs.calls.count == 2)
        #expect(runs.calls.last?.arguments.last?.hasSuffix(" remove'") == true)
        #expect(RemoteHosts.load(store).isEmpty)
    }

    /// N1: text ssh would not take as a host is refused: nothing is added or run, and the field keeps it and says so.
    @Test func textThatIsNotAHostIsKeptAndSaysSo() {
        let hosts = RemoteHosts(store: URL(fileURLWithPath: "/nonexistent/h.json"),
                                runner: SSHRunner { _, _, _ in SSHRunOutput(status: 255, stdout: "", stderr: "") },
                                home: URL(fileURLWithPath: "/nonexistent"), readConfig: { _ in [] })
        for typed in ["ssh gpu1", "me@gpu1 -p 2222", "-oProxyCommand=sh", "  "] {
            #expect(!hosts.setUp(typed))
        }
        #expect(hosts.rows.isEmpty && RemoteHostsText.notAHost == "Not a host name")
        #expect(DemoRemoteHostsModel().setUp(" gpu1 ") && !DemoRemoteHostsModel().setUp("ssh gpu1"))
    }

    /// N2: an Update or a Set up again that did not finish on a set-up host says why on its row, until the next click.
    @Test func aFailedUpdateSaysWhyOnTheHostsRow() {
        var older = Self.setup
        older.helper = RemoteHelperScript.version - 1
        let update = Self.row(.connected(helper: older.helper), setup: older, failure: .refused("config.toml is a link"))
        #expect(update.word == "Connected" && update.detail == "Update failed: config.toml is a link" && !update.amber)
        #expect(update.action == .setUp && update.actionTitle == "Update")
        let again = Self.row(.offline(.notSetUp), failure: .timedOut)
        #expect(again.word == "Helper missing" && again.detail == "Set up failed: Timed out" && again.amber)
        let key = Self.row(.offline(.needsKeyLogin), failure: .connection(.needsKeyLogin))
        #expect(key.word == "Needs key login" && key.detail?.contains("ssh-agent") == true)
    }

    /// S5: an SSH host is never the host the island's rows share, so a remote row always says where it runs, even when
    /// two run on one host.
    @Test func aRemoteHostIsNeverTheSharedHost() throws {
        let base = try #require(FixtureSessionFeed(scenario: .prototype).makeModel().rows.first)
        func row(_ id: String, _ host: String, remote: Bool = false) -> SessionRow {
            var row = base
            row.id = id
            row.host = host
            row.remoteHost = remote ? host : nil
            return row
        }
        #expect(DetailedRowText.sharedHost([row("a", "gpu1", remote: true), row("b", "gpu1", remote: true), row("c", "iTerm")]) == nil)
        #expect(DetailedRowText.sharedHost([row("a", "gpu1", remote: true), row("b", "gpu1", remote: true)]) == nil)
        #expect(DetailedRowText.sharedHost([row("a", "gpu1", remote: true), row("b", "iTerm"), row("c", "iTerm")]) == "iTerm")
    }

    /// N4: only the network coming back or its main interface changing counts; a VPN, Docker or Tailscale interface
    /// coming and going beside it, and the first update, do not.
    @Test func onlyARealNetworkChangeCounts() {
        var watch = NetworkPathWatch()
        let changes = ["en0", "en0", "en0", nil, "en0", "en7", "en7"].map { watch.note(primary: $0) }
        #expect(changes == [false, false, false, false, true, true, false])
    }

    /// S2: tunnels run only while the hooks reach this app. With Live sessions off, or the hook socket taken by another
    /// island app, there are none, and no click (Remove here) starts one; back, they start again.
    @Test func tunnelsRunOnlyWhileTheHooksReachTheApp() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jrh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("h.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        struct Stored: Codable { var hosts: [RemoteHostRecord] }
        try JSONEncoder().encode(Stored(hosts: [RemoteHostRecord(id: "a", destination: "gpu1", setup: Self.setup),
                                                RemoteHostRecord(id: "b", destination: "gpu2", setup: Self.setup)])).write(to: store)
        let runs = Runs()
        runs.answers = [SSHRunOutput(status: 0, stdout: "JR-RESULT {\"v\":2,\"removed\":true}\n", stderr: "")]
        let hosts = RemoteHosts(store: store, runner: SSHRunner { arguments, stdin, _ in runs.next(arguments, stdin) },
                                home: folder, readConfig: { _ in [] })
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        let live = Self.makeLive(settings)
        live.activate()
        #expect(live.mode == .live)
        let launched = Launched()
        let launcher = TunnelLauncher { arguments, _, _ in launched.add(arguments) }
        hosts.attach(to: live, makeTunnels: { $0.makeRemoteTunnels(launcher: launcher) })
        defer {
            hosts.shutdown()
            live.shutdown()
        }
        #expect(launched.count == 2)
        // Live sessions off: both stop, and Remove of one starts nothing for the other.
        settings.liveSessions = false
        await until { hosts.tunnels == nil }
        #expect(hosts.tunnels == nil && launched.running == 0)
        hosts.remove("a")
        await until { hosts.rows.count == 1 }
        #expect(hosts.rows.map(\.word) == ["Paused"] && launched.count == 2 && runs.calls.count == 1)
        // Back on: the one left starts.
        settings.liveSessions = true
        await until { launched.count == 3 }
        #expect(launched.count == 3 && launched.running == 1)
        // Another island app takes the hook socket: a remote hook would reach it, so the tunnel stops; back, it starts.
        live.engine?.bridgeHealth = .taken
        await until { launched.running == 0 }
        #expect(hosts.tunnels == nil && launched.running == 0)
        live.engine?.bridgeHealth = .live(sockets: 2)
        await until { launched.count == 4 }
        #expect(launched.count == 4 && launched.running == 1)
    }

    /// The tunnels' processes, none of them real.
    final class Launched: @unchecked Sendable {
        final class Process: TunnelProcess, @unchecked Sendable {
            var terminated = false
            func write(_ data: Data) {}
            func terminate() { terminated = true }
        }

        private let lock = NSLock()
        private var all: [Process] = []
        var count: Int { lock.withLock { all.count } }
        var running: Int { lock.withLock { all.filter { !$0.terminated }.count } }
        func add(_ arguments: [String]) -> Process {
            let process = Process()
            lock.withLock { all.append(process) }
            return process
        }
    }

    /// The Live sessions switch over an engine whose bridge, owner probe and Open Island check are stand-ins: no hook
    /// socket is probed or bound, and no runtime starts.
    static func makeLive(_ settings: AppSettings) -> LiveSessions {
        LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { false }
            dependencies.socketHasOwner = { _ in false }
            dependencies.startBridge = { _ in StubBridge() }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, identity: .development)
    }

    final class StubBridge: EngineBridge, @unchecked Sendable {
        func updateStateSnapshot(_ snapshot: SessionState) {}
        func stop() {}
    }

    @Test func aHostThatNeverFinishedSetUpIsForgottenWithoutSsh() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jrh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runs = Runs()
        runs.answers = [SSHRunOutput(status: 97, stdout: "", stderr: "")]
        let hosts = RemoteHosts(store: folder.appendingPathComponent("h.json"),
                                runner: SSHRunner { arguments, stdin, _ in runs.next(arguments, stdin) }, home: folder, readConfig: { _ in [] })
        hosts.setUp("spare")
        await until { hosts.rows.first?.word == "Needs Python 3" }
        #expect(hosts.rows.first?.word == "Needs Python 3")
        hosts.remove(hosts.rows[0].id)
        #expect(hosts.rows.isEmpty && runs.calls.count == 1)
        // Something that is not a host is never added.
        hosts.setUp("-oProxyCommand=sh")
        hosts.setUp("a b")
        #expect(hosts.rows.isEmpty && runs.calls.count == 1)
    }
}
