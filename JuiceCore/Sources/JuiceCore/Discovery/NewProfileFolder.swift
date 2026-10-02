import Foundation

/// A profile folder the owner adds from Settings › Accounts, by a short name: `~/.claude-<name>`, which the Claude CLI
/// uses through `CLAUDE_CONFIG_DIR`, or `~/.codex-<name>`, which the Codex CLI uses through `CODEX_HOME` (both set by
/// `CLIEnvironment.make` for any folder but the default). Discovery finds such a folder once its CLI has signed in there
/// (Claude writes the folder's `.claude.json`, Codex its login file), and the account list holds it until then.
///
/// The name is checked before anything is made. It is trimmed and lower-cased, and may hold only `a-z`, `0-9`, `-` and
/// `_`, starting with a letter or a digit, at most `maxLength` characters, so it can never leave the home folder or
/// name a path of its own. A Claude name discovery would pass over (`ProfileDiscovery.ignoredClaudePrefixes`) is
/// refused, and so is a name whose folder, file or link exists, compared without case as the disk compares names.
///
/// `create` makes only the empty folder, readable by its owner alone, and fails when anything took the name in between.
/// Nothing is written inside it: each CLI's own sign-in writes what it keeps there. Codex needs no `config.toml` to sign
/// in or to be read, and without one its hooks stay off (their `[features]` switch is off by default) until Setup's
/// Install, on a click, writes the hooks and that switch.
public enum NewProfileFolder {
    public enum Problem: Error, Sendable, Equatable {
        /// Nothing typed yet.
        case empty
        /// A character outside `a-z 0-9 - _`, a first character that is not a letter or a digit, or too long.
        case invalid
        /// A Claude name discovery skips (the private app's `.claude-db…` and `.claude-samplebench…`).
        case reserved
        /// A folder, file or link already has the name, or the account list already has the folder.
        case exists
        /// The folder could not be made (a read-only home, say).
        case failed
    }

    public static let maxLength = 32

    /// The name as it is used: trimmed and lower-cased.
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `<home>/.claude-<name>` or `<home>/.codex-<name>`, for a normalized name.
    public static func folder(for name: String, provider: Provider, home: String) -> String {
        home + "/" + folderName(for: name, provider: provider)
    }

    static func folderName(for name: String, provider: Provider) -> String {
        provider.defaultFolderName + "-" + name
    }

    /// Whether the normalized name is well formed and not reserved (in `flavor`); the disk is not looked at.
    public static func validate(_ name: String, provider: Provider, flavor: AppFlavor = .current) -> Problem? {
        guard !name.isEmpty else { return .empty }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
        guard allowed, name.count <= maxLength, let first = name.unicodeScalars.first,
              ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return .invalid }
        if provider == .claude,
           ProfileDiscovery.ignoredClaudePrefixes(for: flavor).contains(where: folderName(for: name, provider: provider).hasPrefix) {
            return .reserved
        }
        return nil
    }

    /// The name "+" would type to name `folder` again: the part after `.claude-` or `.codex-` of a folder right in
    /// `home`, lower-cased, when `validate` accepts it; nil for the provider's own folder (`~/.claude`, `~/.codex`) and
    /// for any folder no name makes (`~/.claude-my.work`, `~/.codex-_x`, one elsewhere). The disk is not looked at.
    public static func name(of folder: String, provider: Provider, home: String) -> String? {
        let url = URL(fileURLWithPath: folder).standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: home).standardizedFileURL.path
        else { return nil }
        let last = url.lastPathComponent.lowercased(), prefix = provider.defaultFolderName + "-"
        guard last.hasPrefix(prefix) else { return nil }
        let name = String(last.dropFirst(prefix.count))
        return validate(name, provider: provider) == nil ? name : nil
    }

    /// The folder a name makes in `home`, or why it cannot be used. `known`: the folders the account list already has
    /// (a folder listed there but gone from the disk still takes its name).
    public static func check(_ name: String, provider: Provider, home: String, known: [String] = [],
                             fileManager: FileManager = .default, flavor: AppFlavor = .current) -> Result<String, Problem> {
        let name = normalized(name)
        if let problem = validate(name, provider: provider, flavor: flavor) { return .failure(problem) }
        let folder = folder(for: name, provider: provider, home: home)
        // Defence in depth: the characters above cannot climb out of the home folder, and this proves it.
        let parent = URL(fileURLWithPath: folder).standardizedFileURL.deletingLastPathComponent().standardizedFileURL.path
        guard parent == URL(fileURLWithPath: home).standardizedFileURL.path else { return .failure(.invalid) }
        if isTaken(folder, home: home, known: known, fileManager: fileManager) { return .failure(.exists) }
        return .success(folder)
    }

    /// Anything at the path, a dangling link included (`attributesOfItem` does not follow links), a name in the home
    /// folder that differs only in case, or a folder the account list has.
    static func isTaken(_ folder: String, home: String, known: [String], fileManager: FileManager) -> Bool {
        if (try? fileManager.attributesOfItem(atPath: folder)) != nil { return true }
        let wanted = (folder as NSString).lastPathComponent.lowercased()
        if let names = try? fileManager.contentsOfDirectory(atPath: home), names.contains(where: { $0.lowercased() == wanted }) {
            return true
        }
        let target = folder.lowercased()
        return known.contains { $0.lowercased() == target }
    }

    /// Makes the empty folder, owner-only (0700), and nothing inside it. It never makes a missing home folder, and it
    /// throws `Problem.exists` when anything is at the path, so a name taken since the check is never used twice, and
    /// `Problem.failed` otherwise.
    public static func create(_ folder: String, fileManager: FileManager = .default) throws {
        let home = (folder as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue else { throw Problem.failed }
        do {
            try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw (try? fileManager.attributesOfItem(atPath: folder)) != nil ? Problem.exists : Problem.failed
        }
    }
}
