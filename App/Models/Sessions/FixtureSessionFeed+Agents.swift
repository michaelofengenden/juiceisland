import Foundation
import OpenIslandCore

/// Every agent Open Island's engine knows besides Claude and Codex (P151). Each session is built from its hook's own
/// payload through upstream's public helpers (`sessionTitle`, `defaultJumpTarget`, the metadata, the summaries,
/// `questionPrompt`), in the order and shape `BridgeServer` emits them: `handleGeminiHook`, `handleOpenCodeHook` (the
/// plugin's `permission.asked` and `question.asked` as `open-island-opencode.js` sends them), `handleCursorHook`,
/// `handlePiHook`, `handleGrokHook`, and `handleClaudeHook` for Claude Code's forks, whose tool comes from the
/// helper's `--source` (`hook_source`). `AgentFixtureTests` holds them there. Fictional folders (C22).
extension FixtureSessionFeed {
    enum AgentID {
        static let openCodeApproval = "opencode-ses_demo_push"
        static let qoderApproval = "demo-qoder-approval"
        static let qwenQuestion = "demo-qwen-question"
        static let geminiRunning = "demo-gemini-running"
        static let cursorRunning = "demo-cursor-running"
        static let piRunning = "demo-pi-running"
        static let geminiDone = "demo-gemini-done"
        static let openCodeDone = "opencode-ses_demo_notes"
        static let factoryDone = "demo-factory-done"
        static let grokDone = "demo-grok-done"
        static let kimiDone = "demo-kimi-done"
        static let codebuddyDone = "demo-codebuddy-done"
        static let ohMyPiDone = "demo-ohmypi-done"
        static let openCodeQuestion = "opencode-ses_demo_release"
    }

    /// Needs you: an OpenCode command, a Qoder command, a Qwen question. Running: Gemini, Cursor's shell, Pi's read.
    /// Done: Gemini (its reply sent twice, as Gemini sometimes does), OpenCode, Factory and Grok within the quarter
    /// hour; Kimi, CodeBuddy and Oh My Pi an hour ago and more. The fork that asks is Qoder, which the island answers:
    /// Kimi is Watch, so a card of its with Allow and Deny would show what Kimi can never get (P1135).
    static func agentEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        events += openCodeStart(AgentID.openCodeApproval, project: "notes-site", prompt: "push the fix", at: now - 9 * m)
        events += openCodePermission(AgentID.openCodeApproval, project: "notes-site", tool: "Bash", patterns: [openCodePush],
                                     at: now - 2 * m)
        events += claudeFork(AgentID.qoderApproval, source: "qoder", project: "juice-island", prompt: "clean the build",
                             at: now - 8 * m)
        events.append(forkApproval(AgentID.qoderApproval, source: "qoder", project: "juice-island", tool: "Bash",
                                   input: .object(["command": .string(forkCommand), "description": .string("Remove the stale test bundle")]),
                                   useID: "call_qoder_clean", at: now - 3 * m))
        events += claudeFork(AgentID.qwenQuestion, source: "qwen", project: "WeatherStation", prompt: "pick a chart", at: now - 7 * m)
        events.append(.questionAsked(QuestionAsked(sessionID: AgentID.qwenQuestion, prompt: try! forkPayload([
            "hook_event_name": .string("PermissionRequest"), "session_id": .string(AgentID.qwenQuestion),
            "cwd": .string(folder("WeatherStation")), "hook_source": .string("qwen"), "tool_name": .string("AskUserQuestion"),
            "tool_input": .object(["questions": .array([.object([
                "question": .string("Which chart should the usage page lead with?"), "header": .string("Chart"),
                "multiSelect": .boolean(false),
                "options": .array([
                    .object(["label": .string("Burn-down"), "description": .string("Quota left against the reset.")]),
                    .object(["label": .string("Daily spend"), "description": .string("One bar a day, this month.")]),
                ]),
            ])])]),
        ]).questionPrompt!, timestamp: now - 4 * m)))
        events += geminiEvents(AgentID.geminiRunning, project: "notes-site", prompt: "tighten the intro", reply: nil, at: now - 6 * m)
        events += cursorEvents(AgentID.cursorRunning, project: "juice-island", prompt: "run the tests", at: now - 5 * m)
        events += piEvents(AgentID.piRunning, variant: .pi, project: "MarathonTrainingLog", prompt: "read the results",
                           tool: "read", input: "results/summary.md", message: nil, at: now - 4 * m, endedAt: nil)
        events += geminiEvents(AgentID.geminiDone, project: "notes-site", prompt: "draft the setup page",
                               reply: geminiReply + "\n\n" + geminiReply, at: now - 14 * m, finishedAt: now - 6 * m)
        events += openCodeStart(AgentID.openCodeDone, project: "notes-site", prompt: "sort the notes", at: now - 13 * m)
        events += openCodeStop(AgentID.openCodeDone, project: "notes-site", prompt: "sort the notes",
                               message: "Sorted the notes by date and merged the two March files.", at: now - 7 * m)
        events += claudeFork(AgentID.factoryDone, source: "droid", project: "juice-island", prompt: "check the release script",
                             at: now - 12 * m)
        events += forkStop(AgentID.factoryDone, source: "droid", project: "juice-island", prompt: "check the release script",
                           message: "The release script tags `juice-0.4-1` and pushes only to the private origin.", at: now - 8 * m)
        events += grokEvents(AgentID.grokDone, project: "Desktop", prompt: "rename the screenshots",
                             message: "Renamed 14 screenshots by date.", at: now - 11 * m, finishedAt: now - 9 * m)
        events += claudeFork(AgentID.kimiDone, source: "kimi", project: "WeatherStation", prompt: "list the open issues",
                             at: now - 90 * m)
        events += forkStop(AgentID.kimiDone, source: "kimi", project: "WeatherStation", prompt: "list the open issues",
                           message: "Seven issues are open; two are labelled bug.", at: now - 85 * m)
        events += claudeFork(AgentID.codebuddyDone, source: "codebuddy", project: "notes-site", prompt: "fix the links",
                             at: now - 120 * m)
        events += forkStop(AgentID.codebuddyDone, source: "codebuddy", project: "notes-site", prompt: "fix the links",
                           message: "Fixed three broken links.", at: now - 110 * m)
        events += piEvents(AgentID.ohMyPiDone, variant: .ohMyPi, project: "Desktop", prompt: "sum the invoices", tool: nil, input: nil,
                           message: "The invoices come to 1,240 in March.", at: now - 150 * m, endedAt: now - 140 * m)
        return events
    }

    /// OpenCode asks one question, as its plugin sends it (a question with no header gets "Question 1").
    static func agentQuestionEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = openCodeStart(AgentID.openCodeQuestion, project: "notes-site", prompt: "ship the release", at: now - 6 * m)
        var asked = openCodePayload(AgentID.openCodeQuestion, project: "notes-site", event: .questionAsked)
        asked.questionID = "que_demo_branch"
        asked.questionText = "Which branch should the release go out from?"
        asked.questions = [OpenCodeQuestionPayload(question: "Which branch should the release go out from?", header: "Question 1", options: [
            OpenCodeQuestionOptionPayload(label: "main", description: "What is merged today."),
            OpenCodeQuestionOptionPayload(label: "release/0.4", description: "Cut last week, fixes only."),
        ])]
        events.append(.questionAsked(QuestionAsked(sessionID: AgentID.openCodeQuestion, prompt: asked.questionPrompt, timestamp: now - 1 * m)))
        return events + geminiEvents(AgentID.geminiRunning, project: "notes-site", prompt: "tighten the intro", reply: nil, at: now - 6 * m)
            + cursorEvents(AgentID.cursorRunning, project: "juice-island", prompt: "run the tests", at: now - 5 * m)
    }

    static let openCodePush = "git push origin fix/intro-links"
    static let forkCommand = "rm -rf .build/arm64-apple-macosx/debug/JuiceIslandPackageTests.xctest && swift build --build-tests"
    static let geminiReply = """
        Drafted **docs/setup.md**:

        - Install, then run `notes-site serve`
        - The config lives in `~/.config/notes-site`
        """

    static func folder(_ project: String) -> String { NSHomeDirectory() + "/Developer/" + project }

    // MARK: OpenCode (its plugin writes to the bridge's socket itself)

    static func openCodePayload(_ id: String, project: String, event: OpenCodeHookEventName) -> OpenCodeHookPayload {
        OpenCodeHookPayload(hookEventName: event, sessionID: id, cwd: folder(project), terminalApp: "iTerm",
                            terminalTTY: "/dev/ttys021")
    }

    /// `session.created`, then the user's text part as UserPromptSubmit.
    static func openCodeStart(_ id: String, project: String, prompt: String, at date: Date) -> [AgentEvent] {
        let start = openCodePayload(id, project: project, event: .sessionStart)
        var prompted = openCodePayload(id, project: project, event: .userPromptSubmit)
        prompted.prompt = prompt
        return [
            .sessionStarted(SessionStarted(sessionID: id, title: start.sessionTitle, tool: .openCode, origin: .live, initialPhase: .running,
                                           summary: start.implicitStartSummary, timestamp: date, jumpTarget: start.defaultJumpTarget)),
            .openCodeSessionMetadataUpdated(OpenCodeSessionMetadataUpdated(sessionID: id, openCodeMetadata: prompted.defaultOpenCodeMetadata,
                                                                           timestamp: date + 1)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: prompted.promptPreview.map { promptPrefix + $0 } ?? "",
                                                    phase: .running, timestamp: date + 1)),
        ]
    }

    /// `permission.asked` as the plugin maps it (`tool_input` is its JSON, cut at 200), and the request as the bridge
    /// builds it from that.
    static func openCodePermission(_ id: String, project: String, tool: String, patterns: [String], at date: Date) -> [AgentEvent] {
        let asked = openCodePermissionPayload(id, project: project, tool: tool, patterns: patterns)
        return [.permissionRequested(PermissionRequested(sessionID: id, request: openCodeRequest(asked), timestamp: date))]
    }

    static func openCodePermissionPayload(_ id: String, project: String, tool: String, patterns: [String]) -> OpenCodeHookPayload {
        var asked = openCodePayload(id, project: project, event: .permissionRequest)
        let quoted = patterns.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
        var json = "{\"patterns\":[\(quoted)],\"metadata\":{}"
        if tool == "Bash", !patterns.isEmpty { json += ",\"command\":\"\(patterns.joined(separator: " && "))\"" }
        if tool == "Edit" || tool == "Write", let first = patterns.first { json += ",\"file_path\":\"\(first)\"" }
        json += "}"
        asked.toolName = tool
        asked.toolInput = String(json.prefix(200))
        asked.permissionID = "per_demo_\(id.count)"
        asked.permissionTitle = "Allow \(tool)"
        asked.permissionDescription = patterns.first.map { "OpenCode wants to run \(tool): \($0)" } ?? "OpenCode wants to run \(tool)"
        return asked
    }

    /// `BridgeServer.handleOpenCodeHook`'s PermissionRequest.
    static func openCodeRequest(_ payload: OpenCodeHookPayload) -> PermissionRequest {
        PermissionRequest(title: payload.permissionTitle ?? payload.toolName.map { "Allow \($0)" } ?? "Allow OpenCode tool",
                          summary: payload.permissionDescription ?? "OpenCode needs permission to continue.",
                          affectedPath: payload.toolInputPreview ?? payload.cwd, primaryActionTitle: "Allow", secondaryActionTitle: "Deny",
                          toolName: payload.toolName)
    }

    /// `session.status` idle: Stop with the last assistant text the plugin kept; the metadata as the bridge merges
    /// it (the prompt kept).
    static func openCodeStop(_ id: String, project: String, prompt: String, message: String, at date: Date) -> [AgentEvent] {
        var stop = openCodePayload(id, project: project, event: .stop)
        stop.lastAssistantMessage = message
        var metadata = stop.defaultOpenCodeMetadata
        metadata.initialUserPrompt = prompt
        metadata.lastUserPrompt = prompt
        return [
            .openCodeSessionMetadataUpdated(OpenCodeSessionMetadataUpdated(sessionID: id, openCodeMetadata: metadata, timestamp: date)),
            .sessionCompleted(SessionCompleted(sessionID: id, summary: stop.lastAssistantMessage ?? stop.assistantMessagePreview ?? "",
                                               timestamp: date)),
        ]
    }

    // MARK: Claude Code's forks (Claude's payload, `hook_source` from `--source`)

    static func forkPayload(_ fields: [String: ClaudeHookJSONValue]) throws -> ClaudeHookPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(ClaudeHookPayload.self, from: encoder.encode(ClaudeHookJSONValue.object(fields)))
    }

    private static func forkFields(_ id: String, source: String, project: String, event: String) -> [String: ClaudeHookJSONValue] {
        ["hook_event_name": .string(event), "session_id": .string(id), "cwd": .string(folder(project)), "hook_source": .string(source),
         "transcript_path": .string(NSHomeDirectory() + "/.\(source)/sessions/\(id).jsonl"), "terminal_app": .string("Ghostty")]
    }

    /// SessionStart, then UserPromptSubmit, as `handleClaudeHook` emits them.
    static func claudeFork(_ id: String, source: String, project: String, prompt: String, at date: Date) -> [AgentEvent] {
        let start = try! forkPayload(forkFields(id, source: source, project: project, event: "SessionStart")
                                     .merging(["source": .string("startup")]) { $1 })
        let prompted = try! forkPayload(forkFields(id, source: source, project: project, event: "UserPromptSubmit")
                                        .merging(["prompt": .string(prompt)]) { $1 })
        return [
            .sessionStarted(SessionStarted(sessionID: id, title: start.sessionTitle, tool: start.resolvedAgentTool, origin: .live,
                                           initialPhase: .completed, summary: start.implicitStartSummary, timestamp: date,
                                           jumpTarget: start.defaultJumpTarget, claudeMetadata: start.defaultClaudeMetadata)),
            .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: prompted.defaultClaudeMetadata,
                                                                       timestamp: date + 1)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: prompted.promptPreview.map { promptPrefix + $0 } ?? "",
                                                    phase: .running, timestamp: date + 1)),
        ]
    }

    /// PermissionRequest: the request as the bridge builds it, Claude's own title, sentence and preview.
    static func forkApproval(_ id: String, source: String, project: String, tool: String, input: ClaudeHookJSONValue, useID: String,
                             at date: Date) -> AgentEvent {
        let asked = try! forkPayload(forkFields(id, source: source, project: project, event: "PermissionRequest")
                                     .merging(["tool_name": .string(tool), "tool_input": input, "tool_use_id": .string(useID)]) { $1 })
        return .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: asked.permissionRequestTitle, summary: asked.permissionRequestSummary, affectedPath: asked.permissionAffectedPath,
            primaryActionTitle: "Allow Once", secondaryActionTitle: "Deny", toolName: asked.toolName, toolUseID: asked.toolUseID,
            suggestedUpdates: asked.permissionSuggestions ?? []), timestamp: date))
    }

    /// Stop, with `last_assistant_message`; the metadata as the bridge merges it (the prompt kept).
    static func forkStop(_ id: String, source: String, project: String, prompt: String, message: String, at date: Date) -> [AgentEvent] {
        let stop = try! forkPayload(forkFields(id, source: source, project: project, event: "Stop")
                                    .merging(["last_assistant_message": .string(message)]) { $1 })
        var metadata = stop.defaultClaudeMetadata
        metadata.initialUserPrompt = prompt
        metadata.lastUserPrompt = prompt
        return [
            .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: metadata, timestamp: date)),
            .sessionCompleted(SessionCompleted(sessionID: id, summary: stop.lastAssistantMessage ?? "", timestamp: date)),
        ]
    }

    // MARK: Gemini CLI (fire and forget: no approvals)

    static func geminiEvents(_ id: String, project: String, prompt: String, reply: String?, at date: Date,
                             finishedAt: Date? = nil) -> [AgentEvent] {
        var hook = GeminiHookPayload(cwd: folder(project), hookEventName: .sessionStart, sessionID: id, source: "startup",
                                     terminalApp: "Ghostty", terminalTTY: "/dev/ttys031")
        var events: [AgentEvent] = [.sessionStarted(SessionStarted(
            sessionID: id, title: hook.sessionTitle, tool: .geminiCLI, origin: .live, initialPhase: .completed,
            summary: hook.implicitSummary, timestamp: date, jumpTarget: hook.defaultJumpTarget))]
        hook.hookEventName = .beforeAgent
        hook.source = nil
        hook.prompt = prompt
        var metadata = geminiMerged(nil, hook.defaultGeminiMetadata)
        events.append(.geminiSessionMetadataUpdated(GeminiSessionMetadataUpdated(sessionID: id, geminiMetadata: metadata, timestamp: date + 1)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: hook.implicitSummary, phase: .running, timestamp: date + 1)))
        guard let reply, let finishedAt else { return events }
        hook.hookEventName = .afterAgent
        hook.promptResponse = reply
        metadata = geminiMerged(metadata, hook.defaultGeminiMetadata)
        events.append(.geminiSessionMetadataUpdated(GeminiSessionMetadataUpdated(sessionID: id, geminiMetadata: metadata, timestamp: finishedAt)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: hook.implicitSummary, timestamp: finishedAt)))
        return events
    }

    /// `BridgeServer.synchronizeGeminiMetadata`'s merge.
    static func geminiMerged(_ existing: GeminiSessionMetadata?, _ update: GeminiSessionMetadata) -> GeminiSessionMetadata {
        GeminiSessionMetadata(transcriptPath: update.transcriptPath ?? existing?.transcriptPath,
                              initialUserPrompt: existing?.initialUserPrompt ?? update.initialUserPrompt ?? update.lastUserPrompt,
                              lastUserPrompt: update.lastUserPrompt ?? existing?.lastUserPrompt,
                              lastAssistantMessage: update.lastAssistantMessage ?? existing?.lastAssistantMessage,
                              lastAssistantMessageBody: update.lastAssistantMessageBody ?? existing?.lastAssistantMessageBody)
    }

    // MARK: Cursor (its hooks run inside the IDE; a shell command is allowed at once)

    static func cursorEvents(_ id: String, project: String, prompt: String, at date: Date) -> [AgentEvent] {
        var hook = CursorHookPayload(hookEventName: .beforeSubmitPrompt, conversationId: id, generationId: "gen-demo-1",
                                     workspaceRoots: [folder(project)], prompt: prompt, model: "demo-model")
        var events: [AgentEvent] = [
            .sessionStarted(SessionStarted(sessionID: id, title: hook.sessionTitle, tool: .cursor, origin: .live, initialPhase: .running,
                                           summary: hook.implicitStartSummary, timestamp: date, jumpTarget: hook.defaultJumpTarget,
                                           cursorMetadata: hook.defaultCursorMetadata)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: hook.promptPreview.map { promptPrefix + $0 } ?? "",
                                                    phase: .running, timestamp: date + 1)),
        ]
        let prompted = hook.defaultCursorMetadata
        hook.hookEventName = .beforeShellExecution
        hook.prompt = nil
        hook.command = "swift test --filter AgentFixtureTests"
        var metadata = hook.defaultCursorMetadata
        metadata.initialUserPrompt = prompted.initialUserPrompt
        metadata.lastUserPrompt = prompted.lastUserPrompt
        events.append(.cursorSessionMetadataUpdated(CursorSessionMetadataUpdated(sessionID: id, cursorMetadata: metadata, timestamp: date + 60)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: hook.commandPreview.map { "Running: \($0)" } ?? "",
                                                              phase: .running, timestamp: date + 60)))
        return events
    }

    // MARK: Pi and Oh My Pi (their extension writes to the bridge's socket itself)

    static func piEvents(_ id: String, variant: PiAgentVariant, project: String, prompt: String, tool: String?, input: String?,
                         message: String?, at date: Date, endedAt: Date?) -> [AgentEvent] {
        let start = PiHookPayload(hookEventName: .sessionStart, agent: variant, sessionID: id, cwd: folder(project), terminalApp: "Terminal")
        var prompted = start
        prompted.hookEventName = .userPromptSubmit
        prompted.prompt = prompt
        var metadata = PiSessionMetadata.merged(existing: nil, update: prompted.defaultPiMetadata)
        var events: [AgentEvent] = [
            .sessionStarted(SessionStarted(sessionID: id, title: start.sessionTitle, tool: variant.tool, origin: .live, initialPhase: .completed,
                                           summary: start.implicitStartSummary, timestamp: date, jumpTarget: start.defaultJumpTarget)),
            .piSessionMetadataUpdated(PiSessionMetadataUpdated(sessionID: id, piMetadata: metadata, timestamp: date + 1)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: prompted.promptPreview.map { promptPrefix + $0 } ?? "",
                                                    phase: .running, timestamp: date + 1)),
        ]
        if let tool {
            var running = start
            running.hookEventName = .preToolUse
            running.toolName = tool
            running.toolInput = input
            metadata = PiSessionMetadata.merged(existing: metadata, update: running.defaultPiMetadata)
            events.append(.piSessionMetadataUpdated(PiSessionMetadataUpdated(sessionID: id, piMetadata: metadata, timestamp: date + 30)))
            events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Running \(tool): \(running.toolInputPreview ?? "")",
                                                                  phase: .running, timestamp: date + 30)))
        }
        guard let message, let endedAt else { return events }
        var stop = start
        stop.hookEventName = .stop
        stop.lastAssistantMessage = message
        metadata = PiSessionMetadata.merged(existing: metadata, update: stop.defaultPiMetadata, clearsCurrentTool: true)
        events.append(.piSessionMetadataUpdated(PiSessionMetadataUpdated(sessionID: id, piMetadata: metadata, timestamp: endedAt)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: stop.assistantMessagePreview ?? "", timestamp: endedAt)))
        return events
    }

    // MARK: Grok (fire and forget; its hooks keep no metadata, the summary is the message)

    static func grokEvents(_ id: String, project: String, prompt: String, message: String, at date: Date, finishedAt: Date) -> [AgentEvent] {
        let start = GrokHookPayload(cwd: folder(project), hookEventName: .sessionStart, sessionID: id, source: "startup", terminalApp: "Warp")
        let prompted = GrokHookPayload(cwd: folder(project), hookEventName: .userPromptSubmit, sessionID: id, prompt: prompt, terminalApp: "Warp")
        let stop = GrokHookPayload(cwd: folder(project), hookEventName: .stop, sessionID: id, lastAssistantMessage: message,
                                   reason: "end_turn", terminalApp: "Warp")
        return [
            .sessionStarted(SessionStarted(sessionID: id, title: start.sessionTitle, tool: .grokBuild, origin: .live, initialPhase: .completed,
                                           summary: start.implicitSummary, timestamp: date, jumpTarget: start.defaultJumpTarget)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: prompted.implicitSummary, phase: .running, timestamp: date + 1)),
            .sessionCompleted(SessionCompleted(sessionID: id, summary: stop.implicitSummary, timestamp: finishedAt)),
        ]
    }
}
