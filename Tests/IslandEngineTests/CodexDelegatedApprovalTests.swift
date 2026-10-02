import Foundation
import OpenIslandCore
import Testing
@testable import IslandEngine

/// P733: a Codex chat that handed its work to a subagent (its own turn ended while the subagent runs, P513), and that
/// subagent's approval. The request keeps its own context and owner: it waits on the chat's row under the subagent's
/// role with the subagent's command; with Answer Codex on the island on it is still never held (only a main-thread call
/// is, P470), so no island answer can reach the subagent's call as the chat's; the chat's own call with the same command
/// and its output leave it, and only the subagent's own rollout closes it. The chat's status follows: it needs you while
/// the request waits, then waits on its agent again, never running and never done, with no Done sound. Fictional ids
/// and commands; the subagent's rollout is a fixture file in a temporary folder.
@MainActor
@Suite(.serialized)
struct CodexDelegatedApprovalTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias X = CodexAttentionTableTests
    typealias T = CodexThreadFixtures

    @Test
    func aDelegatedRunsApprovalKeepsItsContextItsOwnerAndTheChatsStatus() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("juice-delegated-\(UUID().uuidString.prefix(8))",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("rollout-\(T.subagentID(1)).jsonl")
        try R.text([R.meta(id: T.subagentID(1)), X.reviewer("user"), X.turn, X.exec("call_k1", "make test")])
            .write(to: child, atomically: true, encoding: .utf8)
        let s = S()
        s.engine.answersCodex = true
        s.begin(T.chatA, tool: .codex, prompt: "check every section")
        s.rollout(T.chatA, [R.meta(id: T.chatA), X.reviewer("user"), X.turn])
        s.engine.takeCodexChildren([CodexChildThread(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "Hubble",
                                                     isRunning: true, updatedAt: s.clock.current, transcriptPath: child.path)])
        let word = { s.engine.state.session(id: T.chatA).map(s.engine.statusWord) }
        // The chat's own turn ends while its subagent runs: it waits on it.
        s.hook(S.codex("Stop", session: T.chatA), source: "codex")
        s.bridge(F.completed(T.chatA, at: s.clock.current))
        #expect(s.phase(T.chatA) == .completed && word() == .subagents(1))

        // The subagent asks to run `make test`: never held, on the chat's row under its role, with its own command.
        let id = try #require(s.hook(S.codex("PermissionRequest", session: T.chatA, input: ["command": "make test"],
                                             agent: T.subagentID(1), transcript: child.path), source: "codex", entrypoint: nil))
        await s.settle { s.isOpen(id) }
        #expect(s.broker.held.current.isEmpty)
        s.at(9)
        let head = try #require(s.head(T.chatA))
        #expect(head.id == id && head.agentID == T.subagentID(1) && !head.isAnswerable)
        #expect(head.agentType == "explorer")                              // its role, as its hook names it (P219)
        #expect(head.command == "make test" && word() == .needsApproval(tool: "Bash") && s.glyph(T.chatA) == "!")
        s.engine.childRollouts?.waitUntilIdle()
        await s.settle { s.request(id)?.callID != nil }
        #expect(s.request(id)?.callID == "call_k1")

        // The chat's own call with the same command, and its output: not the subagent's.
        s.rollout(T.chatA, [X.exec("call_root", "make test", at: 20), C.output("call_root", "ok", at: 21)])
        #expect(s.isOpen(id) && word() == .needsApproval(tool: "Bash"))

        // The subagent's own output closes it: the chat waits on its agent again, with no Done.
        R.append(R.text([C.output("call_k1", "ok", at: 30)]), to: child)
        s.engine.childRollouts?.pollNow(sessionID: id)
        s.engine.childRollouts?.waitUntilIdle()
        await s.settle { !s.isOpen(id) }
        #expect(!s.isOpen(id) && s.glyph(T.chatA) == nil)
        #expect(s.phase(T.chatA) == .completed && word() == .subagents(1))
        s.at(60)
        #expect(s.dones.isEmpty)
    }
}
