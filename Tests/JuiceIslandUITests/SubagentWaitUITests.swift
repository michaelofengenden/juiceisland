import Foundation
import IslandHookNotes
import JuiceCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The owner's report of 2026-09-28 (P370-P372), through the live model, its sounds and the island's finish: a Claude
/// session whose main turn ended while a background agent still runs is a teal row ("Waiting on 1 agent", the delegate's
/// glyph), counted and led as at work, with no Done card, sound or finish; the Stop of the turn the agent's result wakes
/// is the one Done. The engine's bridge, runtime and frontmost check are stand-ins; no socket is bound and no sound
/// plays. Shapes as in `ClaudeSubagentWaitTests` (hook notes first, then what upstream's bridge emits).
@MainActor
struct SubagentWaitUITests {
    final class Probe: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var checks: [(at: Date, run: @MainActor @Sendable () -> Void)] = []
    }

    private final class StubBridge: EngineBridge, @unchecked Sendable {
        func updateStateSnapshot(_ snapshot: SessionState) {}
        func stop() {}
    }

    private func makeLive(_ probe: Probe, settings: AppSettings, player: RecordingSoundPlayer) -> LiveSessions {
        settings.liveSessions = true
        settings.suppressForFocusedSessions = false
        settings.doneSound = .system("Hero")
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { false }
            dependencies.socketHasOwner = { _ in false }
            dependencies.startBridge = { _ in StubBridge() }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            dependencies.isSessionFrontmost = { _ in false }
            dependencies.frontmostBundleID = { nil }
            dependencies.now = { probe.now }
            dependencies.scheduleSignalCheck = { _, _ in }
            dependencies.scheduleSubagentCheck = { delay, check in probe.checks.append((probe.now + delay, check)) }
            dependencies.readCodexSettings = { _ in nil }
            dependencies.processExists = { _ in true }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, sounds: player)
        live.activate()
        return live
    }

    // MARK: Hooks

    private static func note(_ event: String, agent: String? = nil, background: Int? = nil,
                             kinds: [String: Int]? = nil) -> HookContextNote {
        HookContextNote(event: event, sessionID: "chat", agentPID: 900, agentID: agent, agentType: agent == nil ? nil : "worker",
                        entrypoint: "cli", source: "claude", backgroundTaskCount: background, backgroundTaskKinds: kinds)
    }

    private static func activity(_ summary: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: "chat", summary: summary, phase: .running, timestamp: date))
    }

    private func begin(_ engine: SessionEngine, _ probe: Probe) {
        engine.ingest(note: Self.note("SessionStart"))
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: "chat", title: "Claude · parser", tool: .claudeCode, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: probe.now, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "parser", paneTitle: "claude",
                                                          workingDirectory: "/tmp/parser", terminalTTY: "/dev/ttys003"),
            claudeMetadata: ClaudeSessionMetadata(transcriptPath: nil, lastUserPrompt: "map the parser"))), ingress: .bridge)
        engine.ingest(note: Self.note("UserPromptSubmit"))
        engine.ingest(Self.activity("Prompt: map the parser", at: probe.now), ingress: .bridge)
    }

    private func spawn(_ engine: SessionEngine, _ agent: String, _ probe: Probe) {
        engine.ingest(note: Self.note("SubagentStart", agent: agent))
        engine.ingest(Self.activity("Started worker subagent.", at: probe.now), ingress: .bridge)
    }

    /// The main agent's Stop: `kinds`, its `background_tasks` by kind as this helper counts them (P510); nil, as the
    /// helper before it sent the note (a count only).
    private func stop(_ engine: SessionEngine, background: Int, kinds: [String: Int]? = nil, _ probe: Probe) {
        engine.ingest(note: Self.note("Stop", background: background, kinds: kinds))
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "chat", summary: "Started the agent.", timestamp: probe.now)),
                      ingress: .bridge)
    }

    /// The 1.5 s hold, passed, and any lapse check due by then.
    private func pass(_ engine: SessionEngine, _ probe: Probe, _ seconds: TimeInterval = SignalPipeline.doneHold) {
        probe.now += seconds
        engine.flushHeldSignals()
        let due = probe.checks.filter { $0.at <= probe.now }
        probe.checks.removeAll { $0.at <= probe.now }
        for check in due { check.run() }
    }

    // MARK: The report, replayed

    @Test
    func aMainAgentWaitingOnItsAgentIsATealRowWithNoDoneThenOneDoneAtItsOwnTurnEnd() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        begin(engine, probe)
        spawn(engine, "a1", probe)
        probe.now += 30
        let before = live.rows
        stop(engine, background: 1, probe)
        pass(engine, probe, 5)

        // The row: at work, in the delegate's glyph and teal, "Waiting on 1 agent" once in each style.
        let row = try #require(live.row(id: "chat"))
        #expect(row.bucket == .running && row.glyph == .agents && row.glyphState == .delegating && row.status == .subagents(1))
        #expect(SessionRowText.cleanStatus(row).text == "Waiting on 1 agent" && SessionRowText.cleanStatus(row).word == nil)
        // The first prompt is the title (P203), so no line says it again.
        #expect(row.titleSource == .prompt)
        #expect(DetailedRowText.status(row).word == "Waiting on 1 agent" && DetailedRowText.status(row).prompt == nil)
        let window = SessionRowText.detailedStatus(row)
        #expect(!window.isPrompt && window.word == nil && window.text == "Waiting on 1 agent" && SessionRowText.toolLine(row) == nil)
        #expect(GlyphMood(row.glyph) == .delegating && !GlyphMood(row.glyph).needsYou)
        // Teal by state; by agent, work in progress takes the agent's running colour, as running does (P381).
        #expect(GlyphPalette.colour(agent: .claude, state: .delegating, mode: .byState, needsYou: .pink) == IslandTheme.delegate)
        #expect(GlyphPalette.colour(agent: .claude, state: .delegating, mode: .byAgent, needsYou: .pink)
                == AgentLook.of(.claude).runningColour(.pink))
        #expect(live.card(for: "chat") == nil)
        // No Done: no sound, no finish, no signal from the rows.
        #expect(player.played.isEmpty)
        #expect(live.finishSource == .engine(last: nil))
        #expect(IslandAttention.signals(old: before, new: live.rows, source: live.finishSource, seen: nil).isEmpty)
        // Counted, and led, as at work; the pill's lead is the delegate's glyph.
        #expect(SessionActivity.isActive(row, now: probe.now) && live.runningCount == 1)
        #expect(PillSummary.make(rows: live.rows, countMode: .active, now: probe.now).count == 1)
        let lead = try #require(PillLead.make(rows: live.rows, recentlyFinished: nil))
        #expect(lead.glyph == .agents && lead.state == .delegating && !lead.still)
        // The widget lists it with what runs, in the delegate's glyph.
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: probe.now), sessions: live)
        let widget = try #require(WidgetSnapshot.make(env, at: probe.now).rows.first { $0.id == "chat" })
        #expect(widget.kind == .running && widget.glyph == "agents" && widget.word == nil)

        // The agent's own work reaches nothing the owner hears.
        engine.ingest(note: Self.note("PreToolUse", agent: "a1"))
        engine.ingest(note: Self.note("PostToolUse", agent: "a1"))
        pass(engine, probe, 120)
        #expect(player.played.isEmpty && live.row(id: "chat")?.glyphState == .delegating)

        // It finishes; its result wakes the main agent (blue), whose Stop is the one Done.
        engine.ingest(note: Self.note("SubagentStop", agent: "a1"))
        #expect(live.row(id: "chat")?.glyphState == .delegating)
        engine.ingest(note: Self.note("UserPromptSubmit"))
        engine.ingest(Self.activity("Prompt: <task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n</task-notification>",
                                    at: probe.now), ingress: .bridge)
        let woken = try #require(live.row(id: "chat"))
        #expect(woken.bucket == .running && woken.glyph == .eq && woken.glyphState == .running)
        probe.now += 20
        let running = live.rows
        stop(engine, background: 0, probe)
        pass(engine, probe)
        #expect(player.played == ["Hero"])
        let finish = try #require({ if case let .engine(last) = live.finishSource { last } else { nil } }())
        #expect(finish.sessionID == "chat")
        #expect(IslandAttention.signals(old: running, new: live.rows, source: live.finishSource, seen: nil) == [.finished("chat")])
        #expect(live.row(id: "chat")?.bucket == .done && live.row(id: "chat")?.glyph == .check)
        pass(engine, probe, 60)
        #expect(player.played == ["Hero"])
    }

    /// Its SubagentStop and no wake-up: the row turns done after the grace, silently, and the island hears no finish
    /// from the rows either (the demo's and the renders' source).
    @Test
    func aWaitThatEndsWithNoTurnOfTheMainAgentIsNoFinish() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        begin(engine, probe)
        spawn(engine, "a1", probe)
        stop(engine, background: 1, probe)
        pass(engine, probe, 30)
        let teal = live.rows
        engine.ingest(note: Self.note("SubagentStop", agent: "a1"))
        pass(engine, probe, ClaudeSubagentBook.wakeGrace + 2)
        #expect(live.row(id: "chat")?.bucket == .done && live.row(id: "chat")?.status == .done)
        #expect(IslandAttention.signals(old: teal, new: live.rows).isEmpty)
        #expect(player.played.isEmpty)
        // A Codex chat waits inside its own turn (P212): its turning done is that turn's end, a finish.
        var chat = try #require(teal.first)
        chat.agent = .codex
        var ended = chat
        (ended.bucket, ended.glyph, ended.glyphState, ended.status) = (.done, .check, .done, .done)
        #expect(IslandAttention.signals(old: [chat], new: [ended]) == [.finished("chat")])
    }

    // MARK: Claude's own word (P510)

    /// The owner's report after fc28c1e1: a workflow at the Stop is a teal row, "Waiting on 1 workflow", in every style;
    /// its agents' starts and tools reach nothing the owner sees or hears; its result's wake-up is blue, and that turn's
    /// Stop the one Done.
    @Test
    func aWorkflowAtStopIsATealRowSaidOnceThenOneDoneAtTheWakeUp() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        begin(engine, probe)
        probe.now += 30
        stop(engine, background: 1, kinds: ["workflow": 1], probe)
        pass(engine, probe, 5)
        let row = try #require(live.row(id: "chat"))
        #expect(row.bucket == .running && row.glyph == .agents && row.glyphState == .delegating && row.status == .subagents(0, workflows: 1))
        #expect(SessionRowText.cleanStatus(row).text == "Waiting on 1 workflow")
        #expect(DetailedRowText.status(row).word == "Waiting on 1 workflow")
        #expect(SessionRowText.detailedStatus(row).text == "Waiting on 1 workflow" && row.detail == nil)
        #expect(live.card(for: "chat") == nil && live.runningCount == 1 && player.played.isEmpty)
        let teal = live.rows
        // The next phase's agents: their SubagentStart notes, tools, and the bridge's echoes, interleaved.
        engine.ingest(note: Self.note("SubagentStart", agent: "w4"))
        engine.ingest(note: Self.note("PreToolUse", agent: "w2"))
        engine.ingest(note: Self.note("SubagentStart", agent: "w5"))
        engine.ingest(Self.activity("Started worker subagent.", at: probe.now), ingress: .bridge)
        engine.ingest(note: Self.note("PostToolUse", agent: "w2"))
        engine.ingest(Self.activity("Started worker subagent.", at: probe.now), ingress: .bridge)
        engine.ingest(note: Self.note("SubagentStop", agent: "w2", kinds: ["workflow": 1]))
        pass(engine, probe, 600)
        #expect(live.row(id: "chat")?.status == .subagents(0, workflows: 1) && live.row(id: "chat")?.glyphState == .delegating)
        #expect(IslandAttention.signals(old: teal, new: live.rows, source: live.finishSource, seen: nil).isEmpty)
        #expect(player.played.isEmpty)

        engine.ingest(note: Self.note("UserPromptSubmit"))
        engine.ingest(Self.activity("Prompt: <task-notification>\n<task-id>w-review</task-id>\n<status>completed</status>\n</task-notification>",
                                    at: probe.now), ingress: .bridge)
        #expect(live.row(id: "chat")?.glyphState == .running)
        probe.now += 20
        stop(engine, background: 1, kinds: ["shell": 1], probe)
        pass(engine, probe)
        #expect(player.played == ["Hero"] && live.row(id: "chat")?.bucket == .done)
        pass(engine, probe, 60)
        #expect(player.played == ["Hero"])
    }

    /// Agents and a workflow: "Waiting on 2 agents · 1 workflow", once, on the island, in the window and the widget's
    /// running group; a shell beside them says nothing.
    @Test
    func agentsAndAWorkflowAreSaidTogether() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        begin(engine, probe)
        stop(engine, background: 4, kinds: ["subagent": 2, "workflow": 1, "shell": 1], probe)
        pass(engine, probe, 5)
        let row = try #require(live.row(id: "chat"))
        #expect(row.status == .subagents(2, workflows: 1))
        #expect(SessionRowText.cleanStatus(row).text == "Waiting on 2 agents · 1 workflow")
        #expect(DetailedRowText.status(row).word == "Waiting on 2 agents · 1 workflow")
        #expect(SessionListLayout.groupStatus(row, now: probe.now).hasPrefix("Waiting on 2 agents · 1 workflow"))
        #expect(player.played.isEmpty)
    }

    /// A dev server left running, and the helper before P510 with a workflow no agent of which the book saw start: the
    /// turn is done, with its Done, as today.
    @Test(arguments: [true, false])
    func aShellAloneOrTheOldNoteIsDoneAsToday(_ countsKinds: Bool) throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        begin(engine, probe)
        probe.now += 30
        stop(engine, background: 1, kinds: countsKinds ? ["shell": 1] : nil, probe)
        pass(engine, probe)
        #expect(live.row(id: "chat")?.bucket == .done && live.row(id: "chat")?.status == .done)
        #expect(player.played == ["Hero"])
    }

    // MARK: A Codex chat whose turn ended (P513)

    /// A Codex chat whose own turn ended while two subagents run: teal, "Waiting on 2 agents", no Done card or sound;
    /// their results' wake-up (no prompt hook here: the Stop note alone shows it) is the one Done.
    @Test
    func aCodexChatWaitsOnItsSubagentsAfterItsTurnThenOneDone() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: "cx", title: "Codex · docs", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: probe.now, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "docs", paneTitle: "codex",
                                                          workingDirectory: "/tmp/docs", terminalTTY: "/dev/ttys004"),
            codexMetadata: CodexSessionMetadata(transcriptPath: "/tmp/sessions/rollout-cx.jsonl", lastUserPrompt: "check every page"))),
                      ingress: .bridge)
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "cx", summary: "Prompt: check every page", phase: .running,
                                                              timestamp: probe.now)), ingress: .bridge)
        let children = ["k1", "k2"]
        engine.takeCodexChildren(children.map {
            CodexChildThread(id: $0, parentID: "cx", rootID: "cx", name: "worker", isRunning: true, updatedAt: probe.now, transcriptPath: "")
        })
        func codexStop() {
            engine.ingest(note: HookContextNote(event: "Stop", sessionID: "cx", agentPID: 901, source: "codex"))
            engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "cx", summary: "Asked two workers.", timestamp: probe.now)),
                          ingress: .bridge)
        }
        probe.now += 30
        codexStop()
        pass(engine, probe, 5)
        let row = try #require(live.row(id: "cx"))
        #expect(row.bucket == .running && row.glyph == .agents && row.glyphState == .delegating && row.status == .subagents(2))
        #expect(SessionRowText.cleanStatus(row).text == "Waiting on 2 agents" && live.card(for: "cx") == nil)
        #expect(player.played.isEmpty)
        for child in children {
            engine.ingestSubagentEvent(.sessionCompleted(SessionCompleted(sessionID: child, summary: "Checked.", timestamp: probe.now)))
        }
        pass(engine, probe, 3)
        #expect(player.played.isEmpty)
        codexStop()
        pass(engine, probe)
        #expect(player.played == ["Hero"] && live.row(id: "cx")?.bucket == .done)
        pass(engine, probe, 60)
        #expect(player.played == ["Hero"])
    }

    /// Among other rows: after a running one, before a finished one; the footer marks it with the delegate's glyph.
    @Test
    func aWaitingRowSortsWithTheRunningOnesAndHasItsOwnFooterMark() {
        let now = DemoClock.now
        func row(_ id: String, _ bucket: SessionBucket, _ glyph: PixelGlyph, _ state: GlyphPalette.State, _ status: StatusWord) -> SessionRow {
            SessionRow(id: id, agent: .claude, bucket: bucket, project: "p", task: id, status: status, detail: nil, lastPrompt: nil,
                       host: nil, accountAlias: nil, updatedAt: now, isCodexApp: false, glyph: glyph, glyphState: state, hasCard: false)
        }
        let rows = [row("done", .done, .check, .done, .done), row("waits", .running, .agents, .delegating, .subagents(2)),
                    row("runs", .running, .eq, .running, .working)]
        #expect(SessionListLayout.displayOrder(rows, now: now).map(\.id) == ["waits", "runs", "done"])
        let layout = IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: now, visible: 1)
        #expect(layout.footerMarks == [.running(.claude), .idle])
        let first = IslandListLayout.make(rows: [rows[2], rows[1], rows[0]], style: .clean, showAll: false, now: now, visible: 1)
        #expect(first.footerMarks == [.delegating(.claude), .idle] && first.footer == .more(2))
        // A running row leads the pill before a waiting one; a waiting one before a finished one.
        #expect(PillLead.make(rows: rows, recentlyFinished: nil)?.glyph == .eq)
        #expect(PillLead.make(rows: [rows[0], rows[1]], recentlyFinished: nil)?.state == .delegating)
        // The pill's line runs for either, in the lead's colour.
        #expect(ClosedPillView.edgeLineRuns(rows: [rows[1]]) && ClosedPillView.edgeLineColour(rows: [rows[1]]) == IslandTheme.delegate)
        #expect(ClosedPillView.edgeLineColour(rows: rows) == IslandTheme.run && ClosedPillView.edgeLineColour(rows: [rows[0]]) == IslandTheme.run)
    }
}
