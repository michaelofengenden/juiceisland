import Foundation
import IslandEngine
import Testing
@testable import JuiceIslandUI

/// Stream C: the window list's layout maths, row wording and plan steps.
@MainActor
struct CSessionListTests {
    typealias ID = FixtureSessionFeed.ID

    @Test
    func needsGridIsAutoFit() {
        // 1200 pt window: 1168 inside the list padding → two 579 pt columns; one card takes the full width.
        #expect(SessionListLayout.autoFitColumns(width: 1168, count: 2, minColumn: 430, gap: 10) == 2)
        #expect(SessionListLayout.autoFitColumns(width: 1168, count: 1, minColumn: 430, gap: 10) == 1)
        #expect(SessionListLayout.autoFitColumns(width: 1168, count: 3, minColumn: 430, gap: 10) == 2)
        #expect(SessionListLayout.columnWidth(width: 1168, columns: 2, gap: 10) == 579)
        // 900 pt: 868 < 430 · 2 + 10 → one column.
        #expect(SessionListLayout.autoFitColumns(width: 868, count: 2, minColumn: 430, gap: 10) == 1)
        #expect(SessionListLayout.autoFitColumns(width: 868, count: 0, minColumn: 430, gap: 10) == 0)
    }

    @Test
    func optionGridIsAutoFill() {
        // The card body at 1200 (579 − 20 − 49 = 510) takes two 190 pt option columns; at 900 (799) four.
        #expect(SessionListLayout.autoFillColumns(width: 510, minColumn: 190, gap: 6) == 2)
        #expect(SessionListLayout.autoFillColumns(width: 799, minColumn: 190, gap: 6) == 4)
        #expect(SessionListLayout.autoFillColumns(width: 100, minColumn: 190, gap: 6) == 1)
    }

    @Test
    func runningAndDoneStackUnder1000() {
        #expect(!SessionListLayout.stacksColumns(windowWidth: 1200))
        #expect(!SessionListLayout.stacksColumns(windowWidth: 1000))
        #expect(SessionListLayout.stacksColumns(windowWidth: 999))
    }

    @Test
    func columnsMatchThePrototype() throws {
        let model = FixtureSessionFeed(scenario: .prototype).makeModel()
        let columns = SessionListLayout.columns(model.rows)
        #expect(columns.running.map(\.id) == [ID.running])
        #expect(columns.codexGroup.map(\.id) == [ID.codexRunning, ID.codexIdle])
        #expect(columns.done.map(\.id) == [ID.codexDone])
        // One Claude session and one Codex session run; the idle Codex session sits in the group but is not counted.
        #expect(columns.runningCount == 2)
        #expect(columns.showsRunningCard)
        let now = model.now
        // The tool started 93 minutes ago and last reported 2 minutes ago: the group times the tool.
        let codexRunning = try #require(model.row(id: ID.codexRunning))
        #expect(SessionRowText.age(codexRunning.updatedAt, now: now) == "2m")
        #expect(SessionListLayout.groupStatus(codexRunning, now: now) == "Running tool · 93m")
        #expect(SessionRowText.runningTime(since: now - 30, now: now) == "now")
        #expect(SessionRowText.runningTime(since: now - 2 * 60, now: now) == "2m")
        #expect(SessionRowText.runningTime(since: now - 150 * 60, now: now) == "2h")
        #expect(SessionListLayout.groupStatus(model.row(id: ID.codexIdle)!, now: now) == "Idle · 18m")
    }

    /// The list glides when a session moves, comes or goes (P102), and only then: a row whose words change in place
    /// keeps the arrangement, and one that moves to another card changes it.
    @Test
    func theListsArrangementChangesOnlyWhenASessionMoves() throws {
        let rows = FixtureSessionFeed(scenario: .prototype).makeModel().rows
        func arrangement(_ rows: [SessionRow], needsOnly: Bool = false) -> [String] {
            SessionListLayout.arrangement(needsYou: rows.filter { $0.bucket == .needsYou }, columns: SessionListLayout.columns(rows),
                                          needsOnly: needsOnly)
        }
        var reworded = rows
        reworded[0].status = .thinking
        reworded[0].detail = "Another line"
        reworded[0].updatedAt += 60
        #expect(arrangement(reworded) == arrangement(rows))
        #expect(arrangement(rows, needsOnly: true) != arrangement(rows))
        let running = try #require(rows.firstIndex { $0.id == ID.running })
        var finished = rows
        finished[running].bucket = .done
        #expect(arrangement(finished) != arrangement(rows))
        #expect(arrangement(Array(rows.dropFirst())) != arrangement(rows))
    }

    @Test
    func allStatesKeepInterruptedAndClaudeDoneInDone() {
        let model = FixtureSessionFeed(scenario: .allStates).makeModel()
        let columns = SessionListLayout.columns(model.rows)
        #expect(Set(columns.running.map(\.id)) == [ID.running, ID.thinking])
        #expect(Set(columns.done.map(\.id)) == [ID.codexDone, ID.claudeDone, ID.interrupted])
        #expect(columns.running.count + columns.codexGroup.count + columns.done.count + model.needsYouCount == model.totalCount)
    }

    @Test
    func masonryFillsTheShortestColumn() {
        typealias P = SessionListLayout.Placement
        // Overview at 1200: approval (180) | question (360); Running goes under the short approval, Done under the
        // column that then ends highest (the question, 360 < 180 + 10 + 200).
        let overview = SessionListLayout.masonry(heights: [180, 360, 200, 100], columns: 2, gap: 10)
        #expect(overview.placements == [P(column: 0, y: 0), P(column: 1, y: 0), P(column: 0, y: 190), P(column: 1, y: 370)])
        #expect(overview.height == 470)
        // A third card goes under the shorter of the first two, not alone at the left of a new row.
        let three = SessionListLayout.masonry(heights: [300, 180, 360], columns: 2, gap: 10)
        #expect(three.placements == [P(column: 0, y: 0), P(column: 1, y: 0), P(column: 1, y: 190)])
        #expect(three.height == 550)
        // Ties go left; one column stacks in order; nothing is zero high.
        #expect(SessionListLayout.masonry(heights: [100, 100, 50], columns: 2, gap: 10).placements.map(\.column) == [0, 1, 0])
        let stacked = SessionListLayout.masonry(heights: [100, 50], columns: 1, gap: 10)
        #expect(stacked.placements == [P(column: 0, y: 0), P(column: 0, y: 110)] && stacked.height == 160)
        #expect(SessionListLayout.masonry(heights: [], columns: 2, gap: 10).height == 0)
    }

    @Test
    func runningAndDoneFlowIntoNeedsColumnsOnlyWhenTheyShareThem() {
        // Two or more Needs you columns at 1000 pt or wider: Running and Done fill in under the shortest one.
        #expect(SessionListLayout.flowsIntoNeedsColumns(needsColumns: 2, windowWidth: 1200))
        #expect(SessionListLayout.flowsIntoNeedsColumns(needsColumns: 3, windowWidth: 1600))
        // One Needs you card takes the full width, so Running and Done keep their own row below.
        #expect(!SessionListLayout.flowsIntoNeedsColumns(needsColumns: 1, windowWidth: 1200))
        // Narrow: everything stacks.
        #expect(!SessionListLayout.flowsIntoNeedsColumns(needsColumns: 2, windowWidth: 990))
    }

    @Test
    func longStatusLinesGetATooltip() {
        let long = SessionRowText.DetailedStatus(word: "Done", tone: .done, isPrompt: false,
                                                 text: "Wrote docs/release-checklist.md with 12 steps. The signing step needs your team id.")
        #expect(DetailedRowView.statusHelp(long) == "Done · Wrote docs/release-checklist.md with 12 steps. The signing step needs your team id.")
        let prompt = SessionRowText.DetailedStatus(word: "Interrupted", tone: .muted, isPrompt: true,
                                                   text: "refactor the hover model so that every row lifts the same way")
        #expect(DetailedRowView.statusHelp(prompt) == "Interrupted · You: refactor the hover model so that every row lifts the same way")
        let short = SessionRowText.DetailedStatus(word: "Needs approval", tone: .approval, isPrompt: false, text: "Bash")
        #expect(DetailedRowView.statusHelp(short).isEmpty)
    }

    @Test
    func footerAndRowTooltip() {
        // Needs you only: the other active sessions, never a total of history (P94).
        let now = Date(timeIntervalSince1970: 1_000_000)
        func row(_ id: String, _ bucket: SessionBucket, ago: TimeInterval) -> SessionRow {
            var row = DStub.row(id, .claude, bucket)
            row.updatedAt = now - ago
            return row
        }
        let asks = [row("q1", .needsYou, ago: 7_200), row("q2", .needsYou, ago: 60)]
        let history = (0..<25).map { row("old-\($0)", .done, ago: TimeInterval(3_600 + $0 * 600)) }
        let rows = asks + [row("r", .running, ago: 7_200), row("d", .done, ago: 14 * 60)] + history
        #expect(SessionListLayout.moreFooter(rows, now: now) == "2 more running or done · Show all")
        #expect(SessionListLayout.moreFooter(asks + history, now: now) == "Earlier")
        #expect(SessionListLayout.moreFooter(asks, now: now) == nil)
        let model = FixtureSessionFeed(scenario: .prototype).makeModel()
        let question = model.row(id: ID.question)!
        // C1: no jump hint unless the system-wide key is on and recorded.
        #expect(SessionListLayout.jumpHint(enabled: false, key: "ctrl+g") == nil)
        #expect(SessionListLayout.jumpHint(enabled: true, key: nil) == nil)
        // The row shows only the agent mark and the age; where it runs is the tooltip.
        #expect(SessionListLayout.rowHelp(question) == "Claude · Terminal")
        var elsewhere = question
        elsewhere.agent = .codex
        elsewhere.host = "Ghostty"
        elsewhere.accountAlias = "work"
        #expect(SessionListLayout.rowHelp(elsewhere) == "Codex · Ghostty · work")
        elsewhere.host = ""
        elsewhere.accountAlias = nil
        #expect(SessionListLayout.rowHelp(elsewhere) == "Codex")
        #expect(SessionListLayout.jumpHint(enabled: true, key: "ctrl+g") == "⌃G")
        #expect(SessionListLayout.jumpTargetID(model.rows) == model.needsYou.first?.id)
        #expect(KeyHint.display("shift+ctrl+a") == "⌃⇧A")
    }

    @Test
    func detailedRowWording() {
        let model = FixtureSessionFeed(scenario: .allStates).makeModel()
        func status(_ id: String) -> SessionRowText.DetailedStatus { SessionRowText.detailedStatus(model.row(id: id)!) }
        #expect(status(ID.question) == .init(word: "Question", tone: .approval, isPrompt: true, text: "JuiceBar, JuiceIsland or Sandbar…"))
        #expect(status(ID.approval) == .init(word: "Needs approval", tone: .approval, isPrompt: false, text: "Bash: git push -u origin window-mode"))
        #expect(status(ID.plan) == .init(word: "Plan ready", tone: .approval, isPrompt: false, text: "4 steps"))
        #expect(status(ID.running) == .init(word: nil, tone: .muted, isPrompt: true, text: "build the html mockups"))
        #expect(status(ID.codexDone) == .init(word: "Done", tone: .done, isPrompt: false, text: "wrote results/summary.md"))
        #expect(status(ID.interrupted).word == "Interrupted")
        #expect(SessionRowText.toolLine(model.row(id: ID.running)!)! == ("Edit", "Juice/Sources/JuiceUI/Island/JuiceIslandSectionView.swift"))
        #expect(SessionRowText.toolLine(model.row(id: ID.thinking)!)! == (nil, "Thinking"))
        // The repo once (P204): a title that names it as a word is not led by it again.
        #expect(SessionRowText.detailedTitle(model.row(id: ID.codexDone)!) == "Continue MarathonTrainingLog")
        #expect(SessionRowText.detailedTitle(model.row(id: ID.question)!) == "WeatherStation · Name the app")
        #expect(SessionRowText.cleanStatus(model.row(id: ID.plan)!) == .init(word: "Plan ready", tone: .approval, toolVerb: nil, text: "4 steps"))
    }

    @Test
    func planSteps() {
        #expect(SessionRowText.planSteps("1. a\n2. b\n  3) c\nnotes\n10. d") == 4)
        #expect(SessionRowText.planSteps("Just do it") == nil)
        #expect(SessionRowText.planSteps(nil) == nil)
        #expect(SessionRowText.stepsText(1) == "1 step")
    }

    @Test
    func codeCommentSplits() {
        #expect(CodeBlockView.split("git push # why") == ("git push", "# why"))
        #expect(CodeBlockView.split("echo '#1'") == ("echo '#1'", nil))
    }
}
