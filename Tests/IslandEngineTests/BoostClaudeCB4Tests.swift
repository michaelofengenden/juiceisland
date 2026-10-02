import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// CB4 (boost hunt, Claude legacy rows of §2.5 and the broker fallback, C16): a request upstream's bridge holds (the
/// owner's helper until Setup's Update, or a new helper that found no broker) follows the Claude rules, the transcript
/// evidence included: a deny with feedback or Esc at Claude's prompt fires no hook and only writes the call's
/// `tool_result`. The bridge's request carries the call's id (`claudeToolUseID`, from its PreToolUse cache) and the
/// session's transcript is known, but the book's legacy request is built with no transcript path, so it is never
/// watched: after Esc it stays "!" (drawn at 8 s with a note-v1 helper, with a sound) until the next prompt.
@MainActor
struct BoostClaudeCB4Tests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    @Test
    func cb4ALegacyRequestIsClosedByItsTranscriptResult() async throws {
        for version in [1, 2] {
            let s = S()
            s.begin()
            s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "U1"), version: version)
            s.bridge(F.running("s1", summary: "Running Bash: git push origin main", at: s.clock.current))
            s.bridge(F.permission("s1", toolUseID: "U1", at: s.clock.current))
            s.at(6)
            if version >= 2 { s.hook(S.notification("permission_prompt")) } else { s.at(8) }
            #expect(s.glyph() == "!", "v\(version)")
            #expect(s.watches.all.current.map(\.toolUseID) == ["U1"], "v\(version): the legacy request is not watched")
            // Esc at Claude's prompt: the call's result in the session's transcript.
            await s.transcriptResult("U1")
            #expect(s.glyph() == nil, "v\(version)")
        }
    }
}
