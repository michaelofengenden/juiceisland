import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// P290: upstream's installer writes Codex's hooks with no `--source`, and the helper's notes for them named none, so
/// every Codex check on a note never matched: a new turn's prompt left the last turn's approvals open (C8), and a
/// Codex hook never had its rollout read at once. The helper now names Codex; a note from a helper before that (note
/// version 2 with no source) reads as Codex's too, since Codex's is the only hook upstream's installer leaves unnamed.
@MainActor
@Suite(.serialized)
struct CodexNoteSourceTests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias T = CodexAttentionTableTests

    /// The note a helper sends for a Codex hook with no `--source`: the helper since P290 names Codex, one before it
    /// named nothing.
    static func note(_ object: [String: Any], helperBeforeP290: Bool) throws -> HookContextNote {
        var note = try #require(HookContextNote.make(object: object, environment: [:], agentPID: 900, source: HookContextNote.codexSource))
        if helperBeforeP290 { note.source = nil }
        return note
    }

    @Test func aNoteSaysWhichAgentItIsForWhicheverHelperSentIt() throws {
        let object = S.codex("UserPromptSubmit", turn: "turn-2")
        #expect(try Self.note(object, helperBeforeP290: false).agentSource == "codex")
        #expect(try Self.note(object, helperBeforeP290: true).agentSource == "codex")
        for source in ["claude", "qwen", "gemini"] {
            #expect(HookContextNote.make(object: object, environment: [:], agentPID: nil, source: source)?.agentSource == source)
        }
        // A version-1 note never said which agent it was for.
        var old = try Self.note(object, helperBeforeP290: true)
        old.version = 1
        #expect(old.agentSource == nil)
        // It travels as it is: the datagram names Codex.
        let sent = try #require(try Self.note(object, helperBeforeP290: false).encoded().flatMap(HookContextNote.decode))
        #expect(sent.source == "codex")
    }

    /// C8 with Codex's notes as they come: a prompt steered into the running turn leaves the approval, a new turn's
    /// prompt closes it, from today's helper and from one before P290 alike (it stayed open until the turn's end).
    @Test(arguments: [false, true])
    func aNewCodexTurnClosesTheLastTurnsApproval(helperBeforeP290: Bool) throws {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user"), T.turn])
        let id = try #require(s.hook(S.codex("PermissionRequest", turn: "turn-1"), source: "codex", entrypoint: nil))
        s.at(8)
        s.engine.ingest(note: try Self.note(S.codex("UserPromptSubmit", turn: "turn-1", extra: ["prompt": "use the staging remote"]),
                                            helperBeforeP290: helperBeforeP290))
        #expect(s.isOpen(id))
        s.engine.ingest(note: try Self.note(S.codex("UserPromptSubmit", turn: "turn-2", extra: ["prompt": "now the docs"]),
                                            helperBeforeP290: helperBeforeP290))
        #expect(!s.isOpen(id))
    }

    /// A Codex Notification (should Codex ever send one) is not Claude's `permission_prompt`, whichever helper sent it.
    @Test(arguments: [false, true])
    func aCodexNoteIsNeverReadAsClaudesNotice(helperBeforeP290: Bool) throws {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user"), T.turn])
        let notice = S.codex("Notification", extra: ["notification_type": "permission_prompt", "message": "Codex needs your permission"])
        s.engine.ingest(note: try Self.note(notice, helperBeforeP290: helperBeforeP290))
        #expect(s.engine.openRequests.isEmpty && s.engine.attentionTally.noticesWithoutRequest == 0)
    }
}
