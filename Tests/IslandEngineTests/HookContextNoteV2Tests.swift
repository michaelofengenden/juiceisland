import Foundation
import IslandHookNotes
import Testing

/// Note version 2: ids, names, counts and an input digest, still never text or a path; version 1 still reads.
struct HookContextNoteV2Tests {
    static let preToolUse = Data(#"""
    {"hook_event_name":"PreToolUse","session_id":"root-1","tool_name":"Bash","tool_use_id":"toolu_01A",
     "tool_input":{"command":"rm -rf build","description":"clean the build folder"},"agent_id":"a-77","agent_type":"worker",
     "permission_mode":"bypassPermissions","transcript_path":"/tmp/secret-folder/t.jsonl","cwd":"/tmp/secret-folder",
     "prompt":"a secret prompt"}
    """#.utf8)

    @Test
    func aToolEventCarriesItsIdsAndADigestButNoText() throws {
        let note = try #require(HookContextNote.make(input: Self.preToolUse, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"],
                                                     agentPID: 900, source: "claude"))
        #expect(note.version == 2)
        #expect(note.toolUseID == "toolu_01A" && note.toolName == "Bash" && note.agentID == "a-77" && note.agentType == "worker")
        #expect(note.permissionMode == "bypassPermissions" && note.entrypoint == "cli" && note.source == "claude")
        #expect(note.inputDigest == HookInputDigest.of(["description": "clean the build folder", "command": "rm -rf build"]))
        #expect(note.inputDigest?.count == 16)
        let text = String(decoding: try #require(note.encoded()), as: UTF8.self)
        for secret in ["rm -rf", "clean the build", "secret-folder", "secret prompt", "t.jsonl"] {
            #expect(!text.contains(secret), "\(secret) leaked into \(text)")
        }
        #expect(HookContextNote.decode(try #require(note.encoded())) == note)
    }

    @Test
    func theDigestIgnoresKeyOrderAndTellsInputsApart() {
        let one = HookInputDigest.of(["b": 2, "a": ["x": "y", "w": [1, 2]]] as [String: Any])
        let two = HookInputDigest.of(["a": ["w": [1, 2], "x": "y"], "b": 2] as [String: Any])
        #expect(one == two)
        #expect(one != HookInputDigest.of(["a": ["w": [1, 2], "x": "z"], "b": 2] as [String: Any]))
    }

    @Test
    func notificationsStartsStopsAndTurnsCarryTheirFields() throws {
        let notice = Data(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#.utf8)
        let noted = try #require(HookContextNote.make(input: notice, environment: [:], agentPID: nil))
        #expect(noted.notificationType == "permission_prompt" && noted.inputDigest == nil)
        #expect(!String(decoding: try #require(noted.encoded()), as: UTF8.self).contains("needs your permission"))

        let start = Data(#"{"hook_event_name":"SessionStart","session_id":"s","source":"fork"}"#.utf8)
        #expect(try #require(HookContextNote.make(input: start, environment: [:], agentPID: nil)).sessionStartSource == "fork")
        let stop = Data(#"{"hook_event_name":"Stop","session_id":"s","background_tasks":[{"id":"1"},{"id":"2"}]}"#.utf8)
        #expect(try #require(HookContextNote.make(input: stop, environment: [:], agentPID: nil)).backgroundTaskCount == 2)
        let prompt = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","turn_id":"turn-9","source":"x"}"#.utf8)
        let turn = try #require(HookContextNote.make(input: prompt, environment: [:], agentPID: nil))
        #expect(turn.turnID == "turn-9" && turn.sessionStartSource == nil)
    }

    /// P163: the helper and the app may be a build apart, so version 1 notes still read; an unknown version does not.
    @Test
    func versionOneStillReadsAndAnUnknownVersionDoesNot() throws {
        let one = Data(#"{"v":1,"event":"Stop","session_id":"s","agent_pid":42}"#.utf8)
        let decoded = try #require(HookContextNote.decode(one))
        #expect(decoded.version == 1 && decoded.agentPID == 42 && decoded.toolUseID == nil)
        #expect(HookContextNote.decode(Data(#"{"v":3,"event":"Stop","session_id":"s"}"#.utf8)) == nil)
    }

    /// Every field at its longest still gives one datagram: the names only shown go first, the ids stay.
    @Test
    func theWidestNoteStillFits() throws {
        let limit = String(repeating: "y", count: HookContextNote.fieldLimit)
        let widest = HookContextNote(event: String(repeating: "E", count: 64), sessionID: String(repeating: "S", count: 128),
                                     stopHookActive: true, itermSessionID: limit, tmux: limit, tmuxPane: limit, agentPID: Int32.max,
                                     hostBundleID: limit, termProgram: limit, toolUseID: String(repeating: "t", count: 128),
                                     toolName: String(repeating: "n", count: 64), agentID: String(repeating: "a", count: 128),
                                     agentType: String(repeating: "k", count: 64), notificationType: String(repeating: "p", count: 64),
                                     permissionMode: String(repeating: "m", count: 32), entrypoint: String(repeating: "e", count: 32),
                                     turnID: String(repeating: "u", count: 128), source: "claude",
                                     sessionStartSource: String(repeating: "s", count: 32), backgroundTaskCount: 99,
                                     inputDigest: String(repeating: "d", count: 16), effort: String(repeating: "f", count: 16),
                                     backgroundTaskKinds: Dictionary(uniqueKeysWithValues: (HookContextNote.knownBackgroundKinds
                                         .union([HookContextNote.otherBackgroundKind])).map { ($0, 999) }),
                                     agentInBackground: true)
        let data = try #require(widest.encoded())
        #expect(data.count <= HookContextNote.maximumSize)
        let decoded = try #require(HookContextNote.decode(data))
        #expect(decoded.toolUseID == widest.toolUseID && decoded.agentID == widest.agentID && decoded.turnID == widest.turnID)
        // The kinds the engine waits on stay (P510).
        #expect(decoded.backgroundTaskKinds?["subagent"] == 999 && decoded.backgroundTaskKinds?["workflow"] == 999)
        #expect(decoded.agentInBackground == true)
        #expect(decoded.notificationType == widest.notificationType && decoded.inputDigest == widest.inputDigest)
    }
}
