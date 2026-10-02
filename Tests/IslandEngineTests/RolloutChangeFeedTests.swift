import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// The Codex app rescan follows the sessions folder's changes instead of walking every rollout on every pass (P85).
/// Serialized: each test waits on FSEvents.
@Suite(.serialized)
struct RolloutChangeFeedTests {
    typealias F = RolloutFixtures

    private static let ids = ["019d516f-71ee-7e40-bcff-50000000000a", "019d516f-71ee-7e40-bcff-50000000000b",
                              "019d516f-71ee-7e40-bcff-50000000000c", "019d516f-71ee-7e40-bcff-50000000000d"]

    private func rollout(_ index: Int, in root: URL, folder: String = "2026/09/24") -> URL {
        let url = root.appendingPathComponent(folder)
            .appendingPathComponent(String(format: "rollout-2026-09-24T10-00-%02d-%@.jsonl", index, Self.ids[index]))
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! F.text(F.head(id: Self.ids[index]) + F.turn(prompt: "prompt \(index)", reply: "reply \(index)", from: 10))
            .write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// Waits (up to 10 s) until the feed holds a change whose path ends with each of `suffixes`.
    private func waitFor(_ suffixes: [String], in feed: FolderChangeFeed) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            feed.flush()
            let changes = feed.peek()
            let paths = changes.files.union(changes.folders)
            if suffixes.allSatisfy({ suffix in paths.contains { $0.hasSuffix(suffix) } }) { return true }
            usleep(50_000)
        }
        return false
    }

    @Test
    func aScannerAskedAgainFollowsChangesInsteadOfWalking() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let urls = (0..<3).map { rollout($0, in: root) }
        let scanner = CodexRolloutScanner(rootURL: root)

        #expect(scanner.discoverRecentSessions().count == 3)
        #expect(scanner.lastScanDiagnostics.walkedFileCount == 3)
        #expect(scanner.followedFolder == nil)
        #expect(scanner.discoverRecentSessions().count == 3)
        #expect(scanner.lastScanDiagnostics.walkedFileCount == 3)
        #expect(!scanner.lastScanDiagnostics.followedChanges)
        let feed = try #require(scanner.followedFolder)

        let appended = F.text(F.turn(prompt: "later prompt", reply: "later reply", from: 100))
        F.append(appended, to: urls[1])
        let added = rollout(3, in: root, folder: "2026/09/25")
        #expect(waitFor([urls[1].lastPathComponent, "2026/09/25"], in: feed))

        let now = Date()
        let followed = scanner.discoverRecentSessions(now: now)
        let diagnostics = scanner.lastScanDiagnostics
        #expect(diagnostics.followedChanges)
        #expect(diagnostics.walkedFileCount <= 1)
        let addedSize = try #require(try added.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        // The new rollout: its first line, to tell who started it (P212; it fits in that read), then its fold.
        #expect(diagnostics.bytesRead == appended.utf8.count + 2 * addedSize)
        #expect(followed.count == 4)
        #expect(followed.first { $0.sessionID == Self.ids[1] }?.codexMetadata?.lastUserPrompt == "later prompt")
        // The same records, each rollout named the same way, as a walk finds them (records of the same time and title
        // come in no set order, in upstream's discovery too).
        let walked = CodexRolloutScanner(rootURL: root).discoverRecentSessions(now: now)
        #expect(followed.sorted { $0.sessionID < $1.sessionID } == walked.sorted { $0.sessionID < $1.sessionID })

        let quiet = scanner.discoverRecentSessions()
        #expect(quiet.count == 4)
        #expect(scanner.lastScanDiagnostics.followedChanges)
        #expect(scanner.lastScanDiagnostics.walkedFileCount == 0)
        #expect(scanner.lastScanDiagnostics.cacheHitCount == 4)
        #expect(scanner.lastScanDiagnostics.bytesRead == 0)
    }

    @Test
    func aRemovedOrAgedRolloutLeavesAndALostTrackWalks() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let urls = (0..<2).map { rollout($0, in: root) }
        let scanner = CodexRolloutScanner(rootURL: root)
        _ = scanner.discoverRecentSessions()
        _ = scanner.discoverRecentSessions()
        let feed = try #require(scanner.followedFolder)

        try FileManager.default.removeItem(at: urls[0])
        #expect(waitFor([urls[0].lastPathComponent], in: feed))
        #expect(scanner.discoverRecentSessions().map(\.sessionID) == [Self.ids[1]])
        #expect(scanner.lastScanDiagnostics.followedChanges)

        // Two days on, nothing changed: the rollout the pass knew has aged out, without a walk.
        #expect(scanner.discoverRecentSessions(now: Date().addingTimeInterval(2 * 86_400)).isEmpty)
        #expect(scanner.lastScanDiagnostics.followedChanges)
        #expect(scanner.lastScanDiagnostics.walkedFileCount == 0)

        feed.loseTrack()
        #expect(scanner.discoverRecentSessions().map(\.sessionID) == [Self.ids[1]])
        #expect(!scanner.lastScanDiagnostics.followedChanges)
        #expect(scanner.lastScanDiagnostics.walkedFileCount == 1)
    }

    /// The feed names a file as `FileManager`'s enumerator names it (/private/var for /var), so a pass that follows
    /// changes and one that walks agree on every path.
    @Test
    func theFeedNamesFilesAsTheWalkDoes() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        #expect(FolderChangeFeed(folder: root.appendingPathComponent("missing")) == nil)
        let feed = try #require(FolderChangeFeed(folder: root))
        let url = rollout(0, in: root)
        #expect(waitFor([url.lastPathComponent], in: feed))
        let walked = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.path }.first { $0.hasSuffix(url.lastPathComponent) })
        #expect(feed.drain().files.contains(walked))
        #expect(feed.drain() == FolderChangeFeed.Changes())
    }
}
