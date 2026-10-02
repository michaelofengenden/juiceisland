// Changed from Open Island 1.2.1's Sources/OpenIslandCore/CodexSessionTracking.swift (GPL-3.0), September 2026: its
// CodexRolloutDiscovery, with every read bounded.
import Foundation
import OpenIslandCore

/// What one pass of `CodexRolloutScanner` did.
public struct CodexRolloutScanDiagnostics: Equatable, Sendable {
    /// Rollouts modified within `maxAge`, before the `maxFiles` cap.
    public var candidateCount = 0
    public var bytesRead = 0
    public var parsedFileCount = 0
    public var cacheHitCount = 0
    /// Rollouts read as a head and a tail window instead of whole.
    public var windowedFileCount = 0
    /// Windowed rollouts whose tail window held no line with a time, so the wider window was folded.
    public var widenedFileCount = 0
    /// Windowed rollouts whose wider window held none either, so the lines before it were folded.
    public var lookedBackFileCount = 0
    /// Windowed rollouts with no line that has a time within any of those bounds: the record keeps what was known.
    public var unreachedFileCount = 0
    /// Lines dropped for being longer than `Limits.maxLineLength`.
    public var skippedLineCount = 0
    /// Rollout files a walk of the sessions folder looked at (none when the pass followed the change feed).
    public var walkedFileCount = 0
    /// The pass took its rollouts from the change feed instead of a walk (P85).
    public var followedChanges = false
    /// Paths the change feed reported since the pass before.
    public var changedPathCount = 0
    /// Rollouts whose first line was read to tell who started them (P212); a rollout is read for that once.
    public var classifiedFileCount = 0
    /// Recent rollouts of Codex's reviewer and its other helpers, left out before the `maxFiles` cap (P212).
    public var internalFileCount = 0
    /// Recent rollouts of subagents, folded into their chats instead of made records (P212).
    public var subagentFileCount = 0
}

/// A subagent a Codex chat spawned, or the thread a review of the chat runs in, as a scan found its rollout (P212,
/// P217): never a row of its own; a subagent is counted on its chat's row while it runs, a review says so there.
public struct CodexChildThread: Equatable, Sendable {
    public var id: String
    /// The thread that spawned it.
    public var parentID: String
    /// The chat at the root, when its rollout names one (`session_id`).
    public var rootID: String?
    /// Its role, or its nickname (`CodexSubagent.name`).
    public var name: String?
    /// Its last turn has not ended, as the end of its rollout says.
    public var isRunning: Bool
    /// When its rollout was last written.
    public var updatedAt: Date
    public var transcriptPath: String
    /// The thread a `/review` of the chat runs in (P217), not a subagent: never counted, never watched.
    public var isReview: Bool

    public init(id: String, parentID: String, rootID: String? = nil, name: String? = nil, isRunning: Bool, updatedAt: Date,
                transcriptPath: String, isReview: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.rootID = rootID
        self.name = name
        self.isRunning = isRunning
        self.updatedAt = updatedAt
        self.transcriptPath = transcriptPath
        self.isReview = isReview
    }
}

/// Upstream's `CodexRolloutDiscovery` with every read bounded (P83): the same rollouts (modified in the last day, the
/// newest 40), the same records and the same incremental later passes. `SessionDiscoveryCoordinator` holds one for
/// ~/.codex, at launch and for the Codex app rescan (`Patches/bounded-transcripts.patch`), and
/// `SessionEngine.addProfileDiscoveries` makes one for each other Codex home.
///
/// Upstream folds each recent rollout from byte 0 on its first pass. A long session's rollout can reach gigabytes, and
/// with a few of those that pass ran for minutes at a full core while memory grew past 3 GB, and no session appeared.
/// Here a rollout larger than `wholeFileLimit` is read as its head (the session_meta and the first
/// prompt) and a tail window folded from the first line that starts in it; a rollout that grew more than
/// `wholeFileLimit` since the last pass is caught up the same way. The middle is never read, so the record can miss
/// what only the middle has: the last prompt and the last reply when the tail window holds none (they are then the
/// ones the earlier passes found, or on a first pass the first prompt and no reply, as upstream's rollout watcher
/// has them), and a turn that began before the window reads from its first line in the window. `CodexRolloutTracker`
/// then refreshes the session from its own reads, as upstream's watcher would.
///
/// Upstream also walks the whole sessions folder on every pass, and the Codex app rescan asks for one every 10 s. A
/// scanner asked for a second pass follows the folder's changes from then on (`FolderChangeFeed`, P85): that pass
/// still walks, and later ones look only at the rollouts that changed since, plus the recent ones they already know.
///
/// Upstream made a record of every recent rollout, the newest 40, whoever started it: Codex's approvals reviewer
/// writes a rollout per reviewed chat and its subagents one each, so on the owner's Mac the reviewer's and the
/// subagents' rollouts filled the 40 and a chat of the owner's was left out (P1, P212). Here every recent rollout is
/// classified first, from its first line (`CodexRolloutKinds`, once per rollout), and only chats count toward the cap:
/// a reviewer's or a helper's rollout is left out, and a subagent's (the newest `maxChildFiles`) is read only at its
/// end, for whether its turn still runs, and handed on as a `CodexChildThread` (`lastScanChildren`, `childrenHandler`).
/// A chat the Codex desktop app wrote (`session_meta.originator`) is a Codex app thread from the first pass, as the
/// rescan makes the ones it finds later, so one found at launch and quiet since still shows while it runs; but only
/// while it is plausibly live (written in the last 10 minutes, or a subagent or review of it runs), since the app keeps
/// its threads alive whatever their rollouts say, and a chat whose turn the app never ended (a force quit) would be a
/// running row for good (P216). A review is folded into its chat when the chat's rollout is here, and is a chat until
/// then (P217).
public final class CodexRolloutScanner: @unchecked Sendable {
    public struct Limits: Sendable {
        /// A rollout up to this size is read whole on its first pass, as upstream reads every one.
        public var wholeFileLimit: Int
        /// How far into a larger rollout the first pass looks for its session_meta and its first prompt (upstream's
        /// watcher looks as far for the first prompt).
        public var headLimit: Int
        /// How much of a larger rollout's end the first pass folds.
        public var tailWindow: Int
        /// Folded instead when the tail window holds no line with a time (it lies inside one long line). When this
        /// holds none either, `CodexRolloutScanner` folds the lines that start in as many bytes before it.
        public var widenedTailWindow: Int
        /// A longer line is dropped as it streams.
        public var maxLineLength: Int

        public init(wholeFileLimit: Int = 16 << 20, headLimit: Int = 4 << 20, tailWindow: Int = 4 << 20,
                    widenedTailWindow: Int = 32 << 20, maxLineLength: Int = 8 << 20) {
            self.wholeFileLimit = wholeFileLimit
            self.headLimit = headLimit
            self.tailWindow = tailWindow
            self.widenedTailWindow = widenedTailWindow
            self.maxLineLength = maxLineLength
        }
    }

    private struct Candidate {
        var fileURL: URL
        var modifiedAt: Date
        var fileSize: Int
    }

    /// A rollout's fold up to `consumedOffset`, the end of its last complete line (or of the bytes of a line being
    /// skipped), so a later pass reads only what was appended and never folds a line twice.
    private struct ParseState {
        var consumedOffset: Int
        var isSkippingLine: Bool
        var snapshot: CodexRolloutSnapshot
        var sessionMeta: SessionMeta?
        var fileSize: Int
        var modifiedAt: Date
        var record: CodexTrackedSessionRecord?
    }

    private struct Fold {
        var snapshot: CodexRolloutSnapshot
        var sessionMeta: SessionMeta?
        var consumedOffset: Int
        var isSkippingLine: Bool
        /// The last line when it has no newline yet: it counts for the record only, as in upstream.
        var trailingLine: String?
    }

    private struct SessionMeta {
        var sessionID: String
        var cwd: String
        var timestamp: Date?
        var kind: CodexThreadKind = .chat
        var originator: String?

        var workspaceName: String {
            let workspace = URL(fileURLWithPath: cwd).lastPathComponent
            return workspace.isEmpty ? "Workspace" : workspace
        }
    }

    /// A subagent's rollout end read for its turn state; later passes read only what was appended, up to as much.
    private struct ChildState {
        var fileSize: Int
        var modifiedAt: Date
        /// The end of the last complete line read.
        var consumed: Int
        /// Its last turn start (true) or end (false) read so far; nil: none read yet.
        var isRunning: Bool?
    }

    private static let chunkSize = 64 * 1_024
    /// How much of a subagent's rollout end is read for its turn state.
    static let childTailWindow = 256 * 1_024
    /// A subagent whose rollout end holds no turn start or end runs if its rollout was written this recently.
    static let childQuietLimit: TimeInterval = 600
    /// A desktop chat written this recently is taken to be live (upstream's `codexAppStalenessTimeout`, P216).
    static let appThreadLiveWindow: TimeInterval = 600

    private let rootURL: URL
    private let fileManager: FileManager
    private let maxAge: TimeInterval
    private let maxFiles: Int
    private let maxChildFiles: Int
    private let limits: Limits

    private let stateLock = NSLock()
    private var parseStates: [String: ParseState] = [:]
    private var scanInProgress = false
    private var _lastScanDiagnostics = CodexRolloutScanDiagnostics()

    private var _lastScanChildren: [CodexChildThread] = []
    private var _childrenHandler: (@Sendable ([CodexChildThread]) -> Void)?

    // Read and written only inside a pass, which runs alone (`scanInProgress`).
    private var childStates: [String: ChildState] = [:]
    private var passCount = 0
    private var changeFeed: FolderChangeFeed?
    /// Every rollout modified within `maxAge` at the last pass, by path, kept current from the change feed; nil until a
    /// walk has run with the feed following the folder.
    private var recentByPath: [String: Candidate]?

    public var lastScanDiagnostics: CodexRolloutScanDiagnostics {
        stateLock.withLock { _lastScanDiagnostics }
    }

    /// The subagents the last pass found, newest first (P212).
    public var lastScanChildren: [CodexChildThread] {
        stateLock.withLock { _lastScanChildren }
    }

    /// Called at the end of every pass, off the caller's thread, with the subagents it found (the engine's children
    /// book, which the Codex app rescan keeps current).
    public var childrenHandler: (@Sendable ([CodexChildThread]) -> Void)? {
        get { stateLock.withLock { _childrenHandler } }
        set { stateLock.withLock { _childrenHandler = newValue } }
    }

    /// The feed a second pass started (tests; read between passes).
    var followedFolder: FolderChangeFeed? { changeFeed }

    public init(rootURL: URL = CodexRolloutDiscovery.defaultRootURL, fileManager: FileManager = .default,
                maxAge: TimeInterval = 86_400, maxFiles: Int = 40, maxChildFiles: Int = 64, limits: Limits = Limits()) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.maxAge = maxAge
        self.maxFiles = maxFiles
        self.maxChildFiles = maxChildFiles
        self.limits = limits
    }

    /// Upstream's `discoverRecentSessions`: a pass that starts while another runs returns nothing.
    public func discoverRecentSessions(now: Date = .now) -> [CodexTrackedSessionRecord] {
        let started: Bool = stateLock.withLock {
            guard !scanInProgress else { return false }
            scanInProgress = true
            return true
        }
        guard started else { return [] }
        var diagnostics = CodexRolloutScanDiagnostics()
        defer {
            stateLock.withLock {
                _lastScanDiagnostics = diagnostics
                scanInProgress = false
            }
            TranscriptReadTally.add(considered: min(diagnostics.candidateCount, maxFiles), read: diagnostics.parsedFileCount,
                                    bytes: diagnostics.bytesRead)
        }

        // Every recent rollout is classified before the cap: only the owner's chats count toward it (P212).
        var chats: [Candidate] = []
        var subagents: [(candidate: Candidate, subagent: CodexSubagent, isReview: Bool)] = []
        var reviews: [(candidate: Candidate, review: CodexSubagent)] = []
        for candidate in recentCandidates(now: now, diagnostics: &diagnostics) {
            switch kind(of: candidate, diagnostics: &diagnostics) {
            case .chat, nil:
                chats.append(candidate)
            case let .subagent(subagent):
                diagnostics.subagentFileCount += 1
                subagents.append((candidate, subagent, false))
            case let .review(review):
                reviews.append((candidate, review))
            case .reviewer, .helper:
                diagnostics.internalFileCount += 1
            }
        }
        // A review is folded into its chat when the chat's rollout is here; a review that is a chat's first action runs
        // before Codex writes the chat's rollout, and is a chat of its own until then, as it always was (P217).
        let chatIDs = Set(chats.compactMap { Self.threadID(ofRollout: $0.fileURL) })
        for (candidate, review) in reviews {
            if chatIDs.contains(review.rootID ?? review.parentID) {
                diagnostics.subagentFileCount += 1
                subagents.append((candidate, review, true))
            } else {
                chats.append(candidate)
            }
        }
        chats.sort(by: Self.newestFirst)
        subagents.sort { Self.newestFirst($0.candidate, $1.candidate) }
        let recent = Array(chats.prefix(maxFiles))
        let paths = Set(recent.map(\.fileURL.path))
        stateLock.withLock { parseStates = parseStates.filter { paths.contains($0.key) } }

        let kept = Array(subagents.prefix(maxChildFiles))
        let childPaths = Set(kept.map(\.candidate.fileURL.path))
        childStates = childStates.filter { childPaths.contains($0.key) }
        let children = kept.map { child(of: $0.candidate, $0.subagent, isReview: $0.isReview, now: now, diagnostics: &diagnostics) }
        let liveChats = Self.chatsWithLiveChildren(children, now: now)

        var recordsByID: [String: CodexTrackedSessionRecord] = [:]
        for candidate in recent {
            guard var record = discoverRecord(candidate, diagnostics: &diagnostics) else { continue }
            // The desktop app's chat is its thread only while it is plausibly live (P216): the app keeps such a thread
            // alive, whatever its rollout says, for as long as it runs.
            if record.jumpTarget?.terminalApp == "Codex.app", now.timeIntervalSince(candidate.modifiedAt) > Self.appThreadLiveWindow,
               !liveChats.contains(record.sessionID) {
                record.jumpTarget = nil
            }
            if let existing = recordsByID[record.sessionID], existing.updatedAt >= record.updatedAt { continue }
            recordsByID[record.sessionID] = record
        }

        let handler = stateLock.withLock { () -> (@Sendable ([CodexChildThread]) -> Void)? in
            _lastScanChildren = children
            return _childrenHandler
        }
        handler?(children)

        return recordsByID.values.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                : lhs.updatedAt > rhs.updatedAt
        }
    }

    private func recentCandidates(now: Date, diagnostics: inout CodexRolloutScanDiagnostics) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-maxAge)
        passCount += 1
        if passCount >= 2, changeFeed == nil {
            // Started before the walk below, so nothing that changes during the walk is missed.
            changeFeed = FolderChangeFeed(folder: rootURL)
            recentByPath = nil
        }

        let candidates: [Candidate]
        if let feed = changeFeed, let known = recentByPath, case let changes = feed.drain(), !changes.needsWalk {
            candidates = follow(changes, from: known, cutoff: cutoff, diagnostics: &diagnostics)
        } else {
            // What the feed has so far is in the walk.
            _ = changeFeed?.drain()
            candidates = walk(rootURL, cutoff: cutoff, diagnostics: &diagnostics)
            recentByPath = changeFeed == nil ? nil : Dictionary(candidates.map { ($0.fileURL.path, $0) }) { first, _ in first }
        }

        diagnostics.candidateCount = candidates.count
        return candidates.sorted(by: Self.newestFirst)
    }

    private static func newestFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        lhs.modifiedAt == rhs.modifiedAt
            ? lhs.fileURL.lastPathComponent.localizedStandardCompare(rhs.fileURL.lastPathComponent) == .orderedDescending
            : lhs.modifiedAt > rhs.modifiedAt
    }

    /// The thread id a rollout's name ends with (`rollout-<time>-<id>.jsonl`, the id of its `session_meta`).
    static func threadID(ofRollout url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else { return nil }
        let id = String(name.suffix(36))
        return UUID(uuidString: id) == nil ? nil : id
    }

    /// The chats a running subagent or review of this pass keeps live: its turn has not ended and its rollout was written
    /// within `CodexThreadBook.runningQuietLimit` (chat A's turn waits on its subagents, its own rollout quiet).
    static func chatsWithLiveChildren(_ children: [CodexChildThread], now: Date) -> Set<String> {
        let byID = Dictionary(children.map { ($0.id, $0) }) { first, _ in first }
        var chats: Set<String> = []
        for child in children where child.isRunning && now.timeIntervalSince(child.updatedAt) <= CodexThreadBook.runningQuietLimit {
            var owner = child
            for _ in 0..<CodexThreadBook.depthLimit {
                guard owner.rootID == nil, let parent = byID[owner.parentID] else { break }
                owner = parent
            }
            chats.insert(owner.rootID ?? owner.parentID)
        }
        return chats
    }

    /// Who started a rollout's thread: from the session_meta an earlier pass folded, else from its first line, read once
    /// for every reader (`CodexRolloutKinds`). nil while that line is still being written.
    private func kind(of candidate: Candidate, diagnostics: inout CodexRolloutScanDiagnostics) -> CodexThreadKind? {
        let path = candidate.fileURL.path
        if let known = stateLock.withLock({ parseStates[path]?.sessionMeta?.kind }) { return known }
        var bytes = 0
        let kind = CodexRolloutKinds.kind(atPath: path, bytesRead: &bytes)
        if bytes > 0 {
            diagnostics.classifiedFileCount += 1
            diagnostics.bytesRead += bytes
        }
        return kind
    }

    /// A subagent as its rollout's end says: running while its last turn start has no end after it. Only the end is
    /// read (`childTailWindow`), then only what was appended; a rollout whose end holds neither runs if it was written
    /// in the last `childQuietLimit` (a turn ends with a short `task_complete` line, so an end with no turn event lies
    /// inside a turn).
    private func child(of candidate: Candidate, _ subagent: CodexSubagent, isReview: Bool, now: Date,
                       diagnostics: inout CodexRolloutScanDiagnostics) -> CodexChildThread {
        let path = candidate.fileURL.path
        var state = childStates[path]
        if state?.fileSize != candidate.fileSize || state?.modifiedAt != candidate.modifiedAt {
            state = readChildState(candidate, known: state, diagnostics: &diagnostics)
            childStates[path] = state
        }
        let running = state?.isRunning ?? (now.timeIntervalSince(candidate.modifiedAt) < Self.childQuietLimit)
        return CodexChildThread(id: subagent.id, parentID: subagent.parentID, rootID: subagent.rootID, name: subagent.name,
                                isRunning: running, updatedAt: candidate.modifiedAt, transcriptPath: path, isReview: isReview)
    }

    private func readChildState(_ candidate: Candidate, known: ChildState?, diagnostics: inout CodexRolloutScanDiagnostics) -> ChildState? {
        guard let handle = try? FileHandle(forReadingFrom: candidate.fileURL) else { return known }
        defer { try? handle.close() }
        let size = candidate.fileSize
        let from: Int
        var splitter: RolloutLineSplitter
        var running: Bool?
        if let known, size >= known.consumed, size - known.consumed <= Self.childTailWindow {
            from = known.consumed
            splitter = RolloutLineSplitter(maxLineLength: limits.maxLineLength)
            running = known.isRunning
        } else {
            let start = max(0, size - Self.childTailWindow)
            from = max(0, start - 1)
            splitter = RolloutLineSplitter(maxLineLength: limits.maxLineLength, skippingFirstLine: start > 0)
            running = known?.isRunning
        }
        let read = readChunks(handle, from: from, budget: .max, diagnostics: &diagnostics) { chunk in
            splitter.feed(chunk) { line in
                if let turn = Self.turnState(line) { running = turn }
            }
            return true
        }
        return ChildState(fileSize: size, modifiedAt: candidate.modifiedAt, consumed: from + read - splitter.pending.count,
                          isRunning: running)
    }

    /// A turn start (true) or end (false) event line; nil for any other line. Only a line that names one is parsed.
    static func turnState(_ line: String) -> Bool? {
        let starts = rolloutLine(line, contains: "task_started") || rolloutLine(line, contains: "turn_started")
        let ends = rolloutLine(line, contains: "task_complete") || rolloutLine(line, contains: "turn_complete")
            || rolloutLine(line, contains: "turn_aborted")
        guard starts || ends, rolloutLine(line, contains: "event_msg"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] else { return nil }
        switch payload["type"] as? String {
        case "task_started", "turn_started": return true
        case "task_complete", "turn_complete", "turn_aborted": return false
        default: return nil
        }
    }

    /// The recent rollouts under `folder`, from a walk of every file in it.
    private func walk(_ folder: URL, cutoff: Date, diagnostics: inout CodexRolloutScanDiagnostics) -> [Candidate] {
        guard fileManager.fileExists(atPath: folder.path),
              let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: Self.candidateKeys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var candidates: [Candidate] = []
        for case let fileURL as URL in enumerator {
            guard Self.isRollout(fileURL) else { continue }
            diagnostics.walkedFileCount += 1
            if let candidate = candidate(fileURL, cutoff: cutoff) { candidates.append(candidate) }
        }
        return candidates
    }

    /// The recent rollouts known at the last pass, brought up to date with what changed since: each changed file is
    /// looked at again, and each changed folder walked again. A rollout that did not change kept its date, so it is
    /// recent now only if it was then; the ones that aged since are let go.
    private func follow(_ changes: FolderChangeFeed.Changes, from known: [String: Candidate], cutoff: Date,
                        diagnostics: inout CodexRolloutScanDiagnostics) -> [Candidate] {
        diagnostics.followedChanges = true
        diagnostics.changedPathCount = changes.files.count + changes.folders.count
        var known = known
        for folder in changes.folders {
            known = known.filter { !$0.key.hasPrefix(folder + "/") }
            for candidate in walk(URL(fileURLWithPath: folder, isDirectory: true), cutoff: cutoff, diagnostics: &diagnostics) {
                known[candidate.fileURL.path] = candidate
            }
        }
        for path in changes.files {
            let fileURL = URL(fileURLWithPath: path)
            known[path] = Self.isRollout(fileURL) ? candidate(fileURL, cutoff: cutoff) : nil
        }
        known = known.filter { $0.value.modifiedAt >= cutoff }
        recentByPath = known
        return Array(known.values)
    }

    private static let candidateKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]

    private static func isRollout(_ fileURL: URL) -> Bool {
        fileURL.lastPathComponent.hasPrefix("rollout-") && fileURL.pathExtension == "jsonl"
    }

    /// The rollout at `fileURL` when it is a regular file modified since `cutoff`.
    private func candidate(_ fileURL: URL, cutoff: Date) -> Candidate? {
        guard let values = try? fileURL.resourceValues(forKeys: Set(Self.candidateKeys)), values.isRegularFile == true else {
            return nil
        }
        let modifiedAt = values.contentModificationDate ?? .distantPast
        guard modifiedAt >= cutoff else { return nil }
        return Candidate(fileURL: fileURL, modifiedAt: modifiedAt, fileSize: values.fileSize ?? 0)
    }

    private func discoverRecord(_ candidate: Candidate, diagnostics: inout CodexRolloutScanDiagnostics) -> CodexTrackedSessionRecord? {
        let path = candidate.fileURL.path
        let fileSize = candidate.fileSize
        var cached = stateLock.withLock { parseStates[path] }
        if let state = cached, state.fileSize == fileSize, state.modifiedAt == candidate.modifiedAt {
            diagnostics.cacheHitCount += 1
            return state.record
        }
        if let state = cached, fileSize < state.consumedOffset
            || (fileSize == state.fileSize && candidate.modifiedAt != state.modifiedAt) {
            // Truncated or rewritten in place: the fold no longer matches the bytes on disk (upstream's rule).
            cached = nil
        }

        guard let handle = try? FileHandle(forReadingFrom: candidate.fileURL) else { return nil }
        defer { try? handle.close() }
        diagnostics.parsedFileCount += 1

        let fold: Fold
        if let state = cached, fileSize - state.consumedOffset <= limits.wholeFileLimit {
            fold = self.fold(handle, from: state.consumedOffset, skippingFirstLine: state.isSkippingLine,
                             onto: state.snapshot, sessionMeta: state.sessionMeta, diagnostics: &diagnostics)
        } else if cached == nil, fileSize <= limits.wholeFileLimit {
            fold = self.fold(handle, from: 0, skippingFirstLine: false, onto: CodexRolloutSnapshot(), sessionMeta: nil,
                             diagnostics: &diagnostics)
        } else {
            // A first pass over a large rollout, or a later one that fell more than `wholeFileLimit` behind.
            diagnostics.windowedFileCount += 1
            var sessionMeta = cached?.sessionMeta
            var firstPrompt = cached?.snapshot.initialUserPrompt
            if sessionMeta == nil || firstPrompt == nil {
                // Read again when the earlier passes had not reached the first prompt, so the window's first prompt
                // does not stand in for it.
                let head = readHead(handle, diagnostics: &diagnostics)
                sessionMeta = sessionMeta ?? head.sessionMeta
                firstPrompt = firstPrompt ?? head.firstPrompt
            }
            // The last prompt and reply found so far stand until the window has its own.
            let seed = CodexRolloutSnapshot(initialUserPrompt: firstPrompt,
                                            lastUserPrompt: cached?.snapshot.lastUserPrompt ?? firstPrompt,
                                            lastAssistantMessage: cached?.snapshot.lastAssistantMessage)
            fold = foldTail(handle, fileSize: fileSize, seed: seed, known: cached?.snapshot, sessionMeta: sessionMeta,
                            modifiedAt: candidate.modifiedAt, diagnostics: &diagnostics)
        }

        var recordSnapshot = fold.snapshot
        var recordMeta = fold.sessionMeta
        if let trailing = fold.trailingLine.flatMap(RolloutFolder.cleaned) {
            CodexRolloutReducer.apply(line: trailing, to: &recordSnapshot)
            RolloutFolder.applyReviewStart(trailing, to: &recordSnapshot)
            if recordMeta == nil { recordMeta = Self.sessionMeta(fromLine: trailing) }
        }
        let record = recordMeta.map { makeRecord(fileURL: candidate.fileURL, modifiedAt: candidate.modifiedAt,
                                                 snapshot: recordSnapshot, sessionMeta: $0) }
        stateLock.withLock {
            parseStates[path] = ParseState(consumedOffset: fold.consumedOffset, isSkippingLine: fold.isSkippingLine,
                                           snapshot: fold.snapshot, sessionMeta: fold.sessionMeta, fileSize: fileSize,
                                           modifiedAt: candidate.modifiedAt, record: record)
        }
        return record
    }

    /// Folds every complete line from `offset` to the end of the file onto `snapshot`; given `end`, only until the
    /// lines that start before it are folded (a line that starts before `end` is read to its newline, or until it is
    /// too long to fold). The consumed offset is then only as far as the read went.
    private func fold(_ handle: FileHandle, from offset: Int, skippingFirstLine: Bool, until end: Int = .max,
                      onto snapshot: CodexRolloutSnapshot, sessionMeta: SessionMeta?,
                      diagnostics: inout CodexRolloutScanDiagnostics) -> Fold {
        var folder = RolloutFolder(snapshot)
        var sessionMeta = sessionMeta
        var splitter = RolloutLineSplitter(maxLineLength: limits.maxLineLength, skippingFirstLine: skippingFirstLine)
        var position = offset
        let read = readChunks(handle, from: offset, budget: .max, diagnostics: &diagnostics) { chunk in
            splitter.feed(chunk) { line in
                folder.apply(line)
                if sessionMeta == nil { sessionMeta = Self.sessionMeta(fromLine: line) }
            }
            position += chunk.count
            return position < end || (!splitter.pending.isEmpty && position - splitter.pending.count < end)
        }
        diagnostics.skippedLineCount += splitter.skippedLineCount
        let trailing = splitter.pending.isEmpty ? nil : String(decoding: splitter.pending, as: UTF8.self)
        return Fold(snapshot: folder.finish(), sessionMeta: sessionMeta, consumedOffset: offset + read - splitter.pending.count,
                    isSkippingLine: splitter.isSkipping, trailingLine: trailing)
    }

    /// The session_meta and the first prompt, from at most `headLimit` bytes; stops as soon as it has both.
    private func readHead(_ handle: FileHandle,
                          diagnostics: inout CodexRolloutScanDiagnostics) -> (sessionMeta: SessionMeta?, firstPrompt: String?) {
        var sessionMeta: SessionMeta?
        var folder = RolloutFolder()
        var splitter = RolloutLineSplitter(maxLineLength: limits.maxLineLength)
        _ = readChunks(handle, from: 0, budget: limits.headLimit, diagnostics: &diagnostics) { chunk in
            splitter.feed(chunk) { line in
                if sessionMeta == nil { sessionMeta = Self.sessionMeta(fromLine: line) }
                if folder.snapshot.initialUserPrompt == nil { folder.apply(line) }
            }
            return sessionMeta == nil || folder.snapshot.initialUserPrompt == nil
        }
        diagnostics.skippedLineCount += splitter.skippedLineCount
        return (sessionMeta, folder.snapshot.initialUserPrompt)
    }

    /// Folds the lines that start in the last `tailWindow` bytes onto `seed`, which holds only the prompts and the
    /// reply known so far. A window with no line that has a time lies inside one long line, or in lines too long to
    /// fold (a command's output of tens of megabytes is written twice, each time on one line): the wider window is
    /// folded instead, and when that has none either, the lines that start in the `widenedTailWindow` bytes before it,
    /// which hold the rollout's last state. Nothing after them changes a snapshot, so the fold keeps its offsets from
    /// the wider window, which reached the end of the file.
    ///
    /// Past those bounds the last state is out of reach, and the snapshot keeps what is known: `known`, the earlier
    /// passes' fold, on a catch-up, and the seed on a first pass. Such a rollout ends inside a turn (a turn ends with a
    /// short `task_complete` line), so the seed's running phase is what upstream's fold of the whole file gives too.
    /// Either is dated by the rollout's last write, which wrote its last line: the session_meta's time is when the
    /// session started, days back for a long one.
    private func foldTail(_ handle: FileHandle, fileSize: Int, seed: CodexRolloutSnapshot, known: CodexRolloutSnapshot?,
                          sessionMeta: SessionMeta?, modifiedAt: Date, diagnostics: inout CodexRolloutScanDiagnostics) -> Fold {
        var fold = Fold(snapshot: seed, sessionMeta: sessionMeta, consumedOffset: 0, isSkippingLine: false)
        var start = 0
        for (index, window) in [limits.tailWindow, limits.widenedTailWindow].enumerated() {
            if index > 0 { diagnostics.widenedFileCount += 1 }
            start = max(0, fileSize - window)
            // One byte early, so a window that starts right after a newline keeps its first line.
            fold = self.fold(handle, from: max(0, start - 1), skippingFirstLine: start > 0, onto: seed,
                             sessionMeta: sessionMeta, diagnostics: &diagnostics)
            if fold.snapshot.updatedAt != nil { return fold }
            if start == 0 { break }
        }
        if start > 0 {
            diagnostics.lookedBackFileCount += 1
            let lookBack = max(0, start - limits.widenedTailWindow)
            let before = self.fold(handle, from: max(0, lookBack - 1), skippingFirstLine: lookBack > 0, until: start,
                                   onto: seed, sessionMeta: sessionMeta, diagnostics: &diagnostics)
            fold.sessionMeta = fold.sessionMeta ?? before.sessionMeta
            if before.snapshot.updatedAt != nil {
                fold.snapshot = before.snapshot
                return fold
            }
        }
        diagnostics.unreachedFileCount += 1
        var last = known ?? seed
        last.initialUserPrompt = seed.initialUserPrompt
        last.lastUserPrompt = seed.lastUserPrompt
        last.updatedAt = modifiedAt
        fold.snapshot = last
        return fold
    }

    /// Reads from `offset` in 64 KB chunks until the end of the file, `budget` bytes, or `body` returns false. Each
    /// read and what is done with it run in their own autorelease pool: without one, every chunk a pass read stayed
    /// in memory until the pass ended. Returns the bytes read.
    private func readChunks(_ handle: FileHandle, from offset: Int, budget: Int,
                            diagnostics: inout CodexRolloutScanDiagnostics, _ body: (Data) -> Bool) -> Int {
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return 0 }
        var read = 0
        while read < budget {
            let more = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: min(Self.chunkSize, budget - read)), !chunk.isEmpty else {
                    return false
                }
                read += chunk.count
                return body(chunk)
            }
            guard more else { break }
        }
        diagnostics.bytesRead += read
        return read
    }

    private func makeRecord(fileURL: URL, modifiedAt: Date, snapshot: CodexRolloutSnapshot,
                            sessionMeta: SessionMeta) -> CodexTrackedSessionRecord {
        // The desktop app's chat is a Codex app thread from the first pass, with the rescan's jump target (upstream's
        // record carries the flag in `jumpTarget.terminalApp`): its liveness is the app's, not a process's, so it shows
        // while it runs however quiet it is (P212). The pass takes the flag off one that is not plausibly live (P216).
        let appTarget = Self.isDesktopApp(sessionMeta.originator)
            ? JumpTarget(terminalApp: "Codex.app", workspaceName: sessionMeta.workspaceName, paneTitle: "Codex · \(sessionMeta.workspaceName)",
                         workingDirectory: sessionMeta.cwd, codexThreadID: sessionMeta.sessionID)
            : nil
        return CodexTrackedSessionRecord(
            sessionID: sessionMeta.sessionID,
            title: "Codex · \(sessionMeta.workspaceName)",
            origin: .live,
            attachmentState: .stale,
            summary: snapshot.summary ?? "Started Codex session in \(sessionMeta.workspaceName).",
            phase: snapshot.phase,
            updatedAt: snapshot.updatedAt ?? sessionMeta.timestamp ?? modifiedAt,
            jumpTarget: appTarget,
            codexMetadata: CodexSessionMetadata(
                transcriptPath: fileURL.path,
                initialUserPrompt: snapshot.initialUserPrompt,
                lastUserPrompt: snapshot.lastUserPrompt,
                lastAssistantMessage: snapshot.lastAssistantMessage,
                currentTool: snapshot.currentTool,
                currentCommandPreview: snapshot.currentCommandPreview))
    }

    private static func sessionMeta(fromLine line: String) -> SessionMeta? {
        guard rolloutLine(line, contains: #""session_meta""#),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "session_meta" else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        guard let sessionID = payload["id"] as? String, !sessionID.isEmpty,
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        return SessionMeta(sessionID: sessionID, cwd: cwd,
                           timestamp: timestamp((payload["timestamp"] as? String) ?? (object["timestamp"] as? String)),
                           kind: CodexThreadKind.of(payload: payload), originator: payload["originator"] as? String)
    }

    /// The Codex desktop app's `originator` (`CodexOriginator`: "Codex Desktop", `codex_desktop`, a Work thread's
    /// `codex_work_…`; the ChatGPT app that hosts it): the CLI's is `codex_cli_rs`, `codex exec`'s `codex_exec`, the VS
    /// Code extension's `codex_vscode`.
    static func isDesktopApp(_ originator: String?) -> Bool {
        CodexOriginator.isAppThread(originator)
    }

    private static func timestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
