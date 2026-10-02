import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Replay (owner's message 2, Codex): the Codex app's GPT-6 threads run in code mode. Their only shell tool is the
/// `exec` custom tool (codex-rs 0.157 `astra_*` scenario snapshots: `custom/exec`, `function/wait`), whose script calls
/// `tools.exec_command(...)` as a nested call (`core/src/tools/code_mode/mod.rs`, dispatched straight to the tool runtime:
/// no `function_call` line of its own in the rollout). The owner's live threads showed exactly these tools (`exec`,
/// `wait`, `js`; r-phantom §2). A command that needs approval comes to the hook as `Bash`; the rollout only ever shows the
/// `exec` cell and its output. The owner allows it in Codex; the island must not keep "!" once the cell has run.
@MainActor
@Suite(.serialized)
struct ReplayCodexCodeModeTests {
    typealias E = AttentionEndToEndTests

    func beginCodexApp(_ rig: AttentionRig) async throws -> (url: URL, tracker: CodexRolloutTracker) {
        let url = rig.folder.appendingPathComponent("rollout-c1.jsonl")
        let meta = RolloutLines.line("session_meta", ["id": "c1", "cwd": "/tmp/HarborLogPaper", "originator": "codex_desktop", "source": "vscode"], at: 0)
        try RolloutLines.text([meta, RolloutLines.turnContext(reviewer: "user"), RolloutLines.event("task_started", ["turn_id": "turn-1"], at: 0)])
            .write(to: url, atomically: true, encoding: .utf8)
        await rig.finished(E.codex("SessionStart", session: "c1", transcript: url.path, extra: ["source": "startup"]), source: "codex",
                           entrypoint: nil, events: [E.started("c1", tool: .codex, transcript: url.path)])
        await rig.finished(E.codex("UserPromptSubmit", session: "c1", transcript: url.path, extra: ["prompt": "publish the paper branch"]),
                           source: "codex", entrypoint: nil,
                           events: E.prompt("c1", "publish the paper branch", tool: .codex, transcript: url.path))
        if var thread = rig.engine.state.session(id: "c1") {
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
        return (url, tracker)
    }

    func append(_ lines: [String], to watch: (url: URL, tracker: CodexRolloutTracker), _ rig: AttentionRig) async {
        let handle = try! FileHandle(forWritingTo: watch.url)
        handle.seekToEndOfFile()
        handle.write(Data(RolloutLines.text(lines).utf8))
        try? handle.close()
        watch.tracker.pollNow(sessionID: "c1")
        watch.tracker.waitUntilIdle()
        await rig.settle()
    }

    /// The cell that asks is written 30 s before the request by the engine's clock: `RolloutLines`' times count from
    /// their first use in the run, which a slow rig start in a loaded full run can put well after the engine's clock,
    /// and a call that starts more than 5 s after its request is never its call (C7).
    static func beforeNow(_ rig: AttentionRig, _ seconds: Int = 30) -> Int {
        Int(rig.now.timeIntervalSince(RolloutLines.start).rounded(.down)) - seconds
    }

    static func cell(_ callID: String, _ script: String, at second: Int) -> String {
        RolloutLines.item("custom_tool_call", ["name": "exec", "namespace": "functions", "call_id": callID, "input": script], at: second)
    }

    static func cellOutput(_ callID: String, _ output: String, at second: Int) -> String {
        RolloutLines.item("custom_tool_call_output", ["call_id": callID, "output": output], at: second)
    }

    /// Answered in Codex within the island's window (2 s): the cell completes at once. Nothing may be drawn or sounded,
    /// and nothing may stay open while the thread runs a minute more of cells.
    @Test
    func aCodeModeApprovalAnsweredAtOnceIsNeverDrawn() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        let watch = try await beginCodexApp(rig)
        defer { watch.tracker.stop() }
        await append([Self.cell("call_cell1", "const r = await tools.exec_command({cmd: 'git push origin main'});\ntext(r.output);", at: Self.beforeNow(rig))],
                     to: watch, rig)
        let result = await rig.hook(E.codex("PermissionRequest", transcript: watch.url.path,
                                            input: ["command": "git push origin main", "description": "Push the branch"]),
                                    source: "codex", entrypoint: nil).result(within: 30)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true)
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        rig.advance(3)
        await append([Self.cellOutput("call_cell1", "Script completed\n   1a2b3c4..5d6e7f8  main -> main", at: 13)], to: watch, rig)
        for n in 1...20 {
            rig.advance(3)
            await append([Self.cell("call_next\(n)", "text(await tools.exec_command({cmd: 'git log -1'}))", at: 20 + 3 * n),
                          Self.cellOutput("call_next\(n)", "Script completed", at: 21 + 3 * n)], to: watch, rig)
        }
        let row = rig.row("c1")
        #expect(row?.glyph != .bang && row?.bucket != .needsYou,
                "answered in Codex at 2 s, run a minute ago, the row still reads \(String(describing: row?.status))")
        #expect(rig.needsYou.isEmpty, "a needs-you sound for a prompt answered in Codex at 2 s")
        #expect(rig.engine.openRequests.isEmpty, "still open: \(rig.engine.openRequests.map { "\($0.toolName ?? "") callID=\($0.callID ?? "nil")" })")
    }

    /// Left alone: the cell yields at 10 s ("Script running with cell ID 1") while Codex's prompt still waits, so "!"
    /// stays; the owner allows it in Codex at 30 s and the model's `wait` on that cell returns its completion at 32 s: the
    /// "!" goes then, not at the turn's end.
    @Test
    func aCodeModeApprovalLeftAloneEndsWhenItsCellCompletes() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        let watch = try await beginCodexApp(rig)
        defer { watch.tracker.stop() }
        await append([Self.cell("call_cell1", "const r = await tools.exec_command({cmd: 'git push origin main'});\ntext(r.output);", at: Self.beforeNow(rig))],
                     to: watch, rig)
        _ = await rig.hook(E.codex("PermissionRequest", transcript: watch.url.path,
                                   input: ["command": "git push origin main", "description": "Push the branch"]),
                           source: "codex", entrypoint: nil).result(within: 30)
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        rig.advance(10)
        await append([Self.cellOutput("call_cell1", "Script running with cell ID 1", at: 20),
                      RolloutLines.item("function_call", ["name": "wait", "namespace": "functions", "call_id": "call_wait1",
                                                          "arguments": #"{"cell_id":"1","yield_time_ms":30000}"#], at: 20)], to: watch, rig)
        rig.advance(5)
        await rig.settle()
        #expect(rig.row("c1")?.glyph == .bang, "the prompt still waits in Codex at 25 s")
        rig.advance(7)
        await append([RolloutLines.item("function_call_output", ["call_id": "call_wait1",
                                                                 "output": "Script completed\n   1a2b3c4..5d6e7f8  main -> main"], at: 32)],
                     to: watch, rig)
        for n in 1...20 {
            rig.advance(3)
            await append([Self.cell("call_next\(n)", "text(await tools.exec_command({cmd: 'git log -1'}))", at: 35 + 3 * n),
                          Self.cellOutput("call_next\(n)", "Script completed", at: 36 + 3 * n)], to: watch, rig)
        }
        let row = rig.row("c1")
        #expect(row?.glyph != .bang && row?.bucket != .needsYou,
                "allowed in Codex at 30 s and run, a minute later the row still reads \(String(describing: row?.status))")
        #expect(rig.engine.openRequests.isEmpty, "still open: \(rig.engine.openRequests.map { "\($0.toolName ?? "") callID=\($0.callID ?? "nil")" })")
    }

    /// The two complaints together: a code-mode push allowed in Codex at 2 s, then, a minute later, the Section E
    /// question. The row must read Question with "?" and the question's card, not a stale "Needs approval" in front of it.
    @Test
    func aQuestionAfterAnAnsweredCodeModeApprovalIsShown() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        let watch = try await beginCodexApp(rig)
        defer { watch.tracker.stop() }
        await append([Self.cell("call_cell1", "const r = await tools.exec_command({cmd: 'git push origin main'});\ntext(r.output);", at: Self.beforeNow(rig))],
                     to: watch, rig)
        _ = await rig.hook(E.codex("PermissionRequest", transcript: watch.url.path,
                                   input: ["command": "git push origin main", "description": "Push the branch"]),
                           source: "codex", entrypoint: nil).result(within: 30)
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        rig.advance(3)
        await append([Self.cellOutput("call_cell1", "Script completed", at: 13)], to: watch, rig)
        rig.advance(60)
        let title = "Section E also contains Figure 17. Should I move it with the rest of Section E, or keep it in the appendix?"
        let arguments = #"{"questions":[{"options":["Move Figure 17 with Section E","Keep Figure 17 in the appendix"],"title":"\#(title)"}]}"#
        await append([RolloutLines.item("function_call", ["name": "request_user_input_async", "namespace": "functions", "call_id": "call_q17",
                                                          "arguments": arguments], at: 73),
                      RolloutLines.item("function_call_output", ["call_id": "call_q17", "output": #"{"accepted":true}"#], at: 73)], to: watch, rig)
        await rig.waitUntil(5) { rig.row("c1")?.glyph == .ques }
        #expect(rig.row("c1")?.glyph == .ques && rig.row("c1")?.status == .question,
                "the row reads \(String(describing: rig.row("c1")?.status)) while the question waits")
        guard case .question? = rig.card("c1") else {
            Issue.record("the card is \(String(describing: rig.card("c1"))), not the question")
            return
        }
    }
}
