import Foundation
import Testing
@testable import IslandEngine

/// Who started a Codex thread, from its rollout's session_meta as each Codex version writes it (P212,
/// `CodexThreadFixtures`; codex-rs `protocol.rs` `SessionSource`, `SubAgentSource`, `ThreadSource`).
struct CodexThreadKindTests {
    typealias T = CodexThreadFixtures
    typealias F = RolloutFixtures

    private func kind(_ line: String) -> CodexThreadKind? { CodexThreadKind.of(line: line) }

    @Test
    func theOwnersChatsAreChatsWhateverClientStartedThem() {
        for source in ["cli", "vscode", "exec", "mcp", "unknown"] as [Any] {
            #expect(kind(T.meta(id: T.chatA, source: source)) == .chat)
        }
        #expect(kind(T.meta(id: T.chatA, source: ["custom": "chatgpt"])) == .chat)
        #expect(kind(T.meta(id: T.chatA, source: "vscode", threadSource: "user")) == .chat)
        // No source at all (Codex's default is vscode), and a legacy first line that is not a session_meta.
        #expect(kind(F.line("session_meta", ["id": T.chatA, "cwd": "/tmp", "originator": "codex_cli_rs", "cli_version": "0.40.0"], at: 0)) == .chat)
        #expect(kind(#"{"id":"x","timestamp":"2025-05-01T10:00:00Z","instructions":null}"#) == nil)
        // An origin this build does not know is a chat: no chat of the owner's is ever hidden.
        #expect(kind(T.meta(id: T.chatA, source: ["somethingnew": ["x": 1]])) == .chat)
    }

    @Test
    func theApprovalsReviewerIsAReviewerInEveryShapeCodexWritesIt() {
        // 0.140 to today: the delegate's own identity, with its thread_source and its parent.
        #expect(kind(T.reviewer(T.reviewerID(1), parent: T.chatA)[0]) == .reviewer)
        // Before thread_source existed.
        #expect(kind(T.meta(id: T.reviewerID(2), source: ["subagent": ["other": "guardian"]])) == .reviewer)
        // The manager's own registration, if a Codex ever writes it.
        #expect(kind(T.meta(id: T.reviewerID(3), source: ["internal": "guardian"])) == .reviewer)
        // A root source whose thread_source says it is the reviewer.
        #expect(kind(T.meta(id: T.reviewerID(4), source: "vscode", threadSource: "guardian_review", parent: T.chatA)) == .reviewer)
    }

    /// A review's thread folds into its chat (P217); one that names no parent (a Codex before 0.140) is a chat, as it
    /// always was.
    @Test
    func aReviewNamesItsChat() {
        #expect(kind(T.reviewThread(parent: T.chatA, running: true)[0])
            == .review(CodexSubagent(id: T.reviewID, parentID: T.chatA, rootID: T.chatA)))
        #expect(kind(T.meta(id: "r1", source: ["subagent": "review"], threadSource: "subagent", parent: T.chatA))
            == .review(CodexSubagent(id: "r1", parentID: T.chatA)))
        #expect(kind(T.meta(id: "r1", source: ["subagent": "review"])) == .chat)
    }

    @Test
    func codexsOtherHelpersAreHelpers() {
        #expect(kind(T.meta(id: "r2", source: ["subagent": "compact"], threadSource: "subagent", parent: T.chatA)) == .helper)
        #expect(kind(T.meta(id: "r3", source: ["subagent": "memory_consolidation"])) == .helper)
        #expect(kind(T.meta(id: "r4", source: ["internal": "memory_consolidation"], threadSource: "memory_consolidation")) == .helper)
        #expect(kind(T.meta(id: "r5", source: ["subagent": ["other": "some_helper"]], threadSource: "subagent", parent: T.chatA)) == .helper)
        #expect(kind(T.meta(id: "r6", source: "cli", threadSource: "memory_consolidation")) == .helper)
    }

    @Test
    func aSpawnedSubagentNamesItsParentItsRootAndItsName() throws {
        let worker = try #require(kind(T.subagent(T.subagentID(1), parent: T.chatA, nickname: "Euclid", role: "worker", running: true)[0])?.subagent)
        #expect(worker == CodexSubagent(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "worker"))
        // Codex's `default` role says nothing: the nickname names it.
        let plain = try #require(kind(T.subagent(T.subagentID(2), parent: T.chatA, nickname: "Hubble", running: false)[0])?.subagent)
        #expect(plain.name == "Hubble")
        // A subagent of a subagent: its parent is the subagent, its root the chat.
        let deep = try #require(kind(T.subagent(T.subagentID(3), parent: T.subagentID(1), root: T.chatA, running: true)[0])?.subagent)
        #expect(deep.parentID == T.subagentID(1))
        #expect(deep.rootID == T.chatA)
        // 0.100: only the parent and the depth, no session_id, no thread_source.
        let old = F.line("session_meta", ["id": "s-old", "timestamp": F.stamp(0), "cwd": "/tmp", "originator": "codex_cli_rs",
                                          "cli_version": "0.100.0",
                                          "source": ["subagent": ["thread_spawn": ["parent_thread_id": T.chatA, "depth": 1]]]], at: 0)
        #expect(kind(old)?.subagent == CodexSubagent(id: "s-old", parentID: T.chatA))
        // A thread spawn that names no parent is not taken for anyone's subagent: hidden as a helper.
        let orphan = F.line("session_meta", ["id": "s-orphan", "cwd": "/tmp", "source": ["subagent": ["thread_spawn": ["depth": 1]]]], at: 0)
        #expect(kind(orphan) == .helper)
    }

    @Test
    func aRolloutsKindIsReadOnceFromItsFirstLineAndNotBeforeThatLineIsWhole() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = root.appendingPathComponent("2026/09/24/rollout-2026-09-24T10-00-00-\(T.reviewerID(9)).jsonl")
        let line = T.reviewer(T.reviewerID(9), parent: T.chatA)[0]
        // Codex is still writing the first line: nothing is known, and nothing is kept.
        try Data(line.utf8.prefix(40)).write(to: url)
        var bytes = 0
        #expect(CodexRolloutKinds.kind(atPath: url.path, bytesRead: &bytes) == nil)
        #expect(bytes == 40)
        try F.text(T.reviewer(T.reviewerID(9), parent: T.chatA)).write(to: url, atomically: true, encoding: .utf8)
        bytes = 0
        #expect(CodexRolloutKinds.kind(atPath: url.path, bytesRead: &bytes) == .reviewer)
        #expect(bytes > 0)
        bytes = 0
        #expect(CodexRolloutKinds.kind(atPath: url.path, bytesRead: &bytes) == .reviewer)
        #expect(bytes == 0)
    }

    /// A Codex process holds its chat's rollout open beside its reviewer's and its subagents', which are newer: the
    /// process is its chat's.
    @Test
    func aProcessIsTakenForItsChatNotItsReviewerOrSubagent() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let chat = T.write(T.chat(T.chatA, prompt: "fix it", running: true, originator: "codex_cli_rs"), id: T.chatA, in: root, minutesAgo: 20)
        let reviewer = T.write(T.reviewer(T.reviewerID(1), parent: T.chatA), id: T.reviewerID(1), in: root, minutesAgo: 1)
        let child = T.write(T.subagent(T.subagentID(1), parent: T.chatA, running: true), id: T.subagentID(1), in: root, minutesAgo: 1)
        #expect(CodexRolloutKinds.chatPaths([chat.path, reviewer.path, child.path]) == [chat.path])
        // Only internal threads open: as given, as upstream picks.
        #expect(CodexRolloutKinds.chatPaths([reviewer.path, child.path]) == [reviewer.path, child.path])
    }
}

/// The last line of defence (P212): whatever reaches a row, the reviewer's prompt is never a prompt or a title, and
/// JSON is never a title.
struct CodexThreadTextTests {
    typealias T = CodexThreadFixtures

    @Test
    func theReviewersPromptIsNeverTheOwnersPromptNorATitle() {
        #expect(PromptText.human(T.reviewPrompt) == nil)
        #expect(PromptText.human(T.followUpPrompt) == nil)
        #expect(ChatTitleText.prompt(T.reviewPrompt) == nil)
        // A prompt that quotes it later is the owner's.
        #expect(PromptText.human("why did it say: The following is the Codex agent history") != nil)
    }

    @Test
    func jsonIsNeverATitle() {
        #expect(PromptText.isJSON(T.verdict))
        // Cut short, as a preview cuts it.
        #expect(PromptText.isJSON(#"{"risk_level":"low","user_authorization":"high","outcome":"allow","ra"#))
        #expect(PromptText.isJSON(#"[{"id": 1}, {"id": 2}]"#))
        #expect(ChatTitleText.prompt(T.verdict) == nil)
        for text in ["Fix the {braces} in the parser", "[Image #1] what is this", "{not json", "[link](https://example.com) broke",
                     "{ this is prose }", "Review paper for inconsistencies"] {
            #expect(!PromptText.isJSON(text), "\(text)")
        }
        #expect(ChatTitleText.prompt("Fix the {braces} in the parser") == "Fix the {braces} in the parser")
    }
}
