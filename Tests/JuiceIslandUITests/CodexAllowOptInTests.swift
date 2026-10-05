import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// CXH, the owner's "do all of them" of 2026-09-28, item 22 (P470): Settings › Island › Answer Codex on the island, on. A
/// Codex shell command or patch is held for the island while its card shows, for at most `CodexHold.limit`: confirmed
/// and sounded at once (Codex sends no notice), Yes and No (with a reason) answer that request's own helper with the exact
/// output Codex's PermissionRequest hook takes (codex-rs `hooks/schema/generated/permission-request.command.output
/// .schema.json`: `additionalProperties: false` at every level; `updatedInput`, `updatedPermissions` and `interrupt`
/// fail the hook); left alone, not shown, no longer shown, opened, or with the switch off, it is released: the helper
/// exits silent and Codex's own prompt decides. Never held while the owner looks at the session's own tab (or the Codex
/// app, for its threads), or under a reviewer that is not the owner. Through the built helper, the engine's real
/// sockets, the engine and the session model (`AttentionRig`); the island's report of what it shows is
/// `EngineSessionsModel.islandShows`, as the panel's `syncShownRequest` sends it. Fixtures in codex-rs's shapes.
@MainActor
@Suite(.serialized)
struct CodexAllowOptInTests {
    typealias E = AttentionEndToEndTests
    static let migrate: [String: Any] = ["command": "python3 scripts/migrate.py --apply", "description": "Apply the migration"]
    static let clean: [String: Any] = ["command": "rm -rf build"]

    // MARK: Rig

    /// A rig with Answer Codex on the island on, and a Codex session begun through the helper, its rollout (a scratch
    /// file, reviewer `reviewer`) watched by a real tracker.
    private func optedIn(reviewer: String = "user", app: Bool = false, backstop: TimeInterval = 600,
                         on: Bool = true) async throws -> (rig: AttentionRig, watch: (url: URL, tracker: CodexRolloutTracker)) {
        let rig = try await AttentionRig(subagentBackstop: backstop)
        rig.engine.answersCodex = on
        let url = rig.folder.appendingPathComponent("rollout-c1.jsonl")
        let meta = RolloutLines.line("session_meta", ["id": "c1", "cwd": "/tmp/project", "originator": app ? "codex_desktop" : "codex_cli_rs",
                                                      "source": app ? "vscode" : "cli"], at: 0)
        try RolloutLines.text([meta, RolloutLines.turnContext(reviewer: reviewer), RolloutLines.event("task_started", at: 0)])
            .write(to: url, atomically: true, encoding: .utf8)
        await rig.finished(E.codex("SessionStart", transcript: url.path), source: nil, entrypoint: nil,
                           events: [E.started("c1", tool: .codex, transcript: url.path)])
        await rig.finished(E.codex("UserPromptSubmit", transcript: url.path, extra: ["prompt": "run the migration"]), source: nil,
                           entrypoint: nil, events: E.prompt("c1", "run the migration", tool: .codex, transcript: url.path))
        if app, var thread = rig.engine.state.session(id: "c1") {
            thread.isCodexAppSession = true
            rig.engine.replace(thread)
        }
        let tracker = CodexRolloutTracker(pollInterval: 60)
        tracker.attentionHandler = { [weak engine = rig.engine] update in
            Task { @MainActor in engine?.ingestCodexAttention(update) }
        }
        tracker.eventHandler = { [weak engine = rig.engine] event in
            Task { @MainActor in engine?.ingest(event, ingress: .rollout) }
        }
        tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: "c1", transcriptPath: url.path)])
        tracker.waitUntilIdle()
        await rig.settle()
        return (rig, (url, tracker))
    }

    /// Codex asks: its PermissionRequest through the built helper, run as upstream's installer writes Codex's hooks
    /// (no `--source`, P290). Waits until the engine has entered it.
    private func ask(_ rig: AttentionRig, _ watch: (url: URL, tracker: CodexRolloutTracker), _ input: [String: Any] = migrate,
                     tool: String = "Bash") async -> HelperRun {
        let count = rig.engine.openRequests.count
        var object = E.codex("PermissionRequest", transcript: watch.url.path, input: input)
        object["tool_name"] = tool
        let run = rig.hook(object, source: nil, entrypoint: nil)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        return run
    }

    /// Lines Codex appends to the rollout, read by the tracker.
    private func append(_ lines: [String], to watch: (url: URL, tracker: CodexRolloutTracker), _ rig: AttentionRig) async {
        let handle = try! FileHandle(forWritingTo: watch.url)
        handle.seekToEndOfFile()
        handle.write(Data(RolloutLines.text(lines).utf8))
        try? handle.close()
        watch.tracker.pollNow(sessionID: "c1")
        watch.tracker.waitUntilIdle()
        await rig.settle()
    }

    /// The call Codex runs once allowed, and its output: evidence that closes a released request.
    private func ran(_ rig: AttentionRig, _ watch: (url: URL, tracker: CodexRolloutTracker), _ callID: String, _ command: String) async {
        let asked = E.askedAt(rig)
        await append([RolloutLines.call("exec_command", callID, #"{"cmd":"\#(command)"}"#, at: asked),
                      RolloutLines.output(callID, "ok", at: asked + 1)], to: watch, rig)
    }

    private func approval(_ rig: AttentionRig) -> ApprovalCardModel? {
        if case let .approval(card)? = rig.card("c1") { card } else { nil }
    }

    private func held(_ rig: AttentionRig) throws -> (card: ApprovalCardModel, request: CardRequest) {
        let card = try #require(approval(rig))
        return (card, try #require(card.request))
    }

    private func left(_ rig: AttentionRig) throws -> TimeInterval {
        try #require(held(rig).request.holdEnds).timeIntervalSince(rig.now)
    }

    /// The helper ended with nothing printed: Codex's own prompt or reviewer decides (a release, a quit: fail open).
    private func silent(_ run: HelperRun) async -> Bool {
        guard let result = await run.result(within: 30) else { return false }
        return result.status == 0 && result.stdout.isEmpty
    }

    /// What the helper printed, checked against Codex's PermissionRequest output schema: exactly `continue: true` and
    /// `hookSpecificOutput` with `hookEventName` and `decision`, whose fields are `behavior` and, for a deny, `message`.
    private func printed(_ run: HelperRun) async -> [String: Any]? {
        guard let result = await run.result(within: 30), result.status == 0,
              let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              Set(object.keys) == ["continue", "hookSpecificOutput"], object["continue"] as? Bool == true,
              let output = object["hookSpecificOutput"] as? [String: Any], Set(output.keys) == ["hookEventName", "decision"],
              output["hookEventName"] as? String == "PermissionRequest",
              let decision = output["decision"] as? [String: Any] else { return nil }
        switch decision["behavior"] as? String {
        case "allow": return Set(decision.keys) == ["behavior"] ? decision : nil
        case "deny": return Set(decision.keys) == ["behavior", "message"] && decision["message"] is String ? decision : nil
        default: return nil
        }
    }

    // MARK: Answered on the island

    /// Held, confirmed and sounded at once, answerable with its countdown; the island's Yes, three seconds in, reaches
    /// that request's own helper as Codex's allow, and nothing else. No Always allow and no No and stop reach it.
    @Test
    func cxhAllowOnTheIslandReachesCodexsOwnHelper() async throws {
        let (rig, watch) = try await optedIn()
        defer { watch.tracker.stop(); rig.stop() }
        let run = await ask(rig, watch)
        #expect(await rig.released(1) == false && run.isRunning)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let shown = try held(rig)
        let opened = try #require(rig.engine.openRequests.first)
        #expect(shown.request.answerable && !shown.request.dismissable && shown.request.place == .terminal)
        #expect(shown.request.holdEnds == opened.openedAt.addingTimeInterval(CodexHold.limit) && opened.isConfirmed)
        #expect(shown.card.alwaysAllowLabel == nil && !shown.card.canStop)
        #expect(rig.needsYou.count == 1 && rig.row("c1")?.glyph == .bang)
        #expect(rig.upstream.current?.commands.contains { $0.event == "PermissionRequest" } == false)
        rig.model.islandShows(requestID: shown.request.id)

        rig.advance(3)
        for refused in [ApprovalDecision.alwaysAllow, .denyAndStop] {
            #expect(await rig.engine.approve(requestID: shown.request.id, decision: refused) == .nothingToSend)
        }
        #expect(run.isRunning)
        await rig.model.decide("c1", .allowOnce, request: shown.request.id)
        let decision = try #require(await printed(run))
        #expect(decision["behavior"] as? String == "allow")
        await rig.settle()
        #expect(rig.card("c1") == nil && rig.engine.openRequests.isEmpty && rig.row("c1")?.bucket != .needsYou)
        await ran(rig, watch, "call_1", Self.migrate["command"] as! String)
        rig.advance(20)
        #expect(rig.needsYou.count == 1 && rig.dones.isEmpty && rig.engine.attentionTally.codexHolds.isEmpty)
    }

    /// No, and No with a reason, from the island within the hold: Codex gets the deny, with the reason as the message its
    /// model reads.
    @Test
    func cxhNoAndNoWithAReasonOnTheIsland() async throws {
        let (rig, watch) = try await optedIn()
        defer { watch.tracker.stop(); rig.stop() }
        let first = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.advance(2)
        await rig.model.decide("c1", .deny, request: try held(rig).request.id)
        let no = try #require(await printed(first))
        #expect(no["behavior"] as? String == "deny" && no["message"] as? String == ApprovalChoices.denyMessage)
        await rig.settle()
        #expect(rig.card("c1") == nil)

        let second = await ask(rig, watch, Self.clean)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let request = try held(rig).request
        rig.model.islandShows(requestID: request.id)
        rig.advance(try left(rig) - 1)
        await rig.model.decide("c1", .denyWithReason("keep the build, it is cached"), request: request.id)
        let reason = try #require(await printed(second))
        #expect(reason["behavior"] as? String == "deny" && reason["message"] as? String == "keep the build, it is cached")
        await rig.settle()
        #expect(rig.engine.openRequests.isEmpty && rig.card("c1") == nil)
    }

    // MARK: Answered in the window (P1050)

    /// Window mode: the window's Needs you card holds the request as the island's card does. Shown there, Yes reaches
    /// that request's own helper as Codex's allow, and No with a reason as its deny.
    @Test
    func cxhTheWindowsCardAnswersCodexInWindowMode() async throws {
        let (rig, watch) = try await optedIn()
        defer { watch.tracker.stop(); rig.stop() }
        let run = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let shown = try held(rig)
        rig.model.windowShows(requestIDs: [shown.request.id])
        rig.advance(CodexHold.showGrace + 3)
        #expect(run.isRunning && approval(rig)?.isAnswerable == true)
        await rig.model.decide("c1", .allowOnce, request: shown.request.id)
        let decision = try #require(await printed(run))
        #expect(decision["behavior"] as? String == "allow")
        await rig.settle()
        #expect(rig.card("c1") == nil && rig.engine.openRequests.isEmpty)
        await ran(rig, watch, "call_1", Self.migrate["command"] as! String)

        let second = await ask(rig, watch, Self.clean)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let request = try held(rig).request
        rig.model.windowShows(requestIDs: [request.id])
        rig.advance(4)
        await rig.model.decide("c1", .denyWithReason("keep the build"), request: request.id)
        let no = try #require(await printed(second))
        #expect(no["behavior"] as? String == "deny" && no["message"] as? String == "keep the build")
        #expect(rig.engine.attentionTally.codexHolds.isEmpty)
    }

    /// Held only while the window shows it: never shown within the grace, released at `showGrace`; shown, then no longer
    /// (the window covered, closed or minimised, the owner in another app, the card scrolled away), released at once;
    /// still shown by the island, the window letting it go keeps it held.
    @Test
    func cxhItIsHeldOnlyWhileTheWindowShowsIt() async throws {
        let (rig, watch) = try await optedIn()
        defer { watch.tracker.stop(); rig.stop() }
        let unseen = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        rig.model.windowShows(requestIDs: [])
        rig.advance(CodexHold.showGrace + 0.5)
        #expect(await silent(unseen) && approval(rig)?.isAnswerable == false)
        await ran(rig, watch, "call_1", Self.migrate["command"] as! String)
        await rig.waitUntil { rig.card("c1") == nil }

        let covered = await ask(rig, watch, Self.clean)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let coveredID = try held(rig).request.id
        rig.model.windowShows(requestIDs: [coveredID])
        rig.advance(4)
        rig.model.windowShows(requestIDs: [coveredID, "another-request"])
        #expect(covered.isRunning)
        rig.model.windowShows(requestIDs: ["another-request"])
        #expect(await silent(covered) && approval(rig)?.isAnswerable == false)
        rig.model.windowShows(requestIDs: [])
        await ran(rig, watch, "call_2", Self.clean["command"] as! String)
        await rig.waitUntil { rig.card("c1") == nil }

        let both = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let bothID = try held(rig).request.id
        rig.model.windowShows(requestIDs: [bothID])
        rig.model.islandShows(requestID: bothID)
        rig.model.windowShows(requestIDs: [])
        rig.advance(3)
        #expect(both.isRunning && approval(rig)?.isAnswerable == true)
        rig.model.islandShows(requestID: nil)
        #expect(await silent(both))
        #expect(rig.engine.attentionTally.codexHolds == ["notShown": 1, "hidden": 2])
    }

    // MARK: Released: Codex's own prompt decides

    /// No answer: at the limit the hold ends, the helper exits silent (Codex shows its own prompt) and the card turns
    /// read-only where it is (Open, ✕), still confirmed; the island's buttons send nothing; the call's own evidence ends it.
    @Test
    func cxhLeftAloneItIsReleasedAtTheLimitAndTurnsReadOnly() async throws {
        let (rig, watch) = try await optedIn()
        defer { watch.tracker.stop(); rig.stop() }
        let run = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let id = try held(rig).request.id
        rig.model.islandShows(requestID: id)
        rig.advance(try left(rig) - 0.5)
        #expect(run.isRunning && approval(rig)?.isAnswerable == true)
        rig.advance(1)
        #expect(await silent(run))
        let after = try held(rig)
        #expect(after.request.id == id && !after.request.answerable && after.request.dismissable && after.request.holdEnds == nil)
        for decision in [ApprovalDecision.allowOnce, .deny, .denyWithReason("no")] {
            #expect(await rig.engine.approve(requestID: id, decision: decision) == .nothingToSend)
        }
        await ran(rig, watch, "call_1", Self.migrate["command"] as! String)
        await rig.waitUntil { rig.card("c1") == nil }
        #expect(rig.engine.openRequests.isEmpty && rig.needsYou.count == 1)
        #expect(rig.engine.attentionTally.codexHolds == ["timeUp": 1])
    }

    /// Held only while the island shows it: never shown within the grace, released at `showGrace`; shown, then no longer
    /// (a fold, another app, Esc), released at once; Open releases it before the jump; the switch going off (or Window
    /// mode) releases it at once.
    @Test
    func cxhItIsHeldOnlyWhileTheIslandShowsIt() async throws {
        let (rig, watch) = try await optedIn()
        defer { watch.tracker.stop(); rig.stop() }
        let unseen = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        rig.advance(CodexHold.showGrace - 0.5)
        #expect(unseen.isRunning)
        rig.advance(1)
        #expect(await silent(unseen) && approval(rig)?.isAnswerable == false)
        await ran(rig, watch, "call_1", Self.migrate["command"] as! String)
        await rig.waitUntil { rig.card("c1") == nil }

        let folded = await ask(rig, watch, Self.clean)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.advance(4)
        #expect(folded.isRunning)
        rig.model.islandShows(requestID: nil)
        #expect(await silent(folded) && approval(rig)?.isAnswerable == false)
        await ran(rig, watch, "call_2", Self.clean["command"] as! String)
        await rig.waitUntil { rig.card("c1") == nil }

        let opened = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        let openedID = try held(rig).request.id
        rig.model.islandShows(requestID: openedID)
        rig.model.openRequest("c1", request: openedID)
        #expect(await silent(opened))
        rig.model.islandShows(requestID: nil)
        await ran(rig, watch, "call_3", Self.migrate["command"] as! String)
        await rig.waitUntil { rig.card("c1") == nil }

        let switched = await ask(rig, watch, Self.clean)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.engine.answersCodex = false
        #expect(await silent(switched) && approval(rig)?.isAnswerable == false)
        #expect(rig.engine.attentionTally.codexHolds == ["notShown": 1, "hidden": 1, "opened": 1, "switchedOff": 1])
    }

    // MARK: Never held

    /// "Keeps the approval in the terminal tab you're viewing": with the session's own tab in front, or the Codex app in
    /// front for one of its threads, the helper ends at once and the card comes read-only at 8 s, as with the switch
    /// off; an app thread with another app in front is held.
    @Test
    func cxhTheTabTheOwnerLooksAtKeepsTheApprovalInCodex() async throws {
        let (tab, tabWatch) = try await optedIn()
        defer { tabWatch.tracker.stop(); tab.stop() }
        tab.frontTab.update { $0 = true }
        let inTab = await ask(tab, tabWatch)
        #expect(await silent(inTab) && tab.card("c1") == nil)
        tab.advance(8)
        #expect(approval(tab)?.isAnswerable == false && approval(tab)?.request?.place == .terminal)

        let (app, appWatch) = try await optedIn(app: true)
        defer { appWatch.tracker.stop(); app.stop() }
        app.front.update { $0 = ExactJump.codexBundleID }
        let inApp = await ask(app, appWatch)
        #expect(await silent(inApp))
        await ran(app, appWatch, "call_1", Self.migrate["command"] as! String)
        app.front.update { $0 = "com.apple.Safari" }
        let elsewhere = await ask(app, appWatch, Self.clean)
        await app.waitUntil { approval(app)?.isAnswerable == true }
        #expect(elsewhere.isRunning && approval(app)?.request?.place == .codexApp)
        #expect(tab.engine.attentionTally.codexHolds == ["focused": 1] && app.engine.attentionTally.codexHolds == ["focused": 1])
    }

    /// An island Allow never settles what Codex's reviewer would: under auto review the helper ends at once and nothing
    /// shows, as with the switch off.
    @Test
    func cxhAnAutoReviewedThreadIsNeverHeld() async throws {
        let (rig, watch) = try await optedIn(reviewer: "auto_review")
        defer { watch.tracker.stop(); rig.stop() }
        var object = E.codex("PermissionRequest", transcript: watch.url.path, input: Self.migrate)
        object["tool_name"] = "Bash"
        let run = rig.hook(object, source: nil, entrypoint: nil)
        #expect(await silent(run))
        rig.advance(10)
        await rig.settle()
        #expect(rig.card("c1") == nil && rig.engine.openRequests.isEmpty && rig.needsYou.isEmpty)
        #expect(rig.engine.attentionTally.codexHolds == ["reviewer": 1])
    }

    /// The app quits mid-hold: the helper exits silent at once and Codex shows its own prompt. A crash ends the
    /// connection the same way. And the broker ends a hold by itself at its bound, whatever the main thread does; the
    /// island's Yes then finds it gone and sends nothing.
    @Test
    func cxhQuittingOrABrokerBoundEndsTheHoldSilently() async throws {
        let (rig, watch) = try await optedIn()
        let run = await ask(rig, watch)
        await rig.waitUntil { approval(rig)?.isAnswerable == true }
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.advance(4)
        #expect(run.isRunning)
        rig.engine.stop()
        #expect(await silent(run))
        watch.tracker.stop()
        rig.stop()

        let (bound, boundWatch) = try await optedIn(backstop: 1)
        defer { boundWatch.tracker.stop(); bound.stop() }
        let stuck = await ask(bound, boundWatch)
        await bound.waitUntil { approval(bound)?.isAnswerable == true }
        let id = try held(bound).request.id
        bound.model.islandShows(requestID: id)
        #expect(await silent(stuck))
        await bound.model.decide("c1", .allowOnce, request: id)
        #expect(approval(bound)?.isAnswerable == false && approval(bound)?.request?.id == id)
        #expect(bound.engine.attentionTally.codexHolds == ["brokerEnded": 1])
    }

    /// With the switch off (the default) nothing changes: every Codex request is handed back at once (CX1).
    @Test
    func cxhOffEveryCodexRequestIsHandedBackAtOnce() async throws {
        let (rig, watch) = try await optedIn(on: false)
        defer { watch.tracker.stop(); rig.stop() }
        let run = await ask(rig, watch)
        let released = await rig.released(1)
        #expect(released)
        #expect(await silent(run))
        rig.advance(8)
        #expect(approval(rig)?.isAnswerable == false && rig.needsYou.count == 1 && rig.engine.attentionTally.codexHolds.isEmpty)
    }
}

/// The switch itself (P470): off by default, on in both modes since the window's Needs you card holds a request as the
/// island's card does (P1050; Answer subagents stays the island's), kept in defaults, followed by the live engine as it
/// changes; Diagnostics counts how Codex holds ended.
@MainActor
@Suite(.serialized)
struct CodexAnswerSwitchTests {
    @Test
    func theSwitchIsOffByDefaultAndAnswersInEitherMode() throws {
        let settings = AppSettings.ephemeral()
        #expect(!settings.answerCodexOnIsland)
        settings.showAs = .island
        #expect(!LiveSessions.answersCodex(settings))
        settings.answerCodexOnIsland = true
        settings.answerSubagentsOnIsland = true
        #expect(LiveSessions.answersCodex(settings) && LiveSessions.answersSubagents(settings))
        settings.showAs = .window
        #expect(LiveSessions.answersCodex(settings) && !LiveSessions.answersSubagents(settings))
        settings.answerSubagentsOnIsland = false

        let suite = "ji-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppSettings(defaults: defaults, identity: .development).answerCodexOnIsland)
        AppSettings(defaults: defaults, identity: .development).answerCodexOnIsland = true
        #expect(defaults.bool(forKey: AppSettings.Key.answerCodex))
        #expect(AppSettings(defaults: defaults, identity: .development).answerCodexOnIsland)
        #expect(IslandPaneText.answerCodex == "Codex's own prompt waits up to 12 s.")
    }

    @Test
    func theLiveEngineFollowsTheSwitchAndShowAs() async throws {
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        settings.showAs = .island
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .owner).makeModel() },
                                engine: { SessionEngine.preview() }, profiles: { LiveProfiles(accounts: [], discovered: []) },
                                identity: .other)
        live.activate()
        defer { live.shutdown() }
        let engine = try #require(live.engine)
        #expect(!engine.answersCodex)
        settings.answerCodexOnIsland = true
        for _ in 0..<100 where !engine.answersCodex { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.answersCodex && !engine.answersSubagents)
        settings.answerSubagentsOnIsland = true
        for _ in 0..<100 where !engine.answersSubagents { try await Task.sleep(for: .milliseconds(10)) }
        settings.showAs = .window
        for _ in 0..<100 where engine.answersSubagents { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.answersCodex && !engine.answersSubagents)
        settings.answerCodexOnIsland = false
        for _ in 0..<100 where engine.answersCodex { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!engine.answersCodex)
    }

    @Test
    func diagnosticsCountsHowCodexHoldsEnded() throws {
        var tally = AttentionTally()
        tally.codexHolds = ["focused": 2, "timeUp": 1]
        let details = try #require(DiagnosticsText.attentionDetails(tally))
        #expect(details == "Codex holds ended: focused 2, timeUp 1")
    }
}
