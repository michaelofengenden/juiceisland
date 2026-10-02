import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// R5, the owner's screenshot of 2026-09-27 (P280): a workflow's subagent asks to run a Bash command in the desktop
/// app, which shows its own "Allow once", while the island's card offers only Open and ✕. Claude awaits a background
/// subagent's PermissionRequest hook before it builds that prompt, and sends no `permission_prompt` while the hook
/// holds (claude-code#82150; the hooks docs' "In sessions that can't show a prompt, such as background subagents…"),
/// so a hold would take Claude's own prompt away for as long as the island kept it. With Answer subagents on the island
/// off (the default; on, R6 in `SubagentAllowOptInTests.swift`, P350), the broker hands a subagent's
/// request back at once, whatever its surface, mode or agent type, and it is shown read-only wherever a Claude request
/// is shown (not for `dontAsk` or a headless entrypoint, CL15, CL16); the island's buttons never reach it, and a
/// main-thread request beside it stays the island's to answer. A Deny or an Esc at Claude's own prompt fires no hook
/// (PermissionDenied runs only in auto mode, PostToolUseFailure not for a permission denial): the call's `tool_result`
/// in the subagent's own transcript ends it. Through the built helper, the engine's real sockets and transcript watch,
/// the engine and the session model (`AttentionRig`); fixtures shaped from the hooks docs.
@MainActor
@Suite(.serialized)
struct SubagentAllowReplayTests {
    typealias E = AttentionEndToEndTests

    static let desktop = "claude-desktop"
    static let workflowAgent = "workflow-subagent"
    /// The screenshot's shape: a Bash command Claude asked about. The mode changes nothing here: the policy reads it
    /// only for `dontAsk`.
    static let shots: [String: Any] = ["command": "cd /tmp/project/site && rm -f shots/* && node probe.cjs",
                                       "description": "Shoot pinned charts in light and dark"]
    static let lint: [String: Any] = ["command": "rm -rf /tmp/project/site/.cache", "description": "Clear the site cache"]

    /// A Claude hook of the owner's desktop chat, in bypass as in the screenshot; a subagent's carries the workflow's
    /// agent type.
    static func hook(_ rig: AttentionRig, _ event: String, tool: String? = nil, input: [String: Any]? = nil, toolUseID: String? = nil,
                     agent: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var more = extra
        if agent != nil { more["agent_type"] = workflowAgent }
        return E.claude(rig, event, tool: tool, input: input, toolUseID: toolUseID, agent: agent, mode: "bypassPermissions", extra: more)
    }

    func begin(_ rig: AttentionRig) async {
        await rig.finished(Self.hook(rig, "SessionStart", extra: ["source": "startup"]), entrypoint: Self.desktop,
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"), terminal: "Claude.app")])
        await rig.finished(Self.hook(rig, "UserPromptSubmit", extra: ["prompt": "run the site workflow"]), entrypoint: Self.desktop,
                           events: E.prompt("s1", "run the site workflow", transcript: E.transcript(rig, "s1")))
    }

    /// A PreToolUse, then the PermissionRequest (which carries no `tool_use_id`, as the hooks docs say).
    func ask(_ rig: AttentionRig, _ input: [String: Any], toolUseID: String, agent: String? = nil) async -> HelperRun {
        await rig.finished(Self.hook(rig, "PreToolUse", tool: "Bash", input: input, toolUseID: toolUseID, agent: agent),
                           entrypoint: Self.desktop, events: [E.running("s1", "Running Bash")])
        let count = rig.engine.openRequests.count
        let run = rig.hook(Self.hook(rig, "PermissionRequest", tool: "Bash", input: input, agent: agent), entrypoint: Self.desktop)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        return run
    }

    /// Claude's own `permission_prompt`, about 6 s after a request it shows.
    func notice(_ rig: AttentionRig) async {
        await rig.finished(Self.hook(rig, "Notification", extra: ["notification_type": "permission_prompt",
                                                                 "message": "Claude needs your permission to use Bash"]),
                           entrypoint: Self.desktop)
    }

    /// Allowed at Claude's own prompt, the call ran: its PostToolUse, by the agent's call id.
    func ran(_ rig: AttentionRig, _ input: [String: Any], toolUseID: String, agent: String? = nil) async {
        await rig.finished(Self.hook(rig, "PostToolUse", tool: "Bash", input: input, toolUseID: toolUseID, agent: agent),
                           entrypoint: Self.desktop, events: [E.running("s1", "Ran Bash")])
    }

    /// A subagent's own transcript, next to its chat's (the hooks docs' `agent_transcript_path`,
    /// `<session>/subagents/agent-<id>.jsonl`).
    static func agentTranscript(_ rig: AttentionRig, _ agent: String) -> URL {
        rig.folder.appendingPathComponent("projects/-tmp-project/s1/subagents/agent-\(agent).jsonl")
    }

    /// One transcript line, as Claude writes a subagent's (compact JSON, one object per line).
    static func transcriptLine(_ agent: String, _ message: [String: Any]) throws -> Data {
        let object: [String: Any] = ["type": message["role"] as? String ?? "user", "isSidechain": true, "agentId": agent,
                                     "sessionId": "s1", "cwd": "/tmp/project", "message": message]
        return try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
    }

    /// The subagent's transcript as it stands when it asks: its call's `tool_use`, not yet answered.
    func transcriptBeforeAsking(_ rig: AttentionRig, agent: String, toolUseID: String, input: [String: Any]) throws {
        let url = Self.agentTranscript(rig, agent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let use: [String: Any] = ["role": "assistant", "content": [["type": "tool_use", "id": toolUseID, "name": "Bash", "input": input]]]
        try Self.transcriptLine(agent, use).write(to: url)
    }

    /// Deny (or Esc) at Claude's own prompt for a subagent's call: no hook fires; Claude writes the call's result, an
    /// error, to the subagent's own transcript.
    func deniedInClaude(_ rig: AttentionRig, agent: String, toolUseID: String) throws {
        let result: [String: Any] = ["role": "user", "content": [[
            "type": "tool_result", "tool_use_id": toolUseID, "is_error": true,
            "content": "The user doesn't want to proceed with this tool use. The tool use was rejected.",
        ]]]
        let handle = try FileHandle(forWritingTo: Self.agentTranscript(rig, agent))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.transcriptLine(agent, result))
    }

    func approval(_ rig: AttentionRig) -> ApprovalCardModel? {
        if case let .approval(card)? = rig.card("s1") { card } else { nil }
    }

    static func decision(_ result: HelperRun.Result?) -> [String: Any]? {
        guard let result, let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let output = object["hookSpecificOutput"] as? [String: Any] else { return nil }
        return output["decision"] as? [String: Any]
    }

    /// The screenshot: the helper ends at once with nothing printed (Claude builds its own prompt), the card is
    /// read-only from Claude's notice, "workflow-subagent · Bash · in Claude"; the island's Allow and No send nothing;
    /// answered in Claude, its own call's PostToolUse ends it, and a click on the card as drawn does nothing.
    @Test
    func r5AWorkflowSubagentsRequestIsHandedBackAtOnceAndStaysReadOnly() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let run = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let result = await run.result(within: 30)
        #expect(result?.status == 0 && result?.stdout.isEmpty == true && (result?.elapsed ?? 99) < 2.5)
        #expect(rig.engine.attentionTally.held == 0 && rig.engine.attentionTally.released == 1)
        rig.advance(5)
        #expect(rig.card("s1") == nil && rig.needsYou.isEmpty)
        rig.advance(1)
        await notice(rig)
        let card = try #require(approval(rig))
        let shown = try #require(card.request)
        #expect(!shown.answerable && shown.agentType == Self.workflowAgent && shown.place == .claudeApp && shown.dismissable)
        #expect(card.tool == "Bash" && card.body == .command(Self.shots["command"] as! String) && card.alwaysAllowLabel == nil && !card.canStop)
        #expect(rig.row("s1")?.glyph == .bang && rig.needsYou.count == 1)

        // The island's Allow, No and No with a reason reach nothing: the hook has ended, Claude's own prompt decides.
        for decision in [ApprovalDecision.allowOnce, .deny, .denyWithReason("not the shots folder")] {
            #expect(await rig.engine.approve(requestID: shown.id, decision: decision) == .nothingToSend)
            await rig.model.decide("s1", decision, request: shown.id)
        }
        #expect(rig.engine.openRequests.map(\.id) == [shown.id] && approval(rig)?.request?.id == shown.id)

        // Allowed in Claude's own prompt: the subagent's call ran.
        await ran(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        #expect(rig.card("s1") == nil && rig.engine.openRequests.isEmpty && rig.row("s1")?.bucket == .running)
        #expect(await rig.engine.approve(requestID: shown.id, decision: .allowOnce) == .nothingToSend)
        rig.advance(10)
        #expect(rig.needsYou.count == 1 && rig.dones.isEmpty)
    }

    /// The main thread and a subagent ask at once: the main thread's request is held and answerable, the subagent's
    /// handed back; the island's Allow goes to the main thread's helper only, with its own command, and the subagent's
    /// card that comes next is read-only; a Deny at Claude's own prompt, which fires no hook, ends it by the call's
    /// result in the subagent's own transcript.
    @Test
    func r5TheMainThreadsRequestStaysTheIslandsBesideASubagents() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let main = await ask(rig, E.push, toolUseID: "UM")
        rig.advance(1)
        try transcriptBeforeAsking(rig, agent: "wf-a", toolUseID: "UA", input: Self.shots)
        let sub = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let handedBack = await sub.result(within: 30)
        #expect(handedBack?.status == 0 && handedBack?.stdout.isEmpty == true && (handedBack?.elapsed ?? 99) < 2.5)
        #expect(main.isRunning && rig.engine.attentionTally.held == 1 && rig.engine.attentionTally.released == 1)
        rig.advance(5)
        await notice(rig)
        rig.advance(1)
        await notice(rig)
        let head = try #require(approval(rig)?.request)
        #expect(head.answerable && head.agentType == nil && head.more == 1)
        #expect(approval(rig)?.body == .command("git push origin main"))

        await rig.model.decide("s1", .allowOnce, request: head.id)
        let answered = await main.result(within: 30)
        let decision = try #require(Self.decision(answered))
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedInput"] as? [String: Any])?["command"] as? String == "git push origin main")
        await rig.settle()

        let next = try #require(approval(rig)?.request)
        #expect(next.id != head.id && !next.answerable && next.agentType == Self.workflowAgent && next.more == 0)
        #expect(await rig.engine.approve(requestID: next.id, decision: .allowOnce) == .nothingToSend)
        try deniedInClaude(rig, agent: "wf-a", toolUseID: "UA")
        await rig.waitUntil { rig.engine.openRequests.isEmpty }
        await rig.settle()
        #expect(rig.card("s1") == nil && rig.engine.openRequests.isEmpty && rig.dones.isEmpty)
    }

    /// Two subagents ask at once: both handed back, both read-only in the order asked; one's call ends only its own
    /// request, the other's SubagentStop ends the rest.
    @Test
    func r5TwoSubagentsAskingAtOnceAreEachReadOnlyAndEndOnTheirOwn() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let first = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let second = await ask(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        for run in [first, second] {
            let result = await run.result(within: 30)
            #expect(result?.status == 0 && result?.stdout.isEmpty == true && (result?.elapsed ?? 99) < 2.5)
        }
        #expect(rig.engine.attentionTally.held == 0 && rig.engine.attentionTally.released == 2)
        rig.advance(6)
        await notice(rig)
        await notice(rig)
        let head = try #require(approval(rig)?.request)
        #expect(!head.answerable && head.more == 1 && rig.needsYou.count == 2)
        #expect(rig.engine.openRequests.allSatisfy { $0.agentType == Self.workflowAgent && !$0.isAnswerable })
        #expect(rig.engine.openRequests.first?.agentID == "wf-a")

        await ran(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        #expect(rig.engine.openRequests.map(\.agentID) == ["wf-a"] && approval(rig)?.request?.id == head.id
            && approval(rig)?.request?.more == 0)

        await rig.finished(Self.hook(rig, "SubagentStop", agent: "wf-a",
                                     extra: ["stop_hook_active": false, "last_assistant_message": "Shots taken.",
                                             "agent_transcript_path": "/tmp/project/s1/subagents/agent-wf-a.jsonl"]),
                           entrypoint: Self.desktop)
        #expect(rig.card("s1") == nil && rig.engine.openRequests.isEmpty)
    }
}
