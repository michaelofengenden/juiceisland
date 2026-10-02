import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// CB7 (boost hunt, C11 for the Claude "prompt with no hook" and MCP rows): a notice opened from a Notification's note
/// takes no agent pid (the note has one), so the liveness pass never closes it; and a session with a confirmed request
/// is never ended by the pass (`waitsOnYou`). A Claude that crashes (no SessionEnd) while its sandbox prompt or MCP
/// form waits leaves "!" or "?" for good.
@MainActor
struct BoostClaudeCB7Tests {
    typealias S = AttentionScene

    @Test
    func cb7ANoticeOfAGoneAgentCloses() {
        for type in ["permission_prompt", "elicitation_dialog"] {
            let s = S()
            s.begin()
            s.hook(S.notification(type), pid: 900)
            #expect(s.glyph() != nil, "\(type)")
            s.gone.update { _ = $0.insert(900) }
            s.livenessPass()
            #expect(s.glyph() == nil, "\(type): the notice outlives its agent")
        }
    }
}
