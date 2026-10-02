import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// P290 end to end, with Codex's hooks run as upstream's installer writes them: the built helper with no `--source`.
/// Its notes name Codex, so a new turn's prompt ends the last turn's approval (C8) while a prompt steered into the turn
/// leaves it. The other end-to-end suites run Codex's hooks with `--source codex`, which no installed hook passes, and
/// so never saw the notes arrive unnamed.
@MainActor
@Suite(.serialized)
struct CodexHookSourceEndToEndTests {
    typealias E = AttentionEndToEndTests

    @Test
    func aCodexHookWithNoSourceIsReadAsCodexs() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        let url = rig.folder.appendingPathComponent("rollout-c1.jsonl")
        let meta = RolloutLines.line("session_meta", ["id": "c1", "cwd": "/tmp/project", "originator": "codex_cli_rs", "source": "cli"], at: 0)
        try RolloutLines.text([meta, RolloutLines.turnContext(reviewer: "user"), RolloutLines.event("task_started", at: 0)])
            .write(to: url, atomically: true, encoding: .utf8)
        await rig.finished(E.codex("SessionStart", transcript: url.path), source: nil, entrypoint: nil,
                           events: [E.started("c1", tool: .codex, transcript: url.path)])
        await rig.finished(E.codex("UserPromptSubmit", transcript: url.path, extra: ["prompt": "tidy the paper"]), source: nil,
                           entrypoint: nil, events: E.prompt("c1", "tidy the paper", tool: .codex, transcript: url.path))
        // Upstream's helper took them as Codex's, as it takes every hook with no source.
        #expect(rig.upstream.current?.commands.map(\.source) == ["codex", "codex"])

        let result = await rig.hook(E.codex("PermissionRequest", transcript: url.path), source: nil, entrypoint: nil).result(within: 30)
        let released = await rig.released(1)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true && released)
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        await rig.finished(E.codex("UserPromptSubmit", turn: "turn-1", transcript: url.path, extra: ["prompt": "use the staging remote"]),
                           source: nil, entrypoint: nil)
        #expect(rig.engine.openRequests.count == 1, "a prompt steered into the running turn closed its approval")
        await rig.finished(E.codex("UserPromptSubmit", turn: "turn-2", transcript: url.path, extra: ["prompt": "now the docs"]),
                           source: nil, entrypoint: nil)
        #expect(rig.engine.openRequests.isEmpty, "the new turn's prompt left the last turn's approval open")
    }
}
