import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Every transcript reader drains an autorelease pool for each read (P83, P84): without one, every chunk a pass read
/// stayed alive until its caller's pool drained, and the owner's first launch grew by 13 to 30 MB a second. Each case
/// reads 256 MB of a sparse file (read as zeros, so nothing is written to disk) and checks how much more the heap
/// holds by the end of the read. The heap is the whole process's, and other suites run alongside: each case takes the
/// smallest growth of up to three runs, since their allocations can land in one run while chunks left behind land in
/// every one.
@Suite(.serialized)
struct RolloutMemoryTests {
    typealias F = RolloutFixtures
    typealias C = ClaudeFixtures
    typealias Box = EngineFixtures.Box

    private static let readSize = 256 << 20
    private static let allowedGrowth = 64 << 20

    /// The smallest growth `run` reports, over up to three runs.
    private func smallestGrowth(_ run: () throws -> Int) rethrows -> Int {
        var smallest = Int.max
        for _ in 0..<3 where smallest >= Self.allowedGrowth {
            smallest = min(smallest, try run())
        }
        return smallest
    }

    @Test
    func theCodexScannerHoldsAboutOneChunkAtATime() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head()).write(to: url, atomically: true, encoding: .utf8)
        F.appendHole(Self.readSize, to: url)

        let grown = smallestGrowth {
            let scanner = CodexRolloutScanner(rootURL: root, limits: CodexRolloutScanner.Limits(wholeFileLimit: 2 * Self.readSize))
            let before = F.liveHeapBytes()
            _ = scanner.discoverRecentSessions()
            let grown = F.liveHeapBytes() - before
            #expect(scanner.lastScanDiagnostics.bytesRead > Self.readSize)
            return grown
        }
        #expect(grown < Self.allowedGrowth)
    }

    @Test
    func theClaudeScannerHoldsAboutOneChunkAtATime() throws {
        let root = C.projectsFolder()
        defer { F.remove(root) }
        let url = C.transcriptURL(in: root)
        C.write(C.turn(prompt: "first prompt", reply: "first reply", from: 0), to: url)
        F.appendHole(Self.readSize, to: url)

        let grown = smallestGrowth {
            let scanner = ClaudeTranscriptScanner(rootURL: root, limits: ClaudeTranscriptScanner.Limits(wholeFileLimit: 2 * Self.readSize))
            let before = F.liveHeapBytes()
            _ = scanner.discoverRecentSessions()
            let grown = F.liveHeapBytes() - before
            #expect(scanner.lastScanDiagnostics.bytesRead > Self.readSize)
            return grown
        }
        #expect(grown < Self.allowedGrowth)
    }

    /// Measured when the tracker sends the read's events, on its queue, in the work item that read it.
    @Test
    func theTrackerLeavesNoChunksBehind() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text([F.event("user_message", ["message": "first prompt"], at: 1)]).write(to: url, atomically: true, encoding: .utf8)
        F.appendHole(Self.readSize, to: url)
        F.append(F.text([F.event("task_complete", ["last_agent_message": "all done"], at: 2)]), to: url)

        let grown = smallestGrowth {
            let tracker = CodexRolloutTracker(pollInterval: 60, initialReadLimit: 2 * Self.readSize, catchUpLimit: 2 * Self.readSize)
            defer { tracker.stop() }
            let largest = Box<Int?>(nil)
            let before = F.liveHeapBytes()
            tracker.eventHandler = { _ in
                let grown = F.liveHeapBytes() - before
                largest.update { $0 = max($0 ?? grown, grown) }
            }
            tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: F.sessionID, transcriptPath: url.path)])
            tracker.waitUntilIdle()
            #expect(tracker.bytesRead > Self.readSize)
            return largest.current ?? .max
        }
        #expect(grown < Self.allowedGrowth)
    }
}
