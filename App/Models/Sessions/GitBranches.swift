import Foundation

/// The branch a session's folder has checked out (P434 to P436), for Detailed rows and a Clean row's peek. A repo's own
/// default branch (origin's HEAD, else `main` or `master`) says nothing and is left off, as a host every row shares is:
/// the branch is worth its room when it tells a session apart (a feature branch, a worktree). Read from the folder's
/// `.git` (a linked worktree's or a submodule's `gitdir:` file followed), off the main thread, once when a session is
/// first seen and again when it starts or ends a turn, so a branch switched between turns shows at the next one; a
/// read that finds nothing new redraws nothing, and nothing reads on a timer. Only a few small files are opened (`HEAD`,
/// the `.git` file, `commondir`, origin's `HEAD`), each read to a bound, never a ref's history, the index or an object.
/// Places macOS guards with a privacy prompt (Desktop, Documents, Downloads, Library with iCloud Drive and the cloud
/// folders, Pictures, Movies, Music, Public; other volumes) are never read, even through a symbolic link (`GitHead`):
/// there, Claude's own worktree name (upstream's `worktreeBranch`, from the folder's path) is all a row has.
@MainActor
final class GitBranches {
    enum Source: Sendable {
        /// The demo's and the renders' folders, with the reads they stand for; nothing is read.
        case fixed([String: GitHead.Read])
        /// Each folder's `.git`, read by `read` off the main thread (the live app: `GitHead.read`).
        case live(read: @Sendable (String) -> GitHead.Read)
    }

    private let source: Source
    /// The last read of each folder.
    private var reads: [String: GitHead.Read] = [:]
    /// Folders whose read runs now, and those asked for again meanwhile.
    private var reading: Set<String> = []
    private var again: Set<String> = []
    /// Each session's moment (at work or done) its folder was last read for: a new one reads again.
    private var moments: [String: Moment] = [:]
    /// Reads started (tests).
    private(set) var readCount = 0
    /// Called when a read changed what a folder shows, so the rows are mapped again.
    var changed: (@MainActor () -> Void)?

    /// A turn at work (needs you or running) or done: a session moving between them reads its folder again.
    enum Moment: Equatable, Sendable { case working, done }

    init(_ source: Source) {
        self.source = source
    }

    /// The live app's: every folder read by `GitHead.read`.
    static func live() -> GitBranches { GitBranches(.live(read: { GitHead.read(folder: $0) })) }

    /// The branch a row shows for `session`, in `folder`, at `moment`: the folder's last read, unless it is the repo's
    /// default or its HEAD is detached (nothing then); with no read of its own (none yet, or none possible), Claude's
    /// worktree name (`metadata`), unless it is `main` or `master`. Asks for a read when the session is new or its
    /// moment changed; the read lands later and maps the rows again only when what it shows changed.
    func branch(folder: String?, session: String, moment: Moment, metadata: String?) -> String? {
        var read: GitHead.Read?
        if let folder, !folder.isEmpty {
            switch source {
            case let .fixed(reads): read = reads[folder]
            case .live:
                if moments[session] != moment {
                    moments[session] = moment
                    request(folder)
                }
                read = reads[folder]
            }
        }
        switch read {
        case let .branch(name, isDefault)?: return isDefault ? nil : GitHead.shown(name)
        case .detached?: return nil
        case .none?, nil:
            guard let metadata = metadata.flatMap(GitHead.shown), !GitHead.usualDefaults.contains(metadata) else { return nil }
            return metadata
        }
    }

    /// Forgets the sessions no longer listed (their folders' reads stay: another session may be in the same folder).
    func keep(sessions: Set<String>) {
        guard moments.count > sessions.count else { return }
        moments = moments.filter { sessions.contains($0.key) }
    }

    private func request(_ folder: String) {
        guard case let .live(read) = source else { return }
        guard reading.insert(folder).inserted else {
            again.insert(folder)
            return
        }
        readCount += 1
        Task.detached(priority: .utility) { [weak self] in
            let result = read(folder)
            await self?.landed(folder, result)
        }
    }

    private func landed(_ folder: String, _ result: GitHead.Read) {
        reading.remove(folder)
        let before = reads[folder]
        reads[folder] = result
        if again.remove(folder) != nil { request(folder) }
        if before != result { changed?() }
    }
}

/// What a folder's `.git` says, read to a bound and only where macOS asks no permission for it (P435). Pure file reads:
/// tests point it at folders of their own.
enum GitHead {
    enum Read: Equatable, Sendable {
        /// `HEAD` names a branch; `isDefault`: it is the repo's default (origin's `HEAD`, else `main` or `master`).
        case branch(String, isDefault: Bool)
        /// `HEAD` holds a commit (a rebase, a bisect, a checkout of a tag).
        case detached
        /// No repository, a guarded place, or a file that is not what git writes.
        case none
    }

    static let usualDefaults: Set<String> = ["main", "master"]
    /// The most a file is read: `HEAD` and origin's `HEAD` are one line, a `.git` file and `commondir` a path.
    static let fileBytes = 4_096
    /// A name longer than this is not a branch's.
    static let nameLimit = 255
    /// Folders walked up from a session's folder to find its `.git`, and symbolic links followed on the way.
    static let maxDepth = 64
    static let maxLinks = 16

    /// The folders under the home folder macOS guards with a privacy prompt for an app without access (and Library,
    /// which holds iCloud Drive, the cloud providers' folders and other apps' data); other volumes are guarded too.
    static let guardedHomeFolders = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Public"]

    /// Whether `path` (absolute, standardized) is in a guarded place.
    static func isGuarded(_ path: String, home: String) -> Bool {
        if path == "/Volumes" || path.hasPrefix("/Volumes/") { return true }
        return guardedHomeFolders.contains { folder in
            let guarded = home + "/" + folder
            return path == guarded || path.hasPrefix(guarded + "/")
        }
    }

    /// A branch as a row shows it: nil for anything that is not a plain name (the tag cuts a long one in its middle and
    /// says it whole in its tooltip).
    static func shown(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= nameLimit,
              !name.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }

    /// The branch checked out where `folder` is, as git has it: the nearest `.git` at or above the folder (not above the
    /// home folder when the folder is in it), a directory or a `gitdir:` file, then its `HEAD`.
    static func read(folder: String, home given: String = NSHomeDirectory()) -> Read {
        // The home folder as its links resolve, so a path is judged against it however either is written.
        guard folder.hasPrefix("/"), let home = resolvedLinks(given, home: nil), let start = safePath(folder, home: home) else { return .none }
        var directory = start
        for _ in 0..<maxDepth {
            let entry = directory == "/" ? "/.git" : directory + "/.git"
            if let dotGit = safePath(entry, home: home) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                    let gitDirectory = isDirectory.boolValue ? dotGit : linkedDirectory(file: dotGit, from: directory, home: home)
                    guard let gitDirectory else { return .none }
                    return head(gitDirectory: gitDirectory, home: home)
                }
            } else {
                return .none
            }
            if directory == home || directory == "/" { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return .none
    }

    /// `HEAD` in a git directory: the branch it names and whether that is the repo's default, or detached.
    static func head(gitDirectory: String, home: String) -> Read {
        guard let text = readFile(gitDirectory + "/HEAD", home: home) else { return .none }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else {
            let hex = line.count >= 40 && line.allSatisfy(\.isHexDigit)
            return hex ? .detached : .none
        }
        guard let name = shown(String(line.dropFirst(prefix.count))) else { return .none }
        let common = readFile(gitDirectory + "/commondir", home: home)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : resolved($0, from: gitDirectory) } ?? gitDirectory
        let originPrefix = "ref: refs/remotes/origin/"
        let origin = readFile(common + "/refs/remotes/origin/HEAD", home: home)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.hasPrefix(originPrefix) ? String($0.dropFirst(originPrefix.count)) : nil }
        return .branch(name, isDefault: origin.map { $0 == name } ?? usualDefaults.contains(name))
    }

    /// A `.git` file's `gitdir:` (a linked worktree's, a submodule's), relative to the folder that holds it.
    private static func linkedDirectory(file: String, from folder: String, home: String) -> String? {
        guard let text = readFile(file, home: home) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.lowercased().hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let directory = safePath(resolved(path, from: folder), home: home) else { return nil }
        return directory
    }

    private static func resolved(_ path: String, from folder: String) -> String {
        let absolute = path.hasPrefix("/") ? path : folder + "/" + path
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    /// At most `fileBytes` of a file, as text, when its path (links followed) is not guarded.
    private static func readFile(_ path: String, home: String) -> String? {
        guard let safe = safePath(path, home: home), let handle = FileHandle(forReadingAtPath: safe) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: fileBytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `path` with every symbolic link on the way followed, one component at a time, so no link leads a read into a
    /// guarded place: nil when the path or a link's target is guarded, or the links run too deep. Only entries in
    /// places already known not to be guarded are looked at (`readlink`).
    static func safePath(_ path: String, home: String) -> String? {
        resolvedLinks(path, home: home)
    }

    /// `path` with its links followed; with a `home`, nil as soon as a component or a link's target is guarded there.
    private static func resolvedLinks(_ path: String, home: String?) -> String? {
        var pending = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropFirst().reversed() as [String]
        var resolved = ""
        var links = 0
        while let component = pending.popLast() {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                if resolved == "/" { resolved = "" }
                continue
            }
            let candidate = resolved + "/" + component
            if let home, isGuarded(candidate, home: home) { return nil }
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                links += 1
                guard links <= maxLinks else { return nil }
                let parts = URL(fileURLWithPath: target).standardizedFileURL.pathComponents
                if target.hasPrefix("/") { resolved = "" }
                pending += (target.hasPrefix("/") ? parts.dropFirst() : ArraySlice(target.split(separator: "/").map(String.init))).reversed()
                continue
            }
            resolved = candidate
        }
        let result = resolved.isEmpty ? "/" : resolved
        if let home, isGuarded(result, home: home) { return nil }
        return result
    }
}
