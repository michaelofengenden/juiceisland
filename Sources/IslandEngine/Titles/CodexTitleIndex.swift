import Foundation

/// One Codex home's thread names: `$CODEX_HOME/session_index.jsonl` (`codex-rs/rollout/src/session_index.rs`), where
/// the TUI's automatic title (at most 36 characters, after the first turn), `/rename`, and a rename in the Codex app or
/// the IDE (the app-server's `thread/name/set`) all land. The rollout never holds the name.
///
///     {"id":"<thread id>","thread_name":"Fix flaky auth test","updated_at":"2026-09-25T10:00:00Z"}
///
/// Append-only and newest-wins; an empty name clears the thread's; `remove_thread_name_entries` rewrites the file
/// through a temporary file and a rename (a new inode). The thread id is the hook's `session_id`, the rollout's
/// `session_meta` id and the row's id.
///
/// Reads are bounded and never on a timer of their own (P201, P205): an id not looked up yet is looked up in the file's
/// last 256 KB, newest first, stopping once every such id is found; after that only the bytes appended since, at most
/// 256 KB of them (more, and the last 256 KB are looked through again); a new inode or a shorter file looks every id up
/// again from the end. Only the ids asked for are kept. The names go to the engine's memory, never further (P200).
struct CodexTitleIndex {
    static let window = 256 * 1024
    static let fileName = "session_index.jsonl"

    let path: String
    /// The file as last read: device and inode, and where reading stopped (after the last complete line).
    private var identity: (device: UInt64, inode: UInt64)?
    private(set) var offset = 0
    /// Names by thread id, for the ids looked up; "" for one looked up whose name was cleared or never set.
    private(set) var names: [String: String] = [:]
    /// Bytes read so far (tests).
    private(set) var bytesRead = 0

    init(home: String) {
        path = (home as NSString).appendingPathComponent(Self.fileName)
    }

    /// The Codex home a rollout belongs to: `<home>/sessions/YYYY/MM/DD/rollout-….jsonl` or
    /// `<home>/archived_sessions/rollout-….jsonl`; nil for any other path.
    static func home(ofRollout path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        if folder.lastPathComponent == "archived_sessions" { return folder.deletingLastPathComponent().path }
        let sessions = folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard sessions.lastPathComponent == "sessions" else { return nil }
        return sessions.deletingLastPathComponent().path
    }

    /// Brings `ids`' names up to date and forgets every other id's. Returns their names, the cleared ones left out.
    mutating func refresh(ids: Set<String>) -> [String: String] {
        names = names.filter { ids.contains($0.key) }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            identity = nil
            offset = 0
            names = Dictionary(uniqueKeysWithValues: ids.map { ($0, "") })
            return [:]
        }
        let now = (device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        let size = Int(info.st_size)
        if let identity, identity == now, size >= offset {
            if size - offset > Self.window {
                lookUp(ids, fileSize: size, keepingUnfound: true)
            } else if size > offset {
                readAppended(ids, to: size)
            }
            let unknown = ids.subtracting(names.keys)
            if !unknown.isEmpty { lookUp(unknown, fileSize: size, keepingUnfound: false) }
        } else {
            // A first read, or the file was rewritten: every id from the end.
            names = [:]
            lookUp(ids, fileSize: size, keepingUnfound: false)
        }
        identity = now
        return names.filter { !$0.value.isEmpty }
    }

    /// Looks `ids` up in the last `window` bytes, newest first. An id not found gets "" unless `keepingUnfound` (the
    /// file grew past the window: its name, if any, is older than the window and still holds).
    private mutating func lookUp(_ ids: Set<String>, fileSize: Int, keepingUnfound: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let start = max(0, fileSize - Self.window)
        // One byte early, so a window that starts on a line's first byte keeps that line.
        let from = max(0, start - 1)
        guard (try? handle.seek(toOffset: UInt64(from))) != nil,
              let data = try? handle.read(upToCount: fileSize - from) else { return }
        bytesRead += data.count
        let (lines, end) = Self.completeLines(data, skippingFirst: start > 0)
        var left = ids
        for line in lines.reversed() where !left.isEmpty {
            guard let entry = Self.entry(line), left.contains(entry.id) else { continue }
            names[entry.id] = entry.name
            left.remove(entry.id)
        }
        if !keepingUnfound { for id in left { names[id] = "" } }
        offset = from + end
    }

    /// Folds the lines appended since the last read, oldest first, so the newest line wins.
    private mutating func readAppended(_ ids: Set<String>, to fileSize: Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: fileSize - offset) else { return }
        bytesRead += data.count
        let (lines, end) = Self.completeLines(data, skippingFirst: false)
        for line in lines {
            guard let entry = Self.entry(line), ids.contains(entry.id) else { continue }
            names[entry.id] = entry.name
        }
        offset += end
    }

    /// The lines of `data` that end in it, and the byte after the last one's newline (a line still being written waits
    /// for the next read).
    static func completeLines(_ data: Data, skippingFirst: Bool) -> (lines: [Data], end: Int) {
        var lines: [Data] = []
        var start = data.startIndex
        var end = 0
        var skipping = skippingFirst
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if skipping {
                skipping = false
            } else if newline > start {
                lines.append(Data(data[start..<newline]))
            }
            start = data.index(after: newline)
            end = data.distance(from: data.startIndex, to: start)
        }
        return (lines, end)
    }

    /// One index line: the thread id and its name, trimmed ("" clears it).
    static func entry(_ line: Data) -> (id: String, name: String)? {
        guard line.range(of: Data("\"thread_name\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, let name = object["thread_name"] as? String else { return nil }
        return (id, ChatTitleText.clean(name) ?? "")
    }
}

extension CodexTitleIndex {
    /// The names `lines` give, oldest first, the newest winning (the demo and renders: nothing is opened).
    static func names(fromLines lines: [String]) -> [String: String] {
        var names: [String: String] = [:]
        for line in lines { if let entry = entry(Data(line.utf8)) { names[entry.id] = entry.name } }
        return names
    }
}
