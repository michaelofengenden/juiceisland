import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// The line splitter and the folder under the Codex rollout scanner and tracker (P83).
struct RolloutReadingTests {
    typealias F = RolloutFixtures

    private func lines(_ chunks: [String], maxLineLength: Int = 1 << 20, skippingFirstLine: Bool = false)
        -> (lines: [String], splitter: RolloutLineSplitter) {
        var splitter = RolloutLineSplitter(maxLineLength: maxLineLength, skippingFirstLine: skippingFirstLine)
        var found: [String] = []
        for chunk in chunks { splitter.feed(Data(chunk.utf8)) { found.append($0) } }
        return (found, splitter)
    }

    @Test
    func linesAcrossChunksComeOutWholeAndTheUnfinishedOneWaits() {
        let (found, splitter) = lines(["ab", "c\nde\n\nf", "gh\ni", "j"])
        #expect(found == ["abc", "de", "fgh"])
        #expect(splitter.pending == Data("ij".utf8))
        #expect(!splitter.isSkipping)
    }

    @Test
    func aLineOverTheLimitIsDroppedAsItStreamsAndTheNextOneKept() {
        let long = String(repeating: "x", count: 40)
        let (found, splitter) = lines(["a\n" + long.prefix(15), long.dropFirst(15) + "\nb\n", long + "\nc"], maxLineLength: 16)
        #expect(found == ["a", "b"])
        #expect(splitter.skippedLineCount == 2)
        #expect(splitter.pending == Data("c".utf8))
        // A line still too long when the bytes run out is skipped from where the next read picks up.
        let (_, open) = lines(["a\n" + long], maxLineLength: 16)
        #expect(open.isSkipping && open.pending.isEmpty)
    }

    @Test
    func aReadThatBeginsInsideALineDropsItUpToItsNewline() {
        #expect(lines(["tail of a line\nfirst\nsecond\n"], skippingFirstLine: true).lines == ["first", "second"])
        #expect(lines(["\nfirst\n"], skippingFirstLine: true).lines == ["first"])
    }

    @Test
    func aThirtyMegabyteLineCostsOnePass() {
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1_024)
        var splitter = RolloutLineSplitter(maxLineLength: 64 << 20)
        var lengths: [Int] = []
        let started = Date()
        for _ in 0..<480 { splitter.feed(chunk) { lengths.append($0.utf8.count) } }
        splitter.feed(Data("\n".utf8)) { lengths.append($0.utf8.count) }
        #expect(lengths == [480 * 64 * 1_024])
        #expect(Date().timeIntervalSince(started) < 1)
    }

    /// Every case of the reducer's `updatedAt`: an `event_msg` always sets it, a developer or injected message never
    /// does, an assistant message after the last event does.
    @Test
    func theFolderGivesUpstreamsSnapshot() {
        let turn = F.head() + F.turn(prompt: "first", reply: "done", from: 10)
        let cases: [[String]] = [
            turn,
            turn + [F.message("assistant", "one more thing", at: 30)],
            turn + [F.message("developer", "a developer note", at: 40)],
            turn + [F.message("assistant", "late", at: 50), F.message("developer", "note", at: 60),
                    F.item("unknown_kind", at: 70)],
            turn + F.turn(prompt: "second", reply: "also done", from: 100)
                + [F.event("user_message", ["message": "third", "images": []], at: 200), F.item("reasoning", at: 201)],
            (turn + [F.message("assistant", "late", at: 50), F.message("developer", "note", at: 60)])
                .enumerated().map { F.numbered($1, $0) },
            [F.meta(), #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"no time"}}"#],
            [F.meta(), #"{"type":"event_msg","timestamp":"\#(F.stamp(9))","payload":{"type":"task_complete"}}"#,
             F.message("developer", "note", at: 12)],
        ]
        for lines in cases {
            var folder = RolloutFolder()
            lines.forEach { folder.apply($0) }
            #expect(folder.finish() == CodexRolloutReducer.snapshot(for: lines))
        }
    }

    @Test
    func aFolderStartedFromASnapshotKeepsItsTimeUntilALineSetsOne() {
        var earlier = CodexRolloutSnapshot()
        CodexRolloutReducer.apply(line: F.event("task_complete", ["last_agent_message": "done"], at: 5), to: &earlier)
        var folder = RolloutFolder(earlier)
        folder.apply(F.message("developer", "note", at: 9))
        #expect(folder.finish().updatedAt == F.time(5))
        var later = RolloutFolder(earlier)
        later.apply(F.event("token_count", at: 9))
        #expect(later.finish().updatedAt == F.time(9))
    }
}
