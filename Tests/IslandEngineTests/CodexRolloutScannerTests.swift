import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// Codex rollout discovery with bounded reads (P83): huge rollouts are read as a head and a tail window, small ones
/// whole with upstream's records, and every later pass reads only what was appended. Serialized because the large
/// fixtures are hundreds of megabytes of (mostly sparse) file each.
@Suite(.serialized)
struct CodexRolloutScannerTests {
    typealias F = RolloutFixtures

    /// The owner's case in small: a session_meta head and a first turn, 255 MB nobody reads, a 40 MB tool output on
    /// one line, then the last turn. About 300 MB in all.
    private func hugeRollout(in root: URL) -> URL {
        let url = F.rolloutURL(in: root)
        try! F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        F.appendHole(255 << 20, to: url)
        F.appendLongLine(40 << 20, at: 500, to: url)
        F.append(F.text(F.turn(prompt: "last prompt", reply: "all done", from: 600)), to: url)
        return url
    }

    @Test
    func aHugeRolloutIsReadAsItsHeadAndItsLastWindowThenOnlyWhatIsAppended() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = hugeRollout(in: root)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 295 << 20)
        let scanner = CodexRolloutScanner(rootURL: root)

        let started = Date()
        let records = scanner.discoverRecentSessions()
        #expect(Date().timeIntervalSince(started) < 2)
        let first = scanner.lastScanDiagnostics
        #expect(first.windowedFileCount == 1)
        // The first line's chunk (who started the thread, P212), the head's first chunk and the last 4 MB.
        #expect(first.bytesRead <= 64 * 1_024 + (4 << 20) + 2 * 64 * 1_024 + 1)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.sessionID == F.sessionID)
        #expect(record.title == "Codex · project")
        #expect(record.phase == .completed)
        #expect(record.summary == "all done")
        #expect(record.updatedAt == F.time(607))
        #expect(record.codexMetadata?.transcriptPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            == url.resolvingSymlinksInPath())
        #expect(record.codexMetadata?.initialUserPrompt == "first prompt")
        #expect(record.codexMetadata?.lastUserPrompt == "last prompt")
        #expect(record.codexMetadata?.lastAssistantMessage == "all done")

        let appended = F.text([F.event("user_message", ["message": "next prompt", "images": []], at: 700),
                               F.event("task_started", at: 701),
                               F.event("exec_command_begin", ["command": ["bash", "-lc", "make"]], at: 702)])
        F.append(appended, to: url)
        let next = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.bytesRead == appended.utf8.count)
        #expect(scanner.lastScanDiagnostics.windowedFileCount == 0)
        #expect(next.phase == .running)
        #expect(next.summary == "Running command.")
        #expect(next.updatedAt == F.time(702))
        #expect(next.codexMetadata?.initialUserPrompt == "first prompt")
        #expect(next.codexMetadata?.lastUserPrompt == "next prompt")

        _ = scanner.discoverRecentSessions()
        #expect(scanner.lastScanDiagnostics.cacheHitCount == 1)
        #expect(scanner.lastScanDiagnostics.bytesRead == 0)
    }

    /// A rollout whose last lines are a command's output, too long to fold, after the command started: the tail window
    /// and the wider one lie inside the output, and the lines before it give the record its last state and time.
    @Test
    func aTailInsideOneLongLineIsFoldedFromTheLinesBeforeIt() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        F.appendHole(3 << 20, to: url)
        F.append(F.text(Array(F.turn(prompt: "second prompt", reply: "-", from: 400).prefix(8))), to: url)
        F.appendLongLine(1_536 << 10, at: 404, to: url)
        let scanner = CodexRolloutScanner(rootURL: root, limits: Self.smallLimits)

        let record = try #require(scanner.discoverRecentSessions().first)
        let diagnostics = scanner.lastScanDiagnostics
        #expect(diagnostics.widenedFileCount == 1)
        #expect(diagnostics.lookedBackFileCount == 1)
        #expect(diagnostics.unreachedFileCount == 0)
        // The first line's chunk (who started the thread, P212), the head's first chunk, the tail window, the wider one,
        // and the look-back with at most one chunk past it.
        #expect(diagnostics.classifiedFileCount == 1)
        #expect(diagnostics.bytesRead <= 64 * 1_024 + 64 * 1_024 + (256 << 10) + 2 * (1 << 20) + 64 * 1_024 + 3)
        #expect(record.phase == .running)
        #expect(record.summary == "Running command.")
        #expect(record.updatedAt == F.time(403))
        #expect(record.codexMetadata?.initialUserPrompt == "first prompt")
        #expect(record.codexMetadata?.lastUserPrompt == "second prompt")
        #expect(record.codexMetadata?.currentTool == "exec_command")

        let done = F.text([F.event("task_complete", ["last_agent_message": "finished"], at: 900)])
        F.append(done, to: url)
        let next = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.bytesRead == done.utf8.count)
        #expect(next.phase == .completed)
        #expect(next.summary == "finished")
        #expect(next.codexMetadata?.lastUserPrompt == "second prompt")
    }

    /// A rollout whose end is one line longer than every bound: no line of it is folded, the record stands on the
    /// session_meta and the first prompt and is dated by the rollout's last write, not the session's start, and the
    /// next line appended is read alone.
    @Test
    func aTailOutOfReachIsDatedByTheLastWriteAndStaysBounded() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        F.appendHole(200 << 20, to: url)
        F.appendLongLine(40 << 20, at: 500, to: url)
        let written = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let scanner = CodexRolloutScanner(rootURL: root)

        let record = try #require(scanner.discoverRecentSessions().first)
        let diagnostics = scanner.lastScanDiagnostics
        #expect(diagnostics.lookedBackFileCount == 1)
        #expect(diagnostics.unreachedFileCount == 1)
        // The first line's chunk (P212), the head's first chunk, 4 MB, 32 MB, and the 32 MB before those with at most
        // one chunk past them.
        #expect(diagnostics.bytesRead <= 64 * 1_024 + 64 * 1_024 + (4 << 20) + (64 << 20) + 64 * 1_024 + 3)
        #expect(record.phase == .running)
        #expect(record.summary == "Started Codex session in project.")
        #expect(record.updatedAt == written)
        #expect(record.codexMetadata?.initialUserPrompt == "first prompt")
        #expect(record.codexMetadata?.lastUserPrompt == "first prompt")

        let done = F.text([F.event("task_complete", ["last_agent_message": "finished"], at: 900)])
        F.append(done, to: url)
        let next = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.bytesRead == done.utf8.count)
        #expect(next.phase == .completed)
        #expect(next.summary == "finished")
        #expect(next.updatedAt == F.time(900))
    }

    /// A catch-up whose every bound lies inside lines too long to fold keeps the state the earlier passes found, dated
    /// by the rollout's last write.
    @Test
    func aCatchUpOutOfReachKeepsTheKnownState() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        let scanner = CodexRolloutScanner(rootURL: root, limits: Self.smallLimits)
        #expect(scanner.discoverRecentSessions().first?.phase == .completed)

        F.appendHole(3 << 20, to: url)
        let written = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let record = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.unreachedFileCount == 1)
        #expect(record.phase == .completed)
        #expect(record.summary == "first reply")
        #expect(record.updatedAt == written)
        #expect(record.codexMetadata?.lastUserPrompt == "first prompt")
        #expect(record.codexMetadata?.lastAssistantMessage == "first reply")
    }

    @Test
    func aLineOverTheCapIsSkippedAndTheLinesAfterItFolded() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        F.appendLongLine(9 << 20, at: 30, to: url)
        F.append(F.text(F.turn(prompt: "second prompt", reply: "second reply", from: 40)), to: url)
        let scanner = CodexRolloutScanner(rootURL: root)

        let record = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.windowedFileCount == 0)
        #expect(scanner.lastScanDiagnostics.skippedLineCount == 1)
        #expect(record.summary == "second reply")
        #expect(record.codexMetadata?.lastUserPrompt == "second prompt")
    }

    /// Rollouts read whole give upstream's records: a finished turn, one cut off without its final newline, one still
    /// running with a developer note after its last event, and one that is only a head.
    @Test
    func smallRolloutsGiveUpstreamsRecords() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let ids = ["019d516f-71ee-7e40-bcff-000000000001", "019d516f-71ee-7e40-bcff-000000000002",
                   "019d516f-71ee-7e40-bcff-000000000003", "019d516f-71ee-7e40-bcff-000000000004"]
        let bodies = [
            F.text(F.head(id: ids[0]) + F.turn(prompt: "one", reply: "done one", from: 10)),
            F.text(F.head(id: ids[1]) + F.turn(prompt: "two", reply: "done two", from: 20)).dropLast().description,
            F.text(F.head(id: ids[2]) + Array(F.turn(prompt: "three", reply: "-", from: 30).prefix(8))
                   + [F.message("developer", "note", at: 40)]),
            F.text(F.head(id: ids[3])),
        ]
        for (index, body) in bodies.enumerated() {
            try body.write(to: F.rolloutURL(in: root, id: ids[index], second: index), atomically: true, encoding: .utf8)
        }
        let now = Date()
        let ours = CodexRolloutScanner(rootURL: root).discoverRecentSessions(now: now)
        #expect(ours.count == 4)
        #expect(ours == CodexRolloutDiscovery(rootURL: root).discoverRecentSessions(now: now))
    }

    @Test
    func manyRolloutsKeepTheNewestFortyAndASecondPassReadsNothing() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        var sizes: [Int] = []
        for index in 0..<50 {
            let id = String(format: "019d516f-71ee-7e40-bcff-%012d", index)
            let url = F.rolloutURL(in: root, id: id, second: index)
            let body = F.text(F.head(id: id) + F.turn(prompt: "prompt \(index)", reply: "reply \(index)", from: 10))
            try body.write(to: url, atomically: true, encoding: .utf8)
            F.setModified(url, to: Date().addingTimeInterval(-Double(index) * 60))
            sizes.append(body.utf8.count)
        }
        let scanner = CodexRolloutScanner(rootURL: root)

        let records = scanner.discoverRecentSessions()
        let first = scanner.lastScanDiagnostics
        #expect(records.count == 40)
        #expect(first.candidateCount == 50)
        #expect(first.parsedFileCount == 40)
        // Every recent rollout's first line is read once to tell who started it, before the cap (P212); each of these
        // fits in that one read.
        #expect(first.classifiedFileCount == 50)
        #expect(first.bytesRead == sizes.reduce(0, +) + sizes.prefix(40).reduce(0, +))
        #expect(!records.contains { $0.codexMetadata?.lastUserPrompt == "prompt 45" })

        _ = scanner.discoverRecentSessions()
        #expect(scanner.lastScanDiagnostics.cacheHitCount == 40)
        #expect(scanner.lastScanDiagnostics.parsedFileCount == 0)
        #expect(scanner.lastScanDiagnostics.bytesRead == 0)
    }

    private static let smallLimits = CodexRolloutScanner.Limits(wholeFileLimit: 1 << 20, headLimit: 256 << 10,
                                                                tailWindow: 256 << 10, widenedTailWindow: 1 << 20,
                                                                maxLineLength: 512 << 10)

    /// A rollout that gained more than `wholeFileLimit` since the last pass is read like a new large one, keeping what
    /// the earlier passes found in its head, and the last prompt and reply they found when the window holds none.
    @Test
    func aRolloutFarBehindIsCaughtUpFromItsTail() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        let scanner = CodexRolloutScanner(rootURL: root, limits: Self.smallLimits)
        _ = scanner.discoverRecentSessions()

        F.appendHole(2 << 20, to: url)
        F.append(F.text(F.turn(prompt: "later prompt", reply: "later reply", from: 100)), to: url)
        let record = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.windowedFileCount == 1)
        #expect(scanner.lastScanDiagnostics.bytesRead <= (256 << 10) + 1)
        #expect(record.codexMetadata?.initialUserPrompt == "first prompt")
        #expect(record.codexMetadata?.lastUserPrompt == "later prompt")
        #expect(record.summary == "later reply")

        // The next window holds a turn's tool calls and no prompt or reply.
        F.appendHole(2 << 20, to: url)
        F.append(F.text([F.event("task_started", at: 200),
                         F.event("exec_command_begin", ["command": ["bash", "-lc", "make"]], at: 201)]), to: url)
        // The second pass started following the folder's changes (P85); a walk keeps this pass off FSEvents' timing.
        scanner.followedFolder?.loseTrack()
        let next = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.windowedFileCount == 1)
        #expect(next.phase == .running)
        #expect(next.summary == "Running command.")
        #expect(next.updatedAt == F.time(201))
        #expect(next.codexMetadata?.initialUserPrompt == "first prompt")
        #expect(next.codexMetadata?.lastUserPrompt == "later prompt")
        #expect(next.codexMetadata?.lastAssistantMessage == "later reply")
    }

    /// A catch-up whose earlier passes had not reached a first prompt reads the head again for it, instead of taking
    /// the window's first prompt for it.
    @Test
    func aCatchUpReadsTheHeadForAFirstPromptNotYetSeen() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head()).write(to: url, atomically: true, encoding: .utf8)
        let scanner = CodexRolloutScanner(rootURL: root, limits: Self.smallLimits)
        #expect(scanner.discoverRecentSessions().first?.codexMetadata?.initialUserPrompt == nil)

        F.append(F.text(F.turn(prompt: "first prompt", reply: "first reply", from: 10)), to: url)
        F.appendHole(2 << 20, to: url)
        F.append(F.text(F.turn(prompt: "later prompt", reply: "later reply", from: 100)), to: url)
        let record = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.windowedFileCount == 1)
        #expect(record.codexMetadata?.initialUserPrompt == "first prompt")
        #expect(record.codexMetadata?.lastUserPrompt == "later prompt")
    }

    @Test
    func aTruncatedRolloutIsReadAgainFromItsStart() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        let scanner = CodexRolloutScanner(rootURL: root)
        _ = scanner.discoverRecentSessions()

        let shorter = F.text(F.head() + Array(F.turn(prompt: "again", reply: "-", from: 50).prefix(3)))
        try shorter.write(to: url, atomically: false, encoding: .utf8)
        let record = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.bytesRead == shorter.utf8.count)
        #expect(record.codexMetadata?.initialUserPrompt == "again")
        #expect(record.phase == .running)
    }

    /// Other Codex homes go through the same scanner at launch.
    @Test
    func otherCodexHomesAreScannedWithinBounds() throws {
        let home = F.sessionsFolder().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".codex-side", isDirectory: true)
        let sessions = folder.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions.appendingPathComponent("2026/09/24"), withIntermediateDirectories: true)
        _ = hugeRollout(in: sessions)
        var payload = SessionDiscoveryCoordinator.StartupDiscoveryPayload(
            codexRecords: [], codexRecordsNeedPrune: false, claudeRecords: [], claudeRecordsNeedPrune: false,
            openCodeRecords: [], openCodeRecordsNeedPrune: false, cursorRecords: [], cursorRecordsNeedPrune: false,
            piRecords: [], piRecordsNeedPrune: false, discoveredCodexRecords: [], discoveredClaudeSessions: [], hooksBinaryURL: nil)
        let target = ProfileHookTarget(provider: .codex, folder: folder.path, alias: "side", isDefaultFolder: false,
                                       accountID: nil, isMonitored: true)

        let started = Date()
        SessionEngine.addProfileDiscoveries(to: &payload, from: [target])
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(payload.discoveredCodexRecords.map(\.sessionID) == [F.sessionID])
        #expect(payload.discoveredCodexRecords.first?.codexMetadata?.lastUserPrompt == "last prompt")
    }
}
