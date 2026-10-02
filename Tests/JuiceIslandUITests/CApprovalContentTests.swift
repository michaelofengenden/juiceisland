import Foundation
import IslandEngine
@testable import JuiceIslandUI
@testable import OpenIslandCore
import Testing

/// The cards show what is approved (`ApprovalContent`): the box holds the command, the change or the URL, the dim
/// line why, from requests shaped as upstream's bridge makes them.
@MainActor
struct CApprovalContentTests {
    typealias ID = FixtureSessionFeed.ID

    static func claudeRequest(_ tool: String, shown: String, summary: String? = nil) -> PermissionRequest {
        PermissionRequest(title: "Allow \(tool)", summary: summary ?? "Claude Code wants to run \(tool).", affectedPath: shown,
                          primaryActionTitle: "Allow Once", secondaryActionTitle: "Deny", toolName: tool, toolUseID: "toolu_1")
    }

    @Test func claudesBashShowsTheWholeCommandAndItsDescription() {
        let command = "git commit -m \"$(cat <<'EOF'\nFix the card\nEOF\n)\""
        let input: ClaudeHookJSONValue = .object(["command": .string(command), "description": .string("Commit the fix")])
        let mapped = ApprovalContent.make(request: Self.claudeRequest("Bash", shown: ToolCallPreview.affectedPath(of: input)!),
                                          input: input, tool: .claudeCode, folder: "/tmp/project")
        #expect(mapped.tool == "Bash")
        #expect(mapped.body == .command(command))
        #expect(mapped.reason == "Commit the fix")
        #expect(mapped.rowText == "git commit -m \"$(cat <<'EOF' Fix the card EOF )\"")
    }

    /// Before the transcript has the call: the request's own 110 characters, "…" where upstream cut them, and never
    /// upstream's sentence.
    @Test func claudesBashUnreadShowsWhatTheRequestCarries() {
        let clipped = String(repeating: "a", count: 109) + "…"
        let mapped = ApprovalContent.make(request: Self.claudeRequest("Bash", shown: clipped), input: nil, tool: .claudeCode, folder: nil)
        #expect(mapped.body == .command(clipped))
        #expect(mapped.reason == nil)
    }

    @Test func upstreamsSentencesAreNeverAReason() {
        #expect(ApprovalContent.claudeReason("Claude Code wants to run Bash.") == nil)
        #expect(ApprovalContent.claudeReason("Qwen Code wants to run WebFetch.") == nil)
        #expect(ApprovalContent.claudeReason("Claude wants to exit plan mode and start implementation.") == nil)
        #expect(ApprovalContent.claudeReason("Claude Code needs permission to continue.") == nil)
        #expect(ApprovalContent.claudeReason("Permission needed · Claude wants to fetch a page") == "Permission needed · Claude wants to fetch a page")
        #expect(ApprovalContent.codexReason("Codex wants to run: npm test", shown: "npm test") == nil)
        #expect(ApprovalContent.codexReason("Codex wants to use apply_patch.", shown: "apply_patch") == nil)
        #expect(ApprovalContent.codexReason("Codex wants to run a shell command.", shown: "npm test") == nil)
        #expect(ApprovalContent.codexReason("npm test", shown: "npm test") == nil)
        #expect(ApprovalContent.codexReason("Run the tests once?", shown: "npm test") == "Run the tests once?")
    }

    /// The owner's screenshot: Codex's justification was in the box and the command under it, cut and prefixed "in".
    @Test func codexShowsTheCommandInTheBoxAndTheJustificationUnder() throws {
        let feed = FixtureSessionFeed(scenario: .codexApproval)
        let model = feed.makeModel()
        guard case let .approval(card) = model.card(for: ID.codexApproval) else { Issue.record("no approval card"); return }
        #expect(card.tool == "Bash")
        #expect(card.body == .command(FixtureSessionFeed.codexInstallCommand))
        #expect(card.reason == "May I install the validated additive dashboard publication into local-artifacts?")
        let row = try #require(model.row(id: ID.codexApproval))
        #expect(SessionRowText.cleanStatus(row).text == "Bash: " + FixtureSessionFeed.codexInstallCommand)
    }

    /// Codex's PreToolUse path names no tool and says only "Codex wants to run a shell command.".
    @Test func codexsPreToolUseShapeReadsAsBash() {
        let request = PermissionRequest(title: "Run Bash command", summary: "Codex wants to run a shell command.", affectedPath: "ls -la")
        let mapped = ApprovalContent.make(request: request, input: nil, tool: .codex, folder: nil)
        #expect(mapped.tool == "Bash" && mapped.body == .command("ls -la") && mapped.reason == nil)
    }

    @Test func codexsPatchIsADiffPerFile() {
        let patch = """
        *** Begin Patch
        *** Update File: App/a.swift
        @@ struct A
         let a = 1
        -let b = 2
        +let b = 3
        *** Add File: App/b.swift
        +let c = 4
        *** Delete File: App/old.swift
        *** End Patch
        """
        let request = PermissionRequest(title: "Apply code patch", summary: "Codex wants to use apply_patch.", affectedPath: patch,
                                        toolName: "apply_patch")
        let mapped = ApprovalContent.make(request: request, input: nil, tool: .codex, folder: nil)
        guard case let .diff(files) = mapped.body else { Issue.record("no diff"); return }
        #expect(files.map(\.path) == ["App/a.swift", "App/b.swift", "App/old.swift"])
        #expect(files[0].lines.map(\.kind) == [.context, .removed, .added] && files[0].added == 1 && files[0].removed == 1)
        #expect(files[1].lines == [.init(kind: .added, text: "let c = 4")])
        #expect(files[2].deleted)
        #expect(mapped.rowText == "a.swift, b.swift, old.swift")
    }

    @Test func anEditIsACompactDiffOfItsFile() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 5", with: "line five")
        let input: ClaudeHookJSONValue = .object(["file_path": .string("/tmp/project/App/a.swift"), "old_string": .string(old),
                                                  "new_string": .string(new)])
        let mapped = ApprovalContent.make(request: Self.claudeRequest("Edit", shown: "/tmp/project/App/a.swift"), input: input,
                                          tool: .claudeCode, folder: "/tmp/project")
        guard case let .diff(files) = mapped.body, let file = files.first else { Issue.record("no diff"); return }
        #expect(file.path == "App/a.swift")
        #expect(file.lines == [.init(kind: .context, text: "line 4"), .init(kind: .removed, text: "line 5"),
                               .init(kind: .added, text: "line five"), .init(kind: .context, text: "line 6")])
        #expect(mapped.rowText == "a.swift")
        #expect(mapped.reason == nil)
    }

    @Test func multiEditsAreSeparatedAndWritesAreAllAdded() {
        let multi: ClaudeHookJSONValue = .object(["file_path": .string("/tmp/project/a.swift"), "edits": .array([
            .object(["old_string": .string("a"), "new_string": .string("b")]),
            .object(["old_string": .string("c"), "new_string": .string("d")]),
        ])])
        let mapped = ApprovalContent.make(request: Self.claudeRequest("MultiEdit", shown: "/tmp/project/a.swift"), input: multi,
                                          tool: .claudeCode, folder: "/tmp/project")
        guard case let .diff(files) = mapped.body else { Issue.record("no diff"); return }
        #expect(files[0].lines.map(\.kind) == [.removed, .added, .gap, .removed, .added])

        let lines = (1...(ApprovalContent.diffLineLimit + 5)).map { "row \($0)" }.joined(separator: "\n")
        let write: ClaudeHookJSONValue = .object(["file_path": .string("/elsewhere/notes.md"), "content": .string(lines + "\n")])
        let written = ApprovalContent.make(request: Self.claudeRequest("Write", shown: "/elsewhere/notes.md"), input: write,
                                           tool: .claudeCode, folder: "/tmp/project")
        guard case let .diff(writtenFiles) = written.body, let file = writtenFiles.first else { Issue.record("no diff"); return }
        #expect(file.lines.count == ApprovalContent.diffLineLimit && file.omitted == 5)
        #expect(file.added == ApprovalContent.diffLineLimit + 5 && file.removed == 0)
        #expect(file.path == "/elsewhere/notes.md")
    }

    @Test func aLineDiffKeepsOneLineOfContextAndFoldsTheRest() {
        let old = (1...20).map { "l\($0)" }.joined(separator: "\n")
        var new = old.replacingOccurrences(of: "l3\n", with: "L3\n")
        new = new.replacingOccurrences(of: "l17\n", with: "")
        let lines = LineDiff.lines(old: old, new: new)
        #expect(lines.map(\.kind) == [.context, .removed, .added, .context, .gap, .context, .removed, .context])
        #expect(LineDiff.lines(old: "same", new: "same").isEmpty)
        #expect(LineDiff.lines(old: "", new: "a\nb").map(\.kind) == [.added, .added])
    }

    @Test func otherToolsShowWhatTheyAreAbout() {
        let fetch: ClaudeHookJSONValue = .object(["url": .string("https://example.com/a"), "prompt": .string("What changed?")])
        let fetched = ApprovalContent.make(request: Self.claudeRequest("WebFetch", shown: "https://example.com/a"), input: fetch,
                                           tool: .claudeCode, folder: nil)
        #expect(fetched.body == .text("https://example.com/a") && fetched.reason == "What changed?")
        let mcp: ClaudeHookJSONValue = .object(["query": .string("scroll view"), "limit": .number(5)])
        let tool = ApprovalContent.make(request: Self.claudeRequest("mcp__docs__search", shown: "scroll view"), input: mcp,
                                        tool: .claudeCode, folder: nil)
        #expect(tool.body == .text("limit: 5\nquery: scroll view"))
        let grep: ClaudeHookJSONValue = .object(["pattern": .string("TODO"), "path": .string("/tmp/project/App")])
        let grepped = ApprovalContent.make(request: Self.claudeRequest("Grep", shown: "/tmp/project/App"), input: grep,
                                           tool: .claudeCode, folder: "/tmp/project")
        #expect(grepped.body == .text("TODO") && grepped.reason == "in App")
    }

    // MARK: The fixtures' cards

    @Test func theFixturesCardsShowWhatIsApproved() throws {
        let model = FixtureSessionFeed(scenario: .cards).makeModel()
        guard case let .approval(commit) = model.card(for: ID.longBash),
              case let .object(input) = FixtureSessionFeed.toolCalls["toolu_demo_commit"],
              case let .string(command) = input["command"] else { Issue.record("no commit card"); return }
        #expect(commit.body == .command(command) && command.contains("\n"))
        #expect(commit.reason == "Commit the approval card fix")

        guard case let .approval(unread) = model.card(for: ID.unreadBash), case let .command(shown) = unread.body else {
            Issue.record("no unread card"); return
        }
        #expect(shown.hasSuffix("…") && shown.count == 110 && unread.reason == nil)

        guard case let .approval(edit) = model.card(for: ID.edit), case let .diff(files) = edit.body else { Issue.record("no edit"); return }
        #expect(files.map(\.path) == ["App/Cards/ApprovalCardView.swift"] && files[0].added == 2 && files[0].removed == 2)

        guard case let .plan(plan) = model.card(for: ID.longPlan) else { Issue.record("no plan"); return }
        #expect(plan.steps == 12 && plan.plan?.hasPrefix("# Cards show what is approved") == true)
        #expect(SessionRowText.cleanStatus(try #require(model.row(id: ID.longPlan))).text == "12 steps")
        #expect(SessionRowText.cleanStatus(try #require(model.row(id: ID.edit))).text == "Edit: ApprovalCardView.swift")
        #expect(DetailedRowText.status(try #require(model.row(id: ID.longPlan))) == .init(word: "Plan ready", tone: .approval, text: "12 steps"))
    }

    /// A plan not read (yet) is "Plan ready" and the buttons, never upstream's sentence.
    @Test func aPlanNotReadShowsNoText() {
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        engine.loadPreviewEvents(FixtureSessionFeed.events(.allStates, now: DemoClock.now))
        let model = EngineSessionsModel(engine: engine, clock: { DemoClock.now })
        guard case let .plan(plan) = model.card(for: ID.plan) else { Issue.record("no plan"); return }
        #expect(plan.plan == nil && plan.steps == nil)
        #expect(SessionRowText.cleanStatus(model.row(id: ID.plan)!).text == nil)
    }
}

/// The fixtures' requests and questions are what upstream makes of a live hook's payload: renders show the live cards.
@MainActor
struct FixtureShapeTests {
    typealias ID = FixtureSessionFeed.ID

    static func payload<T: Decodable>(_ type: T.Type, _ object: [String: ClaudeHookJSONValue]) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(T.self, from: encoder.encode(ClaudeHookJSONValue.object(object)))
    }

    static func claude(tool: String, input: ClaudeHookJSONValue, id: String) throws -> ClaudeHookPayload {
        try payload(ClaudeHookPayload.self, [
            "hook_event_name": .string("PermissionRequest"), "session_id": .string("s1"), "cwd": .string("/tmp/project"),
            "transcript_path": .string("/tmp/projects/-tmp-project/s1.jsonl"), "tool_name": .string(tool), "tool_input": input,
            "tool_use_id": .string(id),
        ])
    }

    @Test func claudeRequestsAreUpstreams() throws {
        let scenarios: [FixtureSessionFeed.Scenario] = [.prototype, .allStates, .cards]
        var checked = 0
        for scenario in scenarios {
            let feed = FixtureSessionFeed(scenario: scenario)
            for session in feed.engine.state.sessions where session.tool == .claudeCode {
                guard let request = session.permissionRequest, let tool = request.toolName, let useID = request.toolUseID else { continue }
                let input = FixtureSessionFeed.toolCalls[useID] ?? .object(["command": .string(FixtureSessionFeed.unreadCommand)])
                let upstream = try Self.claude(tool: tool, input: input, id: useID)
                #expect(request.title == upstream.permissionRequestTitle, "\(session.id)")
                #expect(request.summary == upstream.permissionRequestSummary, "\(session.id)")
                #expect(request.affectedPath == upstream.permissionAffectedPath, "\(session.id)")
                checked += 1
            }
        }
        #expect(checked >= 8)
    }

    @Test func codexRequestsAreUpstreams() throws {
        var checked = 0
        for scenario in [FixtureSessionFeed.Scenario.codexApproval, .cards] {
            let feed = FixtureSessionFeed(scenario: scenario)
            for session in feed.engine.state.sessions where session.tool == .codex {
                guard let request = session.permissionRequest else { continue }
                let justification = session.id == ID.codexShort ? "Run the test suite once to check the fix?"
                    : "May I install the validated additive dashboard publication into local-artifacts?"
                let upstream = try Self.payload(CodexHookPayload.self, [
                    "hook_event_name": .string("PermissionRequest"), "session_id": .string(session.id), "cwd": .string("/tmp/project"),
                    "model": .string("gpt-5-codex"), "permission_mode": .string("default"), "tool_name": .string("Bash"),
                    "tool_use_id": .string(request.toolUseID ?? ""),
                    "tool_input": .object(["command": .string(request.affectedPath), "description": .string(justification)]),
                ])
                #expect(request.title == upstream.permissionRequestTitle)
                #expect(request.summary == upstream.permissionRequestSummary)
                #expect(request.affectedPath == upstream.permissionRequestAffectedPath)
                checked += 1
            }
        }
        #expect(checked == 2)
    }

    /// AskUserQuestion as upstream builds it: "Other" after each question's options, the prompt's title.
    @Test func questionsAreUpstreams() throws {
        let feed = FixtureSessionFeed(scenario: .cards)
        let prompt = try #require(feed.engine.state.session(id: ID.questions)?.questionPrompt)
        let input: ClaudeHookJSONValue = .object(["questions": .array(prompt.questions.map { item in
            .object(["question": .string(item.question), "header": .string(item.header), "multiSelect": .boolean(item.multiSelect),
                     "options": .array(item.options.filter { !$0.allowsFreeform }.map {
                         .object(["label": .string($0.label), "description": .string($0.description)])
                     })])
        })])
        let upstream = try #require(try Self.claude(tool: "AskUserQuestion", input: input, id: "toolu_q").questionPrompt)
        #expect(prompt.title == upstream.title)
        #expect(prompt.questions.count == upstream.questions.count)
        for (ours, theirs) in zip(prompt.questions, upstream.questions) {
            #expect(ours.question == theirs.question && ours.header == theirs.header && ours.multiSelect == theirs.multiSelect)
            #expect(ours.options.map(\.label) == theirs.options.map(\.label))
            #expect(ours.options.map(\.allowsFreeform) == theirs.options.map(\.allowsFreeform))
        }
    }
}

/// Several questions at once, and multi-select: one question at a time, every answer sent together.
@MainActor
struct CQuestionStepsTests {
    typealias ID = FixtureSessionFeed.ID

    static func question(_ model: EngineSessionsModel) -> QuestionCardModel? {
        if case let .question(card) = model.card(for: ID.questions) { card } else { nil }
    }

    @Test func questionsPageThroughAndSendEveryAnswerTogether() async throws {
        let feed = FixtureSessionFeed(scenario: .cards)
        let model = feed.makeModel()
        var card = try #require(Self.question(model))
        #expect(card.step == 0 && card.count == 3 && card.topic == "Channel" && card.options.map(\.label) == ["Beta", "Stable"])
        #expect(CardText.status(.question(card)).text == "Channel · 1/3")

        #expect(!model.answerQuestion(ID.questions, .option(1)))
        card = try #require(Self.question(model))
        #expect(card.step == 1 && card.multiSelect && card.picked.isEmpty && card.topic == "Checks")
        #expect(!model.answerQuestion(ID.questions, .next))
        #expect(!model.answerQuestion(ID.questions, .option(2)))
        #expect(!model.answerQuestion(ID.questions, .option(0)))
        #expect(!model.answerQuestion(ID.questions, .option(1)))
        #expect(!model.answerQuestion(ID.questions, .option(1)))
        #expect(try #require(Self.question(model)).picked == [0, 2])
        #expect(!model.answerQuestion(ID.questions, .back))
        card = try #require(Self.question(model))
        #expect(card.step == 0 && card.picked == [1])
        #expect(!model.answerQuestion(ID.questions, .option(1)))
        #expect(try #require(Self.question(model)).picked == [0, 2])
        #expect(!model.answerQuestion(ID.questions, .next))
        #expect(try #require(Self.question(model)).isLastStep)
        #expect(feed.sentCommands.isEmpty)

        #expect(model.answerQuestion(ID.questions, .text("  Both of us ")))
        // Sent first, and the card goes once the answers went (P129).
        for _ in 0..<50 where feed.sentCommands.isEmpty || model.card(for: ID.questions) != nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard case let .answerQuestion(sessionID, response)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(sessionID == ID.questions)
        #expect(response.rawAnswer == nil)
        #expect(response.answers == ["Which channel should the release go to?": "Stable",
                                     "Which checks should run before it ships?": "Unit tests, Lint",
                                     "Who signs off?": "Both of us"])
        #expect(model.card(for: ID.questions) == nil)
    }

    /// One question: a pick sends it at once, with the answer alone as well (upstream's shape); "Other" is the field.
    @Test func oneQuestionSendsAtOnce() async throws {
        let feed = FixtureSessionFeed(scenario: .prototype)
        let model = feed.makeModel()
        guard case let .question(card) = model.card(for: ID.question) else { Issue.record("no question"); return }
        #expect(card.count == 1 && card.options.count == 4 && !card.options.contains { $0.label == "Other" })
        #expect(CardText.status(.question(card)).text == "App name")
        #expect(!model.answerQuestion(ID.question, .option(4)))
        #expect(model.answerQuestion(ID.question, .option(2)))
        for _ in 0..<50 where feed.sentCommands.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        guard case let .answerQuestion(_, response)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(response.rawAnswer == "Sandbar" && response.answers == ["Which name should the app use?": "Sandbar"])
    }
}
