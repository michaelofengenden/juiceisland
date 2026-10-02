import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// What's new (P716): the note update-app.sh leaves beside the status file reads as its subjects in plain words; the
/// build it names shows it once as a card (marked shown at once, so the next launch of that build shows none) and
/// About keeps it; another build, the same build, a note with nothing in it or none at all show nothing.
@MainActor
@Suite(.serialized)
struct WhatsNewTests {
    static let old = String(repeating: "1", count: 40)
    static let new = String(repeating: "2", count: 40)

    static func file(from: String = old, to: String = new, count: Int = 5, _ subjects: [String]) -> String {
        (["from:\(from)", "to:\(to)", "count:\(count)"] + subjects).joined(separator: "\n") + "\n"
    }

    @Test func aNoteReadsAsItsSubjectsInPlainWords() throws {
        let note = try #require(WhatsNewNote(text: Self.file(["Keep  the island's   card short.", "", "Add What's new..", " Fix a crash "])))
        #expect(note.from == Self.old && note.to == Self.new && note.count == 5)
        #expect(note.subjects == ["Keep the island's card short", "Add What's new", "Fix a crash"])
        #expect(note.lines(limit: 2) == (["Keep the island's card short", "Add What's new"], 3))
        #expect(note.lines(limit: 10).more == 2)
        // A count below the subjects listed (a hand-edited file) never makes "and -1 more".
        #expect(WhatsNewNote(text: Self.file(count: 1, ["A", "B"]))?.lines(limit: 5).more == 0)
        #expect(WhatsNewNote(text: Self.file([])) == nil)
        #expect(WhatsNewNote(text: "to:\(Self.new)\nfrom:\(Self.old)\ncount:1\nA\n") == nil)
        #expect(WhatsNewNote(text: "from:\(Self.old)\nto:\(Self.new)\ncount:many\nA\n") == nil)
        #expect(WhatsNewNote(text: "") == nil)
    }

    @Test func aNoteBelongsToTheBuildItOpenedOnly() throws {
        let note = try #require(WhatsNewNote(text: Self.file(["A"])))
        #expect(note.belongs(to: Self.new) && note.belongs(to: Self.new.uppercased()))
        #expect(!note.belongs(to: Self.old) && !note.belongs(to: nil) && !note.belongs(to: ""))
        let same = try #require(WhatsNewNote(text: Self.file(from: Self.new, ["A"])))
        #expect(!same.belongs(to: Self.new))
    }

    /// The card shows on the first launch of the build the note names, and is marked shown at once; the next launch
    /// keeps the note for About without the card; ✕ hides it.
    @Test func theCardShowsOnceAndAboutKeepsTheNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-whatsnew-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = UpdateController.Paths(statusFile: root.appendingPathComponent("update-status"), logFile: root.appendingPathComponent("update.log"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.file(["Add What's new", "Prepare updates in the background"]).write(to: paths.whatsNewFile, atomically: true, encoding: .utf8)
        var shown: String?
        func controller(_ commit: String?) -> UpdateController {
            UpdateController(repoPath: "/tmp/repo", commit: commit, paths: paths, bundlePath: "/tmp/Juice Island.app",
                             context: UpdateController.Context(shownWhatsNew: { shown }, markWhatsNewShown: { shown = $0 }))
        }
        let first = controller(Self.new)
        first.restoreAfterLaunch()
        #expect(first.showsWhatsNewCard && first.whatsNew?.subjects.count == 2 && shown == Self.new)
        first.dismissWhatsNew()
        #expect(!first.showsWhatsNewCard && first.whatsNew != nil)

        let second = controller(Self.new)
        second.restoreAfterLaunch()
        #expect(!second.showsWhatsNewCard && second.whatsNew?.to == Self.new)

        for commit in [Self.old, nil] {
            let other = controller(commit)
            other.restoreAfterLaunch()
            #expect(!other.showsWhatsNewCard && other.whatsNew == nil)
        }
    }

    /// The card draws nothing until a note shows, then a few lines; every subject past them is "and N more".
    @Test func theCardDrawsNothingWithoutANote() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let bare = NSHostingView(rootView: WhatsNewCard().environment(env))
        #expect(bare.fittingSize.height == 0)
        let shown = NSHostingView(rootView: WhatsNewCard().environment(try Self.env(subjects: 7)))
        #expect(shown.fittingSize.height > 60)
    }

    /// An environment whose controller read a note of `subjects` for this build, its card showing (renders use it).
    static func env(subjects count: Int, sessions: FixtureSessionFeed.Scenario = .prototype, phase: UpdatePhase = .idle,
                    listOpen: Bool = false) throws -> AppEnvironment {
        let subjects = Array(sampleSubjects.prefix(count))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-whatsnew-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = UpdateController.Paths(statusFile: root.appendingPathComponent("update-status"), logFile: root.appendingPathComponent("update.log"))
        try file(count: count + 9, subjects).write(to: paths.whatsNewFile, atomically: true, encoding: .utf8)
        let controller = UpdateController(repoPath: "/tmp/juice-island", build: String(new.prefix(7)), commit: new, paths: paths,
                                          bundlePath: "/tmp/Juice Island.app", phase: phase)
        controller.restoreAfterLaunch()
        controller.showsWhatsNewList = listOpen
        let stamp = BuildStamp(commit: new, date: Date(timeIntervalSince1970: 1_790_236_800), repoPath: "/tmp/juice-island")
        let checker = UpdateChecker(stamp: stamp, git: NoGitRunner(),
                                    state: .checked(UpdateInfo(newer: 0, subjects: [], tip: new), at: Date(timeIntervalSince1970: 1_790_236_800)))
        return .demo(sessions: sessions, updateChecker: checker, updateController: controller)
    }

    static let sampleSubjects = [
        "Prepare updates in the background and offer Restart to update",
        "Show what changed after an update, once",
        "Keep typed tags in prompts and treat a hook-made Codex app thread as the app's",
        "Hold Liquid's panel to the fit's tolerance, keep the belly off a bud, and frost the hover chip",
        "Stop the island's pill from flickering on a second display",
        "Read the build stamp from Info.plist",
        "Name the update log in About",
    ]
}
