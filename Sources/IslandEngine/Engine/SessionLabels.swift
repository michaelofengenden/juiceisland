import Foundation
import IslandHookNotes

/// The small labels a row's facts show (P445): the model id, the permission mode and the reasoning effort a session last
/// reported, kept across a relaunch so a restored row does not lose them until its agent says them again (a mode or an
/// effort reaches the engine only on the session's next hook, a Codex model on its rollout's next read). Ids and words
/// the agents define, each bounded; never a title, a prompt, a path or any other text of the owner's (P200 keeps titles
/// in memory only).
public struct SessionLabels: Codable, Equatable, Sendable {
    public var model: String?
    public var mode: String?
    public var effort: String?
    /// The session's real agent when its hooks named one its tool does not (`AgentKind`'s word: Copilot, Devin, an agent
    /// behind Claude's hooks, P913). An older file has none.
    public var agent: String?
    /// When a label last changed: the oldest go first past `SessionLabelBook.limit`, and at `SessionLabelBook.lifetime`.
    public var at: Date

    public init(model: String? = nil, mode: String? = nil, effort: String? = nil, agent: String? = nil, at: Date) {
        self.model = model
        self.mode = mode
        self.effort = effort
        self.agent = agent
        self.at = at
    }

    /// Longest label kept: a model id past `CodexAttention.modelLimit` is no name either.
    static let fieldLimit = 64

    /// Only what could be a label: a short single line of letters, digits and the few marks model ids use.
    static func label(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= fieldLimit,
              text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:[]/@"))
}

/// Every session's kept labels, by session id, bounded: `limit` sessions, none older than `lifetime`. Pure.
struct SessionLabelBook: Equatable, Sendable {
    static let limit = 300
    static let lifetime: TimeInterval = 14 * 86_400

    private(set) var labels: [String: SessionLabels] = [:]

    init(labels: [String: SessionLabels] = [:], now: Date) {
        self.labels = labels.filter { now.timeIntervalSince($0.value.at) < Self.lifetime }
        trim()
    }

    func labels(for sessionID: String) -> SessionLabels? { labels[sessionID] }

    /// Takes what the session reports now: a label it reports replaces the kept one; one it does not report (not yet,
    /// after a relaunch) keeps what was kept, except an effort its source says is none (`effortSaid`: Codex's latest turn
    /// left it out, P497). True when something changed.
    @discardableResult
    mutating func take(_ sessionID: String, model: String?, mode: String?, effort: String?, effortSaid: Bool = false,
                       agent: String? = nil, at now: Date) -> Bool {
        let kept = labels[sessionID]
        let next = SessionLabels(model: SessionLabels.label(model) ?? kept?.model, mode: SessionLabels.label(mode) ?? kept?.mode,
                                 effort: SessionLabels.label(effort) ?? (effortSaid ? nil : kept?.effort),
                                 agent: agent.flatMap { AgentKind(rawValue: $0)?.rawValue } ?? kept?.agent, at: now)
        if next.model == nil, next.mode == nil, next.effort == nil, next.agent == nil {
            guard kept != nil else { return false }
            labels[sessionID] = nil
            return true
        }
        guard kept.map({ ($0.model, $0.mode, $0.effort, $0.agent) != (next.model, next.mode, next.effort, next.agent) }) ?? true else {
            return false
        }
        labels[sessionID] = next
        trim()
        return true
    }

    mutating func forget(_ sessionID: String) {
        if labels[sessionID] != nil { labels[sessionID] = nil }
    }

    private mutating func trim() {
        guard labels.count > Self.limit else { return }
        let keep = labels.sorted { $0.value.at > $1.value.at }.prefix(Self.limit)
        labels = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}

/// The labels' file: `~/Library/Application Support/Juice Island/session-labels.json` for the app's own engine, a
/// temporary folder in tests, none for the demo and renders. Read once at the engine's start; written off the main
/// thread whenever a label changes (never on a timer), the latest labels only, in one atomic write.
public final class SessionLabelStore: @unchecked Sendable {
    public static let fileName = "session-labels.json"
    /// Larger than this is no labels file of ours: it is not read.
    static let readLimit = 256 * 1_024

    let url: URL
    private let queue = DispatchQueue(label: "juice-island.session-labels", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: SessionLabels]?

    public init(url: URL) {
        self.url = url
    }

    /// The app's own: in its home, beside its sockets (`HookHome.current`, the private app's `Juice Island` as before).
    public static var app: SessionLabelStore {
        SessionLabelStore(url: HookHome.current.folder.appendingPathComponent(fileName))
    }

    struct File: Codable {
        var version = 1
        var sessions: [String: SessionLabels]
    }

    func load() -> [String: SessionLabels] {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= Self.readLimit, let data = try? Data(contentsOf: url),
              let file = try? Self.decoder.decode(File.self, from: data), file.version == 1 else { return [:] }
        return file.sessions
    }

    /// Queues a write of `labels`; a burst of changes writes the latest once or twice.
    func save(_ labels: [String: SessionLabels]) {
        let first = lock.withLock { () -> Bool in
            defer { pending = labels }
            return pending == nil
        }
        guard first else { return }
        queue.async { [self] in
            guard let latest = lock.withLock({ () -> [String: SessionLabels]? in
                defer { pending = nil }
                return pending
            }) else { return }
            write(latest)
        }
    }

    /// Waits for a queued write (tests; the app's quit).
    public func flush() { queue.sync {} }

    private func write(_ labels: [String: SessionLabels]) {
        guard let data = try? Self.encoder.encode(File(sessions: labels)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
