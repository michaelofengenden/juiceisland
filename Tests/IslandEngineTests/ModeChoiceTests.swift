import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// A plan approved into a mode, and an approval that also switches the session's mode (P450-P455): what each card
/// offers, and the exact decision that goes back to Claude. Hooks in the shapes of the public hooks docs
/// (`PermissionRequest` input with `permission_mode` and `permission_suggestions`; `updatedPermissions` entries
/// `{"type": "setMode", "mode": …, "destination": "session"}`); fictional values.
@MainActor
struct ModeChoiceTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    static let plan: [String: Any] = ["plan": "1. Read the code\n2. Fix the tests", "planFilePath": "/tmp/project/plans/fix.md"]

    /// Claude's own suggestion for a file change in Manual mode (its "Yes, allow all edits during this session"), with the
    /// working folder it would add.
    static let editSuggestions: [[String: Any]] = [
        ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ["type": "addDirectories", "directories": ["/tmp/other"], "destination": "session"],
    ]

    /// A plan confirmed on the island (answerable, the broker holding it): its request id.
    private func askPlan(_ s: S, pid: Int32 = 900) throws -> String {
        s.hook(S.claude("PreToolUse", tool: "ExitPlanMode", input: Self.plan, toolUseID: "UP", mode: "plan"), pid: pid)
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "ExitPlanMode", input: Self.plan, mode: "plan"), pid: pid))
        s.at(s.t + 6)
        s.hook(S.notification("permission_prompt"), pid: pid)
        #expect(s.head()?.id == id && s.head()?.kind == .plan && s.head()?.isAnswerable == true)
        return id
    }

    /// An edit confirmed on the island, in `mode`, with `suggestions`.
    private func askEdit(_ s: S, mode: String = "default", suggestions: [[String: Any]] = editSuggestions, agent: String? = nil) throws -> String {
        s.hook(S.claude("PreToolUse", tool: "Edit", input: S.edit, toolUseID: "UE", agent: agent, mode: mode))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "Edit", input: S.edit, agent: agent, mode: mode,
                                              extra: ["permission_suggestions": suggestions])))
        s.at(s.t + 6)
        s.hook(S.notification("permission_prompt", agent: agent))
        return id
    }

    private func decision(_ s: S, _ id: String) -> ClaudePermissionRequestDecision? {
        guard let answer = s.broker.answers.current.first(where: { $0.id == id }),
              case let .claudeHookDirective(.permissionRequest(decision)) = answer.response else { return nil }
        return decision
    }

    /// The decision as JSON, keys sorted: what the helper prints inside `hookSpecificOutput`.
    private func json(_ decision: ClaudePermissionRequestDecision?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(try #require(decision)), as: UTF8.self)
    }

    private func modes(_ s: S) -> [ClaudePermissionMode] { s.head().map { s.engine.modeChoices(for: $0) } ?? [] }

    // MARK: Plans

    /// A plan offers Accept edits and Manual; Approve sends no mode (Claude goes back to the mode it planned from, P452);
    /// Accept edits sends exactly one setMode for the session, with the plan echoed as Claude needs it.
    @Test
    func aPlanApprovesIntoAcceptEditsOrManualAndApproveAloneSendsNoMode() async throws {
        let plain = S()
        plain.begin()
        let first = try askPlan(plain)
        #expect(modes(plain) == [.acceptEdits, .default])
        #expect(await plain.engine.approve(requestID: first, decision: .allowOnce) == .sent)
        #expect(try json(decision(plain, first)) == #"{"behavior":"allow","updatedInput":{"plan":"1. Read the code\n2. Fix the tests","planFilePath":"/tmp/project/plans/fix.md"}}"#)

        for (mode, raw) in [(ClaudePermissionMode.acceptEdits, "acceptEdits"), (.default, "default")] {
            let s = S()
            s.begin()
            let id = try askPlan(s)
            #expect(await s.engine.approve(requestID: id, decision: .allowSwitchingMode(mode)) == .sent)
            #expect(try json(decision(s, id)) == #"{"behavior":"allow","updatedInput":{"plan":"1. Read the code\n2. Fix the tests","planFilePath":"/tmp/project/plans/fix.md"},"updatedPermissions":[{"destination":"session","mode":"\#(raw)","type":"setMode"}]}"#)
            #expect(s.glyph() == nil && s.phase() == .running)
        }
    }

    /// Bypass permissions takes Accept edits' place only in a session seen in bypass (launched with it, as Claude's own
    /// plan prompt words it); after another process takes the session (a resume), it is gone (P451, P454).
    @Test
    func bypassIsOfferedOnlyWhereTheSessionWasSeenInIt() async throws {
        let s = S()
        s.begin()
        s.hook(S.claude("UserPromptSubmit", mode: "bypassPermissions", extra: ["prompt": "plan the fix"]))
        s.hook(S.claude("UserPromptSubmit", mode: "plan", extra: ["prompt": "plan it first"]))
        let id = try askPlan(s)
        #expect(modes(s) == [.bypassPermissions, .default])
        #expect(await s.engine.approve(requestID: id, decision: .allowSwitchingMode(.bypassPermissions)) == .sent)
        #expect(decision(s, id) == .allow(updatedInput: .object(["plan": .string("1. Read the code\n2. Fix the tests"),
                                                                 "planFilePath": .string("/tmp/project/plans/fix.md")]),
                                         updatedPermissions: [.setMode(destination: .session, mode: .bypassPermissions)]))

        // A subagent's note in bypass says nothing of the session.
        let sub = S()
        sub.begin()
        sub.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UR", agent: "w1", mode: "bypassPermissions"))
        _ = try askPlan(sub)
        #expect(modes(sub) == [.acceptEdits, .default])

        // The same session resumed by another process: its bypass was that process's.
        let resumed = S()
        resumed.begin()
        resumed.hook(S.claude("UserPromptSubmit", mode: "bypassPermissions", extra: ["prompt": "go"]), pid: 900)
        resumed.hook(S.claude("SessionStart", extra: ["source": "resume"]), pid: 901)
        _ = try askPlan(resumed, pid: 901)
        #expect(modes(resumed) == [.acceptEdits, .default])
    }

    /// Auto is never offered or sent, even in a session seen in auto: a hook's setMode auto skips Claude's own switch
    /// into it (P451). A mode the card does not offer sends nothing and leaves the request waiting.
    @Test
    func autoAndUnofferedModesAreNeverSent() async throws {
        let s = S()
        s.begin()
        s.hook(S.claude("UserPromptSubmit", mode: "auto", extra: ["prompt": "plan the fix"]))
        let id = try askPlan(s)
        #expect(modes(s) == [.acceptEdits, .default])
        for mode in [ClaudePermissionMode.auto, .bypassPermissions, .dontAsk, .plan] {
            #expect(await s.engine.approve(requestID: id, decision: .allowSwitchingMode(mode)) == .nothingToSend)
        }
        #expect(s.broker.answers.current.isEmpty && s.isOpen(id) && s.glyph() == "!")
    }

    // MARK: Approvals

    /// An edit in Manual mode offers Claude's own Accept edits; the mode goes for this session only, whatever destination
    /// a suggestion named, and nothing else of the suggestions rides along (P455).
    @Test
    func anEditOffersClaudesAcceptEditsForTheSessionOnly() async throws {
        let s = S()
        s.begin()
        let persisted: [[String: Any]] = [["type": "setMode", "mode": "acceptEdits", "destination": "localSettings"]]
        let id = try askEdit(s, suggestions: persisted + Self.editSuggestions)
        #expect(modes(s) == [.acceptEdits])
        #expect(await s.engine.approve(requestID: id, decision: .allowSwitchingMode(.acceptEdits)) == .sent)
        #expect(try json(decision(s, id)) == #"{"behavior":"allow","updatedInput":{"file_path":"/tmp/project/a.swift","new_string":"b","old_string":"a"},"updatedPermissions":[{"destination":"session","mode":"acceptEdits","type":"setMode"}]}"#)
    }

    /// No mode Claude did not suggest, none it would not take, and never the one the session is in: no suggestion, no
    /// button; Accept edits already on, none; plan, dontAsk, auto or bypass suggested (bypass not seen), none; bypass
    /// added in a session seen in it.
    @Test
    func anApprovalOffersOnlyModesClaudeSuggestedOrTakes() throws {
        let none = S()
        none.begin()
        _ = try askEdit(none, suggestions: [])
        #expect(modes(none).isEmpty)

        let already = S()
        already.begin()
        _ = try askEdit(already, mode: "acceptEdits")
        #expect(modes(already).isEmpty)

        let odd = S()
        odd.begin()
        _ = try askEdit(odd, suggestions: ["plan", "dontAsk", "auto", "bypassPermissions"].map {
            ["type": "setMode", "mode": $0, "destination": "session"]
        })
        #expect(modes(odd).isEmpty)

        let bypass = S()
        bypass.begin()
        bypass.hook(S.claude("UserPromptSubmit", mode: "bypassPermissions", extra: ["prompt": "go"]))
        _ = try askEdit(bypass)
        #expect(modes(bypass) == [.acceptEdits, .bypassPermissions])
    }

    /// A subagent's request held for the island, a released (read-only) one, a Codex approval and the switch off: no mode,
    /// and a mode decision sends nothing (P453).
    @Test
    func noModeOffSwitchOrOnASubagentsOrAnotherAgentsCard() async throws {
        let held = S()
        held.engine.answersSubagents = true
        held.begin()
        held.hook(S.claude("PreToolUse", tool: "Edit", input: S.edit, toolUseID: "UW", agent: "w1"))
        let sub = try #require(held.hook(S.claude("PermissionRequest", tool: "Edit", input: S.edit, agent: "w1",
                                                  extra: ["permission_suggestions": Self.editSuggestions])))
        let subRequest = try #require(held.request(sub))
        #expect(subRequest.isAnswerable && held.engine.modeChoices(for: subRequest).isEmpty)
        #expect(await held.engine.approve(requestID: sub, decision: .allowSwitchingMode(.acceptEdits)) == .nothingToSend)

        let released = S()
        released.begin()
        _ = try askEdit(released, agent: "w2")
        #expect(released.head()?.isAnswerable == false && modes(released).isEmpty)

        let off = S()
        off.engine.offersModeChoices = false
        off.begin()
        let id = try askPlan(off)
        #expect(modes(off).isEmpty)
        #expect(await off.engine.approve(requestID: id, decision: .allowSwitchingMode(.acceptEdits)) == .nothingToSend)
        #expect(off.broker.answers.current.isEmpty)

        let codex = AttentionRequest(id: "c", sessionID: "c1", kind: .approval, channel: .answer(.bridge), source: .bridge, tool: .codex,
                                     content: .approval(PermissionRequest(title: "Bash", summary: "", affectedPath: "", toolName: "Bash",
                                                                          suggestedUpdates: [.setMode(destination: .session, mode: .acceptEdits)])),
                                     openedAt: F.now, state: .confirmed)
        #expect(ApprovalChoices.modes(for: codex, bypassAvailable: true).isEmpty)
    }

    /// Through upstream's bridge (a helper not yet updated): the same one setMode, sent as the bridge's resolution.
    @Test
    func theBridgeCarriesTheSameMode() async throws {
        let s = S()
        s.begin()
        s.hook(S.claude("UserPromptSubmit", extra: ["prompt": "push it"]))
        s.bridge(F.permission("s1", at: s.clock.current))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        let head = try #require(s.head())
        #expect(head.channel == .answer(.bridge) && head.permissionMode == "default")
        // Its suggestions: bypass (not seen: not offered) and a rule (Always allow's, not a mode).
        #expect(s.engine.modeChoices(for: head).isEmpty)
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UR", mode: "bypassPermissions"))
        #expect(s.engine.modeChoices(for: head) == [.bypassPermissions])
        #expect(await s.engine.approve(requestID: head.id, decision: .allowSwitchingMode(.bypassPermissions)) == .sent)
        #expect(s.sent.current == [.resolvePermission(sessionID: "s1", resolution: .allowOnce(
            updatedPermissions: [.setMode(destination: .session, mode: .bypassPermissions)]))])
    }

    // MARK: Choices

    @Test
    func aModeDecisionMapsToOneSessionSetMode() {
        let request = PermissionRequest(title: "Edit", summary: "", affectedPath: "", toolName: "Edit")
        #expect(ApprovalChoices.resolution(for: .allowSwitchingMode(.acceptEdits), request: request)
            == .allowOnce(updatedPermissions: [.setMode(destination: .session, mode: .acceptEdits)]))
        #expect(SessionEngine.modeAllowed(.allowOnce, choices: []) && SessionEngine.modeAllowed(.alwaysAllow, choices: []))
        #expect(!SessionEngine.modeAllowed(.allowSwitchingMode(.acceptEdits), choices: [.default]))
        #expect(SessionEngine.modeAllowed(.allowSwitchingMode(.default), choices: [.default]))
    }
}
