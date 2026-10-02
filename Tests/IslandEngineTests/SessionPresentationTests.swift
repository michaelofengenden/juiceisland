import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func session(_ id: String = "s", phase: SessionPhase, summary: String = "", tool: String? = nil,
                     updatedAt: Date = now, alive: Bool = true, transcript: String? = nil) -> AgentSession {
    var session = AgentSession(id: id, title: id, tool: .claudeCode, origin: .live, phase: phase, summary: summary,
                               updatedAt: updatedAt,
                               claudeMetadata: ClaudeSessionMetadata(transcriptPath: transcript, currentTool: tool,
                                                                     currentToolInputPreview: tool == nil ? nil : "File.swift"))
    session.isHookManaged = true
    session.isProcessAlive = alive
    return session
}

struct StatusWordTests {
    @Test
    func oneWordPerState() {
        #expect(StatusWord.of(session(phase: .running, summary: "Claude Code is compacting the conversation."), interrupted: false) == .compacting)
        #expect(StatusWord.of(session(phase: .running, summary: "Thinking."), interrupted: false) == .thinking)
        #expect(StatusWord.of(session(phase: .running, tool: "Edit"), interrupted: false) == .tool(name: "Edit", detail: "File.swift"))
        #expect(StatusWord.of(session(phase: .running), interrupted: false) == .working)
        #expect(StatusWord.of(session(phase: .waitingForAnswer), interrupted: false) == .question)
        #expect(StatusWord.of(session(phase: .completed), interrupted: true) == .interrupted)
        #expect(StatusWord.of(session(phase: .completed), interrupted: false) == .done)
        #expect(StatusWord.of(session(phase: .running, summary: StatusWord.deniedSummary(tool: "Bash"), tool: "Bash"),
                              interrupted: false) == .denied(tool: "Bash"))
        #expect(StatusWord.of(session(phase: .running, summary: StatusWord.deniedSummary(tool: nil)), interrupted: false) == .denied(tool: nil))
    }
}

struct ApprovalChoicesTests {
    private let rule = ClaudePermissionUpdate.addRules(
        destination: .localSettings, rules: [ClaudePermissionRuleValue(toolName: "Bash", ruleContent: "git push:*")], behavior: .allow)

    private func request(_ updates: [ClaudePermissionUpdate]) -> PermissionRequest {
        PermissionRequest(title: "Bash", summary: "git push", affectedPath: "/tmp", toolName: "Bash", suggestedUpdates: updates)
    }

    @Test
    func alwaysAllowIsClaudesAllowRuleNeverAModeOrADenyRule() {
        let deny = ClaudePermissionUpdate.addRules(destination: .session, rules: [ClaudePermissionRuleValue(toolName: "Bash")], behavior: .deny)
        let bypass = ClaudePermissionUpdate.setMode(destination: .session, mode: .bypassPermissions)
        #expect(ApprovalChoices.alwaysAllowUpdate(for: request([bypass, deny, rule])) == rule)
        #expect(ApprovalChoices.alwaysAllowUpdate(for: request([bypass])) == nil)
        #expect(ApprovalChoices.alwaysAllowLabel(for: request([])) == nil)
    }

    @Test
    func decisionsMapToResolutions() {
        #expect(ApprovalChoices.resolution(for: .deny, request: nil) == .deny(message: ApprovalChoices.denyMessage, interrupt: false))
        #expect(ApprovalChoices.resolution(for: .allowOnce, request: nil) == .allowOnce())
        #expect(ApprovalChoices.resolution(for: .alwaysAllow, request: request([rule])) == .allowOnce(updatedPermissions: [rule]))
        #expect(ApprovalChoices.resolution(for: .alwaysAllow, request: request([])) == nil)
    }
}

struct SessionRankingTests {
    @Test
    func needsYouOutranksRunningWhichOutranksDone() {
        let sessions = [
            session("done", phase: .completed, updatedAt: now.addingTimeInterval(-30)),
            session("run", phase: .running),
            session("ask", phase: .waitingForApproval, updatedAt: now.addingTimeInterval(-900)),
        ]
        let buckets = SessionRanking.buckets(sessions: sessions, now: now) { _ in nil }
        #expect(buckets.primary.map(\.id) == ["ask", "run", "done"])
    }

    @Test
    func hiddenSubagentAndDuplicateTerminalSessionsLeaveTheRows() {
        let sessions = [
            session("a", phase: .running),
            session("b", phase: .running, updatedAt: now.addingTimeInterval(-5)),
            session("sub", phase: .running, transcript: "/x/abc/subagents/agent-1.jsonl"),
            session("gone", phase: .completed, alive: false),
        ]
        var ended = sessions[3]
        ended.isSessionEnded = true
        let buckets = SessionRanking.buckets(sessions: Array(sessions.prefix(3)) + [ended], now: now) { session in
            ["a", "b"].contains(session.id) ? "tty:/dev/ttys003" : nil
        }
        #expect(buckets.primary.map(\.id) == ["a"])
        #expect(Set(buckets.overflow.map(\.id)) == ["b", "gone"])
    }
}
