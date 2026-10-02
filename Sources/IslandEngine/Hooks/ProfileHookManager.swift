import Foundation
import JuiceCore
import Observation
import OpenIslandCore

public enum ProfileHookError: Error, Equatable, Sendable {
    case folderMissing
    case unknownProfile
    case otherIslandHooksPresent(count: Int)
    case openIslandAppRunning
    case bundledHelperMissing
    case invalidConfig(file: String)
    case linkedConfig(file: String)
    case hasComments(file: String)
    case writeFailed(String)
}

/// Installs, removes and checks the Claude Code and Codex hooks of each profile folder. Nothing here runs by
/// itself: `install` and `remove` happen only on an explicit click, and there is no automatic repair. Repair is
/// Install on a profile that has drifted (`HookDrift`).
@MainActor
@Observable
public final class ProfileHookManager {
    public private(set) var statuses: [String: ProfileHookStatus] = [:]
    public private(set) var busy: Set<String> = []
    /// The last drift reading per profile that was not "being edited" (`checkDrift`).
    public private(set) var driftReadings: [String: HookDriftReading] = [:]
    /// "Hooks missing in <alias> · Repair", per profile, from the last drift check.
    public private(set) var driftAlerts: [String: HookDriftAlert] = [:]

    @ObservationIgnored private let bundledHelperURL: URL
    @ObservationIgnored private let managedHelperURL: URL
    @ObservationIgnored private let intents: ProfileHookIntentStore
    @ObservationIgnored private let codexFeatureKey: @Sendable () -> CodexHooksFeatureFlagKey
    @ObservationIgnored private let isOpenIslandAppRunning: @Sendable () -> Bool

    public init(bundledHelperURL: URL, managedHelperURL: URL = ManagedHooksBinary.defaultURL(),
                intents: ProfileHookIntentStore, codexFeatureKey: @escaping @Sendable () -> CodexHooksFeatureFlagKey,
                isOpenIslandAppRunning: @escaping @Sendable () -> Bool) {
        self.bundledHelperURL = bundledHelperURL
        self.managedHelperURL = managedHelperURL
        self.intents = intents
        self.codexFeatureKey = codexFeatureKey
        self.isOpenIslandAppRunning = isOpenIslandAppRunning
    }

    /// Re-reads every target's files off the main actor. Writes nothing. Profiles not in `targets` are forgotten.
    public func refresh(_ targets: [ProfileHookTarget]) async {
        let fresh = await inspect(targets)
        var next: [String: ProfileHookStatus] = [:]
        for status in fresh { next[status.id] = status }
        statuses = next
        let ids = Set(targets.map(\.id))
        driftReadings = driftReadings.filter { ids.contains($0.key) }
        driftAlerts = driftAlerts.filter { ids.contains($0.key) }
    }

    /// Re-reads only these targets' files, keeping every other profile's status. Writes nothing.
    public func refresh(only targets: [ProfileHookTarget]) async {
        for status in await inspect(targets) { statuses[status.id] = status }
    }

    private func inspect(_ targets: [ProfileHookTarget]) async -> [ProfileHookStatus] {
        let managed = managedHelperURL
        let bundled = bundledHelperURL
        let withIntents = targets.map { ($0, intents.intent(for: $0.id)) }
        return await Task.detached(priority: .utility) {
            withIntents.map { target, intent in
                ProfileHookInspector.status(for: target, intent: intent, managedHelperURL: managed, bundledHelperURL: bundled)
            }
        }.value
    }

    /// One drift check of these profiles (P26, P51): compares each settings.json or hooks.json with the expected
    /// entries and raises or clears its row. A file being edited (empty, unparsable or unreadable) changes nothing; a
    /// missing folder has no row. A profile that reads complete is recorded as installed (`HookDrift.recordedIntent`),
    /// so losing every entry later still raises the row. Reads only; nothing is repaired.
    public func checkDrift(_ targets: [ProfileHookTarget]) async {
        let managed = managedHelperURL
        let readings = await Task.detached(priority: .utility) {
            targets.map { ($0, ProfileHookInspector.driftReading(for: $0, managedHelperURL: managed)) }
        }.value
        for (target, reading) in readings {
            guard let reading else {
                driftReadings[target.id] = nil
                driftAlerts[target.id] = nil
                continue
            }
            guard reading != .beingEdited else { continue }
            let intent = intents.intent(for: target.id)
            driftAlerts[target.id] = HookDrift.alert(for: target, intent: intent, reading: reading, previous: driftReadings[target.id])
            driftReadings[target.id] = reading
            let recorded = HookDrift.recordedIntent(after: reading, intent: intent)
            if recorded != intent { intents.setIntent(recorded, for: target.id) }
        }
    }

    /// Setup's and Diagnostics' state for a profile: the inspector's state, with a drifted file shown as `partial`.
    public func setupState(for id: String) -> ProfileHookStatus.State? {
        guard let status = statuses[id] else { return nil }
        guard let reading = driftReadings[id] else { return status.state }
        return HookDrift.setupState(status, reading: reading)
    }

    /// The entries a drifted profile is missing, in the installer's order; empty otherwise.
    public func missingEntries(for id: String) -> [HookEntrySpec] {
        if case let .drifted(missing) = driftReadings[id] { return missing }
        return []
    }

    public var isOpenIslandRunning: Bool { isOpenIslandAppRunning() }

    /// This build carries the helper Install copies (`Contents/Helpers/OpenIslandHooks`).
    public var hasBundledHelper: Bool { FileManager.default.isExecutableFile(atPath: bundledHelperURL.path) }

    /// The managed helper (the one every hook command names) is installed.
    public var managedHelperExists: Bool { FileManager.default.fileExists(atPath: managedHelperURL.path) }

    /// The managed helper differs from this build's while a profile's hooks run it (P163): until an Update click
    /// (`syncHelperIfPresent`), hooks run the old helper and this build's rules are not in effect. From the last
    /// reading (`refresh`); reads nothing itself.
    public var helperNeedsUpdate: Bool {
        hasBundledHelper && managedHelperExists
            && statuses.values.contains { $0.managedEventCount > 0 && !$0.helperMatchesBundle }
    }

    /// The button Setup shows for this profile, and why it is unavailable when it is.
    public func choice(for id: String) -> ProfileHookChoice? {
        guard let status = statuses[id], let state = setupState(for: id) else { return nil }
        return ProfileHookChoice.of(status, setupState: state, openIslandRunning: isOpenIslandRunning, helperPresent: hasBundledHelper)
    }

    /// Repair is Install, on a click: it adds back what is missing (spec §3.5).
    @discardableResult
    public func repair(_ target: ProfileHookTarget) async throws -> ProfileHookStatus {
        try await install(target)
    }

    @discardableResult
    public func install(_ target: ProfileHookTarget) async throws -> ProfileHookStatus {
        try preflight(target, installing: true)
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        let folderURL = URL(fileURLWithPath: target.folder, isDirectory: true)
        let managed = managedHelperURL
        let bundled = bundledHelperURL
        let featureKey = codexFeatureKey
        try await Task.detached(priority: .userInitiated) {
            do {
                switch target.provider {
                case .claude:
                    try ClaudeHookInstallationManager(claudeDirectory: folderURL, managedHooksBinaryURL: managed,
                                                      hookSource: "claude").install(hooksBinaryURL: bundled)
                case .codex:
                    try CodexHookInstallationManager(codexDirectory: folderURL, managedHooksBinaryURL: managed,
                                                     featureKeyProvider: featureKey).install(hooksBinaryURL: bundled)
                }
            } catch {
                throw ProfileHookError.writeFailed(String(describing: type(of: error)))
            }
            HookBackups.prune(in: folderURL, files: ProfileHookInspector.configFileNames(for: target.provider))
        }.value
        intents.setIntent(.installed, for: target.id)
        let status = await reinspect(target)
        await checkDrift([target])
        return status
    }

    @discardableResult
    public func remove(_ target: ProfileHookTarget) async throws -> ProfileHookStatus {
        try preflight(target, installing: false)
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        let folderURL = URL(fileURLWithPath: target.folder, isDirectory: true)
        let managed = managedHelperURL
        try await Task.detached(priority: .userInitiated) {
            do {
                switch target.provider {
                case .claude:
                    try ClaudeHookInstallationManager(claudeDirectory: folderURL, managedHooksBinaryURL: managed,
                                                      hookSource: "claude").uninstall()
                case .codex:
                    try CodexHookInstallationManager(codexDirectory: folderURL, managedHooksBinaryURL: managed,
                                                     featureKeyProvider: { .current }).uninstall()
                }
            } catch {
                throw ProfileHookError.writeFailed(String(describing: type(of: error)))
            }
            HookBackups.prune(in: folderURL, files: ProfileHookInspector.configFileNames(for: target.provider))
        }.value
        intents.setIntent(.removed, for: target.id)
        let status = await reinspect(target)
        await checkDrift([target])
        return status
    }

    /// Replaces the managed helper with this bundle's copy when one is already installed and differs. Never creates
    /// the helper and never touches a config file (same rule as `ManagedHooksBinary.updateIfNeeded`). Refused while
    /// Open Island runs, because its own launch copies its helper back (P27); the app calls this
    /// only once Open Island is gone (M7). The copy is written beside the old helper and renamed over it, so a hook
    /// that fires meanwhile runs one whole helper or the other. A linked helper is refused, never replaced.
    @discardableResult
    public func syncHelperIfPresent() throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: managedHelperURL.path) else { return false }
        guard !ProfileHookInspector.filesMatch(managedHelperURL, bundledHelperURL, fileManager: fileManager) else { return false }
        // A helper that is a symbolic link is someone's own setup: the rename would replace the link, not its target
        // (`HelperSync`'s rule, P24). Refused, to be updated by hand (P186).
        let type = (try? fileManager.attributesOfItem(atPath: managedHelperURL.path))?[.type] as? FileAttributeType
        guard type == .typeRegular else { throw ProfileHookError.linkedConfig(file: managedHelperURL.lastPathComponent) }
        guard !isOpenIslandAppRunning() else { throw ProfileHookError.openIslandAppRunning }
        guard fileManager.isExecutableFile(atPath: bundledHelperURL.path) else { throw ProfileHookError.bundledHelperMissing }
        let staging = managedHelperURL.deletingLastPathComponent()
            .appendingPathComponent(".\(managedHelperURL.lastPathComponent).juice-island-new")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: bundledHelperURL, to: staging)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        guard rename(staging.path, managedHelperURL.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staging)
            throw ProfileHookError.writeFailed("rename failed (errno \(code))")
        }
        return true
    }

    /// Stops at the first problem, before anything is written. The files are inspected again here, because they may
    /// have changed since the last refresh. Remove is refused for the same reasons as Install (except the bundled
    /// helper): upstream's Claude uninstaller deletes every `vibe-island-bridge` hook it finds, both uninstallers
    /// read an unreadable file as empty, and both write by rename, which replaces a symbolic link.
    private func preflight(_ target: ProfileHookTarget, installing: Bool) throws {
        guard !isOpenIslandAppRunning() else { throw ProfileHookError.openIslandAppRunning }
        guard statuses[target.id] != nil else { throw ProfileHookError.unknownProfile }
        let status = ProfileHookInspector.status(for: target, intent: intents.intent(for: target.id),
                                                 managedHelperURL: managedHelperURL, bundledHelperURL: bundledHelperURL)
        statuses[target.id] = status
        if case .folderMissing = status.state { throw ProfileHookError.folderMissing }
        if let problem = ProfileHookInspector.configProblem(for: target) { throw problem.error }
        guard status.vibeEntryCount == 0 else { throw ProfileHookError.otherIslandHooksPresent(count: status.vibeEntryCount) }
        if installing, !FileManager.default.isExecutableFile(atPath: bundledHelperURL.path) {
            throw ProfileHookError.bundledHelperMissing
        }
    }

    private func reinspect(_ target: ProfileHookTarget) async -> ProfileHookStatus {
        let managed = managedHelperURL
        let bundled = bundledHelperURL
        let intent = intents.intent(for: target.id)
        let status = await Task.detached(priority: .utility) {
            ProfileHookInspector.status(for: target, intent: intent, managedHelperURL: managed, bundledHelperURL: bundled)
        }.value
        statuses[target.id] = status
        return status
    }
}

/// Upstream's installers copy each config file to `<file>.backup.<ISO 8601 time, ":" as "-">` before every write and
/// never delete one (ClaudeHookInstallationManager.swift:176-189, CodexHookInstallationManager.swift:207-220 at
/// 1.2.1). After each Install or Remove, only the newest 3 of those backups are kept per file; nothing with another
/// name is touched (P25).
enum HookBackups {
    static let keep = 3

    static func prune(in folderURL: URL, files: [String], fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folderURL.path) else { return }
        for file in files {
            for name in backups(of: file, in: names).dropFirst(keep) {
                try? fileManager.removeItem(at: folderURL.appendingPathComponent(name))
            }
        }
    }

    /// Upstream's backups of `file`, newest first. The UTC timestamp has a fixed width, so names sort by time.
    static func backups(of file: String, in names: [String]) -> [String] {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: file) + #"\.backup\.\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return names.filter { name in
            regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }.sorted(by: >)
    }
}
