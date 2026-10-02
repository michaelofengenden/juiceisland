import Foundation

/// Who started a Codex thread, as the first line of its rollout says (P212). Codex writes a `session_meta` line when it
/// creates a rollout (codex-rs `rollout/src/recorder.rs`), whose `source` names the thread's origin
/// (`protocol/src/protocol.rs` `SessionSource`, serialized lowercase):
/// - a chat the owner started: `"cli"`, `"vscode"`, `"exec"`, `"mcp"`, `"unknown"` or `{"custom":"chatgpt"}`;
/// - Codex's approvals reviewer (Guardian, "auto-review", "Approve for me"): `{"subagent":{"other":"guardian"}}`, or
///   `{"internal":"guardian"}`, with `thread_source` `guardian_review`;
/// - a subagent a chat spawned: `{"subagent":{"thread_spawn":{"parent_thread_id":…,"depth":…,"agent_nickname":…,
///   "agent_role":…}}}`, with `thread_source` `subagent`, the spawning thread as `parent_thread_id` and the root chat as
///   `session_id`;
/// - the thread a `/review` runs in (`codex review`, the TUI's `/review`, the app's Review): `{"subagent":"review"}`,
///   with the chat as `parent_thread_id`;
/// - Codex's other helpers: compaction (`"compact"`), memory consolidation (`{"internal":"memory_consolidation"}`) and
///   any other `{"subagent":{"other":…}}`.
///
/// Only a chat is a row. A reviewer or a helper is never a row, card, count, sound or title; a subagent is folded into
/// its chat's row (P1, P212). A review is folded into its chat once that chat is a row, and is a row of its own until
/// then: a review that is a chat's first action runs before Codex writes the chat's rollout (P217).
public enum CodexThreadKind: Equatable, Sendable {
    case chat
    case subagent(CodexSubagent)
    case review(CodexSubagent)
    case reviewer
    case helper

    public var isChat: Bool { self == .chat }

    public var subagent: CodexSubagent? {
        if case let .subagent(subagent) = self { return subagent }
        return nil
    }

    public var review: CodexSubagent? {
        if case let .review(review) = self { return review }
        return nil
    }

    /// The kind a `session_meta` payload names. One that names none is a chat, as Codex reads it (`source` defaults to
    /// `vscode`); an origin this build does not know is a chat too, so no chat of the owner's is ever hidden.
    public static func of(payload: [String: Any]) -> CodexThreadKind {
        let parent = nonEmpty(payload["parent_thread_id"] as? String)
        let threadSource = payload["thread_source"] as? String
        guard let source = payload["source"] as? [String: Any] else {
            return byThreadSource(threadSource, parent: parent, payload: payload, spawn: nil) ?? .chat
        }
        if let internalSource = source["internal"] as? String {
            return internalSource == guardianName ? .reviewer : .helper
        }
        guard let subagent = source["subagent"] else {
            return byThreadSource(threadSource, parent: parent, payload: payload, spawn: nil) ?? .chat
        }
        if subagent as? String == reviewName {
            // A Codex before 0.140 names no parent: nothing to fold it into, so it is a row, as it always was.
            guard let parent, let id = nonEmpty(payload["id"] as? String) else { return .chat }
            return .review(CodexSubagent(id: id, parentID: parent, rootID: root(of: payload, id: id)))
        }
        guard let fields = subagent as? [String: Any] else { return .helper }
        if let spawn = fields["thread_spawn"] as? [String: Any] {
            return byThreadSource("subagent", parent: nonEmpty(spawn["parent_thread_id"] as? String) ?? parent,
                                  payload: payload, spawn: spawn) ?? .helper
        }
        if let other = fields["other"] as? String, other == guardianName { return .reviewer }
        return .helper
    }

    /// The kind a rollout line names, when it is a `session_meta` line.
    public static func of(line: String) -> CodexThreadKind? {
        guard line.contains(#""session_meta""#),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any] else { return nil }
        return of(payload: payload)
    }

    /// Codex's name for its approvals reviewer (`core/src/guardian/mod.rs` `GUARDIAN_REVIEWER_NAME`).
    static let guardianName = "guardian"
    /// `SubAgentSource::Review`, serialized.
    static let reviewName = "review"

    /// A root `source` with a `thread_source` that says otherwise (`guardian_review`, `memory_consolidation`, or
    /// `subagent` with a parent), or a thread spawn: nil when it is a chat.
    private static func byThreadSource(_ threadSource: String?, parent: String?, payload: [String: Any],
                                       spawn: [String: Any]?) -> CodexThreadKind? {
        switch threadSource {
        case "guardian_review": return .reviewer
        case "memory_consolidation": return .helper
        case "subagent":
            guard let parent, let id = nonEmpty(payload["id"] as? String) else { return nil }
            return .subagent(CodexSubagent(id: id, parentID: parent, rootID: root(of: payload, id: id),
                                           name: name(spawn: spawn, payload: payload)))
        default: return nil
        }
    }

    /// The chat at the root (`session_id`), when it is not the thread itself.
    private static func root(of payload: [String: Any], id: String) -> String? {
        nonEmpty(payload["session_id"] as? String).flatMap { $0 == id ? nil : $0 }
    }

    /// Its role, unless that is Codex's `default`; else its nickname.
    private static func name(spawn: [String: Any]?, payload: [String: Any]) -> String? {
        let fields = [spawn, payload].compactMap { $0 }
        let role = fields.lazy.compactMap { nonEmpty(($0["agent_role"] ?? $0["agent_type"]) as? String) }.first
        if let role, role != "default" { return String(role.prefix(64)) }
        return fields.lazy.compactMap { nonEmpty($0["agent_nickname"] as? String) }.first.map { String($0.prefix(64)) }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// A subagent a Codex chat spawned, as its rollout names it.
public struct CodexSubagent: Equatable, Sendable {
    /// Its own thread id.
    public var id: String
    /// The thread that spawned it: the chat, or another subagent.
    public var parentID: String
    /// The chat at the root (`session_id`), when the rollout names one other than its own id.
    public var rootID: String?
    /// Its role ("worker"), or its nickname when its role is Codex's `default`.
    public var name: String?

    public init(id: String, parentID: String, rootID: String? = nil, name: String? = nil) {
        self.id = id
        self.parentID = parentID
        self.rootID = rootID
        self.name = name
    }
}

/// Each rollout's kind, read once from its first line and kept by path (a rollout's `session_meta` never changes), for
/// every reader: the scanner before its cap, the restored records and the process monitor's rollout pick (P212).
enum CodexRolloutKinds {
    /// How far into a rollout its first line is looked for (the scanner's head limit).
    static let firstLineLimit = 4 << 20
    /// Kinds kept at most; the cache starts over past it.
    static let cacheLimit = 8_192
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CodexThreadKind] = [:]

    /// The kind of the rollout at `path`, from the cache or its first line; nil when the first line is not a complete
    /// `session_meta` line yet (a rollout being created), which is read again next time. `bytesRead` counts the read.
    static func kind(atPath path: String, bytesRead: inout Int) -> CodexThreadKind? {
        if let known = lock.withLock({ cache[path] }) { return known }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var head = Data()
        var complete = false
        while head.count < firstLineLimit {
            let chunk = autoreleasepool { try? handle.read(upToCount: min(64 * 1_024, firstLineLimit - head.count)) }
            guard let chunk, !chunk.isEmpty else { break }
            bytesRead += chunk.count
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                head.append(chunk[chunk.startIndex..<newline])
                complete = true
                break
            }
            head.append(chunk)
        }
        guard complete else { return nil }
        // A first line that is not a session_meta (a rollout from before Codex wrote one) is a chat, as upstream reads it.
        let kind = CodexThreadKind.of(line: String(decoding: head, as: UTF8.self)) ?? .chat
        remember(kind, atPath: path)
        return kind
    }

    static func kind(atPath path: String) -> CodexThreadKind? {
        var bytes = 0
        return kind(atPath: path, bytesRead: &bytes)
    }

    static func remember(_ kind: CodexThreadKind, atPath path: String) {
        lock.withLock {
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[path] = kind
        }
    }

    /// The rollout among `paths` a process is taken to run: a chat's, when any is known to be one. A Codex process holds
    /// its chat's rollout open beside its reviewer's and its subagents' (newer, so upstream's newest-name pick took
    /// them), and its session then never matched its process (P212). None is known to be a chat: `paths` as given.
    static func chatPaths(_ paths: [String]) -> [String] {
        let chats = paths.filter { kind(atPath: $0)?.isChat ?? true }
        return chats.isEmpty ? paths : chats
    }
}
