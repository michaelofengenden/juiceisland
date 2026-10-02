import Foundation
import Observation

/// Every set-up host's tunnel (P747): one `TunnelMachine` each, whose effects this carries out with the launcher and a
/// scheduler. Its states are what the host rows show. Only the app's live engine makes one (`SessionEngine
/// .makeRemoteTunnels`), and only while its bridge runs.
@MainActor
@Observable
public final class RemoteTunnels {
    public struct Host: Equatable, Sendable {
        public var id: String
        public var destination: String
        public var python: String
        public var script: String

        public init(id: String, destination: String, python: String, script: String) {
            self.id = id
            self.destination = destination
            self.python = python
            self.script = script
        }

        var name: String { RemoteDestination.hostName(destination) }
    }

    public private(set) var states: [String: TunnelMachine.State] = [:]

    @ObservationIgnored private var machines: [String: TunnelMachine] = [:]
    @ObservationIgnored private var hosts: [String: Host] = [:]
    @ObservationIgnored private var running: [String: (generation: Int, tunnel: RemoteTunnel)] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let endpoints: RemoteRelay.Endpoints
    @ObservationIgnored private let directory: RemoteSessionDirectory
    @ObservationIgnored private let launcher: TunnelLauncher
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Arguments for a host's tunnel; tests give their own (a local `serve`).
    @ObservationIgnored private let arguments: @Sendable (Host) -> [String]?

    init(endpoints: RemoteRelay.Endpoints, directory: RemoteSessionDirectory, launcher: TunnelLauncher,
         now: @escaping @Sendable () -> Date = { Date() },
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
             Task { @MainActor in
                 try? await Task.sleep(for: .seconds(delay))
                 work()
             }
         },
         arguments: @escaping @Sendable (Host) -> [String]? = { SSHCommands.tunnel(destination: $0.destination, python: $0.python, script: $0.script) }) {
        self.endpoints = endpoints
        self.directory = directory
        self.launcher = launcher
        self.now = now
        self.schedule = schedule
        self.arguments = arguments
    }

    /// The hosts to keep tunnels for: new ones start, gone ones stop, a changed one starts again.
    public func update(_ wanted: [Host]) {
        let ids = Set(wanted.map(\.id))
        for id in Array(hosts.keys) where !ids.contains(id) {
            handle(id, .stop)
            hosts[id] = nil
            machines[id] = nil
            states[id] = nil
        }
        for host in wanted {
            let previous = hosts[host.id]
            hosts[host.id] = host
            // A changed host (Set up again) starts over, a stopped one (the bridge back) starts; one already known keeps its
            // state (an Offline one waits for the owner).
            guard previous != host || machines[host.id]?.state ?? .stopped == .stopped else { continue }
            if previous != nil { handle(host.id, .stop) }
            handle(host.id, .start)
        }
    }

    /// The row's Connect.
    public func connect(_ id: String) { handle(id, .start) }

    /// The Mac woke: every host starts over at once (`TunnelMachine.Event.wake`).
    public func wake() {
        for id in Array(hosts.keys) { handle(id, .wake) }
    }

    /// The network came back or its main interface changed (`TunnelMachine.Event.networkChanged`).
    public func networkChanged() {
        for id in Array(hosts.keys) { handle(id, .networkChanged) }
    }

    public func stopAll() {
        for id in Array(hosts.keys) { handle(id, .stop) }
    }

    /// A jump into a remote tmux pane (best effort).
    public func selectTmuxPane(hostID: String, context: RemoteContext) {
        guard let socket = context.tmuxSocket, let pane = context.tmuxPane else { return }
        running[hostID]?.tunnel.selectTmuxPane(socket: socket, pane: pane)
    }

    private func handle(_ id: String, _ event: TunnelMachine.Event) {
        guard hosts[id] != nil else { return }
        var machine = machines[id] ?? TunnelMachine()
        let effects = machine.handle(event, now: now())
        machines[id] = machine
        if states[id] != machine.state { states[id] = machine.state }
        for effect in effects {
            switch effect {
            case .launch: launch(id)
            case .terminate: terminate(id)
            case let .schedule(date):
                schedule(max(0, date.timeIntervalSince(now()))) { [weak self] in self?.handle(id, .retryDue(date)) }
            }
        }
    }

    private func launch(_ id: String) {
        terminate(id)
        guard let host = hosts[id] else { return }
        guard let arguments = arguments(host) else { return handle(id, .exited(.notSetUp)) }
        generation += 1
        let mine = generation
        let entry = RemoteSessionDirectory.Entry(hostID: id, hostName: host.name, destination: host.destination)
        let tunnel = RemoteTunnel(host: entry, endpoints: endpoints, directory: directory, onReady: { [weak self] version in
            Task { @MainActor in self?.event(id, mine, .ready(helper: version)) }
        }, onExit: { [weak self] failure in
            Task { @MainActor in self?.event(id, mine, .exited(failure)) }
        })
        running[id] = (mine, tunnel)
        tunnel.start(launcher, arguments: arguments)
    }

    private func event(_ id: String, _ generation: Int, _ event: TunnelMachine.Event) {
        guard running[id]?.generation == generation else { return }
        if case .exited = event { running[id] = nil }
        handle(id, event)
    }

    private func terminate(_ id: String) {
        running.removeValue(forKey: id)?.tunnel.stop()
    }
}
