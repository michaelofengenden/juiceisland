// Changed from Open Island 1.2.1's Sources/OpenIslandCore/CodexSessionTracking.swift (GPL-3.0), September 2026: its
// CodexRolloutWatcher, with bounded reads.
import Dispatch
import Foundation
import OpenIslandCore

/// Upstream's `CodexRolloutWatcher` with bounded reads (P83), which `SessionDiscoveryCoordinator` holds in its place
/// (`Patches/bounded-transcripts.patch`): every 3 s, and at each sync, it folds what each watched rollout gained
/// and sends the events upstream's reducer finds. A rollout it starts watching is read as upstream reads it: the first
/// prompt from its first 4 MB, the last prompt from its last 4 MB, then the lines from its last 128 KB on.
///
/// Upstream cut lines by searching and copying its whole buffer again for every line, folded each line with a new
/// date formatter and never drained its autorelease pool, all in `sync`, which the engine calls on the main thread at
/// every event: starting on the owner's 40 recent rollouts took 9.4 s and 260 MB. Here lines are cut in one pass and
/// folded with `RolloutFolder`, the last 4 MB is searched newest first for a prompt, each read runs in its own pool, a line
/// longer than 8 MB is skipped, a rollout that grew more than 16 MB since the last read is caught up from its last
/// 4 MB, and `sync` only hands the targets to the tracker's queue, where the latest targets replace any not yet taken.
///
/// Beside upstream's reducer it folds `CodexAttention` over the same lines (questions, the reviewer, calls and their
/// outputs, turn ends) and hands what changed to `attentionHandler`; a watch's bootstrap also reads the last 4 MB for
/// a question still open, the latest reviewer and the turn's strict review (C6). `pollNow` reads one rollout at once,
/// for a hook of that session.
///
/// Its poll also keeps the watched threads' names (the chat title) from each Codex home's `session_index.jsonl`
/// (`CodexTitleIndex`: a `stat` per home, then only appended bytes), and hands what changed to `titleHandler`. No timer
/// of its own: the names move on the poll that already runs while a rollout is watched (P201).
///
/// With a `kindHandler`, a watched rollout that is not a chat of the owner's (Codex's reviewer, a helper, a subagent,
/// as its `session_meta` says) is reported there once, and nothing else of it is ever handed on: no event, no
/// attention, no name (P212). A review's thread is reported and still handed on: it is a row until the engine folds it
/// into its chat (P217).
public final class CodexRolloutTracker: @unchecked Sendable {
    private struct Observation {
        var target: CodexRolloutWatchTarget
        var offset: Int
        var splitter: RolloutLineSplitter
        var snapshot: CodexRolloutSnapshot
        var attention = CodexAttention()
        /// What the thread is at, for the peek (`CodexWorkFold`, P720); `workSent` is what `workHandler` last had.
        var work = CodexWorkFold()
        var workSent = SessionWork()
        /// Its thread was found not to be a chat and reported to `kindHandler`.
        var kindReported = false
        /// The thread's scope went to `attentionHandler` (once, with the read that found its `session_meta`).
        var scopeSent = false

        /// A chat, or a thread whose kind is not read yet.
        var isChat: Bool { attention.threadKind?.isChat ?? true }
    }

    public var eventHandler: (@Sendable (AgentEvent) -> Void)?
    /// What the rollout said about waiting on the owner since the last read, and where the thread stands now.
    var attentionHandler: (@Sendable (CodexAttentionUpdate) -> Void)?
    /// What a chat is at (its reasoning summary, its plan's steps) whenever a read changed it (P720): for the peek only,
    /// apart from `attentionHandler` so a thought that changes no row moves none. nil keeps none.
    var workHandler: (@Sendable (String, SessionWork) -> Void)?
    /// Threads whose name changed since the last poll: the name, or nil once it was cleared (P202). nil keeps no
    /// names (a subagents' tracker).
    var titleHandler: (@Sendable ([String: String?]) -> Void)?
    /// A watched thread that is not a chat (P212): its session id, the rollout's own thread id and its kind, reported
    /// once instead of anything else it says. nil hands every thread on (the subagents' trackers).
    var kindHandler: (@Sendable (String, String?, CodexThreadKind) -> Void)?

    private let pollInterval: TimeInterval
    private let initialReadLimit: Int
    private let initialPromptBootstrapLimit: Int
    private let catchUpLimit: Int
    private let maxLineLength: Int
    private let queue = DispatchQueue(label: "com.ofengenden.juice.codex-rollout-tracker")
    private var timer: DispatchSourceTimer?
    private var observations: [String: Observation] = [:]
    private let pendingLock = NSLock()
    private var pendingTargets: [CodexRolloutWatchTarget]?
    private let readLock = NSLock()
    private var _bytesRead = 0
    /// Each Codex home's index, by home.
    private var titleIndexes: [String: CodexTitleIndex] = [:]
    /// Threads to name once that are not watched (the launch's finished rows).
    private var titleOnlyTargets: [CodexRolloutWatchTarget] = []
    /// The names last handed to `titleHandler`, by thread.
    private var namedThreads: [String: String] = [:]

    private static let chunkSize = 64 * 1_024

    public init(pollInterval: TimeInterval = 3.0, initialReadLimit: Int = 128 * 1_024,
                initialPromptBootstrapLimit: Int = 4 << 20, catchUpLimit: Int = 16 << 20, maxLineLength: Int = 8 << 20) {
        self.pollInterval = pollInterval
        self.initialReadLimit = initialReadLimit
        self.initialPromptBootstrapLimit = initialPromptBootstrapLimit
        self.catchUpLimit = catchUpLimit
        self.maxLineLength = maxLineLength
    }

    deinit {
        timer?.cancel()
    }

    public func sync(targets: [CodexRolloutWatchTarget]) {
        let isQueued: Bool = pendingLock.withLock {
            defer { pendingTargets = targets }
            return pendingTargets != nil
        }
        guard !isQueued else { return }
        queue.async { [weak self] in
            guard let self, let targets = pendingLock.withLock({ () -> [CodexRolloutWatchTarget]? in
                defer { pendingTargets = nil }
                return pendingTargets
            }) else { return }
            syncLocked(targets: targets)
        }
    }

    public func stop() {
        pendingLock.withLock { pendingTargets = nil }
        queue.sync {
            timer?.cancel()
            timer = nil
            observations.removeAll()
            titleIndexes.removeAll()
            titleOnlyTargets.removeAll()
            namedThreads.removeAll()
        }
    }

    /// Names threads that are not watched once, off the caller's thread (the launch's finished rows, whose names do not
    /// change while no Codex runs them).
    func nameOnce(_ targets: [CodexRolloutWatchTarget]) {
        guard !targets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            titleOnlyTargets += targets
            refreshTitlesLocked()
        }
    }

    /// The bytes read from index files so far (tests).
    var titleBytesRead: Int {
        queue.sync { titleIndexes.values.reduce(0) { $0 + $1.bytesRead } }
    }

    /// Waits until the targets handed to `sync` have been taken and read (tests and `RolloutScanMeasure`).
    public func waitUntilIdle() {
        queue.sync {}
    }

    /// The bytes read from rollouts so far (tests and `RolloutScanMeasure`).
    public var bytesRead: Int {
        readLock.withLock { _bytesRead }
    }

    private func syncLocked(targets: [CodexRolloutWatchTarget]) {
        let targetMap = Dictionary(targets.map { ($0.sessionID, $0) }) { first, _ in first }
        observations = observations.filter { targetMap[$0.key] == $0.value.target }
        for target in targetMap.values where observations[target.sessionID] == nil {
            observations[target.sessionID] = autoreleasepool { makeObservation(for: target) }
        }

        if observations.isEmpty {
            timer?.cancel()
            timer = nil
            return
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in self?.pollLocked() }
            self.timer = timer
            timer.resume()
        }
        pollLocked()
    }

    private func pollLocked() {
        for sessionID in Array(observations.keys) { pollLocked(sessionID) }
        refreshTitlesLocked()
    }

    /// The names of every watched thread and of those to name once, by home; hands the changes on.
    private func refreshTitlesLocked() {
        guard let titleHandler else { return }
        let targets = observations.values.filter(\.isChat).map(\.target) + titleOnlyTargets
        titleOnlyTargets = []
        var idsByHome: [String: Set<String>] = [:]
        for target in targets {
            guard let home = CodexTitleIndex.home(ofRollout: target.transcriptPath) else { continue }
            idsByHome[home, default: []].insert(target.sessionID)
        }
        titleIndexes = titleIndexes.filter { idsByHome[$0.key] != nil }
        var changes: [String: String?] = [:]
        var named: [String: String] = [:]
        for (home, ids) in idsByHome {
            var index = titleIndexes[home] ?? CodexTitleIndex(home: home)
            let names = autoreleasepool { index.refresh(ids: ids) }
            titleIndexes[home] = index
            for id in ids {
                let name = names[id]
                named[id] = name
                if name != namedThreads[id] { changes.updateValue(name, forKey: id) }
            }
        }
        // A thread no longer watched keeps the name it was last given in the engine: only a change is handed on.
        namedThreads = named
        if !changes.isEmpty { titleHandler(changes) }
    }

    private func pollLocked(_ sessionID: String) {
        guard var observation = observations[sessionID] else { return }
        let events = autoreleasepool { refresh(&observation) }
        let attention = observation.attention.takeEvents()
        if let kindHandler, let kind = observation.attention.threadKind, !kind.isChat {
            let report = !observation.kindReported
            observation.kindReported = true
            observations[sessionID] = observation
            if report { kindHandler(sessionID, observation.attention.threadID, kind) }
            // A review is a row of its own until it is folded into its chat, which the engine decides; once it is, the
            // engine drops what it hands on (P217).
            if kind.review == nil { return }
        }
        // Who started the thread goes out with the read that found it, news or not, so a child's or a scripted run's
        // rollout is known for what it is before its first Done falls due (P252).
        let tellsScope = !observation.scopeSent && observation.attention.scope != nil
        if tellsScope { observation.scopeSent = true }
        observations[sessionID] = observation
        events.forEach { eventHandler?($0) }
        if !attention.isEmpty || tellsScope {
            attentionHandler?(CodexAttentionUpdate(sessionID: sessionID, events: attention, state: observation.attention))
        }
        if let workHandler, observation.work.work != observation.workSent {
            observation.workSent = observation.work.work
            observations[sessionID] = observation
            workHandler(sessionID, observation.work.work)
        }
    }

    /// Reads one watched rollout now, off the caller's thread (a Codex hook of that session: its reply or its Stop is
    /// seen at once, not at the next 3 s poll).
    public func pollNow(sessionID: String) {
        queue.async { [weak self] in self?.pollLocked(sessionID) }
    }

    /// Where the thread stands, from what was read so far (nil when the session is not watched). Waits for the queue.
    func attentionState(sessionID: String) -> CodexAttention? {
        queue.sync { observations[sessionID]?.attention }
    }

    private func refresh(_ observation: inout Observation) -> [AgentEvent] {
        let url = URL(fileURLWithPath: observation.target.transcriptPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let fileSize = Int((try? handle.seekToEnd()) ?? 0)
        if fileSize < observation.offset {
            observation.offset = 0
            observation.splitter = RolloutLineSplitter(maxLineLength: maxLineLength)
            observation.snapshot = CodexRolloutSnapshot()
            observation.attention = CodexAttention()
            observation.work = CodexWorkFold()
        }
        let old = observation.snapshot
        var folder = RolloutFolder(old)
        if fileSize - observation.offset > catchUpLimit {
            // Too far behind to fold it all: fold the last lines onto the prompts and the reply, as a new watch would
            // fold them onto its prompts. A rollout cut back has none, so its first prompt is read from its head again.
            // The window starts at the first byte at the earliest: the initializer allows a catch-up limit below the
            // bootstrap limit.
            let firstPrompt = old.initialUserPrompt ?? bootstrapFirstPrompt(handle)
            folder = RolloutFolder(CodexRolloutSnapshot(initialUserPrompt: firstPrompt, lastUserPrompt: old.lastUserPrompt ?? firstPrompt,
                                                        lastAssistantMessage: old.lastAssistantMessage))
            let start = max(0, fileSize - initialPromptBootstrapLimit)
            observation.offset = max(0, start - 1)
            observation.splitter = RolloutLineSplitter(maxLineLength: maxLineLength, skippingFirstLine: start > 0)
        }
        var splitter = observation.splitter
        var attention = observation.attention
        var work = observation.work
        var folded = 0
        let read = readChunks(handle, from: observation.offset) { chunk in
            splitter.feed(chunk) { line in
                folder.apply(line)
                attention.apply(line)
                work.apply(line)
                folded += 1
            }
            return true
        }
        observation.attention = attention
        observation.work = work
        observation.offset += read
        observation.splitter = splitter
        guard folded > 0 else { return [] }
        observation.snapshot = folder.finish()
        return CodexRolloutReducer.events(from: old, to: observation.snapshot, sessionID: observation.target.sessionID,
                                          transcriptPath: observation.target.transcriptPath)
    }

    private func makeObservation(for target: CodexRolloutWatchTarget) -> Observation {
        let fresh = Observation(target: target, offset: 0, splitter: RolloutLineSplitter(maxLineLength: maxLineLength),
                                snapshot: CodexRolloutSnapshot())
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: target.transcriptPath)) else { return fresh }
        defer { try? handle.close() }
        let fileSize = Int((try? handle.seekToEnd()) ?? 0)
        guard fileSize > initialReadLimit else { return fresh }
        var attention = CodexAttention()
        var work = CodexWorkFold()
        let firstPrompt = bootstrapFirstPrompt(handle) { attention.apply($0) }
        let offset = fileSize - initialReadLimit - 1
        // The plan before the window, as the questions and the reviewer: a peek right after the watch starts shows it
        // (P720). Only its calls are folded here (attention's lines hold them); a thought that old is no longer news.
        let lastPrompt = bootstrapLastPrompt(handle, fileSize: fileSize, attentionBefore: offset) { line in
            attention.apply(line)
            if line.contains("update_plan") { work.apply(line) }
        }
        // What changed on the way is dropped; a question still open is announced once, with the first read.
        _ = attention.takeEvents()
        attention.announceOpenQuestions()
        return Observation(target: target, offset: offset,
                           splitter: RolloutLineSplitter(maxLineLength: maxLineLength, skippingFirstLine: true),
                           snapshot: CodexRolloutSnapshot(initialUserPrompt: firstPrompt, lastUserPrompt: lastPrompt ?? firstPrompt),
                           attention: attention, work: work)
    }

    /// The first prompt, from at most the first 4 MB; stops at it. The thread's `session_meta` (an exec run asks
    /// nothing, C15), met on the way, goes to `meta`.
    private func bootstrapFirstPrompt(_ handle: FileHandle, meta: ((String) -> Void)? = nil) -> String? {
        var folder = RolloutFolder()
        var splitter = RolloutLineSplitter(maxLineLength: maxLineLength)
        var metaSeen = meta == nil
        _ = readChunks(handle, from: 0, budget: initialPromptBootstrapLimit) { chunk in
            splitter.feed(chunk) { line in
                if !metaSeen, rolloutLine(line, contains: #""session_meta""#) {
                    metaSeen = true
                    meta?(line)
                }
                if folder.snapshot.initialUserPrompt == nil { folder.apply(line) }
            }
            return folder.snapshot.initialUserPrompt == nil
        }
        return folder.snapshot.initialUserPrompt
    }

    /// The newest prompt in the last 4 MB. The reducer takes a prompt from a `user_message` event or a user `message`
    /// item alone, whatever came before, so only lines that can hold one are kept, and they are folded newest first,
    /// each alone, until one gives a prompt. The same read hands `attention` every line that ends before the watch's
    /// first window (`attentionBefore`) and can matter to `CodexAttention` (the latest reviewer, this turn's strict
    /// review, a question with no turn end after it); the window's own lines are folded by the first refresh.
    private func bootstrapLastPrompt(_ handle: FileHandle, fileSize: Int, attentionBefore windowStart: Int? = nil,
                                     attention: ((String) -> Void)? = nil) -> String? {
        let start = max(0, fileSize - initialPromptBootstrapLimit)
        let from = max(0, start - 1)
        var candidates: [String] = []
        var splitter = RolloutLineSplitter(maxLineLength: maxLineLength, skippingFirstLine: start > 0)
        var tail = RolloutLineSplitter(maxLineLength: maxLineLength, skippingFirstLine: start > 0)
        // Through the window's first byte: a line whose newline is that byte is the window's skipped first line.
        let tailEnd = windowStart.map { $0 + 1 } ?? from
        var fed = from
        _ = readChunks(handle, from: from) { chunk in
            splitter.feed(chunk) { line in
                if rolloutLine(line, contains: #""user_message""#) || rolloutLine(line, contains: #""role":"user""#) {
                    candidates.append(line)
                }
            }
            if let attention, fed < tailEnd {
                let part = chunk.prefix(tailEnd - fed)
                tail.feed(Data(part)) { line in
                    if CodexAttention.mayMatter(line), !rolloutLine(line, contains: #""session_meta""#) { attention(line) }
                }
            }
            fed += chunk.count
            return true
        }
        for line in candidates.reversed() {
            var folder = RolloutFolder()
            folder.apply(line)
            if let prompt = folder.snapshot.lastUserPrompt { return prompt }
        }
        return nil
    }

    /// Reads from `offset` in 64 KB chunks, each in its own autorelease pool, until the end of the file, `budget` bytes
    /// or `body` returns false. Returns the bytes read.
    private func readChunks(_ handle: FileHandle, from offset: Int, budget: Int = .max, _ body: (Data) -> Bool) -> Int {
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return 0 }
        var read = 0
        while read < budget {
            let more = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: min(Self.chunkSize, budget - read)), !chunk.isEmpty else { return false }
                read += chunk.count
                return body(chunk)
            }
            guard more else { break }
        }
        readLock.withLock { _bytesRead += read }
        return read
    }
}
