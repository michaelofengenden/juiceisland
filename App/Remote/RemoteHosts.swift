import AppKit
import Foundation
import IslandEngine
import Network
import Observation

/// One host Setup lists (P751): what the owner named, and what Set up found there (nil until a Set up finished). Kept
/// in the app's own support folder; no secret is ever part of it.
struct RemoteHostRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var destination: String
    var setup: RemoteSetupResult?
    /// A Set up ran on the host but did not finish here (refused, timed out, an answer not understood): it may have left
    /// something there, so Remove runs there too (P756). nil in a list written before.
    var reached: Bool? = nil
}

/// One host's row in Settings › Agents › SSH hosts: its name, its state in a word or two, and the one button the state
/// needs, with Remove beside it.
struct RemoteHostRow: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable { case setUp, connect }

    var id: String
    var name: String
    var word: String
    /// What is hooked there, or what to do about the state; nil when the word says it all.
    var detail: String?
    var amber = false
    var action: Action?
    var actionTitle: String?
    /// Remove (a set-up host: our hooks out, then forgotten; one that never finished Set up: forgotten).
    var removable = true
}

/// What a row is doing while a click runs.
enum RemoteHostBusy: Equatable, Sendable { case settingUp, removing }

/// The rows' words (unit-tested). Plain, short, one fact each.
enum RemoteHostText {
    static func row(_ record: RemoteHostRecord, state: TunnelMachine.State?, busy: RemoteHostBusy?, failure: RemoteSetupFailure?,
                    removeFailed: Bool) -> RemoteHostRow {
        var row = RemoteHostRow(id: record.id, name: record.destination, word: "")
        switch busy {
        case .settingUp?:
            row.word = "Setting up…"
            row.removable = false
            return row
        case .removing?:
            row.word = "Removing…"
            row.removable = false
            return row
        case nil:
            break
        }
        if removeFailed {
            row.word = failure?.words ?? "Not reachable"
            row.amber = true
            row.detail = "Its hooks are still there. Remove again to forget it here."
            return row
        }
        guard let setup = record.setup else {
            row.word = failure?.words ?? "Not set up"
            row.amber = failure != nil
            row.detail = failure.flatMap(hint)
            row.action = .setUp
            row.actionTitle = "Set up"
            return row
        }
        row.detail = hooked(setup)
        let older = setup.helper < RemoteHelperScript.version
        if older {
            row.detail = "Helper older than this build"
            row.action = .setUp
            row.actionTitle = "Update"
        }
        switch state {
        case nil, .stopped?:
            row.word = "Paused"
            row.detail = "Connects while Live sessions is on"
        case .connecting?:
            row.word = "Connecting…"
        case .connected?:
            row.word = "Connected"
        case .retrying?:
            row.word = "Reconnecting"
        case let .offline(failure)?:
            row.word = words(failure)
            row.amber = failure != .unreachable
            row.detail = hint(.connection(failure)) ?? row.detail
            if row.action == nil || failure == .notSetUp || failure == .protocolError {
                let setUp = failure == .notSetUp || failure == .protocolError
                row.action = setUp ? .setUp : .connect
                row.actionTitle = setUp ? "Set up" : "Connect"
            }
        }
        // An Update or a Set up again that did not finish says why until the next click; the host keeps what it had.
        // A reason the state word already says (Needs key login) keeps the state's own hint.
        if let failure, failure.words != row.word {
            row.detail = "\(older ? "Update" : "Set up") failed: \(failure.words)"
        }
        return row
    }

    static func words(_ failure: TunnelFailure) -> String {
        switch failure {
        case .needsKeyLogin: "Needs key login"
        case .hostKey: "Unknown host key"
        case .notSetUp: "Helper missing"
        case .protocolError: "Unexpected answer"
        case .unreachable: "Offline"
        }
    }

    /// What to do about a failure, when there is something to do.
    static func hint(_ failure: RemoteSetupFailure) -> String? {
        switch failure {
        case .connection(.needsKeyLogin): "Add its key to ssh-agent or an IdentityFile in ~/.ssh/config"
        case .connection(.hostKey): "Connect once in Terminal to accept its key"
        case .noPython: "Install python3 there"
        default: nil
        }
    }

    /// "Claude Code, Codex": what Set up hooked; Codex's own `/hooks` approval is the owner's, on the host.
    static func hooked(_ setup: RemoteSetupResult) -> String {
        var parts = setup.claude ? ["Claude Code"] : []
        if setup.codex { parts.append(setup.codexFeature == "off" ? "Codex (hooks off in its config)" : "Codex (approve with /hooks)") }
        return parts.joined(separator: ", ")
    }
}

/// What Setup's SSH hosts section reads. `RemoteHosts` in the app, `DemoRemoteHostsModel` in renders and tests. Nothing
/// here connects, installs or removes except on a click (`setUp`, `perform`, `remove`).
@MainActor
protocol RemoteHostsModel: AnyObject {
    var rows: [RemoteHostRow] { get }
    /// The pop-up's choices: `Host` names from `~/.ssh/config` not already listed.
    var configHosts: [String] { get }
    /// False for text that is not a host name: nothing is added or run, and the field keeps it.
    @discardableResult
    func setUp(_ destination: String) -> Bool
    func perform(_ action: RemoteHostRow.Action, on id: String)
    func remove(_ id: String)
    /// Setup appeared: the config's names are read again.
    func refreshConfigHosts()
}

/// Setup's fixture hosts: fictional names, nothing read, written or connected. Its buttons do nothing.
@MainActor
final class DemoRemoteHostsModel: RemoteHostsModel {
    let rows: [RemoteHostRow]
    let configHosts: [String]

    init(rows: [RemoteHostRow] = [], configHosts: [String] = []) {
        self.rows = rows
        self.configHosts = configHosts
    }

    func setUp(_ destination: String) -> Bool {
        RemoteDestination.isValid(destination.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func perform(_ action: RemoteHostRow.Action, on id: String) {}
    func remove(_ id: String) {}
    func refreshConfigHosts() {}

    static let setup = RemoteSetupResult(helper: RemoteHelperScript.version, python: "/usr/bin/python3",
                                         script: "/home/me/.juice-island/jr.py", claude: true, codex: false)

    /// One host in each state the owner meets most.
    static var fixture: DemoRemoteHostsModel {
        func row(_ id: String, _ destination: String, setup: RemoteSetupResult? = DemoRemoteHostsModel.setup,
                 _ state: TunnelMachine.State?, busy: RemoteHostBusy? = nil, failure: RemoteSetupFailure? = nil) -> RemoteHostRow {
            RemoteHostText.row(RemoteHostRecord(id: id, destination: destination, setup: setup), state: state, busy: busy,
                               failure: failure, removeFailed: false)
        }
        var both = setup
        both.codex = true
        both.codexFeature = "added"
        return DemoRemoteHostsModel(rows: [
            row("a", "gpu1", setup: both, .connected(helper: 1)),
            row("b", "ubuntu@trainer", .retrying(at: DemoClock.now, after: .unreachable)),
            row("c", "lab-box", .offline(.needsKeyLogin)),
            row("d", "spare", setup: nil, nil, failure: .noPython),
            row("e", "build", setup: nil, nil, busy: .settingUp),
        ], configHosts: ["devbox", "gpu2"])
    }
}

/// The app's hosts (P747, P749, P751): the list, Set up and Remove on the owner's click, and one tunnel per set-up host
/// while the live engine's bridge runs. A wake or a network change tries a host that is down at once; nothing else
/// starts a connection by itself.
@MainActor
@Observable
final class RemoteHosts: RemoteHostsModel {
    private(set) var records: [RemoteHostRecord] = []
    private(set) var configHosts: [String] = []
    private var busy: [String: RemoteHostBusy] = [:]
    private var failures: [String: RemoteSetupFailure] = [:]
    private var removeFailed: Set<String> = []
    private(set) var tunnels: RemoteTunnels?

    @ObservationIgnored private let store: URL
    @ObservationIgnored private let runner: SSHRunner
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let readConfig: @Sendable (URL) -> [String]
    @ObservationIgnored private weak var engine: SessionEngine?
    @ObservationIgnored private var makeTunnels: (@MainActor (SessionEngine) -> RemoteTunnels)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathWatch = NetworkPathWatch()
    @ObservationIgnored private var loaded = false

    init(store: URL = RemoteSetup.hostsFile, runner: SSHRunner = .ssh, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         readConfig: @escaping @Sendable (URL) -> [String] = { SSHConfigHosts.read(home: $0) }) {
        self.store = store
        self.runner = runner
        self.home = home
        self.readConfig = readConfig
    }

    /// The list is read at launch (`attach`) or at the first click, never when the model is built: tests and renders
    /// that build the app's environment read no file of the owner's.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        records = Self.load(store)
    }

    var rows: [RemoteHostRow] {
        records.map { record in
            RemoteHostText.row(record, state: tunnels?.states[record.id], busy: busy[record.id], failure: failures[record.id],
                               removeFailed: removeFailed.contains(record.id))
        }
    }

    // MARK: Clicks

    @discardableResult
    func setUp(_ typed: String) -> Bool {
        loadIfNeeded()
        let destination = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteDestination.isValid(destination) else { return false }
        let id: String
        if let existing = records.first(where: { $0.destination == destination }) {
            id = existing.id
            guard busy[id] == nil else { return true }
        } else {
            id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            records.append(RemoteHostRecord(id: id, destination: destination))
            save()
            configHosts.removeAll { $0 == destination }
        }
        busy[id] = .settingUp
        failures[id] = nil
        removeFailed.remove(id)
        let runner = runner
        Task {
            let result = await RemoteSetup.install(destination, runner: runner)
            busy[id] = nil
            switch result {
            case let .success(setup):
                guard let index = records.firstIndex(where: { $0.id == id }) else { return }
                records[index].setup = setup
                records[index].reached = nil
                save()
                applyTunnels(restarting: id)
            case let .failure(failure):
                failures[id] = failure
                if failure.mayHaveReachedTheHost, let index = records.firstIndex(where: { $0.id == id }),
                   records[index].setup == nil, records[index].reached != true {
                    records[index].reached = true
                    save()
                }
            }
        }
        return true
    }

    func perform(_ action: RemoteHostRow.Action, on id: String) {
        guard let record = records.first(where: { $0.id == id }), busy[id] == nil else { return }
        switch action {
        case .setUp: setUp(record.destination)
        case .connect:
            failures[id] = nil
            tunnels?.connect(id)
        }
    }

    /// Our hooks out of the host, then the host off the list. A host no Set up ever reached, or one whose Remove
    /// already failed (unreachable), is only forgotten here.
    func remove(_ id: String) {
        loadIfNeeded()
        guard let record = records.first(where: { $0.id == id }), busy[id] == nil else { return }
        guard record.setup != nil || record.reached == true, !removeFailed.contains(id) else { return forget(id) }
        busy[id] = .removing
        applyTunnels()
        let runner = runner
        Task {
            let result = await RemoteSetup.remove(record.destination, runner: runner)
            busy[id] = nil
            switch result {
            case .success:
                forget(id)
            case let .failure(failure):
                failures[id] = failure
                removeFailed.insert(id)
                applyTunnels()
            }
        }
    }

    func refreshConfigHosts() {
        loadIfNeeded()
        let read = readConfig, home = home
        Task {
            let names = await Task.detached(priority: .utility) { read(home) }.value
            let listed = Set(records.map(\.destination))
            configHosts = names.filter { !listed.contains($0) }
        }
    }

    private func forget(_ id: String) {
        records.removeAll { $0.id == id }
        save()
        busy[id] = nil
        failures[id] = nil
        removeFailed.remove(id)
        applyTunnels()
        engine?.endRemoteSessions(hostID: id)
    }

    // MARK: Tunnels

    /// Follows the live engine: tunnels while its bridge runs, none otherwise. The app calls this once, at launch.
    func attach(to sessions: LiveSessions, makeTunnels: @escaping @MainActor (SessionEngine) -> RemoteTunnels = { $0.makeRemoteTunnels() }) {
        self.makeTunnels = makeTunnels
        loadIfNeeded()
        follow(sessions)
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tunnels?.wake() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let primary = path.status == .satisfied ? path.availableInterfaces.first?.name ?? "" : nil
            Task { @MainActor in self?.pathChanged(primary: primary) }
        }
        monitor.start(queue: DispatchQueue(label: "RemoteHosts.path"))
        pathMonitor = monitor
    }

    /// Only a real change counts (`NetworkPathWatch`): a VPN, Docker or Tailscale coming and going says nothing to ssh.
    private func pathChanged(primary: String?) {
        guard pathWatch.note(primary: primary) else { return }
        tunnels?.networkChanged()
    }

    /// Tunnels only while the hooks reach this app: Live sessions on, and the hook socket not taken by another island app
    /// (a remote hook relayed then would reach that app). Otherwise none at all, so no click (Set up, Remove) starts one.
    private func follow(_ sessions: LiveSessions) {
        let live = withObservationTracking { sessions.hooksReachApp } onChange: { [weak self, weak sessions] in
            Task { @MainActor in
                guard let self, let sessions else { return }
                self.follow(sessions)
            }
        }
        if live, let engine = sessions.engine {
            if tunnels == nil || self.engine !== engine {
                tunnels?.stopAll()
                self.engine = engine
                let made = makeTunnels?(engine) ?? engine.makeRemoteTunnels()
                engine.onRemoteJump = { [weak made] host, context in made?.selectTmuxPane(hostID: host, context: context) }
                tunnels = made
            }
            applyTunnels()
        } else if let tunnels {
            tunnels.stopAll()
            self.tunnels = nil
        }
    }

    /// Every set-up host that is not being removed has a tunnel; `restarting` starts one over (Set up again).
    private func applyTunnels(restarting id: String? = nil) {
        guard let tunnels else { return }
        let hosts = records.compactMap { record -> RemoteTunnels.Host? in
            guard let setup = record.setup, busy[record.id] != .removing else { return nil }
            return RemoteTunnels.Host(id: record.id, destination: record.destination, python: setup.python, script: setup.script)
        }
        if let id, hosts.contains(where: { $0.id == id }) {
            tunnels.update(hosts.filter { $0.id != id })
        }
        tunnels.update(hosts)
    }

    func shutdown() {
        tunnels?.stopAll()
        tunnels = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // MARK: Store

    private struct Stored: Codable {
        var hosts: [RemoteHostRecord]
    }

    static func load(_ url: URL) -> [RemoteHostRecord] {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.hosts.filter { RemoteDestination.isValid($0.destination) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Stored(hosts: records)) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: store, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
    }
}

/// Which network path updates are real changes for a tunnel (P747): the network coming back, or its main interface
/// changing (Wi-Fi to Ethernet, a VPN taking every route). A VPN, Docker or Tailscale interface coming and going beside
/// the main one changes nothing ssh rides on, and the first update is the path as it is, not a change.
struct NetworkPathWatch: Equatable, Sendable {
    private var seen = false
    private var primary: String?

    /// `primary`: the main interface's name while the path is satisfied, nil while it is not. True for a real change.
    mutating func note(primary: String?) -> Bool {
        defer {
            seen = true
            self.primary = primary
        }
        guard seen, let primary else { return false }
        return primary != self.primary
    }
}
