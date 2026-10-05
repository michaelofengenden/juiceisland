import Darwin
import Foundation
import JuiceCore
import OpenIslandCore

/// The hook socket as the engine last found it (Diagnostics' Bridge row, the production badge).
public enum BridgeHealth: Equatable, Sendable {
    /// No bridge: a headless engine, or one not started or stopped.
    case off
    /// The engine's listener holds the hook socket paths it bound, this many.
    case live(sockets: Int)
    /// Another app listens on a hook socket path the bridge held (it unlinked ours and bound its own): hooks reach that
    /// app, not this one. The engine stopped its bridge, and takes the paths back only once nobody listens there.
    case taken
}

/// Which file a socket path is: its device and inode (`lstat`), so a path unlinked or bound again by another app reads
/// as another file.
struct SocketIdentity: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64

    /// nil when nothing is at the path.
    static func of(_ url: URL) -> SocketIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return SocketIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
}

/// P112: the hook socket after the start. Another island app, a dev build or a test can unlink the socket file and
/// bind its own (`BridgeServer.bindListener` removes whatever is at its path), and upstream never deletes the file when
/// it stops, so the path is left with nobody listening; the engine's listener then sits on a file nobody can reach,
/// with nothing to say so. The engine notes each path's file right after its bind and looks again when the socket's
/// folder changes (a kqueue watch, nothing on a timer), on wake and when an app quits (`LiveSessions`): a path that
/// is missing or another file is taken back when nobody listens there (a restart of the bridge alone), and left to
/// whoever listens there otherwise (`taken`), never stolen from a live owner.
extension SessionEngine {
    /// Looks at each hook socket path once, off the main thread (`lstat`, and a probe of each path that is not the
    /// bridge's own file), then takes lost paths back or waits. One look at a time; returns the one running.
    @discardableResult
    public func checkBridgeSockets() -> Task<Void, Never>? {
        guard configuration.startBridge, hasStarted, bridgeHealth != .off else { return nil }
        checkLegacyRelay()
        if let socketCheck { return socketCheck }
        let paths = HookSocketProbe.paths(for: configuration.socketURL)
        let identity = dependencies.socketIdentity
        let hasOwner = dependencies.socketHasOwner ?? { HookSocketProbe.probe($0).hasOwner }
        // While taken, the bridge holds nothing: every path is somebody else's until a probe says it is free.
        let recorded: [String: SocketIdentity?]? = bridgeHealth == .taken ? nil : boundSockets
        let check = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> (lost: [URL], owned: [URL]) in
                let lost = paths.filter { url in
                    guard let recorded else { return true }
                    return (recorded[url.path] ?? nil) != identity(url)
                }
                return (lost, lost.filter(hasOwner))
            }.value
            guard let self else { return }
            self.socketCheck = nil
            self.settleBridgeSockets(lost: found.lost, owned: found.owned)
        }
        socketCheck = check
        return check
    }

    /// What a look found. Nothing lost keeps the bridge. A path somebody else listens on is theirs: the bridge stops
    /// and waits (`taken`). A missing or left-behind path is taken back with a restart of the bridge alone, which
    /// closes the hooks' open connections, so it waits while a session waits on an approval or a question (whose hook
    /// still holds its connection) and looks again in `socketRetry`. Only the legacy `/tmp` path lost (the system's
    /// cleanup of `/tmp`) is noted and left: current hooks use the primary path, and a restart would close their
    /// connections.
    func settleBridgeSockets(lost: [URL], owned: [URL]) {
        guard bridgeHealth != .off, !lost.isEmpty else { return }
        let legacy = BridgeSocketLocation.legacyURL.path
        // On the app's own socket, the legacy `/tmp` path goes to whichever island binds it last: no current helper dials
        // it, so losing it is noted and left, whoever took it (P912).
        if configuration.ownsSocket, lost.allSatisfy({ $0.path == legacy }) {
            if !legacySocketLossNoted {
                legacySocketLossNoted = true
                JuiceLog.bridge.notice("the legacy hook socket in /tmp is gone; the app's own one still listens")
            }
            return
        }
        let owned = configuration.ownsSocket ? owned.filter { $0.path != legacy } : owned
        if !owned.isEmpty {
            guard bridgeHealth != .taken else { return }
            stopBridgeServer()
            bridgeHealth = .taken
            lastStatusMessage = "Another app took the hook socket; its hooks go there until it quits."
            JuiceLog.bridge.error("another app listens on the hook socket: its hooks go there; the bridge waits for it to let go")
            return
        }
        let wasTaken = bridgeHealth == .taken
        if !wasTaken, lost.allSatisfy({ $0.path == legacy && $0 != configuration.socketURL }) {
            if !legacySocketLossNoted {
                legacySocketLossNoted = true
                JuiceLog.bridge.notice("the legacy hook socket in /tmp is gone; the primary one still listens")
            }
            return
        }
        if !wasTaken, attention.all.contains(where: { $0.channel == .answer(.bridge) }) {
            retryBridgeSocketCheck()
            return
        }
        stopBridgeServer()
        do {
            try startBridgeServer(probed: Set(HookSocketProbe.paths(for: configuration.socketURL).map(\.path)))
        } catch {
            bridgeHealth = .taken
            JuiceLog.bridge.error("the hook socket could not be taken back: \(Self.logReason(error), privacy: .public)")
            return
        }
        bridgeTakenBackAt = dependencies.now()
        connectObserver()
        checkLegacyRelay()
        JuiceLog.bridge.notice("""
            the hook socket was \(wasTaken ? "let go by the app that took it" : "unlinked or left behind", privacy: .public): \
            taken back
            """)
    }

    // MARK: Open Island's socket, relayed (P911)

    /// Starts relaying Open Island's socket when something of Juice's still dials it, Open Island is not running and
    /// nobody listens there; stops when another app took the path, or once nothing of Juice's dials it (Move, Remove,
    /// P932). Off the main actor for the probe; one look at a time.
    @discardableResult
    func checkLegacyRelay() -> Task<Void, Never>? {
        guard let path = configuration.legacyBridgeURL, configuration.ownsSocket, bridgeServer != nil else { return nil }
        if let legacyRelayCheck { return legacyRelayCheck }
        let relay = legacyRelay
        let target = configuration.socketURL
        let targets = profileTargets
        let isWanted = dependencies.legacyRelayWanted
        let wanted: @Sendable () -> Bool = { isWanted(targets) }
        let otherIsland = dependencies.isOtherIslandRunning
        let identity = dependencies.socketIdentity
        let hasOwner = dependencies.socketHasOwner ?? { HookSocketProbe.probe($0).hasOwner }
        let check = Task { [weak self] in
            enum Step { case keep, stop, unwanted, start, startAfterStop }
            let step = await Task.detached(priority: .utility) { () -> Step in
                if let relay {
                    // Ours while the file is the one it bound, and only while something of Juice's dials it; another
                    // app's once it bound its own.
                    guard identity(path) != relay.identity else { return wanted() ? .keep : .unwanted }
                    return wanted() && !otherIsland() && !hasOwner(path) ? .startAfterStop : .stop
                }
                return wanted() && !otherIsland() && !hasOwner(path) ? .start : .keep
            }.value
            guard let self else { return }
            self.legacyRelayCheck = nil
            guard self.bridgeServer != nil else { return }
            switch step {
            case .keep:
                break
            case .stop:
                self.stopLegacyRelay()
                JuiceLog.bridge.notice("Open Island's hook socket is another app's again; the relay stopped")
            case .unwanted:
                self.stopLegacyRelay()
                JuiceLog.bridge.notice("nothing of ours dials Open Island's hook socket now; the relay stopped")
            case .start, .startAfterStop:
                self.stopLegacyRelay()
                do {
                    self.legacyRelay = try LegacyBridgeRelay(path: path, target: target)
                    JuiceLog.bridge.notice("older hooks reach the app through Open Island's socket")
                } catch {
                    JuiceLog.bridge.error("Open Island's hook socket could not be relayed: \(Self.logReason(error), privacy: .public)")
                }
            }
        }
        legacyRelayCheck = check
        return check
    }

    func stopLegacyRelay() {
        legacyRelayCheck?.cancel()
        legacyRelayCheck = nil
        legacyRelay?.stop()
        legacyRelay = nil
    }

    /// Whether Open Island's socket is relayed now (Diagnostics, tests).
    public var relaysLegacySocket: Bool { legacyRelay != nil }

    /// A click changed hooks (Move, Remove, an OpenCode plugin's Update): the relay looks again at whether anything of
    /// Juice's still dials Open Island's socket (P932).
    @discardableResult
    public func hooksChanged() -> Task<Void, Never>? { checkLegacyRelay() }

    /// One more look after `socketRetry`, while a lost path waits for a session to be answered.
    func retryBridgeSocketCheck() {
        guard socketRetryTask == nil else { return }
        socketRetryTask = Task { [weak self] in
            try? await Task.sleep(for: SessionEngine.socketRetry)
            guard !Task.isCancelled, let self else { return }
            self.socketRetryTask = nil
            self.checkBridgeSockets()
        }
    }

    static let socketRetry: Duration = .seconds(30)

    /// Watches the socket's folder, so a path unlinked or bound again is looked at within a second. Only for the app's
    /// engine (`Configuration.watchesBridgeSockets`).
    func watchBridgeSockets() {
        guard configuration.watchesBridgeSockets, socketWatch == nil else { return }
        let folder = configuration.socketURL.deletingLastPathComponent().path
        let watch = dependencies.watchSocketFolder
            ?? { folder, onChange in ConfigFolderWatcher(folder: folder, files: [], onChange: onChange) }
        socketWatch = watch(folder) { [weak self] in self?.socketFolderChanged() }
    }

    func stopWatchingBridgeSockets() {
        socketWatch?.cancel()
        socketWatch = nil
        socketCheck?.cancel()
        socketCheck = nil
        socketFolderSettle?.cancel()
        socketFolderSettle = nil
        socketRetryTask?.cancel()
        socketRetryTask = nil
    }

    /// A change in the socket's folder (the bridge's own bind among them): one look once it has been quiet a second.
    func socketFolderChanged() {
        socketFolderSettle?.cancel()
        socketFolderSettle = Task { [weak self] in
            try? await Task.sleep(for: SessionEngine.socketFolderQuiet)
            guard !Task.isCancelled, let self else { return }
            self.socketFolderSettle = nil
            self.checkBridgeSockets()
        }
    }

    static let socketFolderQuiet: Duration = .seconds(1)
}
