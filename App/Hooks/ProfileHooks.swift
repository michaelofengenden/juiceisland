import AppKit
import Foundation
import IslandEngine
import IslandHookNotes
import JuiceCore
import Observation
import OpenIslandCore

/// Setup, Diagnostics' Hooks section and the drift rows over the real `ProfileHookManager` (spec §3.5, §4.5): one
/// row per profile in `ProfileDirectory`, drift checks at launch, on wake, on a profile change and 2 s after the last
/// file event in a profile (`HookDriftMonitor`). It reads and watches only; hooks change on the owner's click
/// (`perform`, `installAllMonitored`) and never otherwise. Built inert: `activate()`, at launch, starts the reading.
@MainActor
@Observable
final class ProfileHooks: HooksModel {
    let manager: ProfileHookManager
    @ObservationIgnored let directory: ProfileDirectory
    /// Setup's OpenCode row (P480).
    let openCode: OpenCodePluginModel
    private(set) var openIslandRunning = false
    private(set) var vibeIslandRunning = false
    private(set) var helperInBuild = false
    private var clickRefusals: [String: ProfileHookRefusal] = [:]
    /// Profiles a click has sent to Install, Repair or Remove, from the click until that action ends. The manager
    /// marks a profile busy only once its task runs, so without this a second click in between would start a second
    /// install of the same profile beside the first.
    private var clicked: Set<String> = []
    /// An Update click on the helper, from the click until it ends, or why it was refused.
    private var helperClick: HelperUpdate?
    /// The live engine's last hook event per profile; set by the app while Live sessions runs.
    @ObservationIgnored var hookEvents: @MainActor () -> [String: Date] = { [:] }
    /// A click changed hooks or the OpenCode plugin: the live engine looks again at whether anything of Juice's still
    /// dials Open Island's socket (P932).
    @ObservationIgnored var onHooksChanged: @MainActor () -> Void = {}

    @ObservationIgnored private let watch: HookDriftMonitor.Watch
    @ObservationIgnored private let schedule: HookDriftMonitor.Schedule
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let isOpenIslandRunning: @MainActor () -> Bool
    @ObservationIgnored private let isVibeIslandRunning: @MainActor () -> Bool
    @ObservationIgnored private let home: String
    @ObservationIgnored private(set) var monitor: HookDriftMonitor?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(manager: ProfileHookManager, directory: ProfileDirectory, home: String = NSHomeDirectory(),
         openCode: OpenCodePluginModel? = nil,
         watch: @escaping HookDriftMonitor.Watch = { _, _ in nil },
         schedule: @escaping HookDriftMonitor.Schedule = HookDriftMonitor.sleepThenRun,
         now: @escaping @Sendable () -> Date = { Date() },
         isOpenIslandRunning: @escaping @MainActor () -> Bool = { false },
         isVibeIslandRunning: @escaping @MainActor () -> Bool = { false }) {
        self.manager = manager
        self.directory = directory
        self.home = home
        // Tests that build their own hooks never read this Mac's OpenCode folder or run `opencode`.
        self.openCode = openCode ?? .inert
        self.watch = watch
        self.schedule = schedule
        self.now = now
        self.isOpenIslandRunning = isOpenIslandRunning
        self.isVibeIslandRunning = isVibeIslandRunning
    }

    /// The app's: the helper this bundle carries (`Contents/Helpers/OpenIslandHooks`, bundled by the build), installed
    /// as the app's own `<home>/bin/JuiceHooks` (P900), intents in this app's defaults, and Codex's current
    /// `[features] hooks` key (Codex 0.130 and later; no `codex` is ever run to ask).
    static func app(directory: ProfileDirectory) -> ProfileHooks {
        let manager = ProfileHookManager(bundledHelperURL: HelperSync.bundledHelperURL(), managedHelperURL: HookHome.current.helperURL,
                                         intents: ProfileHookIntentStore(), codexFeatureKey: { .current },
                                         isOpenIslandAppRunning: { SingleIslandGuard.otherIslandIsRunning() })
        return ProfileHooks(manager: manager, directory: directory, openCode: OpenCodePluginModel(), watch: { target, onChange in
            ConfigFolderWatcher.watch(target, onChange: onChange)
        }, isOpenIslandRunning: { SingleIslandGuard.otherIslandIsRunning() },
           isVibeIslandRunning: { SingleIslandGuard.vibeIslandIsRunning() })
    }

    // MARK: Reading

    /// Reads every profile, starts the drift triggers and follows profile changes, wake and Open Island. Once.
    func activate() {
        guard monitor == nil else { return }
        updateEnvironment()
        let monitor = HookDriftMonitor(watch: watch, schedule: schedule, now: now) { [weak self] targets, reason in
            await self?.check(targets, reason)
        }
        self.monitor = monitor
        directory.onChange.append { [weak self] targets in
            Task { @MainActor in await self?.monitor?.profilesChanged(targets) }
        }
        directory.activate()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.monitor?.wake() }
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateEnvironment() }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateEnvironment() }
            },
        ]
        let targets = directory.targets
        Task { await monitor.launch(targets) }
        Task { await openCode.refresh(askVersion: false) }
    }

    /// Stops the watches (quitting).
    func stop() {
        monitor?.stop()
        directory.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    private func updateEnvironment() {
        openIslandRunning = isOpenIslandRunning()
        vibeIslandRunning = isVibeIslandRunning()
        helperInBuild = manager.hasBundledHelper
    }

    /// One drift check: the whole list at launch and on a profile change (profiles that went are forgotten), the
    /// profiles in question otherwise.
    func check(_ targets: [ProfileHookTarget], _ reason: HookDriftMonitor.Reason) async {
        updateEnvironment()
        switch reason {
        case .launch, .profileChange: await manager.refresh(targets)
        case .wake, .fileEvent: await manager.refresh(only: targets)
        }
        await manager.checkDrift(targets)
        if reason == .fileEvent { for target in targets { clickRefusals[target.id] = nil } }
        // A refused Update is offered again once something changed (Open Island quit, a wake, a profile change).
        if case .refused = helperClick { helperClick = nil }
    }

    // MARK: HooksModel

    /// Every profile, except a default folder that does not exist and is no account: nothing to set up there.
    private var shownTargets: [ProfileHookTarget] {
        directory.targets.filter { target in
            target.accountID != nil || manager.statuses[target.id].map { $0.state != .folderMissing } ?? true
        }
    }

    var rows: [HookSetupRow] {
        shownTargets.map { target in
            let status = manager.statuses[target.id]
            let state = manager.setupState(for: target.id)
            let choice = status.flatMap { status in
                state.map { ProfileHookChoice.of(status, setupState: $0, openIslandRunning: openIslandRunning, helperPresent: helperInBuild) }
            }
            return HookRowText.row(target: target, status: status, setupState: state, choice: choice,
                                   missing: manager.missingEntries(for: target.id), busy: isBusy(target.id),
                                   clickRefusal: clickRefusals[target.id], home: home)
        }
    }

    var alerts: [HookDriftAlert] { shownTargets.compactMap { manager.driftAlerts[$0.id] } }

    var integrations: HookIntegrations {
        HookIntegrations(openIslandRunning: openIslandRunning,
                         vibeProfiles: shownTargets.filter { (manager.statuses[$0.id]?.vibeEntryCount ?? 0) > 0 }.count,
                         helperInBuild: helperInBuild, vibeIslandRunning: vibeIslandRunning)
    }

    var lastEvents: [String: Date] { hookEvents() }

    var helperUpdate: HelperUpdate? {
        if let helperClick { return helperClick }
        // Juice's helper is its own (P900): Open Island running no longer holds its Update up.
        return manager.helperNeedsUpdate ? .available : nil
    }

    /// Replaces the managed helper by rename (held helpers keep running the old one to their end), then reads every
    /// profile again. The line reads "…"
    /// until the profiles have been read again: the statuses say "older" until then, and Update must not come back,
    /// enabled, as if the click had failed (P175).
    func updateHelper() {
        guard helperClick != .updating else { return }
        helperClick = .updating
        Task {
            var outcome: HelperUpdate?
            do {
                _ = try manager.syncHelperIfPresent()
            } catch let error as ProfileHookError {
                outcome = .refused(HookRowText.refusal(ProfileHookRefusal(error)))
            } catch {
                outcome = .refused(HookRowText.refusal(.writeFailed))
            }
            // A refusal shows at once; a replaced helper keeps "…" through the re-read.
            if outcome != nil { helperClick = outcome }
            await manager.refresh(only: directory.targets)
            updateEnvironment()
            if helperClick == .updating { helperClick = outcome }
        }
    }

    func clickRefusal(for id: String) -> String? { clickRefusals[id].map(HookRowText.refusal) }

    func readAgain() async {
        updateEnvironment()
        await manager.refresh(only: directory.targets)
        await manager.checkDrift(directory.targets)
    }

    // MARK: OpenCode

    var openCodeRow: OpenCodeSetupRow? { openCode.row(home: home) }

    func performOpenCode() {
        Task {
            await openCode.perform()
            onHooksChanged()
        }
    }

    func removeOpenCode() {
        Task {
            await openCode.perform(only: .remove)
            onHooksChanged()
        }
    }

    func refreshOpenCode() {
        updateEnvironment()
        Task { await openCode.refresh(askVersion: true) }
    }

    // MARK: Clicks

    private func isBusy(_ id: String) -> Bool { clicked.contains(id) || manager.busy.contains(id) }

    func perform(_ action: ProfileHookAction, on id: String) {
        guard let target = directory.targets.first(where: { $0.id == id }), !isBusy(id) else { return }
        clickRefusals[id] = nil
        clicked.insert(id)
        Task { await run(action, on: target) }
    }

    func installAllMonitored() {
        let chosen = installableMonitoredRows.compactMap { row in directory.targets.first { $0.id == row.id } }
        clicked.formUnion(chosen.map(\.id))
        Task {
            for target in chosen { await run(.install, on: target) }
        }
    }

    /// One action on each profile, in turn: never two installs side by side, which would both copy the helper (P939).
    func run(_ action: ProfileHookAction, on ids: [String]) {
        let chosen = ids.compactMap { id in directory.targets.first { $0.id == id && !isBusy(id) } }
        guard !chosen.isEmpty else { return }
        for target in chosen { clickRefusals[target.id] = nil }
        clicked.formUnion(chosen.map(\.id))
        Task {
            for target in chosen { await run(action, on: target) }
        }
    }

    /// The click's one action; a refusal (the preflight reads the files again) or a failed write is kept for its row.
    func run(_ action: ProfileHookAction, on target: ProfileHookTarget) async {
        defer { clicked.remove(target.id) }
        do {
            switch action {
            case .install: try await manager.install(target)
            case .repair: try await manager.repair(target)
            case .remove: try await manager.remove(target)
            }
            clickRefusals[target.id] = nil
        } catch let error as ProfileHookError {
            clickRefusals[target.id] = ProfileHookRefusal(error)
        } catch {
            clickRefusals[target.id] = .writeFailed
        }
        updateEnvironment()
        onHooksChanged()
    }
}
