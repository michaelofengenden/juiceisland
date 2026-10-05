import Foundation
import IslandEngine
import OpenIslandCore

/// A headless `SessionEngine` (`SessionEngine.preview`) fed with fixture events through `loadPreviewEvents`: no
/// bridge, no discovery, no process monitor, no socket, no jump and no sound. Commands the cards send land in
/// `sentCommands`; nothing leaves the process.
///
/// Approvals and questions are shaped as upstream's bridge makes them from a live hook (`ClaudeHooks.swift`,
/// `CodexHooks.swift`; `FixtureShapeTests` feeds the hooks' own payloads through upstream to hold them there): a
/// Claude request carries upstream's fixed sentence and at most 110 characters of the input, and the tool call
/// itself comes from `toolCalls`, as a live one comes from the transcript; a Codex request carries the justification
/// and the whole command. So a render shows what the live island shows.
@MainActor
final class FixtureSessionFeed {
    enum Scenario: Sendable {
        /// The prototype's sessions: the question, the approval, the running Edit, the Codex done, the two Codex rows.
        case prototype
        /// `prototype` plus a plan ready, a Claude done, an interrupted turn and a thinking session.
        case allStates
        case empty
        /// One Codex turn done, its last message in Markdown with a file citation (the owner's Done card, 2026-09-24).
        case markdown
        /// A Codex session asking to run a long command (the owner's approval card, 2026-09-25) at the top of four rows:
        /// the question, a running Edit and a Claude turn just done.
        case codexApproval
        /// Every kind of card, long and short, for Claude and Codex: a multi-line command, one the transcript does not
        /// have yet, an edit, a new file, a fetch, a short Codex command, three questions at once, a long plan.
        case cards
        /// Every other agent the engine knows, one session each, from their hooks' own payloads (P151,
        /// `FixtureSessionFeed+Agents.swift`): OpenCode and Kimi approvals, a Qwen question, Gemini, Cursor and Pi
        /// running, the rest done.
        case agents
        /// OpenCode asks a question, with Gemini and Cursor running.
        case agentQuestion
        /// The owner's first screenshot (2026-09-25): a Codex app thread that asks a question while it reasons on, and
        /// a Claude row whose last "prompt" was a background task's notice (`FixtureSessionFeed+Attention.swift`).
        case owner
        /// Requests as the engine's book holds them: Claude's two in a queue (answerable), and read-only ones: Codex's
        /// in a terminal, a subagent's, a Claude Desktop session's, a prompt with no hook; and a failed turn.
        case attention
        /// Claude and Codex side by side, titled as their chats (`FixtureSessionFeed+Look.swift`): an approval and a run
        /// each, a Claude session with no title yet, a long name, and OpenCode's question.
        case look
        /// Models, modes and task lists, a stalled run and a long reply (`FixtureSessionFeed+Rows.swift`, P310-P312).
        case rows
        /// Branches and a compaction's time (`FixtureSessionFeed+Details.swift`, P433, P434): Claude compacting in its
        /// worktree, Codex on a feature branch, Claude on main, Claude done on a long branch.
        case details
        /// Done cards whose messages hold a table, fenced code, links and a table wider than the card (P430 to P432).
        case replies
        /// The owner's screenshot of 2026-09-30 (P660, P661): a Codex app thread whose hooks named no host asks a question,
        /// its prompt the app's in-app browser context and then the owner's words (`FixtureSessionFeed+CodexApp.swift`).
        case codexAppContext
        /// Diagnostics' Demo sessions and the README's shots (P967, `FixtureSessionFeed+DemoSessions.swift`): Claude asks
        /// to run a command and asks a question, Claude edits, Codex runs a command and is done, Copilot CLI runs; in
        /// made-up folders only.
        case demoSessions
    }

    /// Session ids, so renders and tests can pick a card.
    enum ID {
        static let question = "demo-question"
        static let approval = "demo-approval"
        static let running = "demo-running"
        static let codexDone = "demo-codex-done"
        static let codexRunning = "demo-codex-running"
        static let codexIdle = "demo-codex-idle"
        static let plan = "demo-plan"
        static let claudeDone = "demo-claude-done"
        static let interrupted = "demo-interrupted"
        static let thinking = "demo-thinking"
        static let markdownDone = "demo-markdown-done"
        static let codexApproval = "demo-codex-approval"
        static let longBash = "demo-long-bash"
        static let unreadBash = "demo-unread-bash"
        static let edit = "demo-edit"
        static let write = "demo-write"
        static let fetch = "demo-fetch"
        static let codexShort = "demo-codex-short"
        static let questions = "demo-questions"
        static let longPlan = "demo-long-plan"
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [BridgeCommand] = []
        private var replies: [(text: String, route: ReplyRoute)] = []
        private var fails = false
        var failing: Bool {
            get { lock.withLock { fails } }
            set { lock.withLock { fails = newValue } }
        }
        func append(_ command: BridgeCommand) { lock.withLock { commands.append(command) } }
        func append(reply: String, route: ReplyRoute) { lock.withLock { replies.append((reply, route)) } }
        var all: [BridgeCommand] { lock.withLock { commands } }
        var allReplies: [(text: String, route: ReplyRoute)] { lock.withLock { replies } }
    }

    let engine: SessionEngine
    let recorder = Recorder()
    let now: Date
    /// The engine's and the model's clock: `now` held still (renders, tests), or the wall clock (Demo sessions, P967).
    let clock: @Sendable () -> Date
    /// What the scenario's folders' `.git` would say (`GitBranches.fixed`): nothing is read.
    let branchReads: [String: GitHead.Read]
    var sentCommands: [BridgeCommand] { recorder.all }
    var sentReplies: [(text: String, route: ReplyRoute)] { recorder.allReplies }

    /// `sendsFail`: every command and reply a card sends fails, as an unreachable bridge or terminal would, so the cards
    /// keep their "Not sent" state (renders and tests; `sendsFail` can change later). Replies land in `sentReplies`,
    /// never in a terminal.
    init(scenario: Scenario = .allStates, now: Date = DemoClock.now, sendsFail: Bool = false, clock: (@Sendable () -> Date)? = nil) {
        self.now = now
        let clock = clock ?? { now }
        self.clock = clock
        branchReads = scenario == .details ? Self.detailsBranchReads : [:]
        let recorder = recorder
        recorder.failing = sendsFail
        engine = SessionEngine.preview(clock: clock, commands: { command in
            if recorder.failing { throw CocoaError(.featureUnsupported) }
            recorder.append(command)
        }, toolCalls: Self.toolCalls, replies: { route, text in
            guard !recorder.failing else { return false }
            recorder.append(reply: text, route: route)
            return true
        })
        engine.loadPreviewEvents(Self.events(scenario, now: now))
        Self.loadAttention(scenario, into: engine, now: now)
        if scenario == .rows { Self.loadRows(into: engine, now: now) }
        Self.loadTitles(into: engine)
        // The demo's Claude turn in Ghostty, its agent named as a hook's context note names it, so its card offers a
        // reply (P128, P139); no process is looked at.
        engine.loadPreviewAgents([ID.claudeDone: 4242])
    }

    var sendsFail: Bool {
        get { recorder.failing }
        set { recorder.failing = newValue }
    }

    /// A sessions model over this feed; row clicks are recorded and noted "Demo session", never jumped. `stalledAfter`:
    /// off unless given, so the demo's long runs stay running (P312).
    func makeModel(stalledAfter: TimeInterval? = nil) -> EngineSessionsModel {
        let clock = clock
        return EngineSessionsModel(engine: engine, clock: { clock() }, stalledAfter: { stalledAfter }, branches: GitBranches(.fixed(branchReads)))
    }

    // MARK: Events

    static func events(_ scenario: Scenario, now: Date) -> [AgentEvent] {
        switch scenario {
        case .empty: return []
        case .prototype: return prototypeEvents(now: now)
        case .allStates: return prototypeEvents(now: now) + extraEvents(now: now)
        case .markdown: return markdownEvents(now: now)
        case .codexApproval: return codexApprovalEvents(now: now)
        case .cards: return cardEvents(now: now)
        case .agents: return agentEvents(now: now)
        case .agentQuestion: return agentQuestionEvents(now: now)
        case .owner: return ownerEvents(now: now)
        case .attention: return attentionEvents(now: now)
        case .look: return lookEvents(now: now)
        case .rows: return rowsEvents(now: now)
        case .details: return detailsEvents(now: now)
        case .replies: return repliesEvents(now: now)
        case .codexAppContext: return codexAppContextEvents(now: now)
        case .demoSessions: return demoSessionsEvents(now: now)
        }
    }

    /// Codex's last message as it arrives: Markdown, a citation directive and a link (fictional folder, C22).
    static var markdownMessage: String {
        let file = NSHomeDirectory() + "/Developer/notes-site/notes.pdf"
        return """
        Read the report and wrote **three pages** of notes: :codex-file-citation{path="\(file)"}

        ## Next
        - The *summary* is in `results/summary.md`
        - Check [the outline](https://example.com/outline) before the __second pass__
        """
    }

    private static func markdownEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = start(ID.markdownDone, title: "Summarise the report", project: "notes-site", prompt: "summarise the report",
                           tool: .codex, at: now - 12 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: ID.markdownDone, codexMetadata: CodexSessionMetadata(
            transcriptPath: demoRollout(ID.markdownDone), lastUserPrompt: "summarise the report", lastAssistantMessage: markdownMessage), timestamp: now - 3 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: ID.markdownDone, summary: markdownMessage, timestamp: now - 3 * m)))
        return events
    }

    private static func prototypeEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = questionEvents(now: now)
        // Claude wants to push, with its own "always allow git push" suggestion (and no mode: a push writes no file).
        events += start(ID.approval, title: "Push the window mode", project: "juice-island", prompt: "push the branch", at: now - 9 * m,
                        branch: "window-mode")
        events.append(claudeApproval(ID.approval, "Bash", useID: "toolu_demo_push", shown: pushCommand, at: now - 3 * m,
                                     suggestions: [.addRules(destination: .localSettings,
                                                             rules: [ClaudePermissionRuleValue(toolName: "Bash", ruleContent: "git push:*")],
                                                             behavior: .allow)]))
        events += runningEvents(now: now)
        // Codex finished an hour ago.
        events += start(ID.codexDone, title: "Continue MarathonTrainingLog", project: "MarathonTrainingLog", prompt: "continue", tool: .codex,
                        at: now - 80 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: ID.codexDone, codexMetadata: CodexSessionMetadata(
            transcriptPath: demoRollout(ID.codexDone), lastUserPrompt: "continue", lastAssistantMessage: "wrote results/summary.md"), timestamp: now - 60 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: ID.codexDone, summary: "wrote results/summary.md", timestamp: now - 60 * m)))
        // Two more Codex sessions: one running a tool for 93 minutes (its last progress 2m ago), one idle.
        events += start(ID.codexRunning, title: "mcp images", project: "Desktop", prompt: "resize the mcp images", tool: .codex, at: now - 95 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: ID.codexRunning, codexMetadata: CodexSessionMetadata(
            transcriptPath: demoRollout(ID.codexRunning), lastUserPrompt: "resize the mcp images", currentTool: "exec_command", currentCommandPreview: "sips -Z 512 *.png"),
            timestamp: now - 93 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: ID.codexRunning, summary: "Running exec_command", phase: .running, timestamp: now - 93 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: ID.codexRunning, summary: "Running exec_command", phase: .running, timestamp: now - 2 * m)))
        events += start(ID.codexIdle, title: "Draft release notes", project: "notes-site", prompt: "draft the release notes", tool: .codex, at: now - 40 * m)
        events.append(.sessionCompleted(SessionCompleted(sessionID: ID.codexIdle, summary: "Drafted the notes.", timestamp: now - 18 * m)))
        return events
    }

    private static func extraEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        // Plan ready: ExitPlanMode with a numbered plan.
        events += start(ID.plan, title: "Plan the render harness", project: "juice-island", prompt: "plan the render harness", at: now - 6 * m)
        events.append(claudeApproval(ID.plan, "ExitPlanMode", useID: "toolu_demo_plan", shown: shown(toolCalls["toolu_demo_plan"]!),
                                     at: now - 1 * m))
        events += claudeDoneEvents(now: now)
        // A turn cancelled with Esc.
        events += start(ID.interrupted, title: "Refactor the hover model", project: "WeatherStation", prompt: "refactor the hover model", at: now - 50 * m)
        events.append(.sessionCompleted(SessionCompleted(sessionID: ID.interrupted, summary: "Interrupted.", timestamp: now - 44 * m, isInterrupt: true)))
        // Thinking.
        events += start(ID.thinking, title: "Review the pitfalls list", project: "WeatherStation", prompt: "review the pitfalls", at: now - 4 * m)
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: ID.thinking, summary: "Thinking.", phase: .running, timestamp: now - 1 * m)))
        return events
    }

    /// Claude asks which name to use (four options, the last "Decide later"), as upstream's hook builds it: the
    /// prompt titled by its one question, and upstream's free-form "Other" after the options.
    private static func questionEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = start(ID.question, title: "Name the app", project: "WeatherStation", prompt: "JuiceBar, JuiceIsland or Sandbar…",
                           at: now - 20 * m)
        events.append(.questionAsked(QuestionAsked(sessionID: ID.question, prompt: claudeQuestions([
            QuestionPromptItem(question: "Which name should the app use?", header: "App name", options: [
                QuestionOption(label: "Juice Island", description: "Reads like a place; matches the repo juice-island."),
                QuestionOption(label: "Juice Bar", description: "The notch sits in the menu bar; a juice bar serves the juice."),
                QuestionOption(label: "Sandbar", description: "A sand island, the menu bar it sits in, and the battery bars."),
                QuestionOption(label: "Decide later", description: "Keep Juice Island for now; pick before the first build ships."),
            ]),
        ]), timestamp: now - 14 * m)))
        return events
    }

    /// Upstream's `ClaudeHookPayload.questionPrompt`: "Other" (free-form) after each question's options, and the
    /// prompt titled by its question, or "Claude has N questions for you.".
    static func claudeQuestions(_ items: [QuestionPromptItem]) -> QuestionPrompt {
        let questions = items.map { item in
            var item = item
            item.options.append(QuestionOption(label: "Other", description: "", allowsFreeform: true))
            return item
        }
        let title = questions.count == 1 ? questions[0].question : "Claude has \(questions.count) questions for you."
        return QuestionPrompt(title: title, questions: questions)
    }

    /// Claude is editing a file.
    private static func runningEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = start(ID.running, title: "Island section for Juice", project: "WeatherStation", prompt: "build the html mockups",
                           at: now - 30 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: ID.running, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "build the html mockups", currentTool: "Edit",
            currentToolInputPreview: "Juice/Sources/JuiceUI/Island/JuiceIslandSectionView.swift"), timestamp: now - 12 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: ID.running, summary: "Running Edit", phase: .running, timestamp: now - 12 * m)))
        return events
    }

    /// Claude finished a turn.
    private static func claudeDoneEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        // In Ghostty, its terminal known by id: the one demo turn a reply can go to (P128).
        var events = start(ID.claudeDone, title: "Write the release checklist", project: "juice-island", prompt: "write the checklist",
                           at: now - 25 * m, terminal: "Ghostty", terminalID: "3F2A9C1E-0000-4000-8000-00000000D0E1")
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: ID.claudeDone, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "write the checklist",
            lastAssistantMessage: "Wrote docs/release-checklist.md with 12 steps. The signing step needs your team id before the first build."),
            timestamp: now - 5 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: ID.claudeDone, summary: "Wrote docs/release-checklist.md", timestamp: now - 5 * m)))
        return events
    }

    /// Codex asks to run a long command, its title and its status both longer than a row (fictional folder, C22).
    private static func codexApprovalEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = start(ID.codexApproval, title: "Publish the validated additive dashboard and its checks", project: "MarathonTrainingLog",
                           prompt: "publish the dashboard", tool: .codex, at: now - 30 * m)
        events.append(codexApproval(ID.codexApproval, command: codexInstallCommand,
                                    justification: "May I install the validated additive dashboard publication into local-artifacts?",
                                    useID: "call_demo_install", at: now - 1 * m))
        return questionEvents(now: now) + events + runningEvents(now: now) + claudeDoneEvents(now: now)
    }

    /// One of each card, long and short, for Claude and Codex (fictional folders, C22).
    private static func cardEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        events += start(ID.longBash, title: "Commit the card fix", project: "juice-island", prompt: "commit it", at: now - 12 * m)
        events.append(claudeApproval(ID.longBash, "Bash", useID: "toolu_demo_commit",
                                     shown: shown(toolCalls["toolu_demo_commit"]!), at: now - 2 * m))
        events += start(ID.unreadBash, title: "Clean the build folder", project: "juice-island", prompt: "clean up", at: now - 11 * m)
        // Not in the transcript (yet): the card shows the request's own 110 characters, clipped with "…".
        events.append(claudeApproval(ID.unreadBash, "Bash", useID: "toolu_demo_unread",
                                     shown: shown(.object(["command": .string(unreadCommand)])), at: now - 2 * m))
        events += start(ID.edit, title: "Show the command on the card", project: "juice-island", prompt: "fix the approval card",
                        at: now - 10 * m)
        // A file change in Manual mode: Claude suggests Accept edits for the session ("Yes, allow all edits during this
        // session").
        events.append(claudeApproval(ID.edit, "Edit", useID: "toolu_demo_edit",
                                     shown: shown(toolCalls["toolu_demo_edit"]!), at: now - 2 * m,
                                     suggestions: [.setMode(destination: .session, mode: .acceptEdits)]))
        events += start(ID.write, title: "Add the release notes", project: "notes-site", prompt: "write the notes", at: now - 9 * m)
        events.append(claudeApproval(ID.write, "Write", useID: "toolu_demo_write",
                                     shown: shown(toolCalls["toolu_demo_write"]!), at: now - 2 * m))
        events += start(ID.fetch, title: "Read the SwiftUI notes", project: "juice-island", prompt: "check the docs", at: now - 8 * m)
        events.append(claudeApproval(ID.fetch, "WebFetch", useID: "toolu_demo_fetch",
                                     shown: shown(toolCalls["toolu_demo_fetch"]!), at: now - 2 * m))
        events += start(ID.codexShort, title: "Run the tests", project: "notes-site", prompt: "run the tests", tool: .codex, at: now - 7 * m)
        events.append(codexApproval(ID.codexShort, command: "npm test -- --watch=false",
                                    justification: "Run the test suite once to check the fix?", useID: "call_demo_test", at: now - 2 * m))
        events += start(ID.questions, title: "Set up the release", project: "notes-site", prompt: "set up the release", at: now - 6 * m)
        events.append(.questionAsked(QuestionAsked(sessionID: ID.questions, prompt: claudeQuestions([
            QuestionPromptItem(question: "Which channel should the release go to?", header: "Channel", options: [
                QuestionOption(label: "Beta", description: "Testers get it first."),
                QuestionOption(label: "Stable", description: "Everyone gets it."),
            ]),
            QuestionPromptItem(question: "Which checks should run before it ships?", header: "Checks", options: [
                QuestionOption(label: "Unit tests", description: "The whole suite."),
                QuestionOption(label: "Renders", description: "Every render suite, compared with the refs."),
                QuestionOption(label: "Lint", description: "SwiftLint on the changed files."),
            ], multiSelect: true),
            QuestionPromptItem(question: "Who signs off?", header: "Sign-off", options: [
                QuestionOption(label: "Me", description: ""),
                QuestionOption(label: "The reviewer", description: ""),
            ]),
        ]), timestamp: now - 2 * m)))
        events += start(ID.longPlan, title: "Plan the cards stream", project: "juice-island", prompt: "plan the cards", at: now - 5 * m)
        events.append(claudeApproval(ID.longPlan, "ExitPlanMode", useID: "toolu_demo_long_plan",
                                     shown: shown(toolCalls["toolu_demo_long_plan"]!), at: now - 2 * m))
        return events
    }

    // MARK: Requests as upstream's bridge makes them

    /// A Claude PermissionRequest (`BridgeServer` over `ClaudeHookPayload`): "Allow <tool>" (or ExitPlanMode's
    /// "Exit plan mode"), upstream's fixed sentence, and `shown`, what upstream shows of the input
    /// (`ToolCallShape.preview`).
    static func claudeApproval(_ id: String, _ tool: String, useID: String, shown: String, at date: Date,
                               suggestions: [ClaudePermissionUpdate] = []) -> AgentEvent {
        let plan = tool == "ExitPlanMode"
        return .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: plan ? "Exit plan mode" : "Allow \(tool)",
            summary: plan ? "Claude wants to exit plan mode and start implementation." : "Claude Code wants to run \(tool).",
            affectedPath: shown, primaryActionTitle: "Allow Once", secondaryActionTitle: "Deny", toolName: tool, toolUseID: useID,
            suggestedUpdates: suggestions), timestamp: date))
    }

    /// A Codex PermissionRequest (`BridgeServer` over `CodexHookPayload`): the justification as the summary (clipped
    /// to 110, as upstream clips it), the whole command as `affectedPath`.
    static func codexApproval(_ id: String, command: String, justification: String, useID: String, at date: Date) -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: "Run Bash command", summary: ToolCallPreview.clipped(justification) ?? "", affectedPath: command,
            primaryActionTitle: "Allow", secondaryActionTitle: "Deny", toolName: "Bash", toolUseID: useID), timestamp: date))
    }

    /// What upstream shows of a tool call's input as the request's `affectedPath`.
    static func shown(_ input: ClaudeHookJSONValue) -> String { ToolCallPreview.affectedPath(of: input) ?? "" }

    static let pushCommand = "git push -u origin window-mode"

    static let codexInstallCommand = "python3 local-artifacts/dashboard-publication/install.py --execute --verify-checks "
        + "--target \"$HOME/Sites/dashboard\" && python3 local-artifacts/dashboard-publication/checks.py --all --report results/install.md"

    static let unreadCommand = "rm -rf .build/arm64-apple-macosx/debug/JuiceIslandPackageTests.xctest "
        + ".build/arm64-apple-macosx/debug/ModuleCache && swift build --build-tests"

    /// The transcript's tool calls, by call id: what Claude asked to run, write or fetch, whole.
    static let toolCalls: [String: ClaudeHookJSONValue] = [
        // The welcome's Hello demo (P963).
        "toolu_hello_test": .object(["command": .string(HelloDemo.command), "description": .string("Run the tests")]),
        "toolu_demo_push": .object(["command": .string(pushCommand), "description": .string("Push window-mode to origin and track it")]),
        "toolu_demo_plan": .object(["plan": .string("""
            ## Render harness

            Renders stay headless: `ImageRenderer` for plain SwiftUI, an offscreen hosting view for AppKit controls.

            1. Add a render test target
            2. Render each placeholder at 2x
            3. Compare with the prototype shots
            4. Commit
            """)]),
        "toolu_demo_commit": .object([
            "command": .string("""
                git add App/Cards/ApprovalCardView.swift App/Models/Sessions/ApprovalContent.swift && git commit -m "$(cat <<'EOF'
                Show the whole command on approval cards

                The box held upstream's fixed sentence and the command sat under it, cut at 110 characters.
                EOF
                )"
                """),
            "description": .string("Commit the approval card fix"),
        ]),
        "toolu_demo_edit": .object([
            "file_path": .string(NSHomeDirectory() + "/Developer/juice-island/App/Cards/ApprovalCardView.swift"),
            "old_string": .string("""
                        VStack(alignment: .leading, spacing: 0) {
                            CodeBlockView(code: card.command)
                            if let location = card.location { CardWhereLine(text: location).padding(.top, 4) }
                """),
            "new_string": .string("""
                        VStack(alignment: .leading, spacing: 0) {
                            ApprovalBodyView(content: card.body, maxLines: style.codeLines)
                            if let reason = card.reason { CardReasonLine(text: reason).padding(.top, 4) }
                """),
        ]),
        "toolu_demo_write": .object([
            "file_path": .string(NSHomeDirectory() + "/Developer/notes-site/docs/release-notes.md"),
            "content": .string("""
                # Release notes

                ## 0.4
                - Approval cards show the whole command, and a diff for edits
                - Plans show their steps
                - Several questions at once, and multi-select
                """),
        ]),
        "toolu_demo_fetch": .object([
            "url": .string("https://example.com/docs/swiftui/scrollview"),
            "prompt": .string("How does a ScrollView size itself inside a fixed-size stack?"),
        ]),
        "toolu_demo_long_plan": .object(["plan": .string("""
            # Cards show what is approved

            The approval, plan and question cards draw what upstream's request carries, which is not what is approved.

            ## Steps
            1. Read the tool call from the transcript tail by its id, 256 KB, retrying for 1 s
            2. Map each tool to the box: the command, a diff, the URL
            3. Put the agent's reason in the dim line under the box
            4. Scroll a long command instead of cutting it
            5. Show the plan with its step count
            6. Put the primary button in the same place on every card
            7. Page through several questions; toggle multi-select options
            8. Shape the fixtures like the live payloads
            9. Test each tool against upstream's own payload decoding
            10. Render every card, long and short, for Claude and Codex
            11. Compare with the owner's screenshot
            12. Commit on the stream's branch
            """)]),
    ]

    /// What the bridge puts before a UserPromptSubmit's text (upstream BridgeServer; the engine's SignalPipeline
    /// reads it to tell a prompt from other activity).
    static let promptPrefix = "Prompt: "

    /// SessionStart then UserPromptSubmit, as the bridge sends them (fictional folders, C22).
    static func start(_ id: String, title: String, project: String, prompt: String, tool: AgentTool = .claudeCode,
                      at date: Date, branch: String? = nil, terminal: String = "Terminal",
                      terminalID: String? = nil, transcript: String? = nil, folder: String? = nil) -> [AgentEvent] {
        let folder = folder ?? NSHomeDirectory() + "/Developer/" + project
        let started = AgentEvent.sessionStarted(SessionStarted(
            sessionID: id, title: title, tool: tool, origin: .live, initialPhase: .running, summary: "Started.", timestamp: date,
            jumpTarget: JumpTarget(terminalApp: terminal, workspaceName: project, paneTitle: tool == .codex ? "codex" : "claude",
                                   workingDirectory: folder, terminalSessionID: terminalID, terminalTTY: "/dev/ttys00\(id.count % 9)"),
            // A Codex thread's hooks always name its rollout; one with none is an ephemeral run, never listed (P252, P255).
            codexMetadata: tool == .codex ? CodexSessionMetadata(transcriptPath: transcript ?? demoRollout(id), lastUserPrompt: prompt) : nil,
            claudeMetadata: tool == .claudeCode ? ClaudeSessionMetadata(lastUserPrompt: prompt, startupSource: .startup, worktreeBranch: branch) : nil))
        let prompted = AgentEvent.activityUpdated(SessionActivityUpdated(
            sessionID: id, summary: promptPrefix + prompt, phase: .running, timestamp: date + 1))
        return [started, prompted]
    }

    /// A demo Codex thread's rollout path: fictional, never created or read (the demo engine watches no rollout).
    static func demoRollout(_ id: String) -> String { "/tmp/juice-demo/sessions/rollout-\(id).jsonl" }
}
