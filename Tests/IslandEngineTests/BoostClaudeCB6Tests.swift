import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// CB6 (boost hunt, the broker fallback C16 and CL5/C8 for bridge-held Claude requests): upstream's bridge drops its one
/// slot on *any* PostToolUse, PostToolUseFailure, PermissionDenied or UserPromptSubmit of the session
/// (`clearStaleClaudeInteractionIfNeeded`, `BridgeServer.swift:2250-2264`) and says so with `actionableStateResolved`
/// ("Approval was handled outside Open Island."), but it neither answers nor disconnects the helper, and Claude still
/// shows its prompt. The book reads that event as the hook's end and closes the request, so a parallel Read's
/// PostToolUse (probe S5) or a `<task-notification>` turn removes a real wait. With a note-v2 helper (the fallback) the
/// engine has the evidence that the PostToolUse was another call's.
@MainActor
struct BoostClaudeCB6Tests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    @Test
    func cb6AFallbackRequestOutlivesASiblingsPostToolUse() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "U2"))
        s.bridge(F.running("s1", summary: "Running Read", at: s.clock.current))
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "U1"))
        s.bridge(F.running("s1", summary: "Running Bash: git push origin main", at: s.clock.current))
        // No broker: the new helper sends its note, then runs upstream's helper, which the bridge holds.
        let note = try #require(HookContextNote.make(object: S.claude("PermissionRequest", tool: "Bash", input: S.push),
                                                     environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"], agentPID: 900, source: "claude"))
        s.engine.ingest(note: note)
        s.bridge(F.permission("s1", toolUseID: "U1", at: s.clock.current))
        let id = try #require(s.engine.openRequests.first?.id)
        s.at(1)
        s.hook(S.claude("PostToolUse", tool: "Read", input: S.read, toolUseID: "U2"))
        s.bridge(.actionableStateResolved(ActionableStateResolved(sessionID: "s1", summary: "Approval was handled outside Open Island.",
                                                                  timestamp: s.clock.current)),
                 F.running("s1", summary: "Read finished.", at: s.clock.current))
        #expect(s.isOpen(id), "a sibling's PostToolUse closed the Bash request (S5)")
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        #expect(s.glyph() == "!")
    }
}
