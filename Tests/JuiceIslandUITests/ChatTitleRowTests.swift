import AppKit
import Foundation
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Rows and card headers say the chat's title (P200-P205): the agent's own, else the first prompt, else the repo; the
/// title updates when the agent renames; the repo is said once; the status line never repeats the title's prompt.
@MainActor
struct ChatTitleRowTests {
    typealias ID = FixtureSessionFeed.ID

    private func row(_ id: String = "r", task: String = "Fix the upload test", source: TitleSource = .agent, project: String = "notes-site",
                     status: StatusWord = .working, lastPrompt: String? = "fix the flaky upload test") -> SessionRow {
        SessionRow(id: id, agent: .claude, bucket: .running, project: project, task: task, status: status, detail: nil, lastPrompt: lastPrompt,
                   host: "Terminal", accountAlias: "work", updatedAt: DemoClock.now, isCodexApp: false, glyph: .eq, glyphState: .running,
                   hasCard: false, titleSource: source)
    }

    /// The fixtures' titles come in as each agent writes them (a Claude `ai-title` line, a Codex index line) and never
    /// say the agent; every other agent's row says its first prompt.
    @Test
    func rowsSayTheChatsTitle() throws {
        let model = FixtureSessionFeed(scenario: .allStates).makeModel()
        let question = try #require(model.row(id: ID.question))
        #expect(question.task == "Name the app" && question.titleSource == .agent && question.project == "WeatherStation")
        let codex = try #require(model.row(id: ID.codexIdle))
        #expect(codex.task == "Draft release notes" && codex.titleSource == .agent)
        for row in model.rows {
            #expect(!row.task.hasPrefix("Claude ·") && !row.task.hasPrefix("Codex ·"), "\(row.id)")
        }
        let owner = FixtureSessionFeed(scenario: .owner).makeModel()
        for row in owner.rows where row.titleSource != .agent { #expect(row.titleSource == .prompt, "\(row.id)") }
    }

    /// A rename lands on the row at once: Claude's `/rename` line, a clear back to the generated title, and Codex's
    /// renamed thread.
    @Test
    func aRenameRedrawsTheRow() throws {
        let feed = FixtureSessionFeed(scenario: .allStates)
        let model = feed.makeModel()
        #expect(model.row(id: ID.question)?.task == "Name the app")
        feed.engine.loadPreviewTranscript(sessionID: ID.question, lines: [FixtureSessionFeed.claudeTitleLine(ID.question, kind: .custom, "app-name")])
        #expect(model.row(id: ID.question)?.task == "app-name")
        feed.engine.loadPreviewTranscript(sessionID: ID.question, lines: [FixtureSessionFeed.claudeTitleLine(ID.question, kind: .custom, "")])
        #expect(model.row(id: ID.question)?.task == "Name the app")
        #expect(model.card(for: ID.question) != nil)
        feed.engine.loadPreviewCodexIndex(lines: [FixtureSessionFeed.codexIndexLine(ID.codexIdle, "Release notes, v2")])
        #expect(model.row(id: ID.codexIdle)?.task == "Release notes, v2")
        feed.engine.loadPreviewCodexIndex(lines: [FixtureSessionFeed.codexIndexLine(ID.codexIdle, "")])
        let cleared = try #require(model.row(id: ID.codexIdle))
        #expect(cleared.task == "draft the release notes" && cleared.titleSource == .prompt)
    }

    /// The repo once per surface (P204): the grey prefix on the window's and Detailed rows, none when the title is the
    /// repo or already names it; the island's Clean row shows the title alone and its mark's tooltip the repo.
    @Test
    func theRepoIsSaidOnce() {
        #expect(SessionRowText.cleanTitle(row()) == ("notes-site", "Fix the upload test"))
        #expect(SessionRowText.detailedTitle(row()) == "notes-site · Fix the upload test")
        let repo = row(task: "notes-site", source: .repo)
        #expect(SessionRowText.cleanTitle(repo) == (nil, "notes-site"))
        #expect(SessionRowText.detailedTitle(repo) == "notes-site")
        #expect(SessionListLayout.rowHelp(repo, naming: true) == "Claude · Terminal · work")
        #expect(SessionRowText.cleanTitle(row(task: "Continue MarathonTrainingLog", project: "MarathonTrainingLog")).project == nil)
        #expect(SessionRowText.cleanTitle(row(task: "Rename the apps folder", project: "app")).project == "app")
        #expect(IslandRowText.title(row()) == "Fix the upload test")
        #expect(SessionListLayout.rowHelp(row(), naming: true) == "Claude · notes-site · Terminal · work")
        #expect(SessionListLayout.rowHelp(row()) == "Claude · Terminal · work")
        #expect(EngineSessionsModel.title(nil, project: "", agent: .codex) == ("Codex", .repo))
    }

    /// A title that is the first prompt is not said again on the status line (P203): a first turn reads "Working", a
    /// question its question; a later prompt, or a title of the agent's own, still shows.
    @Test
    func theStatusLineNeverRepeatsTheTitlesPrompt() {
        let first = row(task: "fix the flaky upload test", source: .prompt)
        #expect(SessionRowText.shownPrompt(first) == nil)
        #expect(SessionRowText.cleanStatus(first).text == "Working")
        #expect(IslandRowText.status(first).text == "Working")
        #expect(DetailedRowText.status(first) == DetailedRowText.Status(word: nil, tone: .plain, prompt: nil, text: "Working"))
        #expect(SessionRowText.detailedStatus(first) == SessionRowText.DetailedStatus(word: nil, tone: .muted, isPrompt: false, text: "Working"))
        var asking = first
        asking.status = .question
        asking.detail = "Which test runner?"
        #expect(SessionRowText.cleanStatus(asking).text == "Which test runner?")
        #expect(SessionRowText.detailedStatus(asking).text == "Which test runner?" && !SessionRowText.detailedStatus(asking).isPrompt)
        var thinking = first
        thinking.status = .thinking
        #expect(SessionRowText.toolLine(thinking) == nil)
        var later = first
        later.lastPrompt = "now push it"
        #expect(SessionRowText.cleanStatus(later).text == "now push it")
        #expect(SessionRowText.detailedStatus(later).isPrompt)
        let own = row(task: "fix the flaky upload test", source: .agent)
        #expect(SessionRowText.cleanStatus(own).text == "fix the flaky upload test")
        // A prompt the model clipped to a title's length still matches it.
        let long = String(repeating: "word ", count: 60)
        var clipped = row(task: ChatTitleText.clean(long)!, source: .prompt)
        clipped.lastPrompt = long
        #expect(SessionRowText.shownPrompt(clipped) == nil)
    }

    /// A long title's whole text is its tooltip; a short one has none. What counts is the text the row shows: the
    /// grey `repo · ` before the title takes room too, so a 48-character title after a long repo is cut and has one.
    @Test
    func aLongTitleHasItsTextInItsTooltip() {
        #expect(SessionRowText.titleHelp(row()) == "")
        let long = "Publish the validated additive dashboard and its checks to the team"
        #expect(SessionRowText.titleHelp(row(task: long)) == long)
        let cut = row(task: "compare the three runs and write up what changed", source: .prompt, project: "MarathonTrainingLog")
        #expect(cut.task.count == 48)
        #expect(SessionRowText.titleHelp(cut) == cut.task)
        // The island's Clean row shows the title alone, which fits.
        #expect(SessionRowText.titleHelp(cut, showsProject: false) == "")
        // The repo left off (the title is the repo): nothing added.
        #expect(SessionRowText.titleHelp(row(task: "notes-site", source: .repo)) == "")
    }

    /// Detailed's Codex group keeps to the island's width whatever its titles say: a first prompt (up to 200
    /// characters) is cut at the tail, never laid out wider than the island (P209).
    @Test
    func aLongTitleNeverWidensTheIslandsCodexGroup() {
        var long = row(task: String(repeating: "compare the three eval runs ", count: 7), source: .prompt)
        long.agent = .codex
        let width: CGFloat = 460
        let group = NSHostingController(rootView: IslandCodexGroup(rows: [long, row("short")]).environment(AppEnvironment.demo()))
        #expect(group.sizeThatFits(in: CGSize(width: width, height: 1_000)).width <= width)
    }

    /// The island's tooltips (a row mark's repo on the Clean list, a long title's text) show while another app is in
    /// front: the island is a panel that never makes Juice Island the active app (P210). Never ordered in.
    @Test
    func theIslandShowsItsTooltipsWhileAnotherAppIsInFront() {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 185, height: 32), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        #expect(panel.allowsToolTipsWhenApplicationIsInactive)
    }
}
