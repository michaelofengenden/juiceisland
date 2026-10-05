import Darwin
import Foundation
import IslandHookNotes
import JuiceCore

/// A running transcript watch; `stop` ends it.
protocol TranscriptWatching: AnyObject, Sendable {
    func stop()
}

/// Watches one Claude transcript for the `tool_result` of one call (C9, C20a): a deny or an Esc at Claude's own prompt
/// fires no hook, but writes that call's result. File events only (no polling), and only appended bytes are read; a
/// line is looked at only when it names the call's id, and nothing of it is kept. The last 64 KB are read once at
/// the start, for a result written just before the watch.
final class TranscriptEvidenceWatch: TranscriptWatching, @unchecked Sendable {
    static let startWindow = 64 * 1_024
    /// A read catches up at most this much; a transcript that grew more is read from its last this-many bytes.
    static let readLimit = 4 << 20

    private let path: String
    private let needle: Data
    private let onFound: @Sendable () -> Void
    private let queue = DispatchQueue(label: "TranscriptEvidenceWatch")
    private var source: DispatchSourceFileSystemObject?
    private var offset: Int = 0
    private var pending = Data()
    private var found = false

    private init(path: String, toolUseID: String, onFound: @escaping @Sendable () -> Void) {
        self.path = path
        needle = Data(#""tool_use_id":"\#(toolUseID)""#.utf8)
        self.onFound = onFound
    }

    /// nil when the file is not there.
    static func start(path: String, toolUseID: String, onFound: @escaping @Sendable () -> Void) -> TranscriptEvidenceWatch? {
        guard !toolUseID.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let watch = TranscriptEvidenceWatch(path: path, toolUseID: toolUseID, onFound: onFound)
        guard watch.begin() else { return nil }
        return watch
    }

    private func begin() -> Bool {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.readAppended() }
        source.setCancelHandler { close(fd) }
        queue.sync {
            var info = stat()
            let size = stat(path, &info) == 0 ? Int(info.st_size) : 0
            offset = max(0, size - Self.startWindow)
            self.source = source
        }
        source.resume()
        queue.async { [weak self] in self?.readAppended() }
        return true
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    private func readAppended() {
        guard !found, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        if size < offset {
            offset = 0
            pending = Data()
        }
        if size - offset > Self.readLimit {
            offset = size - Self.readLimit
            pending = Data()
        }
        guard size > offset, (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: size - offset) else { return }
        offset += data.count
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            if line.range(of: needle) != nil, line.range(of: Data(#""tool_result""#.utf8)) != nil {
                found = true
                source?.cancel()
                source = nil
                onFound()
                return
            }
        }
        // A partial last line longer than the read limit is not a transcript line worth waiting for.
        if pending.count > Self.readLimit { pending = Data() }
    }
}

/// A Codex rollout's reviewer, approval policy and this turn's strict review, from its last 256 KB (C6): only
/// `session_meta`, `turn_context`, `thread_settings_applied`, turn starts and ends and calls' outputs are folded.
enum CodexSettingsReader {
    static let window = 256 * 1_024

    static func read(path: String) -> CodexAttention? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let start = max(0, size - window)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil, let data = try? handle.read(upToCount: size - start) else { return nil }
        var attention = CodexAttention()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            let text = String(decoding: line, as: UTF8.self)
            guard ["turn_context", "thread_settings_applied", "strict_auto_review", "task_started", "turn_started",
                   "task_complete", "turn_complete", "turn_aborted"].contains(where: text.contains) else { continue }
            attention.apply(text)
        }
        _ = attention.takeEvents()
        return attention
    }
}

/// Whether a Claude profile's `settings.json` runs our helper on Notification with a matcher that lets
/// `permission_prompt` through (C19): the 8 s window then releases an unconfirmed request, because Claude's own notice
/// would have said it waits. Read only (the hook config's events and matchers, as Setup reads them).
enum NotificationArming {
    static func isArmed(_ target: ProfileHookTarget) -> Bool {
        guard target.provider == .claude else { return false }
        let url = URL(fileURLWithPath: target.folder, isDirectory: true).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url) else { return false }
        return isArmed(settings: data)
    }

    static func isArmed(settings data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any], let groups = hooks["Notification"] as? [[String: Any]] else { return false }
        return groups.contains { group in
            let commands = ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
            guard commands.contains(where: isOurs) else { return false }
            return matches(group["matcher"] as? String, "permission_prompt")
        }
    }

    /// Our helper, for Claude, with `--source claude`: Juice's own (`JuiceHooks`, P900) or, until a profile is moved, the
    /// managed `OpenIslandHooks` it installed before.
    static func isOurs(_ command: String) -> Bool {
        (command.contains(HookHome.helperName) || command.contains("OpenIslandHooks")) && command.contains("--source claude")
    }

    /// Claude's matcher rule: none, empty or `*` matches all; otherwise a regular expression.
    static func matches(_ matcher: String?, _ value: String) -> Bool {
        guard let matcher, !matcher.isEmpty, matcher != "*" else { return true }
        if matcher == value { return true }
        guard let expression = try? NSRegularExpression(pattern: "^(?:\(matcher))$") else { return matcher.contains(value) }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

/// An island answer to a request the bridge holds, until the bridge's own echo of it arrives (C12, P169).
struct IslandAnswer: Equatable, Sendable {
    var resolution: PermissionResolutionKind
    var summary: String?
    var at: Date

    enum PermissionResolutionKind: Equatable, Sendable { case allow, deny, denyAndStop, answered }

    /// The bridge's echo comes at once; later than this it is not ours.
    static let echoWindow: TimeInterval = 5
}
