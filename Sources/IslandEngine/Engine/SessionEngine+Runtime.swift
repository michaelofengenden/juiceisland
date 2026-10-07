import Foundation
import JuiceCore
import OpenIslandCore

extension SessionEngine {
    /// Starts the bridge, then discovery and monitoring, as configured. The order makes it all or nothing: the
    /// owner checks come first, then the bind, and discovery and monitoring start only after the bridge is up, so a
    /// failure leaves nothing running and `hasStarted` false. Safe to call again: discovery and monitoring start once,
    /// and a bridge that failed is tried again. Installs nothing, repairs nothing, reads no usage and starts no
    /// updater: those parts of upstream's startup are left out on purpose.
    public func start() throws {
        if configuration.startBridge, bridgeServer == nil {
            do {
                try startBridgeServer()
            } catch {
                JuiceLog.bridge.error("the hook bridge did not start: \(Self.logReason(error), privacy: .public)")
                throw error
            }
        }
        if bridgeServer != nil {
            startHookNotes()
            startHookRequests()
        }
        if !hasStarted {
            // The rows' kept labels before any session is restored, so a restored row shows them at once (P445).
            loadLabels()
            if configuration.loadRuntimeState {
                if let startRuntime = dependencies.startRuntime { startRuntime(self) } else { self.startRuntime() }
            }
            hasStarted = true
        }
        if bridgeServer != nil, observerTask == nil { connectObserver() }
        if bridgeServer != nil {
            watchBridgeSockets()
            checkLegacyRelay()
        }
    }

    /// The owner checks, then the bind, then each socket path's identity as the bind left it (`bridgeHealth`). The
    /// checks come first, so a refusal binds nothing: a live listener on the bridge's socket (`BridgeServer` unlinks
    /// whatever is there), or, for a bridge on Open Island's own socket, Open Island running. A bridge on the app's own
    /// socket runs beside Open Island (P900); the legacy `/tmp` path every `BridgeServer` also binds is then no reason to
    /// refuse, since no current helper dials it (P912). `probed` are paths just probed and found free, or held by the
    /// bridge being replaced, which are not probed again.
    func startBridgeServer(probed: Set<String> = []) throws {
        let ownsSocket = configuration.ownsSocket
        if !ownsSocket, dependencies.isOtherIslandRunning() {
            lastStatusMessage = "Open Island is running; quit it first so the two apps do not fight over the hook socket."
            throw SessionEngineError.otherIslandRunning
        }
        let paths = HookSocketProbe.paths(for: configuration.socketURL)
        let hasOwner = dependencies.socketHasOwner ?? { HookSocketProbe.probe($0).hasOwner }
        let legacy = BridgeSocketLocation.legacyURL.path
        for url in paths where !probed.contains(url.path) && !(ownsSocket && url.path == legacy) && hasOwner(url) {
            lastStatusMessage = "Another app is listening on \(url.lastPathComponent); quit every island app first."
            throw SessionEngineError.hookSocketInUse(path: url.path)
        }
        let startBridge = dependencies.startBridge ?? Self.startBridgeServer
        let server: any EngineBridge
        do {
            server = try startBridge(configuration.socketURL)
        } catch {
            lastStatusMessage = "Could not start the hook bridge: \(error.localizedDescription)"
            throw error
        }
        server.updateStateSnapshot(state)
        bridgeServer = server
        boundSockets = Dictionary(uniqueKeysWithValues: paths.map { ($0.path, dependencies.socketIdentity($0)) })
        legacySocketLossNoted = false
        let sockets = boundSockets.values.compactMap { $0 }.count
        bridgeHealth = .live(sockets: sockets)
        JuiceLog.bridge.notice("the hook bridge listens on \(sockets, privacy: .public) sockets")
    }

    /// A refusal or a failure for the log: the case, never a path.
    static func logReason(_ error: any Error) -> String {
        switch error as? SessionEngineError {
        case .otherIslandRunning: "Open Island runs"
        case .hookSocketInUse: "another app listens on a hook socket"
        case nil: JuiceLog.code(error)
        }
    }

    /// A real `BridgeServer`. A server whose bind failed is stopped again, so nothing half-started is left.
    nonisolated static func startBridgeServer(at socketURL: URL) throws -> any EngineBridge {
        let server = BridgeServer(socketURL: socketURL)
        do {
            try server.start()
        } catch {
            server.stop()
            throw error
        }
        return server
    }

    /// Stops the bridge and the observer. Upstream's process monitor has no stop; it ends with the process.
    public func stop() {
        stopBridgeServer()
        stopWatchingBridgeSockets()
        bridgeHealth = .off
        stopHookNotes()
        stopHookRequests()
        childRollouts?.stop()
        subagentRollouts?.stop()
        discovery?.codexRolloutWatcher.stop()
    }

    /// The bridge and its observer only: the context notes, discovery and monitoring go on (a socket taken back).
    func stopBridgeServer() {
        stopLegacyRelay()
        observerTask?.cancel()
        observerTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        bridgeClient.disconnect()
        bridgeServer?.stop()
        bridgeServer = nil
        boundSockets = [:]
        isBridgeReady = false
    }

    func startRuntime() {
        let discovery = SessionDiscoveryCoordinator()
        discovery.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
        discovery.onStatusMessage = { [weak self] message in self?.lastStatusMessage = message }
        discovery.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        discovery.stateUpdater = { [weak self] newState in self?.takeDiscoveredState(newState) }
        discovery.onAgentEvent = { [weak self] event in self?.ingest(event, ingress: .rollout) }
        discovery.codexRolloutWatcher.eventHandler = { [weak self] event in
            Task { @MainActor [weak self] in self?.ingest(event, ingress: .rollout) }
        }
        // Questions, reviewers, calls and turn ends from the same reads (the needs-you book, C5-C7, C15).
        discovery.codexRolloutWatcher.attentionHandler = { [weak self] update in
            Task { @MainActor [weak self] in self?.ingestCodexAttention(update) }
        }
        // What each chat is at, for the peek (its reasoning summary and its plan's steps, P720).
        discovery.codexRolloutWatcher.workHandler = { [weak self] sessionID, work in
            Task { @MainActor [weak self] in self?.takeCodexWork(sessionID, work) }
        }
        // Thread names from each Codex home's index, on the same poll (the chat title, P201).
        discovery.codexRolloutWatcher.titleHandler = { [weak self] names in
            Task { @MainActor [weak self] in self?.takeCodexTitles(names) }
        }
        // A watched rollout that is not a chat (a reviewer's, a helper's, a subagent's) leaves the rows (P212).
        discovery.codexRolloutWatcher.kindHandler = { [weak self] sessionID, threadID, kind in
            Task { @MainActor [weak self] in self?.takeCodexThreadKind(sessionID: sessionID, threadID: threadID, kind: kind) }
        }
        // Every Codex app rescan's subagents, for their chats' rows (P212).
        discovery.codexRolloutDiscovery.childrenHandler = { [weak self] children in
            Task { @MainActor [weak self] in self?.takeCodexChildren(children) }
        }
        self.discovery = discovery

        let monitoring = ProcessMonitoringCoordinator()
        monitoring.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
        monitoring.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        monitoring.stateUpdater = { [weak self] newState in self?.applyMonitoredState(newState) }
        monitoring.onPersistenceNeeded = { [weak self] in self?.schedulePersistence() }
        // The Codex app starting or quitting needs no action here: its threads come from ~/.codex's hooks and the
        // upkeep tick below. Upstream's CodexAppServerCoordinator is not compiled: a separately spawned app-server
        // sees only threads it loaded itself (spec §8 Q3; guardrail check 6).
        monitoring.onCodexAppMaintenanceTick = { [weak self] in self?.discovery?.maintainCodexAppSessionsIfNeeded() }
        monitoring.isResolvingInitialLiveSessions = true
        self.monitoring = monitoring

        let otherProfiles = profileTargets.filter { !$0.isDefaultFolder }
        Task.detached(priority: .userInitiated) { [weak self] in
            let (payload, titles, threads) = SessionEngine.loadStartupPayload(discovery, otherProfiles: otherProfiles)
            await self?.applyStartupPayload(payload, claudeTitles: titles, codexThreads: threads)
        }
    }

    /// The launch's discovery, off the main thread: upstream's registries and default folders, then every other
    /// profile; beside it, the Claude title lines the same reads folded (never in a session, P200), and the Codex
    /// threads that are not chats: the scans' subagents and the restored records dropped (P212).
    nonisolated static func loadStartupPayload(_ discovery: SessionDiscoveryCoordinator, otherProfiles: [ProfileHookTarget])
        -> (SessionDiscoveryCoordinator.StartupDiscoveryPayload, [String: ClaudeTitleFold], CodexThreadsFound) {
        var payload = discovery.loadStartupDiscoveryPayload()
        var titles = discovery.claudeTranscriptDiscovery.lastScanTitles
        var threads = CodexThreadsFound(children: discovery.codexRolloutDiscovery.lastScanChildren)
        addProfileDiscoveries(to: &payload, titles: &titles, children: &threads.children, from: otherProfiles)
        threads.hidden = dropInternalRecords(&payload)
        return (payload, titles, threads)
    }

    /// What a launch's discovery found, as `RolloutScanMeasure coldstart` reports it: counts, and the rollouts the
    /// engine would then watch, which it hands to a `CodexRolloutTracker` and never prints.
    public struct StartupDiscoveryResult: Sendable {
        public var restoredRecordCount: Int
        public var codexSessionCount: Int
        public var claudeSessionCount: Int
        public var watchTargets: [CodexRolloutWatchTarget]
    }

    /// Runs a launch's discovery exactly as `startRuntime` runs it, for `profiles` (the default folders count through
    /// the coordinator, as at launch), and applies nothing: no registry is pruned or saved.
    public static func measureStartupDiscovery(profiles: [ProfileHookTarget]) async -> StartupDiscoveryResult {
        let discovery = SessionDiscoveryCoordinator()
        let otherProfiles = profiles.filter { !$0.isDefaultFolder }
        let (payload, _, _) = await Task.detached(priority: .userInitiated) {
            SessionEngine.loadStartupPayload(discovery, otherProfiles: otherProfiles)
        }.value
        let codex = payload.codexRecords.map(\.restorableSession) + payload.discoveredCodexRecords.map(\.session)
        var seen: Set<String> = []
        let targets = codex.compactMap { session -> CodexRolloutWatchTarget? in
            guard !session.isSessionEnded, let path = session.codexMetadata?.transcriptPath, !path.isEmpty,
                  seen.insert(session.id).inserted else { return nil }
            return CodexRolloutWatchTarget(sessionID: session.id, transcriptPath: path)
        }
        return StartupDiscoveryResult(
            restoredRecordCount: payload.codexRecords.count + payload.claudeRecords.count + payload.openCodeRecords.count
                + payload.cursorRecords.count + payload.piRecords.count,
            codexSessionCount: payload.discoveredCodexRecords.count, claudeSessionCount: payload.discoveredClaudeSessions.count,
            watchTargets: targets)
    }

    /// Upstream scans only ~/.claude/projects and ~/.codex/sessions at launch; this adds every other profile. Each is
    /// read by `ClaudeTranscriptScanner` or `CodexRolloutScanner`, as the patched coordinator reads the default ones
    /// (P83, P84).
    nonisolated static func addProfileDiscoveries(to payload: inout SessionDiscoveryCoordinator.StartupDiscoveryPayload,
                                                  from targets: [ProfileHookTarget]) {
        var titles: [String: ClaudeTitleFold] = [:]
        var children: [CodexChildThread] = []
        addProfileDiscoveries(to: &payload, titles: &titles, children: &children, from: targets)
    }

    /// As above, with the title lines each Claude profile's read folded and the subagents each Codex profile's found.
    nonisolated static func addProfileDiscoveries(to payload: inout SessionDiscoveryCoordinator.StartupDiscoveryPayload,
                                                  titles: inout [String: ClaudeTitleFold], children: inout [CodexChildThread],
                                                  from targets: [ProfileHookTarget]) {
        for target in targets {
            let root = URL(fileURLWithPath: target.folder, isDirectory: true)
            switch target.provider {
            case .claude:
                let scanner = ClaudeTranscriptScanner(rootURL: root.appendingPathComponent("projects", isDirectory: true))
                payload.discoveredClaudeSessions += scanner.discoverRecentSessions()
                titles.merge(scanner.lastScanTitles) { first, _ in first }
            case .codex:
                let scanner = CodexRolloutScanner(rootURL: root.appendingPathComponent("sessions", isDirectory: true))
                payload.discoveredCodexRecords += scanner.discoverRecentSessions()
                children += scanner.lastScanChildren
            }
        }
    }

    func applyStartupPayload(_ payload: SessionDiscoveryCoordinator.StartupDiscoveryPayload,
                             claudeTitles: [String: ClaudeTitleFold] = [:], codexThreads threads: CodexThreadsFound = CodexThreadsFound()) {
        takeStartupCodexThreads(threads)
        discovery?.applyStartupDiscoveryPayload(payload)
        syncSubagentRollouts()
        settleRestoredWaits()
        retagSessions()
        takeStartupTitles(claude: claudeTitles)
        guard let monitoring else { return }
        // Upstream reconciles once more here, on the main thread: `ps`, an `lsof` per agent and an AppleScript probe of
        // each terminal, before its loop starts. The loop's first pass, which starts at once, does the same with all of
        // that found off the main thread (P86).
        if let startMonitoring = dependencies.startMonitoring {
            startMonitoring(monitoring)
        } else {
            monitoring.startMonitoringIfNeeded()
        }
        endInitialResolution(of: monitoring, after: Self.initialResolutionLimit)
    }

    /// Upstream stops resolving the launch's live sessions only when every running terminal answers its AppleScript
    /// probe. Until then it polls every 2 s (`ps`, an `lsof` per agent, `osascript` per terminal) and the engine holds
    /// back every signal from a rollout, so a terminal that never answers (Automation access denied, a probe that
    /// times out) kept both going for the app's whole life (P86). By this time the launch's sessions are resolved as
    /// well as they will be.
    static let initialResolutionLimit: Duration = .seconds(30)

    /// Returns the task that ends it, so a test can wait for the flag itself rather than for a time.
    @discardableResult
    func endInitialResolution(of monitoring: ProcessMonitoringCoordinator, after limit: Duration) -> Task<Void, Never> {
        Task { [weak monitoring] in
            try? await Task.sleep(for: limit)
            monitoring?.isResolvingInitialLiveSessions = false
        }
    }

    /// A restored "needs you" row can never be answered: upstream saves the phase but not the request, and the hook
    /// that asked is gone. Such a session ends as interrupted, with no signal; only a live hook creates a card
    /// (P8).
    func settleRestoredWaits() {
        for session in state.sessions where session.phase.requiresAttention
            && session.permissionRequest == nil && session.questionPrompt == nil {
            applyOwnInterrupt(session.id, summary: Self.restartedSummary, at: session.updatedAt)
        }
    }

    static let restartedSummary = "Interrupted (app restarted)."

    func connectObserver() {
        observerTask?.cancel()
        reconnectTask?.cancel()
        bridgeClient.disconnect()
        let client = LocalBridgeClient(socketURL: configuration.socketURL)
        bridgeClient = client
        let stream: AsyncThrowingStream<AgentEvent, Error>
        do {
            stream = try client.connect()
        } catch {
            isBridgeReady = false
            lastStatusMessage = "Hook bridge observer could not connect: \(error.localizedDescription)"
            scheduleReconnect()
            return
        }
        observerTask = Task { [weak self] in
            do {
                try await client.send(.registerClient(role: .observer))
            } catch {
                guard !Task.isCancelled else { return }
                self?.isBridgeReady = false
                self?.scheduleReconnect()
                return
            }
            self?.isBridgeReady = true
            self?.reconnectDelay = .seconds(2)
            do {
                for try await event in stream {
                    self?.bridgeEventsTaken += 1
                    self?.ingest(event, ingress: .bridge)
                }
            } catch {}
            guard !Task.isCancelled else { return }
            self?.isBridgeReady = false
            self?.scheduleReconnect()
        }
    }

    /// 2 s, doubling to 30 s, reset by a successful registration.
    func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, .seconds(30))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.bridgeServer != nil else { return }
            self.connectObserver()
        }
    }
}
