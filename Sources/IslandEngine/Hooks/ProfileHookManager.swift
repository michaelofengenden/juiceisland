import Foundation
import IslandHookNotes
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
/// Install on a profile that has drifted (`HookDrift`), and Move is Repair on a profile whose hooks still call Open
/// Island's helper (P903).
///
/// The hooks name Juice's own helper (`HookHome`, P900), and every write goes through `HookFileEdits` (P916): Juice's
/// entries are added and taken out in place and nothing else in the file changes, so Install then Remove gives the file
/// back byte for byte, and Remove never takes Open Island's or anyone else's hooks. No manifest is written: Open Island
/// reads its own under the same name (P901).
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

    public init(bundledHelperURL: URL, managedHelperURL: URL = HookHome.current.helperURL,
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
        let old = Dictionary(targets.map { ($0.id, (statuses[$0.id]?.oldEntryCount ?? 0) > 0) }, uniquingKeysWith: { first, _ in first })
        let readings = await Task.detached(priority: .utility) {
            targets.map { ($0, ProfileHookInspector.driftReading(for: $0, managedHelperURL: managed, oldIsOurs: old[$0.id] ?? false)) }
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
        let before = try preflight(target, installing: true)
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        let managed = managedHelperURL
        let bundled = bundledHelperURL
        let featureKey = codexFeatureKey
        let oldIsOurs = before.oldEntryCount > 0
        let turnedOn = try await Task.detached(priority: .userInitiated) {
            try ProfileHookWrites.install(target, managedHelperURL: managed, bundledHelperURL: bundled, featureKey: featureKey(),
                                          oldIsOurs: oldIsOurs)
        }.value
        if let turnedOn {
            intents.setCodexFeatureTurnedOn(true, for: target.id)
            intents.setCodexSwitch(turnedOn, for: target.id)
        }
        intents.setIntent(.installed, for: target.id)
        let status = await reinspect(target)
        await checkDrift([target])
        return status
    }

    @discardableResult
    public func remove(_ target: ProfileHookTarget) async throws -> ProfileHookStatus {
        let before = try preflight(target, installing: false)
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        let managed = managedHelperURL
        let turnOff = intents.codexFeatureTurnedOn(for: target.id) ? intents.codexSwitch(for: target.id) : nil
        // Juice's older entries on Open Island's helper go too (Remove from all agents takes a folder not yet moved, P932).
        let oldIsOurs = before.oldEntryCount > 0
        let turnedOff = try await Task.detached(priority: .userInitiated) {
            try ProfileHookWrites.remove(target, managedHelperURL: managed, turnFeatureOff: turnOff, oldIsOurs: oldIsOurs)
        }.value
        if turnedOff {
            intents.setCodexFeatureTurnedOn(false, for: target.id)
            intents.setCodexSwitch(nil, for: target.id)
        }
        intents.setIntent(.removed, for: target.id)
        let status = await reinspect(target)
        await checkDrift([target])
        return status
    }

    /// Replaces the managed helper with this bundle's copy when one is already installed and differs. Never creates
    /// the helper and never touches a config file (same rule as `ManagedHooksBinary.updateIfNeeded`). Juice's helper is
    /// its own (P900), so Open Island running no longer stands in the way. The copy is written beside the old helper and
    /// renamed over it, so a hook that fires meanwhile runs one whole helper or the other. A linked helper is refused,
    /// never replaced.
    @discardableResult
    public func syncHelperIfPresent() throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: managedHelperURL.path) else { return false }
        guard !ProfileHookInspector.filesMatch(managedHelperURL, bundledHelperURL, fileManager: fileManager) else { return false }
        // A helper that is a symbolic link is someone's own setup: the rename would replace the link, not its target
        // (`HelperSync`'s rule, P24). Refused, to be updated by hand (P186).
        let type = (try? fileManager.attributesOfItem(atPath: managedHelperURL.path))?[.type] as? FileAttributeType
        guard type == .typeRegular else { throw ProfileHookError.linkedConfig(file: managedHelperURL.lastPathComponent) }
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
    /// have changed since the last refresh. A link, comments or an unreadable file refuse both (the writes go by rename,
    /// which would replace a link, P24). Vibe Island's hooks refuse Install only: Remove takes Juice's own entries and
    /// nothing else (P904). Open Island running refuses nothing: Juice's hooks name its own helper (P900).
    @discardableResult
    private func preflight(_ target: ProfileHookTarget, installing: Bool) throws -> ProfileHookStatus {
        guard statuses[target.id] != nil else { throw ProfileHookError.unknownProfile }
        let status = ProfileHookInspector.status(for: target, intent: intents.intent(for: target.id),
                                                 managedHelperURL: managedHelperURL, bundledHelperURL: bundledHelperURL)
        statuses[target.id] = status
        if case .folderMissing = status.state { throw ProfileHookError.folderMissing }
        if let problem = ProfileHookInspector.configProblem(for: target) { throw problem.error }
        if installing, status.vibeEntryCount > 0 { throw ProfileHookError.otherIslandHooksPresent(count: status.vibeEntryCount) }
        if installing, !FileManager.default.isExecutableFile(atPath: bundledHelperURL.path) {
            throw ProfileHookError.bundledHelperMissing
        }
        return status
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

/// The files Install and Remove write in one profile folder, off the main actor (P916). Install copies the helper first,
/// then adds Juice's entries (taking out Juice's older ones on Open Island's helper, P903, P932), then, for Codex, turns
/// on its hooks switch in config.toml when it is off. Remove takes Juice's entries out, and puts the switch back as it
/// was only when Juice turned it on and no hook is left (P910): the line Install replaced comes back, and a config.toml
/// Install made goes once nothing else is in it. Each file is backed up before it is written.
enum ProfileHookWrites {
    /// What Install changed when Codex's switch was off and it turned it on; nil otherwise.
    static func install(_ target: ProfileHookTarget, managedHelperURL: URL, bundledHelperURL: URL,
                        featureKey: CodexHooksFeatureFlagKey, oldIsOurs: Bool) throws -> CodexSwitchChange? {
        let folder = URL(fileURLWithPath: target.folder, isDirectory: true)
        do {
            try JuiceHelperInstall.ensure(bundled: bundledHelperURL, managed: managedHelperURL)
        } catch JuiceHelperInstall.Failure.bundledHelperMissing {
            throw ProfileHookError.bundledHelperMissing
        } catch JuiceHelperInstall.Failure.linked {
            throw ProfileHookError.linkedConfig(file: managedHelperURL.lastPathComponent)
        } catch {
            throw ProfileHookError.writeFailed("helper")
        }
        let file = folder.appendingPathComponent(ProfileHookInspector.hookFileName(for: target.provider))
        let existing = try read(file)
        let next = try edit(file) {
            try HookFileEdits.installing(existing, layout: .claudeGroups, expected: ExpectedHookEntries.entries(for: target.provider),
                                         command: ProfileHookInspector.managedCommand(for: target, managedHelperURL: managedHelperURL),
                                         owners: ProfileHookInspector.owners(for: target, managedHelperURL: managedHelperURL,
                                                                             oldIsOurs: oldIsOurs))
        }
        try write(next, to: file)
        guard target.provider == .codex else { return nil }
        let config = folder.appendingPathComponent("config.toml")
        let configData = try read(config)
        let text = configData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard !CodexHookInstaller.isCodexHooksFeatureEnabled(in: text) else { return nil }
        let mutation = CodexHookInstaller.enableCodexHooksFeature(in: text, preferredKey: featureKey)
        try write(Data(mutation.contents.utf8), to: config)
        guard mutation.featureEnabledByInstaller else { return nil }
        // The one line upstream's edit replaced in place (`codex_hooks = false` turned `hooks = true`), if it replaced one.
        let before = text.components(separatedBy: "\n"), after = mutation.contents.components(separatedBy: "\n")
        let replaced = before.count == after.count ? zip(before, after).first { $0 != $1 }?.0 : nil
        return CodexSwitchChange(createdFile: configData == nil, replacedLine: replaced)
    }

    /// True when the switch Juice had turned on was put back; `turnFeatureOff` is what Install changed, nil when Juice did
    /// not turn it on.
    static func remove(_ target: ProfileHookTarget, managedHelperURL: URL, turnFeatureOff: CodexSwitchChange?, oldIsOurs: Bool) throws -> Bool {
        let folder = URL(fileURLWithPath: target.folder, isDirectory: true)
        let file = folder.appendingPathComponent(ProfileHookInspector.hookFileName(for: target.provider))
        guard let existing = try read(file) else { return false }
        let next = try edit(file) {
            try HookFileEdits.removing(existing, layout: .claudeGroups,
                                       owners: ProfileHookInspector.owners(for: target, managedHelperURL: managedHelperURL,
                                                                           oldIsOurs: oldIsOurs))
        }
        try write(next, to: file)
        guard target.provider == .codex, let change = turnFeatureOff else { return false }
        // Any hook left in hooks.json keeps the switch on, Juice's or not.
        if let next, hasHooks(next) { return false }
        let config = folder.appendingPathComponent("config.toml")
        guard let text = try read(config).map({ String(decoding: $0, as: UTF8.self) }) else { return true }
        var lines = text.components(separatedBy: "\n")
        if let line = change.replacedLine, let index = switchLine(in: lines) {
            lines[index] = line
            try write(Data(lines.joined(separator: "\n").utf8), to: config)
            return true
        }
        let mutation = CodexHookInstaller.disableCodexHooksFeatureIfManaged(in: text)
        if change.createdFile, mutation.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try write(nil, to: config)
        } else if mutation.changed {
            try write(Data(mutation.contents.utf8), to: config)
        }
        return true
    }

    /// The `hooks = true` (or `codex_hooks = true`) line of config.toml's `[features]`, as upstream's Install writes it.
    static func switchLine(in lines: [String]) -> Int? {
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) else { return nil }
        let end = lines[(header + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        let written = [CodexHooksFeatureFlagKey.current, .legacy].map { "\($0.rawValue) = true" }
        return lines[(header + 1)..<end].firstIndex { written.contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func hasHooks(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [Any])?.isEmpty == false }
    }

    static func read(_ url: URL) throws -> Data? {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw ProfileHookError.invalidConfig(file: url.lastPathComponent) }
        return data
    }

    static func edit<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch HookFileEdits.Problem.comments {
            throw ProfileHookError.hasComments(file: url.lastPathComponent)
        } catch {
            throw ProfileHookError.invalidConfig(file: url.lastPathComponent)
        }
    }

    static func write(_ data: Data?, to url: URL) throws {
        do {
            try ConfigFileWrite.write(data, to: url)
        } catch ConfigFileWrite.Failure.linked {
            throw ProfileHookError.linkedConfig(file: url.lastPathComponent)
        } catch {
            throw ProfileHookError.writeFailed(url.lastPathComponent)
        }
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
