import Foundation
import Testing
@testable import IslandEngine

/// What a Codex rollout says about waiting on the owner (P160, C5-C7, C15): both question tools in their three
/// encodings, the reply envelope and its fallback, turn ends, the reviewer and strict review, calls and outputs.
/// Lines are built in the shapes codex-rs writes (`rollout_payload.rs`, `request_user_input_async.rs`,
/// `answered_question.rs`, `protocol.rs` `TurnContextItem` and `ThreadSettingsAppliedEvent`); texts are fictional.
struct CodexAttentionTests {
    typealias R = RolloutFixtures

    static let asyncArguments = #"{"questions":[{"title":"Section E also has a second figure. Should I remove it?","options":["Remove it","Keep it"]}]}"#
    static let blockingArguments = #"""
    {"questions":[{"id":"figure","header":"Figure","question":"Remove the second figure too?","options":[{"label":"Remove it (Recommended)","description":"Cleaner."},{"label":"Keep it","description":"Safer."}]}]}
    """#

    static func call(_ name: String, _ callID: String, arguments: String, at second: Int = 1) -> String {
        R.item("function_call", ["name": name, "arguments": arguments, "call_id": callID], at: second)
    }

    static func output(_ callID: String, _ output: String, at second: Int = 2) -> String {
        R.item("function_call_output", ["call_id": callID, "output": output], at: second)
    }

    static func reply(_ callIDs: [String], wrapped: Bool = false) -> String {
        let answers = callIDs.enumerated().map { index, id in
            #"{"answer":"Keep it","question":"Q\#(index)","questionItemId":"[\"request_user_input_async\",\"\#(id)\",\#(index)]"}"#
        }
        let envelope = "<send_user_message_question_reply>\n[\(answers.joined(separator: ","))]\n</send_user_message_question_reply>"
        return wrapped ? "# Context from my IDE setup:\n## Open tabs:\n- paper.tex\n## My request for Codex:\n" + envelope : envelope
    }

    static func fold(_ lines: [String]) -> CodexAttention {
        var attention = CodexAttention()
        for line in lines { attention.apply(line) }
        return attention
    }

    // MARK: Questions

    @Test
    func theAsyncQuestionStaysOpenPastItsAcceptedOutput() throws {
        var attention = Self.fold([R.meta(), Self.call("request_user_input_async", "call_A1", arguments: Self.asyncArguments),
                                   Self.output("call_A1", #"{"accepted":true}"#),
                                   R.item("reasoning", ["summary": []], at: 3)])
        let question = try #require(attention.questions["call_A1"])
        #expect(question.kind == .async)
        #expect(question.items == [CodexAttention.Item(question: "Section E also has a second figure. Should I remove it?",
                                                       header: nil, options: ["Remove it", "Keep it"])])
        #expect(attention.takeEvents().contains(.questionOpened(question)))
    }

    @Test
    func theBlockingQuestionClosesOnItsOutputTurnAbortOrTurnEnd() throws {
        let open = [R.meta(), Self.call("request_user_input", "call_Q1", arguments: Self.blockingArguments)]
        let question = try #require(Self.fold(open).questions["call_Q1"])
        #expect(question.kind == .blocking)
        #expect(question.items.first?.header == "Figure")
        #expect(question.items.first?.options == ["Remove it (Recommended)", "Keep it"])
        for end in [Self.output("call_Q1", #"{"answers":{"figure":{"answers":["Keep it"]}}}"#),
                    R.event("turn_aborted", ["reason": "interrupted"], at: 3), R.event("task_complete", at: 3),
                    R.event("turn_complete", at: 3)] {
            var attention = Self.fold(open)
            _ = attention.takeEvents()
            attention.apply(end)
            #expect(attention.questions.isEmpty, "\(end)")
            #expect(attention.takeEvents().contains { if case .questionClosed("call_Q1", _) = $0 { true } else { false } })
        }
    }

    /// The same async question as its call, as a legacy `agent_message` and as a paginated `item_completed`: one question.
    @Test
    func theThreeEncodingsOpenOneQuestion() {
        let legacy = R.event("agent_message", ["message": "Section E also has a second figure. Should I remove it?\n- Remove it\n- Keep it",
                                               "phase": "final_answer", "delivery": "async",
                                               "questions": [["title": "Section E also has a second figure. Should I remove it?",
                                                              "options": ["Remove it", "Keep it"]]]], at: 1)
        let paginated = R.event("item_completed", ["thread_id": "t", "turn_id": "u", "completed_at_ms": 1,
                                                   "item": ["type": "AgentMessage", "id": "call_A1",
                                                            "content": [["type": "Text", "text": "…"]], "phase": "final_answer",
                                                            "delivery": "async",
                                                            "questions": [["title": "Section E also has a second figure. Should I remove it?",
                                                                           "options": ["Remove it", "Keep it"]]]]], at: 1)
        let call = Self.call("request_user_input_async", "call_A1", arguments: Self.asyncArguments)
        for lines in [[call, legacy], [call, paginated], [paginated, call]] {
            var attention = Self.fold(lines)
            #expect(attention.questions.count == 1)
            #expect(attention.takeEvents().filter { if case .questionOpened = $0 { true } else { false } }.count == 1)
        }
        // A legacy message alone (its call's line not read) still opens it, once.
        #expect(Self.fold([legacy, legacy]).questions.count == 1)
        // A message that is not a question opens nothing.
        #expect(Self.fold([R.event("agent_message", ["message": "Done."], at: 1)]).questions.isEmpty)
    }

    @Test
    func theReplyEnvelopeClosesTheQuestionsItNames() {
        let open = [Self.call("request_user_input_async", "call_A1", arguments: Self.asyncArguments),
                    Self.call("request_user_input_async", "call_A2", arguments: Self.asyncArguments.replacingOccurrences(of: "second", with: "third"))]
        // Named by id, bare or after the IDE wrapper, as a user message item or a legacy user_message event.
        for wrapped in [false, true] {
            var attention = Self.fold(open)
            _ = attention.takeEvents()
            attention.apply(R.message("user", Self.reply(["call_A1"], wrapped: wrapped), at: 5))
            #expect(Array(attention.questions.keys) == ["call_A2"])
            #expect(attention.takeEvents() == [.questionClosed(callID: "call_A1", byReply: true)])
        }
        var event = Self.fold(open)
        event.apply(R.event("user_message", ["message": Self.reply(["call_A1", "call_A2"])], at: 5))
        #expect(event.questions.isEmpty)
        // The plain-text fallback quotes the question.
        var fallback = Self.fold(open)
        fallback.apply(R.message("user", "> Section E also has a second figure. Should I remove it?\n\nKeep it", at: 5))
        #expect(Array(fallback.questions.keys) == ["call_A2"])
        // A human prompt ends every async question (Skip leaves no trace); machine text ends none.
        var machine = Self.fold(open)
        machine.apply(R.message("user", "<environment_context><cwd>/tmp/project</cwd></environment_context>", at: 5))
        #expect(machine.questions.count == 2)
        var human = Self.fold(open)
        human.apply(R.message("user", "never mind, go on", at: 5))
        #expect(human.questions.isEmpty)
    }

    @Test
    func theEnvelopesIDsAreTheCallIDs() {
        #expect(CodexAttention.replyCallIDs(#"[{"questionItemId":"[\"request_user_input_async\",\"call_A1\",0]"},{"questionItemId":"[\"request_user_input_async\",\"call_A1\",1]"}]"#)
            == ["call_A1"])
        #expect(CodexAttention.replyCallIDs("not json").isEmpty)
    }

    @Test
    func aNewTurnEndsEveryQuestion() {
        var attention = Self.fold([Self.call("request_user_input_async", "call_A1", arguments: Self.asyncArguments)])
        attention.apply(R.event("task_started", ["model_context_window": 1], at: 9))
        #expect(attention.questions.isEmpty)
    }

    /// `codex exec` registers the async tool on every root thread, with no UI to answer it (C15).
    @Test
    func anExecRunAsksNothing() {
        let exec = R.line("session_meta", ["id": R.sessionID, "cwd": "/tmp/project", "originator": "codex_exec", "source": "exec"], at: 0)
        let attention = Self.fold([exec, Self.call("request_user_input_async", "call_A1", arguments: Self.asyncArguments)])
        #expect(attention.isExec && attention.questions.isEmpty)
        #expect(!Self.fold([R.meta()]).isExec)
        #expect(Self.fold([R.meta()]).originator == "codex_cli_rs")
    }

    @Test
    func questionsAreBounded() throws {
        let long = String(repeating: "q", count: 5_000)
        let options = (0..<12).map { #""\#(String(repeating: "o", count: 400))\#($0)""# }.joined(separator: ",")
        let items = (0..<6).map { _ in #"{"title":"\#(long)","options":[\#(options)]}"# }.joined(separator: ",")
        let attention = Self.fold([Self.call("request_user_input_async", "call_B", arguments: #"{"questions":[\#(items)]}"#)])
        let question = try #require(attention.questions["call_B"])
        #expect(question.items.count == CodexAttention.itemLimit)
        #expect(question.items.allSatisfy { $0.question.count == CodexAttention.questionLimit })
        #expect(question.items.allSatisfy { $0.options.count == CodexAttention.optionLimit })
        #expect(question.items.allSatisfy { $0.options.allSatisfy { $0.count == CodexAttention.optionTextLimit } })
        // A question with no text is none.
        #expect(Self.fold([Self.call("request_user_input_async", "call_C", arguments: #"{"questions":[{"title":"  "}]}"#)]).questions.isEmpty)
    }

    // MARK: Settings (C6)

    @Test
    func theReviewerIsTheLatestOfTurnContextAndThreadSettings() {
        let user = R.line("turn_context", ["cwd": "/tmp/project", "model": "m", "approval_policy": "on-request",
                                           "approvals_reviewer": "user"], at: 1)
        let applied = R.event("thread_settings_applied", ["thread_settings": ["model": "m", "approval_policy": "on-request",
                                                                               "approvals_reviewer": "auto_review"]], at: 2)
        #expect(Self.fold([user]).reviewer == "user")
        #expect(Self.fold([user, applied]).reviewer == "auto_review")
        #expect(Self.fold([applied, user]).reviewer == "user")
        // The older name of the same reviewer, and a granular policy.
        let guardian = R.line("turn_context", ["approval_policy": ["granular": ["sandbox_approval": true]],
                                               "approvals_reviewer": "guardian_subagent"], at: 3)
        #expect(Self.fold([guardian]).reviewer == "auto_review")
        #expect(Self.fold([guardian]).approvalPolicy == "granular")
    }

    @Test
    func aStrictReviewGrantLastsItsTurn() {
        let grant = [R.event("task_started", at: 1), Self.call("request_permissions", "call_P", arguments: "{}"),
                     Self.output("call_P", #"{"permissions":{},"scope":"turn","strict_auto_review":true}"#)]
        #expect(Self.fold(grant).strictAutoReview)
        #expect(!Self.fold(grant + [R.event("task_complete", at: 9)]).strictAutoReview)
        #expect(!Self.fold(grant + [R.event("task_started", at: 9)]).strictAutoReview)
        // Another call's output that happens to say so is not a grant.
        #expect(!Self.fold([Self.call("exec_command", "call_E", arguments: #"{"cmd":"cat grant.json"}"#),
                            Self.output("call_E", #"{"strict_auto_review":true}"#)]).strictAutoReview)
    }

    // MARK: Calls (C7)

    @Test
    func callsAndOutputsAreEventsWithTheirCommands() {
        var attention = Self.fold([
            Self.call("exec_command", "call_1", arguments: #"{"cmd":"git push origin main"}"#),
            Self.call("shell", "call_2", arguments: #"{"command":["bash","-lc","make test"]}"#),
            R.item("custom_tool_call", ["name": "apply_patch", "call_id": "call_3", "input": "*** Begin Patch"], at: 1),
            R.item("local_shell_call", ["call_id": "call_4", "action": ["type": "exec", "command": ["ls", "-la"]]], at: 1),
        ])
        #expect(attention.openCalls.map(\.command) == ["git push origin main", "make test", "*** Begin Patch", "ls -la"])
        _ = attention.takeEvents()
        attention.apply(Self.output("call_2", "ok"))
        attention.apply(R.item("custom_tool_call_output", ["call_id": "call_3", "output": "Done"], at: 3))
        #expect(attention.takeEvents() == [.output(callID: "call_2"), .output(callID: "call_3")])
        #expect(attention.openCalls.map(\.callID) == ["call_1", "call_4"])
        attention.apply(R.event("turn_aborted", at: 4))
        #expect(attention.openCalls.isEmpty)
    }

    /// A line that cannot matter is never parsed; one that is not JSON changes nothing.
    @Test
    func otherLinesChangeNothing() {
        #expect(!CodexAttention.mayMatter(R.event("token_count", ["info": [:]], at: 1)))
        #expect(Self.fold(["{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"", "garbage"]) == CodexAttention())
    }
}
