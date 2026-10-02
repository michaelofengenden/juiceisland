import Foundation
import IslandEngine
import OpenIslandCore

/// Lane c14/cards: a row's branch and a compaction's time (P433, P434), and Done cards whose messages hold tables, code
/// and links (P430 to P432). Every text, id, folder and address fictional (C22).
extension FixtureSessionFeed {
    enum DetailsID {
        /// Claude in a worktree of its own (upstream's `worktreeBranch`, from the folder's path), compacting for 42 s.
        static let compacting = "details-compacting"
        /// Codex on a feature branch, as the folder's read says.
        static let codexBranch = "details-codex-branch"
        /// Claude on the repo's default branch: no tag.
        static let onMain = "details-on-main"
        /// Claude done, on a branch with a long name.
        static let longBranch = "details-long-branch"
    }

    enum RepliesID {
        static let table = "replies-table"
        static let code = "replies-code"
        static let links = "replies-links"
        static let wide = "replies-wide"
    }

    static let detailsCompactingFor: TimeInterval = 42
    static let detailsLongBranch = "fix/upload-retries-keep-the-shared-timer-out-of-the-client"

    static var detailsWorktree: String { NSHomeDirectory() + "/Developer/notes-site/.claude/worktrees/search-index" }
    static func detailsFolder(_ project: String) -> String { NSHomeDirectory() + "/Developer/" + project }

    /// What the folders' `.git` would say, for `GitBranches.fixed`: nothing is read.
    static var detailsBranchReads: [String: GitHead.Read] {
        [detailsFolder("field-notes"): .branch("settings-store", isDefault: false),
         detailsFolder("juice-island"): .branch("main", isDefault: true),
         detailsFolder("upload-kit"): .branch(detailsLongBranch, isDefault: false)]
    }

    static func detailsEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        // Claude compacting in its worktree: the PreCompact came 42 s ago.
        events += start(DetailsID.compacting, title: "Index the notes for search", project: "notes-site", prompt: "index the notes for search",
                        at: now - 20 * m, branch: "search-index", folder: detailsWorktree)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: DetailsID.compacting, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "index the notes for search", model: "claude-opus-5-5[1m]", worktreeBranch: "search-index"), timestamp: now - 5 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: DetailsID.compacting, summary: "Running Edit", phase: .running,
                                                              timestamp: now - 2 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: DetailsID.compacting, summary: "Claude Code is compacting the conversation.",
                                                              phase: .running, timestamp: now - detailsCompactingFor)))
        // Codex on its feature branch, running a tool.
        events += start(DetailsID.codexBranch, title: "Move the settings to one store", project: "field-notes",
                        prompt: "move the settings reads to one store", tool: .codex, at: now - 12 * m)
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: DetailsID.codexBranch, summary: "Running tests", phase: .running,
                                                              timestamp: now - 1 * m)))
        // Claude on main: the default branch says nothing.
        events += start(DetailsID.onMain, title: "Tidy the settings pane", project: "juice-island", prompt: "tidy the settings pane",
                        at: now - 6 * m, terminal: "Ghostty")
        // Claude done on a long branch.
        events += start(DetailsID.longBranch, title: "Fix the upload retries", project: "upload-kit", prompt: "why does the upload test flake",
                        at: now - 40 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: DetailsID.longBranch, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "fix it and run it 50 times", lastAssistantMessage: "Split the retries out of the client; 50 runs pass.",
            model: "claude-sonnet-4-5-20250929"), timestamp: now - 4 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: DetailsID.longBranch, summary: "Split the retries", timestamp: now - 4 * m)))
        return events
    }

    // MARK: Replies

    static let repliesTableMessage = """
        Benchmarks after the change:

        | Suite | Before | After | Change |
        |:------|-------:|------:|:------:|
        | parse | 412 ms | 96 ms | **−77%** |
        | render | 1.8 s | 1.1 s | −39% |
        | `sync` | 88 ms | 91 ms | +3% |

        The sync change is noise.
        """

    static let repliesCodeMessage = """
        Added the retry. Run it with:

        ```sh
        swift test --filter UploadRetryTests --parallel --num-workers 8 --xunit-output results/upload-retries.xml
        ```

        and the helper:

        ```swift
        func retry<T>(_ times: Int, _ body: () throws -> T) rethrows -> T {
            for _ in 1..<times { if let value = try? body() { return value } }

            return try body()
        }
        ```
        """

    static let repliesLinksMessage = """
        Opened the pull request: https://github.com/example/notes-site/pull/42. The run is [on the actions page](https://github.com/example/notes-site/actions/runs/7), and the grid is in <https://developer.apple.com/documentation/swiftui/grid>.
        A [local file](file:///tmp/notes.md) stays text, and [https://bank.example](https://login.example.net/verify) shows where it goes.
        """

    static let repliesWideMessage = """
        | Account | Plan | 5h window | Weekly | Resets | Pace | Note |
        |---|---|--:|--:|---|---|---|
        | work | Max 20x | 41% | 18% | in 2h 5m | steady | the one the island reads first |
        | lab | Pro | 88% | 64% | in 34m | out in ~40m | slow down before the reset |
        """

    static func repliesEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        func claudeDone(_ id: String, title: String, project: String, message: String, at minutes: TimeInterval) {
            events += start(id, title: title, project: project, prompt: title.lowercased(), at: now - (minutes + 5) * m)
            events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: title.lowercased(), lastAssistantMessage: message), timestamp: now - minutes * m)))
            events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: title, timestamp: now - minutes * m)))
        }
        claudeDone(RepliesID.table, title: "Benchmark the parser", project: "notes-site", message: repliesTableMessage, at: 2)
        claudeDone(RepliesID.links, title: "Open the pull request", project: "notes-site", message: repliesLinksMessage, at: 3)
        claudeDone(RepliesID.wide, title: "Compare the accounts", project: "juice-island", message: repliesWideMessage, at: 5)
        // Codex's reply with two fences.
        events += start(RepliesID.code, title: "Add the upload retry", project: "upload-kit", prompt: "add the upload retry", tool: .codex,
                        at: now - 9 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: RepliesID.code, codexMetadata: CodexSessionMetadata(
            transcriptPath: demoRollout(RepliesID.code), lastUserPrompt: "add the upload retry", lastAssistantMessage: repliesCodeMessage),
            timestamp: now - 4 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: RepliesID.code, summary: "Added the retry", timestamp: now - 4 * m)))
        return events
    }
}
