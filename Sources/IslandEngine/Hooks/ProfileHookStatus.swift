import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Synchronization

/// One profile's hook state, built read-only. Carries counts, flags and upstream health issues only, never file
/// contents. Some health issues carry an absolute path, which holds the real folder name: Setup and Diagnostics may
/// show them, but Copy Report (M5) exports only the case names.
public struct ProfileHookStatus: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case folderMissing
        /// A config file the installers would write (settings.json; hooks.json or config.toml) is a symbolic link.
        /// Upstream writes by atomic rename, which would replace the link with a plain file (P24),
        /// so Install and Remove refuse and nothing is written.
        case linkedConfig(file: String)
        /// settings.json or hooks.json has comments (JSONC). Upstream's installers cannot read it; Juice Island never
        /// rewrites it, so Install and Remove refuse and the owner edits it by hand (P25).
        case hasComments(file: String)
        /// A config file exists but cannot be read or decoded. Upstream's installers would treat it as empty and
        /// overwrite it, so Install and Remove refuse and nothing is written.
        case unreadable(file: String)
        /// Vibe Island's hooks are in this file and ours are not all there. Install and Repair refuse whenever
        /// `vibeEntryCount` is above 0, whatever the state, until Vibe Island's are removed (wave 2's Switch to Juice);
        /// Remove takes out Juice's own entries only, so it goes ahead (P904).
        case blockedByOtherIsland(vibeEntries: Int)
        /// The hooks still call Open Island's helper (what Juice installed before its own, P900): they work through the
        /// old socket while nobody else holds it, and Move (Repair) puts Juice's helper in their place (P903).
        case oldHelper(entries: Int)
        case broken([HookHealthReport.Issue])
        case notInstalled
        case partial(installed: Int, expected: Int)
        case codexFeatureOff
        /// Run `/hooks` in this CODEX_HOME to approve these events.
        case codexNeedsTrust(untrustedEvents: [String])
        case installed
    }

    public let target: ProfileHookTarget
    public let state: State
    public let intent: ProfileHookIntent
    public let managedEventCount: Int
    public let expectedEventCount: Int
    public let vibeEntryCount: Int
    public let otherHookCount: Int
    /// Entries that run Open Island's helper with this agent's source (P903).
    public var oldEntryCount = 0
    /// The managed helper exists and has the same bytes as the one in this app's bundle.
    public let helperMatchesBundle: Bool
    /// Codex only.
    public let codexFeatureEnabled: Bool?
    public let checkedAt: Date

    public var id: String { target.id }
}

/// Builds a `ProfileHookStatus` from the files in one profile folder. Reads only; spawns nothing.
enum ProfileHookInspector {
    static func status(for target: ProfileHookTarget, intent: ProfileHookIntent, managedHelperURL: URL,
                       bundledHelperURL: URL, fileManager: FileManager = .default, now: Date = .now) -> ProfileHookStatus {
        let folderURL = URL(fileURLWithPath: target.folder, isDirectory: true)
        let events = target.provider == .claude ? ClaudeHookEvents.all : CodexHookEvents.all
        let helperMatches = filesMatch(managedHelperURL, bundledHelperURL, fileManager: fileManager)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ProfileHookStatus(target: target, state: .folderMissing, intent: intent, managedEventCount: 0,
                                     expectedEventCount: events.count, vibeEntryCount: 0, otherHookCount: 0,
                                     helperMatchesBundle: helperMatches, codexFeatureEnabled: nil, checkedAt: now)
        }

        let configName = hookFileName(for: target.provider)
        let owners = self.owners(for: target, managedHelperURL: managedHelperURL, oldIsOurs: true)
        let groups = hookGroups(in: folderURL.appendingPathComponent(configName))
        var positions: [String: (group: Int, hook: Int)] = [:]
        var vibe = 0
        var other = 0
        var old = 0
        for (event, eventGroups) in groups {
            for (groupIndex, commands) in eventGroups.enumerated() {
                for (hookIndex, entry) in commands.enumerated() {
                    if owners.isOurs(entry) {
                        if positions[event] == nil { positions[event] = (groupIndex, hookIndex) }
                    } else if owners.isOld(entry) {
                        old += 1
                    } else if VibeIslandHooks.isBridge(entry) {
                        // The same rule Switch to Juice takes out by (P955).
                        vibe += 1
                    } else {
                        other += 1
                    }
                }
            }
        }
        let managedCount = events.filter { positions[$0] != nil }.count
        // Open Island's helper's entries are Juice's own older ones only where Juice wrote this profile's hooks before
        // its own helper; anywhere else they are Open Island's, and Juice leaves them alone (P903, P932).
        if !oldIsOurs(intent: intent, managedCount: managedCount) {
            other += old
            old = 0
        }

        var codexFeature: Bool?
        var untrusted: [String] = []
        if target.provider == .codex {
            let config = (try? String(contentsOf: folderURL.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
            codexFeature = CodexHookInstaller.isCodexHooksFeatureEnabled(in: config)
            let trusted = CodexTrustScanner.trustedKeys(inConfig: config)
            let hooksFile = folderURL.appendingPathComponent("hooks.json").path
            untrusted = events.filter { event in
                guard let position = positions[event] else { return false }
                return !trusted.contains(CodexTrustScanner.key(hooksFile: hooksFile, event: event,
                                                               group: position.group, hook: position.hook))
            }
        }

        // Juice's own helper must be there for its entries to run; a profile with none of ours needs none.
        var errors: [HookHealthReport.Issue] = []
        if managedCount > 0 {
            if !fileManager.fileExists(atPath: managedHelperURL.path) {
                errors.append(.binaryNotFound)
            } else if !fileManager.isExecutableFile(atPath: managedHelperURL.path) {
                errors.append(.binaryNotExecutable(path: managedHelperURL.path))
            }
        }
        let state: ProfileHookStatus.State
        if let problem = configProblem(for: target, fileManager: fileManager) {
            state = problem.state
        } else if vibe > 0, managedCount < events.count {
            state = .blockedByOtherIsland(vibeEntries: vibe)
        } else if old > 0 {
            state = .oldHelper(entries: old)
        } else if !errors.isEmpty {
            state = .broken(errors)
        } else if managedCount == 0 {
            state = .notInstalled
        } else if managedCount < events.count {
            state = .partial(installed: managedCount, expected: events.count)
        } else if codexFeature == false {
            state = .codexFeatureOff
        } else if !untrusted.isEmpty {
            state = .codexNeedsTrust(untrustedEvents: untrusted)
        } else {
            state = .installed
        }
        return ProfileHookStatus(target: target, state: state, intent: intent, managedEventCount: managedCount,
                                 expectedEventCount: events.count, vibeEntryCount: vibe, otherHookCount: other,
                                 oldEntryCount: old, helperMatchesBundle: helperMatches, codexFeatureEnabled: codexFeature,
                                 checkedAt: now)
    }

    /// Which commands are Juice's in this profile (its own helper, exactly), and, with `oldIsOurs`, which are Juice's
    /// older ones on Open Island's helper for the same agent (P903). Without it, Open Island's helper's entries are
    /// nobody's to move or remove (P932).
    static func owners(for target: ProfileHookTarget, managedHelperURL: URL, oldIsOurs: Bool) -> HookFileEdits.Owners {
        let helper = managedHelperURL.path
        let source: String? = target.provider == .claude ? "claude" : nil
        return HookFileEdits.Owners(isOurs: { AgentHookTable.isOurs($0, source: source, helperPath: helper) },
                                    isOld: { oldIsOurs && AgentHookTable.isOldIsland($0, source: source) })
    }

    /// Whether the entries on Open Island's helper in this profile are the ones Juice wrote before its own helper (P932).
    /// Before, Juice's command was Open Island's helper itself, so the two cannot be told apart by the command: they are
    /// Juice's where Juice's intent says it installed this profile's hooks and none of its own helper's are there yet.
    /// A Mac where only Open Island set up a profile, or where Juice was connected beside Open Island since, keeps them as
    /// Open Island's.
    static func oldIsOurs(intent: ProfileHookIntent, managedCount: Int) -> Bool {
        intent == .installed && managedCount == 0
    }

    /// How many of Juice's older entries (on Open Island's helper) this profile's file holds; 0 when they are Open
    /// Island's own (P932). Reads that one file only.
    static func oldEntryCount(for target: ProfileHookTarget, intent: ProfileHookIntent, managedHelperURL: URL) -> Int {
        guard intent == .installed else { return 0 }
        let url = URL(fileURLWithPath: target.folder, isDirectory: true).appendingPathComponent(hookFileName(for: target.provider))
        let owners = owners(for: target, managedHelperURL: managedHelperURL, oldIsOurs: true)
        let commands = hookGroups(in: url).values.flatMap { $0.flatMap { $0 } }
        guard !commands.contains(where: owners.isOurs) else { return 0 }
        return commands.filter(owners.isOld).count
    }

    /// The file that holds the hooks: settings.json (Claude) or hooks.json (Codex).
    static func hookFileName(for provider: Provider) -> String {
        provider == .claude ? "settings.json" : "hooks.json"
    }

    /// The command Juice's hooks run in this profile: its own helper, `--source claude` for Claude and none for Codex, as
    /// upstream's installers shape them (P290). A manifest Open Island's installer left is never read: it may name Open
    /// Island's command (P901).
    static func managedCommand(for target: ProfileHookTarget, managedHelperURL: URL, fileManager: FileManager = .default) -> String {
        let quoted = AgentHookTable.shellQuote(managedHelperURL.path)
        return target.provider == .claude ? "\(quoted) --source claude" : quoted
    }

    /// One drift reading of this profile's settings.json or hooks.json (`HookDrift.read`). A missing folder has
    /// nothing to compare and gives nil. A file that exists but cannot be read counts as being edited, like an empty
    /// or unparsable one: no alert, and Setup shows `unreadable` from the inspector instead (P23, P51). A file whose
    /// hooks still call Open Island's helper gives nil too: those hooks work, and its row says Move, not Repair (P903).
    static func driftReading(for target: ProfileHookTarget, managedHelperURL: URL, oldIsOurs: Bool,
                             fileManager: FileManager = .default) -> HookDriftReading? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.folder, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let url = URL(fileURLWithPath: target.folder, isDirectory: true).appendingPathComponent(hookFileName(for: target.provider))
        var data: Data?
        if fileManager.fileExists(atPath: url.path) {
            guard let contents = try? Data(contentsOf: url) else { return .beingEdited }
            data = contents
        }
        let owners = owners(for: target, managedHelperURL: managedHelperURL, oldIsOurs: oldIsOurs)
        if hookGroups(in: url).values.contains(where: { $0.contains { $0.contains(where: owners.isOld) } }) { return nil }
        return HookDrift.read(fileData: data,
                              command: managedCommand(for: target, managedHelperURL: managedHelperURL, fileManager: fileManager),
                              expected: ExpectedHookEntries.entries(for: target.provider))
    }

    /// Why the installers must not touch a config file of this profile.
    enum ConfigProblem: Equatable {
        case linked(String)
        case comments(String)
        case unreadable(String)

        var state: ProfileHookStatus.State {
            switch self {
            case .linked(let file): .linkedConfig(file: file)
            case .comments(let file): .hasComments(file: file)
            case .unreadable(let file): .unreadable(file: file)
            }
        }

        var error: ProfileHookError {
            switch self {
            case .linked(let file): .linkedConfig(file: file)
            case .comments(let file): .hasComments(file: file)
            case .unreadable(let file): .invalidConfig(file: file)
            }
        }
    }

    /// The config files upstream's installers write in a profile folder.
    static func configFileNames(for provider: Provider) -> [String] {
        provider == .claude ? ["settings.json"] : ["hooks.json", "config.toml"]
    }

    /// The first config file of this profile that is a symbolic link (P24), has JSON comments (P25), or exists but
    /// cannot be read or decoded (JSON for settings.json and hooks.json, strict UTF-8 for config.toml; P23).
    /// Upstream reads these with `try?` and would treat such a file as empty. A missing file is fine: install creates it.
    static func configProblem(for target: ProfileHookTarget, fileManager: FileManager = .default) -> ConfigProblem? {
        let folderURL = URL(fileURLWithPath: target.folder, isDirectory: true)
        for name in configFileNames(for: target.provider) {
            let url = folderURL.appendingPathComponent(name)
            // attributesOfItem does not follow a final symbolic link, so a link is seen as one (even a dangling one).
            guard let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { continue }
            if type == .typeSymbolicLink { return .linked(name) }
            guard let data = try? Data(contentsOf: url) else { return .unreadable(name) }
            if name.hasSuffix(".json") {
                if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { continue }
                if let text = String(data: data, encoding: .utf8), let stripped = JSONComments.stripped(text),
                   (try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) is [String: Any] {
                    return .comments(name)
                }
                return .unreadable(name)
            } else {
                guard String(data: data, encoding: .utf8) != nil else { return .unreadable(name) }
            }
        }
        return nil
    }

    /// `event → [group → [command]]` from a Claude settings.json or a Codex hooks.json (same shape).
    static func hookGroups(in fileURL: URL) -> [String: [[String]]] {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [:] }
        var result: [String: [[String]]] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            result[event] = groups.map { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
            }
        }
        return result
    }

    /// Whether the two files hold the same bytes. The helpers are about 5 MB each and every profile's status compares
    /// them, 17 profiles at launch, on wake and on every profile change: about 180 MB read each time. Files of
    /// different sizes differ without a read, and a comparison holds until either file's size, dates or inode change
    /// (`FileComparisons`, P87).
    static func filesMatch(_ lhs: URL, _ rhs: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: lhs.path), fileManager.fileExists(atPath: rhs.path) else { return false }
        return FileComparisons.sameBytes(lhs, rhs)
    }
}

/// Byte comparisons of two files, kept by each file's identity: its path, size, inode and change and modification
/// times. Writing a file changes its times, and an install or a sync renames a new file over it, a new inode.
enum FileComparisons {
    private struct Identity: Hashable {
        var path: String
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modified: timespec
        var changed: timespec

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            path = url.path
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
            changed = info.st_ctimespec
        }

        static func == (lhs: Identity, rhs: Identity) -> Bool {
            lhs.path == rhs.path && lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(path)
            hasher.combine(inode)
            hasher.combine(size)
            hasher.combine(modified.tv_nsec)
            hasher.combine(changed.tv_nsec)
        }
    }

    private struct Pair: Hashable {
        var lhs: Identity
        var rhs: Identity
    }

    private struct Book {
        var results: [Pair: Bool] = [:]
        /// Comparisons that read both files, by the first file's path.
        var byteComparisons: [String: Int] = [:]
    }

    private static let book = Mutex(Book())
    /// A few pairs are ever compared (the managed helper and this bundle's); more, and the oldest are let go.
    private static let limit = 16

    /// How many comparisons with `lhs` first read both files (tests).
    static func byteComparisons(of lhs: URL) -> Int { book.withLock { $0.byteComparisons[lhs.path, default: 0] } }

    static func sameBytes(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = Identity(lhs), let right = Identity(rhs) else { return false }
        if left.size != right.size { return false }
        let pair = Pair(lhs: left, rhs: right)
        if let known = book.withLock({ $0.results[pair] }) { return known }
        guard let leftBytes = try? Data(contentsOf: lhs), let rightBytes = try? Data(contentsOf: rhs) else { return false }
        let same = leftBytes == rightBytes
        book.withLock {
            if $0.results.count >= limit { $0.results.removeAll() }
            $0.results[pair] = same
            $0.byteComparisons[lhs.path, default: 0] += 1
        }
        return same
    }
}

/// Finds `//` and `/* */` comments outside JSON strings.
enum JSONComments {
    /// The text with its comments removed, or nil when it has none.
    static func stripped(_ text: String) -> String? {
        var output = ""
        var found = false
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                index = next
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index = next
            } else if character == "/", next < text.endIndex, text[next] == "/" {
                found = true
                index = text[next...].firstIndex(of: "\n") ?? text.endIndex
            } else if character == "/", next < text.endIndex, text[next] == "*" {
                found = true
                let body = text.index(after: next)
                index = text[body...].range(of: "*/")?.upperBound ?? text.endIndex
            } else {
                output.append(character)
                index = next
            }
        }
        return found ? output : nil
    }
}
