import Foundation
import IslandEngine
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// The pill counts active sessions: running, needing you, or finished within `SessionActivity.recentWindow`. A day
/// of finished history no longer reads as "30", a session leaves the count on the minute clock, and every list shows
/// the active sessions before the older finished ones.
@MainActor
@Suite(.serialized)
struct ActiveCountTests {
    static let now = DemoClock.now

    static func row(_ id: String, _ agent: GlyphPalette.Agent, _ bucket: SessionBucket, ago: TimeInterval,
                    status: StatusWord? = nil, detail: String? = "wrote it") -> SessionRow {
        var row = DStub.row(id, agent, bucket, status: status)
        row.updatedAt = now - ago
        row.detail = detail
        return row
    }

    /// The owner's board: 30 rows from a day of history, of which one needs you, one runs and one finished 5 minutes ago.
    static var thirtyRows: [SessionRow] {
        let older: [SessionRow] = (0..<27).map { index in
            let agent: GlyphPalette.Agent = index % 2 == 0 ? .claude : .codex
            let status: StatusWord = index % 5 == 0 ? .interrupted : .done
            let minutes = Double(20 + index * 50)
            return row("old-\(index)", agent, .done, ago: minutes * 60, status: status)
        }
        return [row("ask", .claude, .needsYou, ago: 5 * 3_600), row("run", .codex, .running, ago: 2 * 3_600),
                row("new", .claude, .done, ago: 5 * 60)] + older
    }

    // MARK: The rule

    @Test func aFinishedSessionIsActiveForFifteenMinutes() {
        #expect(SessionActivity.recentWindow == 15 * 60)
        for status: StatusWord in [.done, .interrupted] {
            #expect(SessionActivity.isActive(Self.row("d", .claude, .done, ago: 14 * 60 + 59, status: status), now: Self.now))
            #expect(!SessionActivity.isActive(Self.row("d", .claude, .done, ago: 15 * 60 + 1, status: status), now: Self.now))
        }
        // Running and waiting are active however long ago they last reported; a failed turn needs you, so it stays.
        #expect(SessionActivity.isActive(Self.row("r", .claude, .running, ago: 6 * 3_600), now: Self.now))
        #expect(SessionActivity.isActive(Self.row("q", .codex, .needsYou, ago: 6 * 3_600), now: Self.now))
        #expect(SessionActivity.isActive(Self.row("f", .claude, .needsYou, ago: 6 * 3_600, status: .failed), now: Self.now))
    }

    /// The clock set back: a row stamped a little ahead is still recent, one stamped 20 minutes ahead is not, so the
    /// count does not keep the jump's finished sessions for its whole length.
    @Test func aFinishedSessionAheadOfTheClockIsNotActiveForTheJump() {
        #expect(SessionActivity.isActive(Self.row("d", .claude, .done, ago: -60), now: Self.now))
        #expect(!SessionActivity.isActive(Self.row("d", .claude, .done, ago: -20 * 60), now: Self.now))
        #expect(SessionActivity.isActive(Self.row("r", .claude, .running, ago: -20 * 60), now: Self.now))
    }

    @Test func thirtyRowsWithThreeActiveCountThree() {
        let rows = Self.thirtyRows
        #expect(rows.count == 30)
        let active = PillSummary.make(rows: rows, countMode: .active, now: Self.now)
        #expect(active.count == 3)
        #expect(PillSummary.make(rows: rows, countMode: .needsYou, now: Self.now).count == 1)
        // Nothing active: no count at all.
        #expect(PillSummary.make(rows: Array(rows.dropFirst(3)), countMode: .active, now: Self.now).count == nil)
        #expect(PillSummary.spoken(3, mode: .active) == "3 active sessions")
        #expect(PillSummary.spoken(1, mode: .active) == "1 active session")
        #expect(PillSummary.spoken(1, mode: .needsYou) == "1 needs you")
        #expect(PillSummary.spoken(2, mode: .needsYou) == "2 need you")
    }

    // MARK: The minute clock

    /// A finished session ages out on the models' minute tick, with no event of its own: the read the pill makes (rows
    /// and the clock) changes, and the count drops.
    @Test func aFinishedSessionLeavesTheCountOnTheMinuteTick() {
        var now = Self.now
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        engine.loadPreviewEvents(Self.session("count-done", finishedAt: Self.now - (14 * 60 + 30))
            + Self.session("count-running", finishedAt: nil))
        let model = EngineSessionsModel(engine: engine, clock: { now })
        func count() -> Int? { PillSummary.make(rows: model.rows, countMode: .active, now: model.now).count }
        #expect(model.totalCount == 2 && count() == 2)
        let redraws = Redraws()
        redraws.watch { _ = count() }

        now += 20
        model.tick()
        #expect(redraws.count == 0 && count() == 2)

        now += 60
        model.tick()
        #expect(redraws.count == 1)
        #expect(count() == 1 && model.totalCount == 2)
    }

    // MARK: The setting

    @Test func theOldAllChoiceCarriesOverAsActive() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = AppSettings.Key.closedPillCount
        defaults.set("allSessions", forKey: key)
        #expect(AppSettings(defaults: defaults).closedPillCount == .active)
        defaults.set("needsYou", forKey: key)
        #expect(AppSettings(defaults: defaults).closedPillCount == .needsYou)
        defaults.set("something else", forKey: key)
        #expect(AppSettings(defaults: defaults).closedPillCount == .active)
        AppSettings(defaults: defaults).closedPillCount = .active
        #expect(defaults.string(forKey: key) == "active")
        #expect(AppSettings(defaults: defaults).closedPillCount == .active)
        #expect(PillCount.allCases == [.active, .needsYou])
    }

    // MARK: The lists

    /// The island: active sessions first (needs you, then what runs, a running Codex chat included, then what finished
    /// within 15 minutes), then the older finished ones; Show all still shows every row.
    @Test func theIslandShowsTheActiveSessionsFirst() {
        let rows = [Self.row("q", .claude, .needsYou, ago: 60), Self.row("old", .claude, .done, ago: 3_600),
                    Self.row("r", .claude, .running, ago: 60), Self.row("new", .claude, .done, ago: 5 * 60),
                    Self.row("idle-old", .codex, .done, ago: 3_600, detail: nil), Self.row("cx", .codex, .running, ago: 60)]
        let clean = IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: Self.now)
        #expect(clean.shown.map(\.id) == ["q", "r", "cx", "new"])
        #expect(clean.hidden.map(\.id) == ["old", "idle-old"] && clean.total == 6)
        let all = IslandListLayout.make(rows: rows, style: .detailed, showAll: true, now: Self.now)
        #expect(all.shown.map(\.id) == ["q", "r", "cx", "new", "old", "idle-old"])
        #expect(SessionListLayout.displayOrder(rows, now: Self.now) == all.shown)
    }

    /// P291: a running chat never sorts below a turn that finished minutes ago. The owner's Codex chat at work came
    /// after three fresh Done rows and fell behind "Show 1 more"; now it is listed with what runs, before them, and a
    /// Codex session idle at the prompt stays with what finished. Needs you still comes first.
    @Test func aRunningChatAlwaysComesBeforeRecentlyFinishedRows() {
        let rows = [Self.row("d1", .claude, .done, ago: 60), Self.row("d2", .claude, .done, ago: 2 * 60),
                    Self.row("d3", .codex, .done, ago: 3 * 60), Self.row("idle", .codex, .done, ago: 4 * 60, detail: nil),
                    Self.row("chat", .codex, .running, ago: 40 * 60), Self.row("r", .claude, .running, ago: 60),
                    Self.row("q", .codex, .needsYou, ago: 30 * 60)]
        #expect(SessionListLayout.displayOrder(rows, now: Self.now).map(\.id) == ["q", "r", "chat", "d1", "d2", "d3", "idle"])
        let clean = IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: Self.now)
        #expect(clean.shown.map(\.id) == ["q", "r", "chat", "d1"])
        #expect(clean.hiddenActive.map(\.id) == ["d2", "d3", "idle"] && clean.footerMarks == [.idle, .idle, .idle])
        // With only finished rows around it, the running chat leads the list.
        let quiet = IslandListLayout.make(rows: Array(rows.prefix(5)), style: .clean, showAll: false, now: Self.now)
        #expect(quiet.shown.first?.id == "chat")
    }

    // MARK: The footer (P94)

    /// Seven active sessions and three older finished ones: the four rows hide three active ones, so the footer reads
    /// "Show 3 more" with a mark for each of those three, never the ten it would show.
    @Test func theFooterCountsTheActiveRowsItHides() {
        let rows = [Self.row("q", .claude, .needsYou, ago: 60), Self.row("r1", .claude, .running, ago: 60),
                    Self.row("r2", .claude, .running, ago: 60), Self.row("r3", .claude, .running, ago: 60),
                    Self.row("new", .claude, .done, ago: 5 * 60),
                    Self.row("cx", .codex, .running, ago: 60), Self.row("new2", .claude, .done, ago: 14 * 60),
                    Self.row("old1", .claude, .done, ago: 3_600), Self.row("old2", .codex, .done, ago: 7_200),
                    Self.row("old3", .claude, .done, ago: 9_000, status: .interrupted)]
        let clean = IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: Self.now)
        #expect(clean.hidden.count == 6 && clean.hiddenActive.map(\.id) == ["cx", "new", "new2"])
        #expect(clean.footer == .more(3) && clean.footer.text == "Show 3 more")
        #expect(clean.footer.spoken == "Show 3 more active sessions")
        #expect(clean.footerMarks == [.running(.codex), .idle, .idle])
        // Detailed shows the hidden active Codex sessions in its Codex group: the footer counts only what stays hidden.
        let detailed = IslandListLayout.make(rows: rows, style: .detailed, showAll: false, now: Self.now)
        #expect(detailed.codexGroup.map(\.id) == ["cx"] && detailed.footer == .more(2) && detailed.showsFooter)
        #expect(IslandFooterLabel.more(1).text == "Show 1 more" && IslandFooterLabel.more(1).spoken == "Show 1 more active session")
    }

    /// Only older finished rows hidden: the footer reads "Earlier", with no number and no marks. The owner's board of
    /// 30 rows with 3 active reads the same, and Show all still shows all 30.
    @Test func theFooterReadsEarlierWhenItHidesOnlyOlderRows() {
        let rows = [Self.row("q", .claude, .needsYou, ago: 60), Self.row("r", .claude, .running, ago: 60),
                    Self.row("old1", .claude, .done, ago: 3_600), Self.row("old2", .codex, .done, ago: 7_200),
                    Self.row("old3", .claude, .done, ago: 15 * 60 + 1)]
        let layout = IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: Self.now)
        #expect(layout.hidden.count == 1)
        #expect(layout.hiddenActive.isEmpty && layout.footer == .earlier && layout.footer.text == "Earlier")
        #expect(layout.footer.spoken == "Show earlier sessions" && layout.footerMarks.isEmpty)

        let board = IslandListLayout.make(rows: Self.thirtyRows, style: .clean, showAll: false, now: Self.now)
        #expect(Set(board.shown.prefix(3).map(\.id)) == ["ask", "run", "new"] && board.hidden.count == 26)
        #expect(board.footer == .earlier && board.footerMarks.isEmpty)
        let all = IslandListLayout.make(rows: Self.thirtyRows, style: .clean, showAll: true, now: Self.now)
        #expect(all.shown.count == 30 && all.hidden.isEmpty)
        // Four rows or fewer: no footer at all.
        #expect(IslandListLayout.make(rows: Array(rows.prefix(4)), style: .clean, showAll: false, now: Self.now).hidden.isEmpty)
    }

    /// Detailed's Codex group lists the active Codex sessions the rows hide, never hours of history: the older Codex rows
    /// wait behind "Earlier" with the rest, and with no older row the footer does not show at all.
    @Test func detailedsCodexGroupListsOnlyActiveSessions() {
        let active = [Self.row("q", .claude, .needsYou, ago: 60), Self.row("r1", .claude, .running, ago: 60),
                      Self.row("r2", .claude, .running, ago: 60), Self.row("r3", .claude, .running, ago: 60),
                      Self.row("cx", .codex, .running, ago: 60)]
        let history = (0..<12).map { Self.row("old-\($0)", .codex, .done, ago: TimeInterval(3_600 + $0 * 3_600)) }
        let layout = IslandListLayout.make(rows: active + history, style: .detailed, showAll: false, now: Self.now)
        #expect(layout.codexGroup.map(\.id) == ["cx"])
        #expect(layout.showsFooter && layout.footer == .earlier && layout.hiddenActive.isEmpty)
        let bare = IslandListLayout.make(rows: active, style: .detailed, showAll: false, now: Self.now)
        #expect(bare.codexGroup.map(\.id) == ["cx"] && !bare.showsFooter)
        // Show all shows every row, the group's included.
        #expect(IslandListLayout.make(rows: active + history, style: .detailed, showAll: true, now: Self.now).shown.count == 17)
    }

    /// A finished row that ages out on the minute clock leaves the footer's number with it.
    @Test func theFooterAgesOutWithTheClock() {
        let rows = [Self.row("r1", .claude, .running, ago: 60), Self.row("r2", .claude, .running, ago: 60),
                    Self.row("r3", .codex, .running, ago: 60), Self.row("r4", .codex, .running, ago: 60),
                    Self.row("done", .claude, .done, ago: 14 * 60)]
        #expect(IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: Self.now).footer == .more(1))
        #expect(IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: Self.now + 61).footer == .earlier)
    }

    /// Detailed's footer under a card counts the other active sessions, not the card's own.
    @Test func theFooterUnderACardCountsTheOtherActiveSessions() {
        let rows = [Self.row("q", .claude, .needsYou, ago: 60), Self.row("r", .claude, .running, ago: 60),
                    Self.row("old", .claude, .done, ago: 3_600)]
        #expect(IslandFooterLabel.underCard("q", rows: rows, now: Self.now) == .more(1))
        #expect(IslandFooterLabel.underCard("q", rows: [rows[0], rows[2]], now: Self.now) == .earlier)
    }

    /// The window: Done keeps its history, the recent ones on top; the Codex group's idle sessions likewise.
    @Test func theWindowCardsKeepTheirHistoryUnderTheActiveOnes() {
        let rows = [Self.row("old", .claude, .done, ago: 3_600), Self.row("new", .claude, .done, ago: 5 * 60),
                    Self.row("idle-old", .codex, .done, ago: 3_600, detail: nil), Self.row("idle-new", .codex, .done, ago: 60, detail: nil),
                    Self.row("cx", .codex, .running, ago: 60)]
        let columns = SessionListLayout.columns(SessionActivity.activeFirst(rows, now: Self.now))
        #expect(columns.done.map(\.id) == ["new", "old"])
        #expect(columns.codexGroup.map(\.id) == ["cx", "idle-new", "idle-old"])
    }

    // MARK: Events

    /// A Claude session with a prompt, running, or finished at `finishedAt`.
    static func session(_ id: String, finishedAt: Date?) -> [AgentEvent] {
        let started = now - 2 * 3_600
        var events: [AgentEvent] = [
            .sessionStarted(SessionStarted(sessionID: id, title: id, tool: .claudeCode, origin: .live, initialPhase: .running,
                                           summary: "Started.", timestamp: started,
                                           jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "demo", paneTitle: "claude",
                                                                  workingDirectory: "/tmp/demo"),
                                           claudeMetadata: ClaudeSessionMetadata(lastUserPrompt: "start"))),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: FixtureSessionFeed.promptPrefix + "start",
                                                    phase: .running, timestamp: started + 1)),
        ]
        if let finishedAt {
            events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: finishedAt)))
        }
        return events
    }
}
