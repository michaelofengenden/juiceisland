import AppKit
import Foundation
import IslandEngine
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The rows lane (P310-P312): models, modes and task progress on Detailed rows and in a Clean row's peek; the peek's
/// contents, dwell and room; a stalled run's row and its one quiet notice. Sessions: `FixtureSessionFeed.Scenario.rows`.
@MainActor
@Suite(.serialized)
struct RowFeaturesTests {
    typealias ID = FixtureSessionFeed.RowsID
    static let limit: TimeInterval = 600

    final class Clock {
        var now = DemoClock.now
        /// The Mac's awake time (`ProcessInfo.systemUptime`): it stands still while the Mac sleeps.
        var uptime: TimeInterval = 1_000
    }

    private func model(stalledAfter: TimeInterval? = limit, clock: Clock = Clock()) -> (FixtureSessionFeed, EngineSessionsModel) {
        let feed = FixtureSessionFeed(scenario: .rows, now: DemoClock.now)
        return (feed, EngineSessionsModel(engine: feed.engine, clock: { clock.now }, stalledAfter: { stalledAfter }))
    }

    // MARK: Facts (P310)

    @Test(arguments: [
        ("claude-opus-5-5[1m]", "Opus 5.5"), ("claude-opus-4-1-20250805", "Opus 4.1"), ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
        ("claude-sonnet-4-5", "Sonnet 4.5"), ("claude-haiku-4-5-20251001", "Haiku 4.5"), ("gpt-6-astra", "GPT-6 Astra"),
        ("gpt-5.1-codex-max", "GPT-5.1 Codex Max"), ("gpt-4o", "GPT-4o"), ("o3", "o3"), ("o4-mini", "o4 Mini"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
    ])
    func modelsAreNamedAsARowSaysThem(_ raw: String, _ name: String) {
        #expect(ModelName.short(raw) == name)
    }

    @Test func aModelThatIsNoNameAndTheDefaultModeSayNothing() {
        #expect(ModelName.short("") == nil)
        #expect(ModelName.short("<synthetic>") == nil)
        #expect(ModelName.short(String(repeating: "long-", count: 10)) == nil)
        #expect(ModeName.short("default") == nil)
        #expect(ModeName.short("bypassPermissions") == "bypass")
        #expect(ModeName.short("plan") == "plan")
        #expect(ModeName.short("acceptEdits") == "accept edits")
        #expect(ModeName.short("somethingNew") == nil)
        // A finished list says nothing either.
        #expect(RowFacts(SessionFacts(tasks: TaskProgress(done: 3, total: 3))).isEmpty)
        #expect(RowFacts(SessionFacts(tasks: TaskProgress(done: 1, total: 3))).progress == "1/3")
    }

    /// Each row carries what its agent reported: Claude's model, mode and tasks from its hooks, Codex's model and plan from
    /// its rollout; a session that said none has none.
    @Test func rowsCarryTheirAgentsFacts() throws {
        let (_, model) = model()
        #expect(model.row(id: ID.claudePlan)?.facts == RowFacts(model: "Opus 5.5", mode: "plan", progress: "2/5", effort: "xhigh"))
        #expect(model.row(id: ID.claudeStalled)?.facts == RowFacts(model: "Sonnet 4.5", mode: "bypass"))
        #expect(model.row(id: ID.codexRunning)?.facts == RowFacts(model: "GPT-6 Astra", progress: "3/7", effort: "high"))
        #expect(model.row(id: ID.claudeDone)?.facts == RowFacts(model: "Opus 5.5"))
        let demo = FixtureSessionFeed(scenario: .prototype, now: DemoClock.now).makeModel()
        #expect(demo.rows.allSatisfy { $0.facts.isEmpty })
    }

    // MARK: Stalled (P312)

    /// Only a running session with nothing waiting and no sign of life for the limit is stalled; off is never.
    @Test func aStallIsARunningSessionQuietPastTheLimit() throws {
        let (_, model) = model()
        #expect(model.rows.filter(\.isStalled).map(\.id) == [ID.claudeStalled])
        let (_, off) = self.model(stalledAfter: nil)
        #expect(!off.rows.contains { $0.isStalled })
        // The demo's sessions at a one-minute limit: its running ones are stalled, never one that waits on the owner or is done.
        let feed = FixtureSessionFeed(scenario: .allStates, now: DemoClock.now)
        let demo = feed.makeModel(stalledAfter: 60)
        #expect(!demo.rows.isEmpty)
        for row in demo.rows where row.isStalled {
            #expect(row.bucket == .running && !row.hasCard)
        }
        #expect(demo.rows.contains { $0.bucket == .running && $0.isStalled })
        #expect(demo.rows.filter { $0.bucket != .running }.allSatisfy { !$0.isStalled })
    }

    /// The minute clock finds a stall with no timer of its own, and the next sign of life ends it.
    @Test func theMinuteClockFindsAStallAndActivityEndsIt() async throws {
        let clock = Clock()
        clock.now = DemoClock.now - 5 * 60
        let (feed, model) = model(clock: clock)
        #expect(model.row(id: ID.claudeStalled)?.isStalled == false)
        clock.now = DemoClock.now
        model.tick()
        #expect(model.row(id: ID.claudeStalled)?.isStalled == true)
        feed.engine.loadPreviewEvents([.activityUpdated(SessionActivityUpdated(sessionID: ID.claudeStalled, summary: "Running Bash",
                                                                               phase: .running, timestamp: DemoClock.now))])
        #expect(model.row(id: ID.claudeStalled)?.isStalled == false)
        #expect(model.card(for: ID.claudeStalled) == nil)
    }

    /// The row says "Stalled", then what it was on; its glyph says nothing of it, so Clean keeps the word.
    @Test func aStalledRowSaysSo() throws {
        let (_, model) = model()
        let row = try #require(model.row(id: ID.claudeStalled))
        let clean = IslandRowText.status(row)
        #expect(clean.word == "Stalled" && clean.tone == .stalled && clean.toolVerb == "Bash")
        #expect(clean.text == FixtureSessionFeed.rowsStalledCommand)
        #expect(DetailedRowText.status(row).word == "Stalled")
        #expect(DetailedRowText.toolLine(row)?.verb == "Bash")
        #expect(SessionRowText.detailedStatus(row).word == "Stalled")
    }

    /// The notice: once, when a row of the owner's turns stalled; never for a row first seen stalled (a launch), a quiet
    /// row, or again while it stays stalled.
    @Test func aStallGivesOneNotice() throws {
        let (_, model) = model()
        let stalled = try #require(model.row(id: ID.claudeStalled))
        var before = stalled
        before.isStalled = false
        #expect(IslandAttention.signals(old: [before], new: [stalled]) == [.stalled(ID.claudeStalled)])
        #expect(IslandAttention.signals(old: [stalled], new: [stalled]).isEmpty)
        #expect(IslandAttention.signals(old: [], new: [stalled]).isEmpty)
        var quiet = stalled, quietBefore = before
        quiet.isQuiet = true
        quietBefore.isQuiet = true
        #expect(IslandAttention.signals(old: [quietBefore], new: [quiet]).isEmpty)
        // The live engine's finishes replace the rows' own, never a stall.
        #expect(IslandAttention.signals(old: [before], new: [stalled], source: .engine(last: nil), seen: nil) == [.stalled(ID.claudeStalled)])
    }

    /// The notice is a brief card (it closes by itself), after what needs you and a finish's card, never over a card the
    /// owner is at. Under Glance the island stays closed: the row's Stalled word alone, no card and no dot.
    @Test func theNoticeIsABriefCardAfterEverythingElse() throws {
        let (_, model) = model()
        let rows = model.rows
        let response = IslandAttention.respond(to: [.stalled(ID.claudeStalled)], rows: rows, finish: .card, cardInUse: false)
        #expect(response == IslandAttention.Response(card: ID.claudeStalled, brief: true))
        #expect(IslandAttention.respond(to: [.stalled(ID.claudeStalled)], rows: rows, finish: .glance, cardInUse: false) == IslandAttention.Response())
        let glanceFinish = IslandAttention.respond(to: [.stalled(ID.claudeStalled), .finished(ID.claudeDone)], rows: rows, finish: .glance, cardInUse: false)
        #expect(glanceFinish.card == nil && glanceFinish.glance == ID.claudeDone)
        #expect(IslandAttention.respond(to: [.stalled(ID.claudeStalled)], rows: rows, finish: .card, cardInUse: true).card == nil)
        let finish = IslandAttention.respond(to: [.stalled(ID.claudeStalled), .finished(ID.claudeDone)], rows: rows, finish: .card, cardInUse: false)
        #expect(finish.card == ID.claudeDone)
        let needs = IslandAttention.respond(to: [.stalled(ID.claudeStalled), .needsYou(ID.claudePlan)], rows: rows, finish: .card, cardInUse: false)
        #expect(needs.card == ID.claudePlan && !needs.brief)
    }

    /// The card is the row alone, brief, with no body; it goes with the stall.
    @Test func theStalledCardIsItsRow() throws {
        let (_, model) = model()
        let card = try #require(model.card(for: ID.claudeStalled))
        #expect(card.isStalled)
        #expect(card.isBrief(in: .islandClean) && card.isBrief(in: .islandDetailed))
        #expect(card.isHeaderOnly(replySetting: true))
        #expect(!card.waits && card.request == nil)
        #expect(model.card(for: ID.claudePlan) == nil)
    }

    /// Time the Mac spent asleep is no inactivity: a wake past Stalled after finds nothing stalled and gives no notice,
    /// and awake time counts on from where it stopped.
    @Test func sleepIsNoInactivity() throws {
        let clock = Clock()
        clock.now = DemoClock.now - 5 * 60
        let feed = FixtureSessionFeed(scenario: .rows, now: DemoClock.now)
        let model = EngineSessionsModel(engine: feed.engine, clock: { clock.now }, stalledAfter: { Self.limit }, uptime: { clock.uptime })
        let before = model.rows
        #expect(before.first { $0.id == ID.claudeStalled }?.isStalled == false)
        // Thirty minutes with the lid closed: the wall clock moves on, the Mac's awake time does not.
        clock.now += 30 * 60
        clock.uptime += 1
        model.tick()
        let woke = model.rows
        #expect(!woke.contains { $0.isStalled })
        #expect(!IslandAttention.signals(old: before, new: woke).contains { if case .stalled = $0 { true } else { false } })
        // Two awake minutes more: eleven quiet minutes awake.
        clock.now += 2 * 60
        clock.uptime += 2 * 60
        model.tick()
        #expect(model.row(id: ID.claudeStalled)?.isStalled == true)
        #expect(model.row(id: ID.claudePlan)?.isStalled == false)
    }

    /// Nothing ticks for a stall (P312): the closed pill's lead is a running row that is not stalled, or with only stalled
    /// ones the equalizer held still; a stalled row draws no running edge line, and Hide the pill when idle hides it.
    @Test func aStalledRowNeverTicksOnThePill() throws {
        let (_, model) = model()
        let stalled = try #require(model.row(id: ID.claudeStalled))
        let live = try #require(model.row(id: ID.codexRunning))
        #expect(stalled.isStalled && !live.isStalled)
        let lead = try #require(PillLead.make(rows: [stalled, live], recentlyFinished: nil))
        #expect(lead.agent == live.agent && lead.glyph == .eq && !lead.still)
        let alone = try #require(PillLead.make(rows: [stalled], recentlyFinished: nil))
        #expect(alone.glyph == .eq && alone.still)
        #expect(PillLead.make(rows: [stalled], recentlyFinished: .codex)?.glyph == .check)
        #expect(!ClosedPillView.edgeLineRuns(rows: [stalled]) && ClosedPillView.edgeLineRuns(rows: [stalled, live]))
        let settings = AppSettings.ephemeral()
        settings.hidePillWhenIdle = true
        let hidden = PillContent.make(rows: [stalled], settings: settings, glance: false, recentlyFinished: nil, now: DemoClock.now,
                                      notch: IslandTheme.Metrics.referenceNotch, menuBar: nil)
        #expect(hidden.lead == nil && hidden.count == nil)
        let shown = PillContent.make(rows: [stalled, live], settings: settings, glance: false, recentlyFinished: nil, now: DemoClock.now,
                                     notch: IslandTheme.Metrics.referenceNotch, menuBar: nil)
        #expect(shown.lead?.agent == live.agent)
    }

    // MARK: Peek (P311)

    /// Only what the row does not say: a prompt the row's line shows is left out, a finished turn's long reply shown
    /// whole, a short one the row says whole left out, JSON and machine text never; facts in Clean only.
    @Test func aPeekSaysOnlyWhatTheRowDoesNot() throws {
        let (_, model) = model()
        let plan = try #require(model.row(id: ID.claudePlan))
        // Clean shows the tool, so the prompt goes to the peek; Detailed's line says "You:" it.
        let cleanPlan = try #require(SessionPeek.make(row: plan, clean: true, prompt: plan.lastPrompt, reply: nil, replyIsCurrent: false, read: nil))
        #expect(cleanPlan.prompt == plan.lastPrompt && cleanPlan.facts == plan.facts && cleanPlan.reply == nil)
        #expect(SessionPeek.make(row: plan, clean: false, prompt: plan.lastPrompt, reply: nil, replyIsCurrent: false, read: nil) == nil)
        // A running Claude turn's metadata reply is the turn before's: never shown without a read.
        let stale = SessionPeek.make(row: plan, clean: false, prompt: plan.lastPrompt, reply: "An earlier answer.", replyIsCurrent: false, read: nil)
        #expect(stale == nil)
        // The read's reply and a pending tool the row does not name.
        var thinking = plan
        thinking.status = .thinking
        let read = SessionPeekRead(prompt: plan.lastPrompt, reply: "Reading the index first.", tool: "Read", toolDetail: "index.ts")
        let peek = try #require(SessionPeek.make(row: thinking, clean: false, prompt: nil, reply: nil, replyIsCurrent: false, read: read))
        #expect(peek.reply == "Reading the index first." && peek.tool == SessionPeek.Tool(verb: "Read", text: "index.ts"))
        #expect(SessionPeek.make(row: plan, clean: false, prompt: nil, reply: nil, replyIsCurrent: false, read: read)?.tool == nil)
        // A finished turn: the long reply whole, a short one the row already says not again, JSON never.
        let done = try #require(model.row(id: ID.claudeDone))
        let long = try #require(SessionPeek.make(row: done, clean: true, prompt: "fix it", reply: FixtureSessionFeed.rowsDoneReply,
                                                 replyIsCurrent: true, read: nil))
        #expect(long.reply == MessageMarkup.plain(FixtureSessionFeed.rowsDoneReply))
        var short = done
        short.detail = "Fixed it."
        short.facts = RowFacts()
        #expect(SessionPeek.make(row: short, clean: true, prompt: nil, reply: "Fixed it.", replyIsCurrent: true, read: nil) == nil)
        #expect(SessionPeek.make(row: short, clean: true, prompt: nil, reply: #"{"verdict":"ok"}"#, replyIsCurrent: true, read: nil) == nil)
        // Machine text is never a prompt.
        let machine = SessionPeek.make(row: short, clean: true, prompt: nil, reply: nil, replyIsCurrent: true,
                                       read: SessionPeekRead(prompt: "<task-notification>done</task-notification>"))
        #expect(machine == nil)
    }

    /// The model's peek: a running Codex turn's reply is its rollout's latest, kept current in its metadata. Its plan
    /// shows whole, so the facts leave its "3/7" to the row (P721).
    @Test func aCodexPeekHasItsTurnsLatestReply() async throws {
        let (_, model) = model()
        let peek = try #require(await model.peek(ID.codexRunning, clean: true))
        #expect(peek.reply == FixtureSessionFeed.rowsCodexReply)
        #expect(peek.facts == RowFacts(model: "GPT-6 Astra", effort: "high"))
        #expect(peek.steps.count == 7 && peek.rowProgress == "3/7")
    }

    private func peeker(_ env: AppEnvironment, ui: IslandUIState, clock: Clock = Clock()) -> IslandPeeker {
        IslandPeeker(ui: ui, settings: env.settings, sessions: { env.sessions }, dwell: .milliseconds(20), warmDwell: .milliseconds(5),
                     clock: { clock.now.timeIntervalSinceReferenceDate })
    }

    /// A rest on a row shows its peek; leaving before the dwell shows none; leaving the row takes it away. Never on a row
    /// whose card waits, never with the setting off, never while a card shows or the island is closed.
    @Test func thePeekFollowsTheRestingPointer() async throws {
        let env = AppEnvironment.demo(sessions: .rows, stalledAfter: Self.limit)
        let ui = IslandUIState()
        ui.isOpen = true
        let peeker = peeker(env, ui: ui)
        let codex = try #require(env.sessions.row(id: ID.codexRunning))
        peeker.hovered(codex, inside: true)
        await peeker.work?.value
        #expect(ui.peek?.sessionID == ID.codexRunning)
        peeker.hovered(codex, inside: false)
        #expect(ui.peek == nil && ui.peekRoom == 0)
        // Left before the dwell: none.
        peeker.hovered(codex, inside: true)
        peeker.hovered(codex, inside: false)
        #expect(peeker.pending == nil && ui.peek == nil)
        // A row whose card waits: its card is the peek.
        var waiting = codex
        waiting.hasCard = true
        peeker.hovered(waiting, inside: true)
        #expect(peeker.pending == nil)
        // Off, a card showing, the island closed: none.
        env.settings.sessionPeek = false
        peeker.hovered(codex, inside: true)
        #expect(peeker.pending == nil)
        env.settings.sessionPeek = true
        ui.presentation = .card(sessionID: ID.claudePlan)
        peeker.hovered(codex, inside: true)
        #expect(peeker.pending == nil)
        ui.presentation = .list
        ui.isOpen = false
        peeker.hovered(codex, inside: true)
        #expect(peeker.pending == nil)
    }

    /// A peeked row that goes, or starts to wait on the owner, loses its peek; so does every peek at a reset.
    @Test func aRowThatWaitsLosesItsPeek() async throws {
        let env = AppEnvironment.demo(sessions: .rows, stalledAfter: Self.limit)
        let ui = IslandUIState()
        ui.isOpen = true
        let peeker = peeker(env, ui: ui)
        let codex = try #require(env.sessions.row(id: ID.codexRunning))
        peeker.hovered(codex, inside: true)
        await peeker.work?.value
        #expect(ui.peek != nil)
        peeker.rowsChanged(env.sessions.rows)
        #expect(ui.peek != nil)
        var waiting = codex
        waiting.hasCard = true
        peeker.rowsChanged([waiting])
        #expect(ui.peek == nil)
        peeker.hovered(codex, inside: true)
        await peeker.work?.value
        peeker.rowsChanged([])
        #expect(ui.peek == nil)
        peeker.hovered(codex, inside: true)
        peeker.reset()
        #expect(peeker.pending == nil && ui.peek == nil)
    }

    /// A finished turn's reply the row's line begins: the peek takes it up where the line cuts it, from the start of the
    /// word it cuts, never saying the line's words again; nothing when the line shows it whole.
    @Test func aPeekTakesUpTheReplyWhereTheRowsLineStops() throws {
        let (_, model) = model()
        let done = try #require(model.row(id: ID.claudeDone))
        let peek = try #require(SessionPeek.make(row: done, clean: true, prompt: "fix it", reply: FixtureSessionFeed.rowsDoneReply,
                                                 replyIsCurrent: true, read: nil))
        #expect(peek.replyContinuesLine)
        let reply = try #require(peek.reply)
        let font = NSFont.systemFont(ofSize: 11)
        func width(_ text: String) -> CGFloat { ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) }
        // A line wide enough for "Split the upload retries out of the client and gave each its own timeo…".
        let shown = "Split the upload retries out of the client and gave each its own timeo"
        let rest = try #require(SessionPeek.rest(of: reply, lineWidth: width(shown + "…") + 1, fontSize: 11))
        #expect(rest.hasPrefix("…timeout. The flaky test"))
        #expect(!rest.contains("Split the upload"))
        #expect(reply.hasSuffix(rest.dropFirst()))
        #expect(SessionPeek.rest(of: "Fixed the flaky test.", lineWidth: width("Fixed the flaky test.") + 2, fontSize: 11) == nil)
        // A running turn's reply is not the row's line: whole.
        let plan = try #require(model.row(id: ID.claudePlan))
        var thinking = plan
        thinking.status = .thinking
        let running = try #require(SessionPeek.make(row: thinking, clean: false, prompt: nil, reply: nil, replyIsCurrent: false,
                                                    read: SessionPeekRead(prompt: plan.lastPrompt, reply: "Reading the index first.")))
        #expect(!running.replyContinuesLine)
    }

    /// The peek writes the owner's prompt as the rows do: a grey "You: ", then the prompt in the Detailed status colour.
    @Test func thePeekWritesThePromptAsTheRowsDo() {
        #expect(IslandPeekView.youLabel == "You: ")
        #expect(IslandPeekView.promptColour == IslandTheme.statusDetailed)
    }

    /// The peek's ground ends on a row's bottom, never across one: a row it covers part of is covered whole, and it
    /// never goes past the list's end.
    @Test func thePeekEndsOnARowsBottom() {
        let rows = (0..<4).map { CGRect(x: 0, y: CGFloat($0) * 41, width: 300, height: 41) }
        // Under the first row, 61 tall: it would end inside the third row; it covers it whole.
        #expect(IslandPeekPlacement.ground(top: 43, height: 61, rows: rows, limit: 164) == CGFloat(123 - 43))
        // Ending right on a row's bottom, or with nothing below: as it is.
        #expect(IslandPeekPlacement.ground(top: 43, height: 39, rows: rows, limit: 164) == 39)
        #expect(IslandPeekPlacement.ground(top: 125, height: 50, rows: rows, limit: 177) == 50)
        // Never past the list's end.
        #expect(IslandPeekPlacement.ground(top: 43, height: 61, rows: rows, limit: 110) == CGFloat(110 - 43))
    }

    /// The room the list lacks: none when the rows below leave enough, the rest when they do not.
    @Test func theRoomIsWhatTheListLacks() {
        #expect(IslandPeekPlacement.room(height: 60, below: 100) == 0)
        #expect(IslandPeekPlacement.room(height: 60, below: 30) == 32)
        #expect(IslandPeekPlacement.room(height: 60, below: 0) == 62)
    }

    /// Drawn in a hosting view never ordered in: a peek under the only row makes the island as much taller as its room,
    /// so it is never drawn beyond it; the first of four rows needs none, and the island keeps its height.
    @Test func aPeekIsNeverDrawnBeyondTheIsland() async throws {
        func height(_ env: AppEnvironment, _ ui: IslandUIState) -> CGFloat {
            let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: ui, animated: false)
                .environment(\.sessionGlyphsAnimated, false).environment(env).environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: view)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
        let (_, model) = model()
        let done = try #require(model.row(id: ID.claudeDone))
        let one = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: [done]))
        let peek = try #require(await model.peek(ID.claudeDone, clean: true))
        let bare = height(one, IslandUIState())
        let ui = IslandUIState()
        ui.peek = peek
        let peeked = height(one, ui)
        #expect(ui.peekRoom > 0)
        #expect(abs(peeked - bare - ui.peekRoom) < 1)
        let all = AppEnvironment.demo(sessions: .rows, stalledAfter: Self.limit)
        let first = try #require(IslandListLayout.make(rows: all.sessions.rows, style: .clean, showAll: false, now: all.sessions.now).shown.first)
        let firstUI = IslandUIState()
        let firstPeek = try #require(await all.sessions.peek(first.id, clean: true))
        firstUI.peek = firstPeek
        let before = height(all, IslandUIState())
        #expect(abs(height(all, firstUI) - before) < 1)
        #expect(firstUI.peekRoom == 0)
    }

    // MARK: Settings

    @Test func theSettingsDefaults() {
        let settings = AppSettings.ephemeral()
        #expect(settings.sessionPeek)
        #expect(settings.stalledAfter == .tenMinutes && settings.stalledAfter.seconds == 600)
        #expect(StallLimit.off.seconds == nil)
    }
}
