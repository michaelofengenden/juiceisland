import Darwin
import Foundation
import IslandHookNotes
import JuiceCore

/// One table agent's hooks as its row shows them (P915, P936).
public enum AgentHookState: Equatable, Sendable {
    /// The agent's folder is not there: it never ran here, and Connect would have nowhere to write (P22).
    case notFound
    case notConnected
    case connected
    /// Every entry of Juice's is in a file Juice will not edit (a link, comments): put there by hand, taken out by hand.
    case connectedByHand
    /// Some of Juice's entries are there, or one is not as Juice writes it.
    case partial(installed: Int, expected: Int)
    /// Vibe Island's hooks are here and Juice's are not all there: Connect waits until they are gone, as a profile's
    /// Install does (P904, P933). Remove still takes Juice's own.
    case vibeIsland(entries: Int, ours: Int)
    /// Juice's plugin of an older revision.
    case outdated
    /// A file Juice will not edit (a link, comments): the lines to paste, and the file they go in (P938). `replacesHooks`:
    /// the file has a `"hooks"` member already, and the lines are that member as Connect would leave it, to put in its
    /// place (a second `"hooks"` would leave one of the two unread).
    case addByHand(file: String, snippet: String, replacesHooks: Bool)
    /// There, but not JSON, not a plugin of ours, or not readable: nothing is written.
    case unreadable(file: String)
}

/// Connects, reads and removes the table's agents (P915 to P934). `status` only reads; `install` and `remove` run only
/// on a click, back the file up before they write, write by rename, and touch only Juice's own entries (or Juice's own
/// file), so Connect then Remove gives back the bytes that were there.
public struct AgentHookInstaller: Sendable {
    public let home: URL
    /// The helper every entry names (`HookHome.helperURL`).
    public let helperPath: String
    /// The helper this build carries, copied to `helperPath` before entries that name it are written; nil writes none
    /// (tests that bring their own).
    public let bundledHelper: URL?
    /// Juice's own files are named `<stem>.json`, `<stem>.js` (`HookHome.ownFileStem`).
    public let ownFileStem: String
    /// The socket Kilo's, Pi's, Oh My Pi's and Amp's plugins dial.
    public let bridgeSocketPath: String

    public init(home: URL, helperPath: String, bundledHelper: URL?, ownFileStem: String, bridgeSocketPath: String) {
        self.home = home
        self.helperPath = helperPath
        self.bundledHelper = bundledHelper
        self.ownFileStem = ownFileStem
        self.bridgeSocketPath = bridgeSocketPath
    }

    /// The app's: this Mac's home folder, the flavor's helper home, the bundled helper.
    public static func app(bundledHelper: URL) -> AgentHookInstaller {
        let home = HookHome.current
        return AgentHookInstaller(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), helperPath: home.helperURL.path,
                                  bundledHelper: bundledHelper, ownFileStem: HookHome.ownFileStem,
                                  bridgeSocketPath: home.bridgeURL.path)
    }

    public func folderURL(_ spec: AgentHookSpec) -> URL { home.appendingPathComponent(spec.folder, isDirectory: true) }
    public func configURL(_ spec: AgentHookSpec) -> URL { folderURL(spec).appendingPathComponent(spec.file(stem: ownFileStem)) }

    /// `~/.cursor/hooks.json`: the file the agent reads now (`resolved`).
    public func shownPath(_ spec: AgentHookSpec) -> String {
        let spec = resolved(spec)
        return "~/\(spec.folder)/\(spec.file(stem: ownFileStem))"
    }

    // MARK: Where the agent reads (P1126, P1132)

    /// The place the agent reads its hooks from now: the first of the spec and its `elsewhere` whose rule holds, else the
    /// spec itself (Connect then makes its file). Reads only.
    public func resolved(_ spec: AgentHookSpec) -> AgentHookSpec {
        places(spec).first(where: holds) ?? spec
    }

    /// The spec and every other place the agent reads, in the agent's order.
    public func places(_ spec: AgentHookSpec) -> [AgentHookSpec] { [spec] + spec.elsewhere }

    func holds(_ spec: AgentHookSpec) -> Bool {
        let url = configURL(spec)
        var info = stat()
        switch spec.readWhen {
        case .always: return true
        case .folderExists: return Self.isFolder(folderURL(spec))
        case .fileExists: return lstat(url.path, &info) == 0
        case .fileHasHooks:
            guard let data = try? Data(contentsOf: url) else { return false }
            let text = String(decoding: data, as: UTF8.self)
            let readable = (try? JSONSpanDocument(data: data)) != nil ? data : JSONComments.stripped(text).map { Data($0.utf8) }
            guard let readable, let reading = try? HookFileEdits.read(readable, layout: spec.layout, expected: [],
                                                                     owners: HookFileEdits.Owners(isOurs: { _ in false }),
                                                                     key: key(spec)) else { return false }
            return reading.others > 0
        }
    }

    /// Juice's own command for this agent. Juice never wrote a table agent's hooks before its own helper, so an entry
    /// on Open Island's helper here is Open Island's, and Juice leaves it alone (P932).
    func owners(_ spec: AgentHookSpec) -> HookFileEdits.Owners {
        let helper = helperPath, source = spec.kind.rawValue, tail = spec.shellTail
        return HookFileEdits.Owners(isOurs: { AgentHookTable.isOurs($0, source: source, helperPath: helper, tail: tail) })
    }

    /// The member Juice's entries sit under in this agent's file (`"hooks"`, or Antigravity CLI's hook name).
    func key(_ spec: AgentHookSpec) -> String { spec.hooksKey(stem: ownFileStem) }

    // MARK: Reading

    public func status(_ table: AgentHookSpec, fileManager: FileManager = .default) -> AgentHookState {
        let spec = resolved(table)
        guard Self.isFolder(folderURL(spec)) else { return .notFound }
        let url = configURL(spec)
        var info = stat()
        let name = spec.file(stem: ownFileStem)
        let siblingVibe = vibeSiblings(spec)
        guard lstat(url.path, &info) == 0 else {
            return siblingVibe > 0 ? .vibeIsland(entries: siblingVibe, ours: 0) : .notConnected
        }
        let linked = info.st_mode & S_IFMT == S_IFLNK
        // A link is read through, read only, so a file the owner keeps elsewhere still says whether Juice's lines are in
        // it (P938).
        guard linked || info.st_mode & S_IFMT == S_IFREG, let data = try? Data(contentsOf: url) else {
            return linked ? addByHand(spec, name: name, existing: nil) : .unreadable(file: name)
        }
        if spec.layout == .plugin {
            if linked { return addByHand(spec, name: name, existing: nil) }
            switch AgentPlugins.read(data, kind: spec.kind) {
            case let .ours(revision): return revision < AgentPlugins.revision(spec.kind) ? .outdated : .connected
            default: return .unreadable(file: name)
            }
        }
        var byHand = linked
        var readable = data
        let reading: HookFileEdits.Reading
        do {
            reading = try HookFileEdits.read(data, layout: spec.layout, expected: spec.events, owners: owners(spec), key: key(spec))
            // Kimi's TOML read but not written back exactly (no final newline, `hooks = []`): by hand (P1130).
            if spec.layout == .kimiToml, !TOMLHookEdits.canWrite(data) { byHand = true }
        } catch HookFileEdits.Problem.comments {
            // Read without its comments, read only: the file itself is never written (P938).
            byHand = true
            guard let stripped = JSONComments.stripped(String(decoding: data, as: UTF8.self)),
                  let read = try? HookFileEdits.read(Data(stripped.utf8), layout: spec.layout, expected: spec.events, owners: owners(spec),
                                                     key: key(spec))
            else { return addByHand(spec, name: name, existing: nil) }
            readable = Data(stripped.utf8)
            reading = read
        } catch {
            return linked ? addByHand(spec, name: name, existing: nil) : .unreadable(file: name)
        }
        let complete = reading.complete.count == spec.events.count
        if byHand { return complete ? .connectedByHand : addByHand(spec, name: name, existing: readable) }
        let vibe = reading.vibe + siblingVibe
        if vibe > 0, !complete { return .vibeIsland(entries: vibe, ours: reading.ours) }
        if complete { return .connected }
        if reading.ours == 0 { return .notConnected }
        return .partial(installed: reading.complete.count, expected: spec.events.count)
    }

    private func addByHand(_ spec: AgentHookSpec, name: String, existing: Data?) -> AgentHookState {
        // Kimi's tables go at the end of the file, whatever `[[hooks]]` it has; only a `hooks` of another kind is replaced.
        let replaces = spec.layout == .kimiToml ? existing.map(TOMLHookEdits.namesHooksOtherwise) ?? false
            : existing.flatMap { try? HookFileEdits.read($0, layout: spec.layout, expected: spec.events, owners: owners(spec),
                                                         key: key(spec)) }?.hasHooks ?? false
        return .addByHand(file: name, snippet: snippet(spec, existing: existing), replacesHooks: replaces)
    }

    /// Vibe Island's hooks beside Juice's own file: another file of the folder Juice's file sits in (Copilot's hooks
    /// folder, Kilo's plugin folder), the agent loads every one of them, naming Vibe Island's bridge (P933). Reads at most
    /// 1 MB of each, names and text only.
    func vibeSiblings(_ spec: AgentHookSpec) -> Int {
        guard case let .owned(folder, fileExtension) = spec.place else { return 0 }
        let directory = folderURL(spec).appendingPathComponent(folder, isDirectory: true)
        let own = spec.file(stem: ownFileStem).split(separator: "/").last.map(String.init)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.filter { $0 != own && $0.hasSuffix("." + fileExtension) }.filter { name in
            guard let handle = FileHandle(forReadingAtPath: directory.appendingPathComponent(name).path) else { return false }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            return HookFileEdits.isVibeIsland(String(decoding: data, as: UTF8.self))
        }.count
    }

    /// The exact lines to paste by hand into a file Juice will not edit (P938). For a file with no `"hooks"` yet: the
    /// `"hooks"` member Connect would add (and `"version": 1` where the layout has one and the file has none), two spaces
    /// in, to go inside the file's outer braces. For a file that has `"hooks"`: that whole member as Connect would leave
    /// it, the owner's own entries kept, to put in its place. Kilo's whole plugin is Juice's own file and has none.
    public func snippet(_ spec: AgentHookSpec, existing: Data? = nil) -> String {
        guard spec.layout != .plugin else { return "" }
        let command = spec.command(helperPath: helperPath), key = key(spec)
        // Kimi's tables, to paste at the end of `config.toml` (P1130).
        if spec.layout == .kimiToml { return TOMLHookEdits.tables(spec.events, command: command) }
        let document = existing.flatMap { try? JSONSpanDocument(data: $0) }
        // Factory Droid's `hooks.json` is the events object itself: the whole file, as Connect would leave it (P1126).
        if spec.layout == .claudeEvents {
            if let document, !document.root.members.isEmpty,
               let merged = try? HookFileEdits.installing(existing, layout: spec.layout, expected: spec.events, command: command,
                                                         owners: owners(spec)),
               let object = try? JSONSerialization.jsonObject(with: merged),
               let text = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                return Self.personKeys(String(decoding: text, as: UTF8.self))
            }
            return HookFileEdits.hooksObject(spec.events, command: command, layout: spec.layout).render(indent: "  ")
        }
        if let document, document.root.member(key) != nil,
           let merged = try? HookFileEdits.installing(existing, layout: spec.layout, expected: spec.events, command: command,
                                                      owners: owners(spec), key: key),
           let member = Self.hooksMember(merged, key: key) {
            return member
        }
        let hooks = HookFileEdits.hooksObject(spec.events, command: command, layout: spec.layout)
        var lines = [JSONFragment.quoted(key) + ": " + hooks.render(indent: "  ")]
        if HookFileEdits.hasVersion(spec.layout), document?.root.member("version") == nil { lines.insert(#""version": 1,"#, at: 0) }
        return lines.joined(separator: "\n")
    }

    /// `"hooks": { … }` of a file (or Juice's own hook name in Antigravity CLI's), written again with two spaces per
    /// level and plain slashes.
    static func hooksMember(_ data: Data, key: String = "hooks") -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hooks = root[key],
              let text = try? JSONSerialization.data(withJSONObject: [key: hooks],
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        var lines = String(decoding: text, as: UTF8.self).components(separatedBy: "\n")
        guard lines.first == "{", lines.last == "}", lines.count > 2 else { return nil }
        lines.removeFirst()
        lines.removeLast()
        return personKeys(lines.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n"))
    }

    /// Foundation writes `"key" : value`; a person writes `"key": value`. Only a key's colon changes.
    static func personKeys(_ text: String) -> String {
        let key = try? NSRegularExpression(pattern: #"^(\s*"(?:[^"\\]|\\.)*") : "#)
        return text.components(separatedBy: "\n").map { line in
            key?.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1: ") ?? line
        }.joined(separator: "\n")
    }

    // MARK: Writing (a click only)

    public enum Failure: Error, Equatable, Sendable {
        case folderMissing
        /// Vibe Island's hooks are there (P933).
        case vibeIsland
        case addByHand
        case unreadable
        case foreign
        case helper(JuiceHelperInstall.Failure)
        case writeFailed(String)
    }

    /// Connect and Repair: the helper first, then Juice's entries; everyone else's stay. Refused while Vibe Island's
    /// hooks are there, as a profile's Install is (P933).
    public func install(_ table: AgentHookSpec, fileManager: FileManager = .default) throws {
        let spec = resolved(table)
        guard Self.isFolder(folderURL(spec)) else { throw Failure.folderMissing }
        if case .vibeIsland = status(table) { throw Failure.vibeIsland }
        if let bundledHelper, spec.layout != .plugin {
            do {
                try JuiceHelperInstall.ensure(bundled: bundledHelper, managed: URL(fileURLWithPath: helperPath), fileManager: fileManager)
            } catch let failure as JuiceHelperInstall.Failure {
                throw Failure.helper(failure)
            }
        }
        let url = configURL(spec)
        let existing = try readForWrite(url)
        let next: Data
        switch (spec.layout, spec.place) {
        case (.plugin, _):
            if let existing, case .ours = AgentPlugins.read(existing, kind: spec.kind) {} else if existing != nil { throw Failure.foreign }
            next = Data(AgentPlugins.source(spec.kind, socketPath: bridgeSocketPath).utf8)
        case (_, .owned):
            // Juice's own file: written whole, from nothing, unless something else sits under its name.
            if let existing, (try? HookFileEdits.read(existing, layout: spec.layout, expected: spec.events, owners: owners(spec),
                                                      key: key(spec))).map({ $0.others > 0 }) ?? true { throw Failure.foreign }
            next = try edited { try HookFileEdits.installing(nil, layout: spec.layout, expected: spec.events,
                                                             command: spec.command(helperPath: helperPath), owners: owners(spec),
                                                             key: key(spec)) }
        case (_, .shared):
            next = try edited { try HookFileEdits.installing(existing, layout: spec.layout, expected: spec.events,
                                                             command: spec.command(helperPath: helperPath), owners: owners(spec),
                                                             key: key(spec)) }
        }
        try write(next, to: url, backup: isShared(spec))
    }

    /// Takes Juice's entries out (Juice's own file goes whole, and the folder it made for it when nothing else is in
    /// it); never another's.
    public func remove(_ table: AgentHookSpec, fileManager: FileManager = .default) throws {
        var failure: Error?
        let places = places(table)
        for (index, spec) in places.enumerated() {
            do {
                try removeOne(spec, later: Array(places.dropFirst(index + 1)))
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    /// `later`: the places the agent reads after this one, in its order.
    func removeOne(_ spec: AgentHookSpec, later: [AgentHookSpec] = []) throws {
        let url = configURL(spec)
        // A place with nothing of Juice's in it (read through a link, without comments) has nothing to take out.
        if spec.layout != .plugin, let data = try? Data(contentsOf: url) {
            let text = String(decoding: data, as: UTF8.self)
            let readable = (try? HookFileEdits.read(data, layout: spec.layout, expected: [], owners: owners(spec), key: key(spec)))
                ?? JSONComments.stripped(text).flatMap { try? HookFileEdits.read(Data($0.utf8), layout: spec.layout, expected: [],
                                                                                  owners: owners(spec), key: key(spec)) }
            if let readable, readable.ours == 0, readable.old == 0 { return }
        }
        guard let existing = try readForWrite(url) else { return }
        if spec.layout == .plugin {
            guard case .ours = AgentPlugins.read(existing, kind: spec.kind) else { throw Failure.foreign }
            try write(nil, to: url, backup: false)
            return removeOwnFolderIfEmpty(spec)
        }
        let others = try edited { try HookFileEdits.read(existing, layout: spec.layout, expected: spec.events, owners: owners(spec),
                                                         key: key(spec)) }.others
        if !isShared(spec), others == 0 {
            try write(nil, to: url, backup: false)
            return removeOwnFolderIfEmpty(spec)
        }
        // A shared file, or Juice's own with someone else's entries in it: only Juice's go, after a backup.
        var next = try edited { try HookFileEdits.removing(existing, layout: spec.layout, owners: owners(spec), key: key(spec)) }
        // Factory Droid reads the places after `hooks.json` only while it is absent. An emptied `hooks.json` goes only when
        // Connect made it and the place Droid would read next holds no hooks of the owner's; the owner's own, or one
        // that keeps the owner's hooks off, stays as `{}`, so what Droid runs is what it ran before Connect (P1188).
        if spec.layout == .claudeEvents, let left = next, (try? HookFileEdits.parse(left))?.root.members.isEmpty == true,
           !wasThereBeforeConnect(url, spec: spec), !ownersHooks(next: later) {
            next = nil
        }
        try write(next, to: url, backup: true)
    }

    /// The file was the owner's before Connect wrote it: one of its backups (Connect backs a file up before its first
    /// change) holds nothing of Juice's. A file Connect made has none such. Reads only.
    func wasThereBeforeConnect(_ url: URL, spec: AgentHookSpec) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return HookBackups.backups(of: url.lastPathComponent, in: names).contains { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let reading = try? HookFileEdits.read(data, layout: spec.layout, expected: [], owners: owners(spec), key: key(spec))
            else { return false }
            return reading.ours == 0 && reading.old == 0
        }
    }

    /// The place the agent would read next, if this one were gone, holds hooks of someone else's. Reads only.
    func ownersHooks(next later: [AgentHookSpec]) -> Bool {
        guard let place = later.first(where: holds), let data = try? Data(contentsOf: configURL(place)) else { return false }
        let readable = (try? JSONSpanDocument(data: data)) != nil ? data
            : JSONComments.stripped(String(decoding: data, as: UTF8.self)).map { Data($0.utf8) }
        guard let readable, let reading = try? HookFileEdits.read(readable, layout: place.layout, expected: [], owners: owners(place),
                                                                  key: key(place)) else { return false }
        return reading.others > 0
    }

    // MARK: Pieces

    /// The folder Juice's own file sits in (`~/.copilot/hooks`, `~/.config/kilo/plugin`, `~/.pi/agent/extensions`), once
    /// Remove has taken that file and nothing else is there: Connect made it, so it goes too (P916). `rmdir` takes only an
    /// empty folder.
    func removeOwnFolderIfEmpty(_ spec: AgentHookSpec) {
        guard case let .owned(folder, _) = spec.place else { return }
        rmdir(folderURL(spec).appendingPathComponent(folder, isDirectory: true).path)
    }

    func isShared(_ spec: AgentHookSpec) -> Bool {
        if case .shared = spec.place { return true }
        return false
    }

    /// The file's bytes, nil when there is none; refused for a link, a folder or a file that cannot be read.
    func readForWrite(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFLNK { throw Failure.addByHand }
        guard info.st_mode & S_IFMT == S_IFREG, let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return data
    }

    func edited<T>(_ edit: () throws -> T) throws -> T {
        do {
            return try edit()
        } catch HookFileEdits.Problem.comments {
            throw Failure.addByHand
        } catch HookFileEdits.Problem.unwritable {
            throw Failure.addByHand
        } catch {
            throw Failure.unreadable
        }
    }

    func write(_ data: Data?, to url: URL, backup: Bool) throws {
        do {
            try ConfigFileWrite.write(data, to: url, backup: backup)
        } catch ConfigFileWrite.Failure.linked {
            throw Failure.addByHand
        } catch let ConfigFileWrite.Failure.writeFailed(reason) {
            throw Failure.writeFailed(reason)
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
