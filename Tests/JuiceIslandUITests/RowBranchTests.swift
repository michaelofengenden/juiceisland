import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P433 to P436: a compacting row's time, and a row's branch (`GitHead`, `GitBranches`). Every repository here is a folder
/// the test makes under the temporary folder, with a home of its own: nothing of the Mac's is read.
@MainActor
@Suite(.serialized)
struct RowBranchTests {
    typealias ID = FixtureSessionFeed.DetailsID

    // MARK: Compacting (P433)

    @Test func theCompactionsClockReadsMinutesAndSeconds() {
        #expect(CompactionText.clock(0) == "0:00" && CompactionText.clock(42.9) == "0:42" && CompactionText.clock(754) == "12:34")
        #expect(CompactionText.clock(3_725) == "1:02:05" && CompactionText.clock(-3) == "0:00")
        #expect(CompactionText.word(since: nil, now: Date()) == "Compacting")
        #expect(CompactionText.word(since: Date(timeIntervalSince1970: 0), now: nil) == "Compacting")
    }

    @Test func theClockMovesOnlyWhileItsRowCanBeSeen() {
        #expect(CompactionText.ticks(animated: true, hidden: false, still: false, scrolledAway: false))
        #expect(!CompactionText.ticks(animated: false, hidden: false, still: false, scrolledAway: false))
        #expect(!CompactionText.ticks(animated: true, hidden: true, still: false, scrolledAway: false))
        #expect(!CompactionText.ticks(animated: true, hidden: false, still: true, scrolledAway: false))
        #expect(!CompactionText.ticks(animated: true, hidden: false, still: false, scrolledAway: true))
    }

    @Test func aCompactingRowSaysForHowLong() throws {
        let feed = FixtureSessionFeed(scenario: .details)
        let model = feed.makeModel()
        let row = try #require(model.row(id: ID.compacting))
        #expect(row.status == .compacting)
        #expect(row.compactingSince == feed.now.addingTimeInterval(-FixtureSessionFeed.detailsCompactingFor))
        #expect(SessionRowText.cleanStatus(row, now: feed.now).text == "Compacting 0:42")
        #expect(SessionRowText.cleanStatus(row).text == "Compacting")
        #expect(DetailedRowText.status(row, now: feed.now.addingTimeInterval(60)).word == "Compacting 1:42")
        // The window's row: with a prompt on line 2, the time is on the tool line.
        #expect(SessionRowText.toolLine(row, now: feed.now)?.text == "Compacting 0:42")
        // Every other row has no count, so its line runs nothing.
        #expect(model.rows.filter { $0.id != ID.compacting }.allSatisfy { $0.compactingSince == nil })
    }

    // MARK: Reading HEAD (P434, P435)

    /// A home of the test's own, under the temporary folder, removed after.
    private struct Home {
        let path: String

        init() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            path = base.appendingPathComponent("ji-branch-\(UUID().uuidString)/home").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        func folder(_ relative: String) throws -> String {
            let folder = path + "/" + relative
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            return folder
        }

        func write(_ relative: String, _ text: String) throws {
            let file = path + "/" + relative
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: file, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        func read(_ relative: String) -> GitHead.Read { GitHead.read(folder: path + "/" + relative, home: path) }
    }

    @Test func aRepositorysBranchFromAnyFolderInIt() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Developer/app/.git/HEAD", "ref: refs/heads/feature/search\n")
        _ = try home.folder("Developer/app/Sources/Deep")
        #expect(home.read("Developer/app") == .branch("feature/search", isDefault: false))
        #expect(home.read("Developer/app/Sources/Deep") == .branch("feature/search", isDefault: false))
        // With no origin, main and master are the default.
        try home.write("Developer/app/.git/HEAD", "ref: refs/heads/main\n")
        #expect(home.read("Developer/app") == .branch("main", isDefault: true))
        // Origin's HEAD names the default when there is one.
        try home.write("Developer/app/.git/refs/remotes/origin/HEAD", "ref: refs/remotes/origin/trunk\n")
        #expect(home.read("Developer/app") == .branch("main", isDefault: false))
        try home.write("Developer/app/.git/HEAD", "ref: refs/heads/trunk\n")
        #expect(home.read("Developer/app") == .branch("trunk", isDefault: true))
        // A commit checked out, a file git never writes, a name no branch has.
        try home.write("Developer/app/.git/HEAD", String(repeating: "a1", count: 20) + "\n")
        #expect(home.read("Developer/app") == .detached)
        try home.write("Developer/app/.git/HEAD", "hello\n")
        #expect(home.read("Developer/app") == .none)
        try home.write("Developer/app/.git/HEAD", "ref: refs/heads/two words\n")
        #expect(home.read("Developer/app") == .none)
    }

    @Test func aLinkedWorktreeAndASubmoduleFollowTheirGitFile() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Developer/app/.git/HEAD", "ref: refs/heads/main\n")
        try home.write("Developer/app/.git/refs/remotes/origin/HEAD", "ref: refs/remotes/origin/main\n")
        // `git worktree add ../app-wt -b wt/one`: a `.git` file, and the worktree's own git folder naming the common one.
        try home.write("Developer/app-wt/.git", "gitdir: \(home.path)/Developer/app/.git/worktrees/app-wt\n")
        try home.write("Developer/app/.git/worktrees/app-wt/HEAD", "ref: refs/heads/wt/one\n")
        try home.write("Developer/app/.git/worktrees/app-wt/commondir", "../..\n")
        #expect(home.read("Developer/app-wt") == .branch("wt/one", isDefault: false))
        // A worktree on the default branch is on it too.
        try home.write("Developer/app/.git/worktrees/app-wt/HEAD", "ref: refs/heads/main\n")
        #expect(home.read("Developer/app-wt") == .branch("main", isDefault: true))
        // A submodule: a relative `gitdir:`.
        try home.write("Developer/app/Vendor/lib/.git", "gitdir: ../../.git/modules/lib\n")
        try home.write("Developer/app/.git/modules/lib/HEAD", "ref: refs/heads/release\n")
        #expect(home.read("Developer/app/Vendor/lib") == .branch("release", isDefault: false))
        // A `.git` file that says nothing of a git folder.
        try home.write("Developer/odd/.git", "not a gitdir\n")
        #expect(home.read("Developer/odd") == .none)
    }

    @Test func nothingAboveTheHomeFolderOrNoRepositoryAtAll() throws {
        let home = try Home()
        defer { home.remove() }
        // A repository above the home folder is never taken for the folder's (the walk stops at home).
        try FileManager.default.createDirectory(atPath: (home.path as NSString).deletingLastPathComponent + "/.git", withIntermediateDirectories: true)
        try "ref: refs/heads/above\n".write(toFile: (home.path as NSString).deletingLastPathComponent + "/.git/HEAD", atomically: true, encoding: .utf8)
        _ = try home.folder("Developer/plain")
        #expect(home.read("Developer/plain") == .none)
        #expect(GitHead.read(folder: "relative/path", home: home.path) == .none)
    }

    /// Folders macOS guards with a privacy prompt are never read, nor reached through a link (P435).
    @Test func guardedPlacesAreNeverRead() throws {
        let home = try Home()
        defer { home.remove() }
        for place in GitHead.guardedHomeFolders {
            try home.write("\(place)/repo/.git/HEAD", "ref: refs/heads/secret\n")
            #expect(home.read("\(place)/repo") == .none, "\(place)")
        }
        // A link from a folder that is not guarded into one that is.
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Developer-link", withDestinationPath: home.path + "/Documents")
        #expect(home.read("Developer-link/repo") == .none)
        // A worktree whose git folder is in a guarded place.
        try home.write("Developer/wt/.git", "gitdir: \(home.path)/Documents/repo/.git\n")
        #expect(home.read("Developer/wt") == .none)
        #expect(GitHead.isGuarded("/Volumes/Backup/repo", home: home.path))
        #expect(!GitHead.isGuarded(home.path + "/DocumentsOld/repo", home: home.path))
        // A link that stays out of them is followed.
        try home.write("Developer/real/.git/HEAD", "ref: refs/heads/linked\n")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Developer/alias", withDestinationPath: "real")
        #expect(home.read("Developer/alias") == .branch("linked", isDefault: false))
    }

    // MARK: When it is read (P436)

    /// A live source whose reads are counted and recorded, answering from `answers`.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: [String] = []
        private var onMain: [Bool] = []
        var answers: [String: GitHead.Read] = [:]
        func read(_ folder: String) -> GitHead.Read {
            lock.withLock {
                folders.append(folder)
                onMain.append(Thread.isMainThread)
                return answers[folder] ?? .none
            }
        }
        var all: [String] { lock.withLock { folders } }
        var anyOnMain: Bool { lock.withLock { onMain.contains(true) } }
    }

    private func settle(_ branches: GitBranches) async {
        for _ in 0..<50 { await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func aFolderIsReadOffTheMainThreadWhenASessionStartsOrEndsATurnOnly() async {
        let reads = Reads()
        reads.answers = ["/r/app": .branch("feature", isDefault: false), "/r/main": .branch("main", isDefault: true)]
        let branches = GitBranches(.live(read: { reads.read($0) }))
        var changes = 0
        branches.changed = { changes += 1 }
        // Nothing known yet: Claude's worktree name stands in, never main or master.
        #expect(branches.branch(folder: "/r/app", session: "s1", moment: .working, metadata: "wt-name") == "wt-name")
        #expect(branches.branch(folder: "/r/main", session: "s2", moment: .working, metadata: "master") == nil)
        await settle(branches)
        #expect(changes == 2)
        #expect(branches.branch(folder: "/r/app", session: "s1", moment: .working, metadata: "wt-name") == "feature")
        #expect(branches.branch(folder: "/r/main", session: "s2", moment: .working, metadata: nil) == nil)
        // Mapped again and again in the same moment: no read.
        for _ in 0..<20 { _ = branches.branch(folder: "/r/app", session: "s1", moment: .working, metadata: nil) }
        await settle(branches)
        #expect(reads.all.count == 2)
        // The turn ends: read again; the same answer redraws nothing.
        _ = branches.branch(folder: "/r/app", session: "s1", moment: .done, metadata: nil)
        await settle(branches)
        #expect(reads.all.count == 3 && changes == 2)
        // A branch switched before the next turn shows once it starts.
        reads.answers["/r/app"] = .branch("other", isDefault: false)
        _ = branches.branch(folder: "/r/app", session: "s1", moment: .working, metadata: nil)
        await settle(branches)
        #expect(changes == 3)
        #expect(branches.branch(folder: "/r/app", session: "s1", moment: .working, metadata: nil) == "other")
        // A detached HEAD shows nothing, not the worktree's name.
        reads.answers["/r/app"] = .detached
        _ = branches.branch(folder: "/r/app", session: "s1", moment: .done, metadata: "wt-name")
        await settle(branches)
        #expect(branches.branch(folder: "/r/app", session: "s1", moment: .done, metadata: "wt-name") == nil)
        #expect(!reads.anyOnMain)
        #expect(branches.readCount == reads.all.count)
    }

    @Test func theDemoAndRendersReadNothing() throws {
        let feed = FixtureSessionFeed(scenario: .details)
        let branches = GitBranches(.fixed(feed.branchReads))
        let model = EngineSessionsModel(engine: feed.engine, clock: { feed.now }, branches: branches)
        #expect(model.row(id: ID.compacting)?.branch == "search-index")
        #expect(model.row(id: ID.codexBranch)?.branch == "settings-store")
        #expect(model.row(id: ID.onMain)?.branch == nil)
        #expect(model.row(id: ID.longBranch)?.branch == FixtureSessionFeed.detailsLongBranch)
        #expect(branches.readCount == 0)
        // Every other scenario reads nothing either, and shows Claude's worktree name alone.
        let prototype = FixtureSessionFeed(scenario: .prototype).makeModel()
        #expect(prototype.row(id: FixtureSessionFeed.ID.approval)?.branch == "window-mode")
    }

    @Test func aCleanRowsPeekSaysItsBranchAndADetailedOneLeavesItToTheRow() async throws {
        let model = FixtureSessionFeed(scenario: .details).makeModel()
        let clean = try #require(await model.peek(ID.codexBranch, clean: true))
        #expect(clean.branch == "settings-store")
        let detailed = await model.peek(ID.codexBranch, clean: false)
        #expect(detailed?.branch == nil)
    }

    // MARK: Detailed rows at larger text (P492)

    /// A Detailed row's branch on line 2 is as wide as its name, up to its cap; short of room it is cut further, so the state
    /// word and the title keep theirs. The window's and the peek's tag keep their width.
    @Test func aDetailedRowsBranchGivesWayBeforeTheStateWord() {
        func width(_ view: some View, _ offered: CGFloat) -> CGFloat {
            NSHostingController(rootView: view.environment(\.islandSize, IslandSize(width: 480, text: 15)))
                .sizeThatFits(in: CGSize(width: offered, height: 40)).width
        }
        let short = width(IslandBranchTag(branch: "main-fix", yields: true), 400)
        let cap = width(IslandBranchTag(branch: String(repeating: "long-branch-", count: 8), yields: true), 400)
        #expect(short < cap - 20, "\(short) vs \(cap)")
        #expect(width(IslandBranchTag(branch: "search-index", yields: true), 40) <= 40)
        #expect(width(IslandBranchTag(branch: "search-index"), 40) > 40)
    }
}
