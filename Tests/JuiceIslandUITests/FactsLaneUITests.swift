import Foundation
import IslandEngine
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// Wave 6's facts lane, the rows' side (P440, P443, P446): a long tool call keeps its row running and never reads as
/// Stalled until `inFlightStall`; the effort beside the model; Claude Code's recap in a finished row's peek. Sessions:
/// `FixtureSessionFeed.Scenario.rows` and one long build added to it. Fictional ids, folders and texts.
@MainActor
@Suite(.serialized)
struct FactsLaneUITests {
    typealias ID = FixtureSessionFeed.RowsID
    static let limit: TimeInterval = 600
    static let build = "facts-long-build"

    final class Clock {
        var now = DemoClock.now
    }

    /// The rows scenario and a Claude session whose build started at `DemoClock.now` (the feed's clock, so its hook note
    /// is stamped then too) and has said nothing since; the model reads the time from `clock`.
    static func model(clock: Clock, call: String? = "toolu_build") -> (FixtureSessionFeed, EngineSessionsModel) {
        let feed = FixtureSessionFeed(scenario: .rows, now: DemoClock.now)
        let now = DemoClock.now
        feed.engine.loadPreviewEvents(FixtureSessionFeed.start(build, title: "Ship the release build", project: "field-notes",
                                                               prompt: "build the release and run every suite", at: now - 60)
            + [.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: build, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "build the release and run every suite", currentTool: "Bash", currentToolInputPreview: "swift build -c release",
                model: "claude-opus-5-5"), timestamp: now)),
               .activityUpdated(SessionActivityUpdated(sessionID: build, summary: "Running Bash: swift build -c release", phase: .running,
                                                       timestamp: now))])
        if let call { feed.engine.loadPreviewNote(event: "PreToolUse", sessionID: build, toolUseID: call, effort: "high") }
        return (feed, EngineSessionsModel(engine: feed.engine, clock: { clock.now }, stalledAfter: { limit }))
    }

    // MARK: P440

    /// Fifteen quiet minutes past a ten-minute limit with its call in flight: running, "Bash" and 15m, no Stalled and no
    /// notice; past `inFlightStall` it is Stalled after all.
    @Test
    func aLongToolCallIsNeverStalled() throws {
        let clock = Clock()
        let (_, model) = Self.model(clock: clock)
        let before = model.rows
        clock.now = DemoClock.now + 15 * 60
        model.tick()
        let row = try #require(model.row(id: Self.build))
        #expect(!row.isStalled && row.bucket == .running)
        #expect(DetailedRowText.toolLine(row)?.verb == "Bash")
        #expect(SessionRowText.runningTime(since: row.activeSince ?? row.updatedAt, now: clock.now) == "15m")
        #expect(!IslandAttention.signals(old: before, new: model.rows).contains(.stalled(Self.build)))
        // The session stalled with nothing in flight, beside it, still says so.
        #expect(model.row(id: ID.claudeStalled)?.isStalled == true)
        clock.now = DemoClock.now + EngineSessionsModel.inFlightStall + 60
        model.tick()
        #expect(model.row(id: Self.build)?.isStalled == true)
    }

    /// The call's end: from then on the limit is Stalled after's own.
    @Test
    func aFinishedCallStallsAtTheLimit() throws {
        let clock = Clock()
        let (feed, model) = Self.model(clock: clock)
        feed.engine.loadPreviewNote(event: "PostToolUse", sessionID: Self.build, toolUseID: "toolu_build")
        clock.now = DemoClock.now + 9 * 60
        model.tick()
        #expect(model.row(id: Self.build)?.isStalled == false)
        clock.now = DemoClock.now + 11 * 60
        model.tick()
        #expect(model.row(id: Self.build)?.isStalled == true)
    }

    /// A session whose helper named no call: upstream's "Running …" says a call is in flight all the same.
    @Test
    func withNoNoteTheSummarySaysACallIsInFlight() throws {
        let clock = Clock()
        let (_, model) = Self.model(clock: clock, call: nil)
        clock.now = DemoClock.now + 15 * 60
        model.tick()
        #expect(model.row(id: Self.build)?.isStalled == false)
    }

    // MARK: P443

    @Test(arguments: [("xhigh", "xhigh"), ("High", "high"), ("max", "max"), ("minimal", "minimal"), ("none", nil), ("default", nil),
                      ("", nil), ("very long effort", nil), ("hi<b>", nil)] as [(String, String?)])
    func effortsAreNamedAsARowSaysThem(_ raw: String, _ name: String?) {
        #expect(EffortName.short(raw) == name)
    }

    /// The effort follows its model, and says nothing without one.
    @Test
    func theEffortIsSaidBesideItsModel() {
        let facts = RowFacts(SessionFacts(model: "claude-opus-5-5[1m]", mode: "plan", tasks: TaskProgress(done: 1, total: 4), effort: "xhigh"))
        #expect(facts.items == ["Opus 5.5", "xhigh", "plan", "1/4"])
        #expect(RowFacts(SessionFacts(mode: "plan", effort: "high")).items == ["plan"])
        let clock = Clock()
        let (_, model) = Self.model(clock: clock)
        #expect(model.row(id: Self.build)?.facts == RowFacts(model: "Opus 5.5", effort: "high"))
    }

    // MARK: P446

    /// A finished Claude row's peek with Claude Code's recap: the recap alone, in place of the prompt and the reply; a
    /// running row's never shows one.
    @Test
    func aRecapTakesThePlaceOfThePromptAndTheReply() throws {
        let clock = Clock()
        let (_, model) = Self.model(clock: clock)
        let done = try #require(model.row(id: ID.claudeDone))
        let recap = "We split the upload retries and the flaky test passes; next, update the docs for the old flag."
        let read = SessionPeekRead(prompt: "fix it and run it 50 times", reply: FixtureSessionFeed.rowsDoneReply, recap: recap)
        let peek = try #require(SessionPeek.make(row: done, clean: true, prompt: done.lastPrompt, reply: FixtureSessionFeed.rowsDoneReply,
                                                 replyIsCurrent: true, read: read))
        #expect(peek.recap == recap && peek.prompt == nil && peek.reply == nil)
        #expect(!peek.saysOnlyItsReply)
        let running = try #require(model.row(id: ID.claudePlan))
        let runningPeek = SessionPeek.make(row: running, clean: true, prompt: running.lastPrompt, reply: nil, replyIsCurrent: false,
                                           read: SessionPeekRead(reply: "Reading the index.", recap: recap))
        #expect(runningPeek?.recap == nil)
    }
}
