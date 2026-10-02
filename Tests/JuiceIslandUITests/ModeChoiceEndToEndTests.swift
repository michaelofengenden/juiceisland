import Foundation
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Permission modes on cards through the built helper (P450-P455): the hooks as Claude sends them (the public hooks
/// docs' `PermissionRequest` input, `permission_mode` and `permission_suggestions`), the engine's real broker, the
/// session model's card and the owner's click, and the whole object the helper prints back for Claude, compared
/// exactly. Fictional values; scratch sockets only (`AttentionRig`).
@MainActor
@Suite(.serialized)
struct ModeChoiceEndToEndTests {
    typealias E = AttentionEndToEndTests

    static let plan: [String: Any] = ["plan": "1. Read the code\n2. Fix the tests", "planFilePath": "/tmp/project/plans/fix.md"]
    static let edit: [String: Any] = ["file_path": "/tmp/project/a.swift", "old_string": "a", "new_string": "b"]

    private func begin(_ rig: AttentionRig, mode: String = "default") async {
        await rig.finished(E.claude(rig, "SessionStart", mode: mode, extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))])
        await rig.finished(E.claude(rig, "UserPromptSubmit", mode: mode, extra: ["prompt": "fix the tests"]),
                           events: E.prompt("s1", "fix the tests", transcript: E.transcript(rig, "s1")))
    }

    /// A request held by the broker and shown at Claude's own notice: the helper still waiting on the island.
    private func ask(_ rig: AttentionRig, tool: String, input: [String: Any], mode: String, extra: [String: Any] = [:]) async -> HelperRun {
        await rig.finished(E.claude(rig, "PreToolUse", tool: tool, input: input, toolUseID: "U1", mode: mode),
                           events: [E.running("s1", "Running \(tool)")])
        let count = rig.engine.openRequests.count
        let run = rig.hook(E.claude(rig, "PermissionRequest", tool: tool, input: input, mode: mode, extra: extra))
        await rig.waitUntil { rig.engine.openRequests.count > count }
        rig.advance(6)
        await rig.finished(E.claude(rig, "Notification", mode: mode,
                                    extra: ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        return run
    }

    /// What the helper printed, as an object: the whole of Claude's answer.
    private func printed(_ run: HelperRun) async throws -> NSDictionary {
        let result = try #require(await run.result(within: 30))
        #expect(result.status == 0)
        return try #require(try JSONSerialization.jsonObject(with: result.stdout) as? NSDictionary)
    }

    /// The helper's whole answer for Claude around `decision` (upstream's `ClaudeHookOutput` envelope).
    private func answer(_ decision: [String: Any]) -> NSDictionary {
        ["continue": true, "suppressOutput": true,
         "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]] as NSDictionary
    }

    private func setMode(_ mode: String) -> [[String: Any]] { [["type": "setMode", "mode": mode, "destination": "session"]] }

    /// A plan: Approve prints the plan back and no mode; Accept edits and Manual print one setMode for the session.
    @Test
    func aPlanApprovedIntoAModePrintsOneSessionSetMode() async throws {
        for (decision, mode) in [(ApprovalDecision.allowOnce, nil), (.allowSwitchingMode(.acceptEdits), "acceptEdits"),
                                 (.allowSwitchingMode(.default), "default")] as [(ApprovalDecision, String?)] {
            let rig = try await AttentionRig()
            defer { rig.stop() }
            await begin(rig, mode: "plan")
            let run = await ask(rig, tool: "ExitPlanMode", input: Self.plan, mode: "plan")
            guard case let .plan(card)? = rig.card("s1") else {
                Issue.record("no plan card")
                return
            }
            #expect(card.isAnswerable && card.modes == [.acceptEdits, .default])
            await rig.model.decide("s1", decision)
            var expected: [String: Any] = ["behavior": "allow", "updatedInput": Self.plan]
            if let mode { expected["updatedPermissions"] = setMode(mode) }
            #expect(try await printed(run) == answer(expected))
            await rig.settle()
            #expect(rig.card("s1") == nil && rig.row("s1")?.bucket == .running)
        }
    }

    /// In a session seen in bypass the plan offers Bypass in Accept edits' place, and it prints as Claude's own option
    /// would set it: bypassPermissions, for the session.
    @Test
    func aPlanInABypassSessionPrintsBypassForTheSession() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig, mode: "bypassPermissions")
        let run = await ask(rig, tool: "ExitPlanMode", input: Self.plan, mode: "plan")
        guard case let .plan(card)? = rig.card("s1") else {
            Issue.record("no plan card")
            return
        }
        #expect(card.modes == [.bypassPermissions, .default])
        await rig.model.decide("s1", .allowSwitchingMode(.bypassPermissions))
        #expect(try await printed(run) == answer(["behavior": "allow", "updatedInput": Self.plan,
                                                  "updatedPermissions": setMode("bypassPermissions")]))
    }

    /// An edit in Manual mode with Claude's own suggestions (Accept edits to its local settings and to the session, a
    /// folder to add): Accept edits prints the mode for the session only, and nothing else of the suggestions (P455).
    @Test
    func anEditsAcceptEditsPrintsTheModeForTheSessionOnly() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let suggestions: [[String: Any]] = [
            ["type": "setMode", "mode": "acceptEdits", "destination": "localSettings"],
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
            ["type": "addDirectories", "directories": ["/tmp/other"], "destination": "session"],
        ]
        let run = await ask(rig, tool: "Edit", input: Self.edit, mode: "default", extra: ["permission_suggestions": suggestions])
        guard case let .approval(card)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.isAnswerable && card.modes == [.acceptEdits] && card.alwaysAllowLabel == nil)
        await rig.model.decide("s1", .allowSwitchingMode(.acceptEdits))
        #expect(try await printed(run) == answer(["behavior": "allow", "updatedInput": Self.edit,
                                                  "updatedPermissions": setMode("acceptEdits")]))
    }

    /// Nothing the card does not offer goes out: Auto, Bypass in a session never seen in it, or any mode with Permission
    /// modes on cards off; the helper still waits, and the plain Yes then prints no mode (P450, P451).
    @Test
    func aModeTheCardDoesNotOfferPrintsNothing() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig, mode: "auto")
        let run = await ask(rig, tool: "Edit", input: Self.edit, mode: "default",
                            extra: ["permission_suggestions": setMode("acceptEdits")])
        for mode in [ClaudePermissionMode.auto, .bypassPermissions, .plan, .dontAsk] {
            await rig.model.decide("s1", .allowSwitchingMode(mode))
        }
        rig.engine.offersModeChoices = false
        guard case let .approval(card)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.modes.isEmpty)
        await rig.model.decide("s1", .allowSwitchingMode(.acceptEdits))
        #expect(run.isRunning && rig.card("s1") != nil)
        await rig.model.decide("s1", .allowOnce)
        #expect(try await printed(run) == answer(["behavior": "allow", "updatedInput": Self.edit]))
    }

    /// P730: a session in an extra Claude config folder (`CLAUDE_CONFIG_DIR`, a profile folder) keeps a mode chosen on the
    /// island as a session in `~/.claude` does. The helper prints the same answer, the mode for the session only (Claude
    /// keeps it in memory: no settings file, so no folder, is named); the session's recorded mode follows its next hook;
    /// and the island asks nothing again: the next edit opens no card, and the command Claude asks about next offers no
    /// Accept edits. No hold, policy or mode the island keeps goes by config folder.
    @Test
    func aModeChosenForASessionInAProfileFolderSticks() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        let work = rig.home.appendingPathComponent(".claude-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        rig.extraEnvironment = ["CLAUDE_CONFIG_DIR": work.path]
        rig.engine.setProfiles(accounts: [], discovered: [DiscoveredProfile(provider: .claude, folder: work.path, suggestedAlias: "Work")])
        let transcript = work.appendingPathComponent("projects/-tmp-project/s1.jsonl").path
        func hook(_ event: String, tool: String? = nil, input: [String: Any]? = nil, toolUseID: String? = nil, mode: String,
                  extra: [String: Any] = [:]) -> [String: Any] {
            E.claude(rig, event, tool: tool, input: input, toolUseID: toolUseID, mode: mode,
                     extra: extra.merging(["transcript_path": transcript]) { own, _ in own })
        }
        func prompt(_ mode: String) async {
            await rig.finished(hook("Notification", mode: mode,
                                    extra: ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        }
        await rig.finished(hook("SessionStart", mode: "default", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: transcript)])
        await rig.finished(hook("UserPromptSubmit", mode: "default", extra: ["prompt": "fix the tests"]),
                           events: E.prompt("s1", "fix the tests", transcript: transcript))
        #expect(rig.engine.accountTag(for: "s1")?.folder == ProfileHookTargets.normalized(work.path))

        // An edit in Manual mode, with Claude's own suggestion: Accept edits on the island.
        await rig.finished(hook("PreToolUse", tool: "Edit", input: Self.edit, toolUseID: "U1", mode: "default"),
                           events: [E.running("s1", "Running Edit")])
        let edit = rig.hook(hook("PermissionRequest", tool: "Edit", input: Self.edit, mode: "default",
                                 extra: ["permission_suggestions": setMode("acceptEdits")]))
        await rig.waitUntil { rig.engine.openRequests.count == 1 }
        rig.advance(6)
        await prompt("default")
        guard case let .approval(card)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.isAnswerable && card.modes == [.acceptEdits])
        await rig.model.decide("s1", .allowSwitchingMode(.acceptEdits))
        #expect(try await printed(edit) == answer(["behavior": "allow", "updatedInput": Self.edit,
                                                   "updatedPermissions": setMode("acceptEdits")]))
        await rig.finished(hook("PostToolUse", tool: "Edit", input: Self.edit, toolUseID: "U1", mode: "acceptEdits"))

        // Claude took it: the next edit asks nothing, and the session's mode is the one chosen.
        await rig.finished(hook("PreToolUse", tool: "Edit", input: Self.edit, toolUseID: "U2", mode: "acceptEdits"),
                           events: [E.running("s1", "Running Edit")])
        await rig.finished(hook("PostToolUse", tool: "Edit", input: Self.edit, toolUseID: "U2", mode: "acceptEdits"))
        let session = try #require(rig.engine.state.session(id: "s1"))
        #expect(rig.engine.openRequests.isEmpty && rig.card("s1") == nil && rig.engine.facts(for: session).mode == "acceptEdits")

        // A command Claude still asks about in Accept edits: one card, held as any, with no Accept edits on it.
        let push: [String: Any] = ["command": "git push origin main"]
        await rig.finished(hook("PreToolUse", tool: "Bash", input: push, toolUseID: "U3", mode: "acceptEdits"),
                           events: [E.running("s1")])
        let command = rig.hook(hook("PermissionRequest", tool: "Bash", input: push, mode: "acceptEdits"))
        await rig.waitUntil { rig.engine.openRequests.count == 1 }
        // Claude's own notice, at once: the rig's clock already ran past this request's real-time window.
        await prompt("acceptEdits")
        guard case let .approval(next)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(next.isAnswerable && next.modes.isEmpty)
        #expect(rig.brokered.current == [true, true])
        await rig.model.decide("s1", .allowOnce)
        #expect(try await printed(command) == answer(["behavior": "allow", "updatedInput": push]))
    }
}
