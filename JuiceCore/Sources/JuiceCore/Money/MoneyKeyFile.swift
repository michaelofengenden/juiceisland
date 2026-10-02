import Darwin
import Foundation

/// Where a money key file may not be (Juice spec §7 amendment 10): the home folder the `~` expands to, and the
/// monitored accounts' folders.
public struct MoneyKeyFileGuard: Sendable, Equatable {
    public var home: String
    public var accountFolders: [String]

    public init(home: String = NSHomeDirectory(), accountFolders: [String] = []) {
        self.home = home
        self.accountFolders = accountFolders
    }
}

/// Why Settings › Money did not save or remove a key. Its message is the pane's status word; it never holds the key.
public enum MoneyKeyEditError: Error, Sendable, Equatable {
    /// Empty, more than one line, a space, or a character outside printable ASCII.
    case notAKey
    /// Anthropic's cost report takes an Admin API key only.
    case notAnAdminKey
    /// A Claude sign-in token, or one shaped like ChatGPT's or Codex's (a JWT): never written anywhere.
    case signInToken
    /// An Anthropic key typed for another source.
    case anthropicKey
    /// The key file's place is refused (a Claude or Codex folder, a monitored account's folder, …).
    case refused(String)
    /// The file system said no: `make the folder`, `save the key file`, `delete the key file`.
    case failed(String)
    /// Another key of the same source is this key already.
    case sameKey

    public var message: String {
        switch self {
        case .notAKey: "Not a key: one line, no spaces"
        case .notAnAdminKey: "Needs an Admin key (sk-ant-admin…)"
        case .signInToken: "A sign-in token is never saved"
        case .anthropicKey: "An Anthropic key is only for Anthropic"
        case .refused(let why): "Refused: \(why)"
        case .failed(let what): "Could not \(what)"
        case .sameKey: "This key is already set"
        }
    }
}

/// What Remove does for a source's key file.
public enum MoneyKeyRemoval: Sendable, Equatable {
    /// The file is one of the places the default lookup tries (the file Add key writes, or one made there by hand): it
    /// is deleted.
    case delete(String)
    /// A file picked elsewhere before keys could be added in Settings: the source stops using it, and the file stays.
    case forget(String)

    public var path: String {
        switch self {
        case .delete(let path), .forget(let path): path
        }
    }
}

/// A money key file: its path comes from Settings › Money (or the default lookup under `~/.config/<provider>/`), and
/// its key is read at request time, never stored, logged or shown (Juice spec §6, §8.1). Settings › Money's Add key
/// writes the key the owner types into the source's own file once (`write`), and Remove deletes that file (`delete`).
///
/// Before anything is opened the path is expanded, checked, resolved through symbolic links and checked again. A file
/// named `auth.json`, `.credentials.json`, `.claude.json` or `credentials.env`, anything inside a `.claude*` or
/// `.codex*` folder, a monitored account's folder, `~/.config/harborlog/` or the Keychain folder is refused, so no CLI
/// credential file is ever opened (Juice spec §8.3; guardrail check 7 lets this file name them, to refuse them).
public enum MoneyKeyFile {
    /// Lower-case file names that are never opened.
    static let refusedNames: Set<String> = ["auth.json", ".credentials.json", ".claude.json", "credentials.env"]
    /// A key is one short line; a bigger file is not a key file.
    static let maximumSize = 4_096

    /// The path picked in Settings, or else the first key file found under `~/.config/<provider>/`, or nil (the source
    /// is not connected and stays hidden). The default lookup only checks that a file exists; it opens nothing.
    public static func path(for account: MoneyAccount, picked: String?, guard fence: MoneyKeyFileGuard) -> String? {
        if let picked, !picked.trimmingCharacters(in: .whitespaces).isEmpty { return picked }
        return account.lookupPaths.first { FileManager.default.fileExists(atPath: expand($0, home: fence.home)) }
    }

    /// The source's further accounts that have a key file (`~/.config/openrouter/key-2`, …), in slot order. Only checks
    /// that files exist; it opens nothing.
    public static func furtherAccounts(of source: MoneySource, guard fence: MoneyKeyFileGuard) -> [MoneyAccount] {
        (2...MoneyAccount.maximumSlots).map { MoneyAccount(source, slot: $0) }.filter { account in
            FileManager.default.fileExists(atPath: expand(account.defaultKeyPath, home: fence.home))
        }
    }

    /// The last path component, for Settings (the key file picker shows only the file name).
    public static func displayName(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// Why `path` may not be opened, or nil. Checks the path as given and, when it exists, the file it resolves to.
    public static func refusal(_ path: String, guard fence: MoneyKeyFileGuard) -> String? {
        let expanded = expand(path, home: fence.home)
        if let why = refusal(literal: expanded, fence: fence) { return why }
        guard let resolved = realPath(expanded) else { return nil }
        return refusal(literal: resolved, fence: fence)
    }

    /// Reads the key for one request. Refused paths are never opened; the file must be a regular file with a single
    /// link, of at most 4 KiB, holding one line with no spaces.
    public static func read(_ path: String, guard fence: MoneyKeyFileGuard) throws(MoneyReadError) -> MoneyKey {
        let expanded = expand(path, home: fence.home)
        if let why = refusal(literal: expanded, fence: fence) { throw .keyFileRefused(why) }
        guard let resolved = realPath(expanded) else { throw .keyFileUnreadable("missing") }
        if let why = refusal(literal: resolved, fence: fence) { throw .keyFileRefused(why) }
        let descriptor = Darwin.open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw .keyFileUnreadable("not readable") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw .keyFileUnreadable("not a file") }
        // A hard link keeps no trace of the file's other names, so a key file with a harmless name could be a CLI
        // credential file's second name: a file with more than one link is refused before a byte is read. So is a
        // file whose opened path (a folder on the way swapped for a link after the check) lands somewhere refused.
        guard info.st_nlink == 1 else { throw .keyFileRefused("a hard link") }
        guard let opened = openedPath(descriptor) else { throw .keyFileUnreadable("not readable") }
        if let why = refusal(literal: opened, fence: fence) { throw .keyFileRefused(why) }
        guard info.st_size <= maximumSize else { throw .keyFileUnreadable("too large") }
        var buffer = [UInt8](repeating: 0, count: maximumSize + 1)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, maximumSize + 1) }
        guard count >= 0, count <= maximumSize else { throw .keyFileUnreadable("not readable") }
        defer { for index in buffer.indices { buffer[index] = 0 } }
        return try parse(Data(buffer[0..<count]))
    }

    /// One line, trailing newline allowed, printable ASCII with no spaces.
    static func parse(_ data: Data) throws(MoneyReadError) -> MoneyKey {
        guard let text = String(data: data, encoding: .utf8) else { throw .keyNotUsable }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.utf8.count <= 1_024,
              line.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { throw .keyNotUsable }
        return MoneyKey(line)
    }

    // MARK: Adding and removing a key (Settings › Money)

    /// Writes the key the owner typed in Settings › Money as `account`'s own key file, `defaultKeyPath` (a further key
    /// beside the source's own, `key-2`), and returns that path. It is the first place the lookup tries, so the reads
    /// use it at once; a key file found in a later place (made by hand, perhaps another tool's `api_key`) is never
    /// written over, and Remove says when it will be read again (`next`). The text must be one line a source may send
    /// (`parse`, `MoneyHostPolicy.keyRefusal`): a sign-in token, or an Anthropic key for another source, is never
    /// written anywhere. The path is checked as a read checks it, and so are the folder it resolves to and the folder
    /// the kernel opened. A missing `~/.config` or provider folder is made 0700 (a folder that exists keeps its mode).
    /// The key goes into a new file, 0600, under a temporary name in the same folder, which is then renamed over the
    /// old key file: an old key, or a link where it was, is replaced whole, and nothing is ever written through a link
    /// or into another file's second name. The key is not kept. A key already in one of `others` (the source's other
    /// key files) is refused: two accounts reading one key would ask for it twice as often as its floor allows, and a
    /// 429 on one would not pause the other. Each of them is read as a read reads it, compared, and dropped.
    @discardableResult
    public static func write(_ text: String, for account: MoneyAccount, notIn others: [String] = [],
                             guard fence: MoneyKeyFileGuard) throws(MoneyKeyEditError) -> String {
        let key: MoneyKey
        do { key = try parse(Data(text.utf8)) } catch { throw .notAKey }
        if let refusal = editRefusal(key, for: account.source) { throw refusal }
        if others.contains(where: { (try? read($0, guard: fence))?.value == key.value }) { throw .sameKey }
        let path = account.defaultKeyPath
        guard let folder = try keyFolder(path, creating: true, guard: fence) else { throw .failed("make the folder") }
        defer { Darwin.close(folder.descriptor) }
        let temporary = ".\(folder.name).\(UUID().uuidString).tmp"
        let file = openat(folder.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw .failed("save the key file") }
        var bytes = Array(key.value.utf8) + [0x0A]
        defer { for index in bytes.indices { bytes[index] = 0 } }
        var written = 0
        var saved = fchmod(file, 0o600) == 0
        while saved, written < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(file, $0.baseAddress! + written, bytes.count - written) }
            if count > 0 { written += count } else if count < 0, errno == EINTR { continue } else { saved = false }
        }
        saved = saved && fsync(file) == 0
        Darwin.close(file)
        guard saved, renameat(folder.descriptor, temporary, folder.descriptor, folder.name) == 0 else {
            unlinkat(folder.descriptor, temporary, 0)
            throw .failed("save the key file")
        }
        fsync(folder.descriptor)
        return path
    }

    /// What Remove does for `source`: nil when it has no key file.
    public static func removal(for account: MoneyAccount, picked: String?, guard fence: MoneyKeyFileGuard) -> MoneyKeyRemoval? {
        guard let path = path(for: account, picked: picked, guard: fence) else { return nil }
        return isLookupPlace(path, for: account, home: fence.home) ? .delete(path) : .forget(path)
    }

    /// The key file the reads use once `path` is deleted or no longer used: the first other place the lookup finds, or
    /// nil (the source then has no key). Only checks that files exist; it opens nothing.
    public static func next(after path: String, for account: MoneyAccount, guard fence: MoneyKeyFileGuard) -> String? {
        let gone = expand(path, home: fence.home)
        return account.lookupPaths.first { place in
            let expanded = expand(place, home: fence.home)
            return expanded != gone && FileManager.default.fileExists(atPath: expanded)
        }
    }

    /// Deletes `source`'s key file at `path`, which must be one of the places the lookup tries, and nothing else. The path
    /// is checked as for a write; a link there is removed, never the file it points to. A file already gone is no error.
    public static func delete(_ path: String, for account: MoneyAccount, guard fence: MoneyKeyFileGuard) throws(MoneyKeyEditError) {
        guard isLookupPlace(path, for: account, home: fence.home) else { throw .refused("not this source's key file") }
        guard let folder = try keyFolder(path, creating: false, guard: fence) else { return }
        defer { Darwin.close(folder.descriptor) }
        var info = stat()
        guard fstatat(folder.descriptor, folder.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw .failed("delete the key file")
        }
        guard (info.st_mode & S_IFMT) != S_IFDIR else { throw .failed("delete the key file") }
        guard unlinkat(folder.descriptor, folder.name, 0) == 0 || errno == ENOENT else { throw .failed("delete the key file") }
    }

    /// `path` is one of the places `account`'s default lookup tries (`MoneyAccount.lookupPaths`).
    static func isLookupPlace(_ path: String, for account: MoneyAccount, home: String) -> Bool {
        let expanded = expand(path, home: home)
        return account.lookupPaths.contains { expand($0, home: home) == expanded }
    }

    /// Why a typed key may not be saved for `source`: exactly what `MoneyHostPolicy.keyRefusal` refuses, told apart.
    static func editRefusal(_ key: MoneyKey, for source: MoneySource) -> MoneyKeyEditError? {
        guard MoneyHostPolicy.keyRefusal(key, for: source) != nil else { return nil }
        if MoneyHostPolicy.claudeTokenPrefixes.contains(where: { key.value.contains($0) })
            || MoneyHostPolicy.carriesSignInToken(key.value) { return .signInToken }
        return source == .anthropic ? .notAnAdminKey : .anthropicKey
    }

    /// Opens the folder that holds `path`'s key file and returns it with the file's name, after checking the path, the
    /// folder it resolves to and the folder the kernel opened. With `creating`, missing folders are made first; without,
    /// a missing folder is nil (there is no file to delete).
    private static func keyFolder(_ path: String, creating: Bool, guard fence: MoneyKeyFileGuard) throws(MoneyKeyEditError)
        -> (descriptor: Int32, name: String)? {
        let expanded = expand(path, home: fence.home)
        if let why = refusal(literal: expanded, fence: fence) { throw .refused(why) }
        let folder = (expanded as NSString).deletingLastPathComponent
        let name = (expanded as NSString).lastPathComponent
        if creating { try makeFolders(folder) }
        guard let resolved = realPath(folder) else {
            if creating { throw .failed("make the folder") }
            return nil
        }
        if let why = refusal(literal: resolved + "/" + name, fence: fence) { throw .refused(why) }
        let descriptor = Darwin.open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .failed(creating ? "save the key file" : "delete the key file") }
        guard let opened = openedPath(descriptor) else {
            Darwin.close(descriptor)
            throw .failed(creating ? "save the key file" : "delete the key file")
        }
        if let why = refusal(literal: opened + "/" + name, fence: fence) {
            Darwin.close(descriptor)
            throw .refused(why)
        }
        return (descriptor, name)
    }

    /// Makes the missing folders down to `folder` (`~/.config/<provider>`), 0700: at most those two, so a missing home
    /// folder is never made. A folder that exists is left as it is.
    private static func makeFolders(_ folder: String) throws(MoneyKeyEditError) {
        var missing: [String] = []
        var current = folder
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            missing.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        guard missing.count <= 2 else { throw .failed("make the folder") }
        for path in missing.reversed() {
            if Darwin.mkdir(path, 0o700) == 0 {
                chmod(path, 0o700)
            } else if errno != EEXIST {
                throw .failed("make the folder")
            }
        }
    }

    // MARK: Paths

    static func expand(_ path: String, home: String) -> String {
        var expanded = path
        if expanded == "~" { expanded = home } else if expanded.hasPrefix("~/") { expanded = home + expanded.dropFirst(1) }
        if !expanded.hasPrefix("/") { expanded = home + "/" + expanded }
        return (expanded as NSString).standardizingPath
    }

    /// The path the kernel opened `descriptor` at (`F_GETPATH`).
    static func openedPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    /// The canonical path with every symbolic link resolved, or nil when it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func refusal(literal path: String, fence: MoneyKeyFileGuard) -> String? {
        let components = path.split(separator: "/").map { $0.lowercased() }
        if let name = components.last, refusedNames.contains(name) { return "a CLI credential file" }
        if components.contains(where: { $0.hasPrefix(".claude") || $0.hasPrefix(".codex") }) {
            return "inside a Claude or Codex folder"
        }
        for index in components.indices.dropLast() where components[index] == ".config" && components[index + 1] == "harborlog" {
            return "inside harborlog's folder"
        }
        for index in components.indices.dropLast() where components[index] == "library" && components[index + 1] == "keychains" {
            return "inside the Keychain folder"
        }
        let lowerPath = path.lowercased()
        for folder in fence.accountFolders {
            let expanded = expand(folder, home: fence.home)
            for candidate in Set([expanded, realPath(expanded) ?? expanded]) {
                let lowerFolder = candidate.lowercased()
                if lowerPath == lowerFolder || lowerPath.hasPrefix(lowerFolder.hasSuffix("/") ? lowerFolder : lowerFolder + "/") {
                    return "inside a monitored account's folder"
                }
            }
        }
        return nil
    }
}
