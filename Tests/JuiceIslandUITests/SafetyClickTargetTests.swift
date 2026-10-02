import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// A click answers the request its card showed, never whichever request is the session's head when the click's task
/// runs (safety boost S1, P170, P186). Headless preview engine, the request broker stood in: no socket, no process.
@MainActor
struct SafetyClickTargetTests {
    /// Stands in for `HookRequestBroker`: which held requests got an island decision.
    final class StubBroker: HookRequestReceiving, @unchecked Sendable {
        private let lock = NSLock()
        private var held: Set<String> = []
        private var answeredIDs: [String] = []

        func hold(_ id: String) { lock.withLock { _ = held.insert(id) } }
        var answered: [String] { lock.withLock { answeredIDs } }

        func answer(_ id: String, _ response: BridgeResponse) -> Bool {
            lock.withLock {
                guard held.remove(id) != nil else { return false }
                answeredIDs.append(id)
                return true
            }
        }

        func release(_ id: String) { lock.withLock { _ = held.remove(id) } }
        func stop() {}
    }

    /// A held Claude main-thread PermissionRequest from a terminal, as the broker hands it to the engine.
    static func request(_ id: String, command: String, toolUseID: String, at date: Date) -> BrokeredRequest {
        let object: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/project",
                                     "transcript_path": "/tmp/juice-safety/s1.jsonl", "permission_mode": "default",
                                     "tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": toolUseID]
        let input = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let line = HookRequestLine(source: "claude", input: input, digest: HookInputDigest.of(["command": command]),
                                   entrypoint: "cli", agentPID: nil, hostBundleID: nil, hasTerminal: true)
        return BrokeredRequest(id: id, line: line, object: object, held: true, at: date)
    }

    /// Two held requests in one session (parallel tool calls): the card shows the first. The owner clicks Allow on it;
    /// before the click's task runs, the first ends (answered at Claude's own prompt, which killed its hook). The
    /// click must send nothing: the second request, which the owner never saw, must not be allowed by it.
    @Test
    func aClickNeverAnswersARequestItsCardDidNotShow() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let engine = SessionEngine.preview(clock: { now })
        let broker = StubBroker()
        engine.hookRequestBroker = broker
        broker.hold("A")
        broker.hold("B")
        engine.takeBrokeredRequest(Self.request("A", command: "git status", toolUseID: "U1", at: now))
        engine.takeBrokeredRequest(Self.request("B", command: "rm -rf build", toolUseID: "U2", at: now.addingTimeInterval(1)))
        #expect(engine.attentionQueue(for: "s1").map(\.id) == ["A", "B"])

        let model = EngineSessionsModel(engine: engine, clock: { now })
        guard case let .approval(card)? = model.card(for: "s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.request?.id == "A")

        // The owner's click on A's card, which names the request it showed.
        model.approve("s1", .allowOnce, request: card.request?.id)
        // A's hook ends first (the note of its end is already on its way to the main actor).
        engine.brokeredRequestEnded("A")
        for _ in 0..<100 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(broker.answered.isEmpty, "a click on A's card answered \(broker.answered)")
        #expect(engine.attentionHead(for: "s1")?.id == "B")
    }

    /// A held AskUserQuestion, as the broker hands it to the engine.
    static func question(_ id: String, _ text: String, options: [String], at date: Date) -> BrokeredRequest {
        let input: [String: Any] = ["questions": [["question": text, "header": "Pick", "multiSelect": false,
                                                   "options": options.map { ["label": $0, "description": ""] }]]]
        let object: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/project",
                                     "transcript_path": "/tmp/juice-safety/s1.jsonl", "permission_mode": "default",
                                     "tool_name": "AskUserQuestion", "tool_input": input]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let line = HookRequestLine(source: "claude", input: data, digest: HookInputDigest.of(input), entrypoint: "cli",
                                   agentPID: nil, hostBundleID: nil, hasTerminal: true)
        return BrokeredRequest(id: id, line: line, object: object, held: true, at: date)
    }

    /// The same for a question card: the owner picks an option on question A; A is answered at Claude's own prompt
    /// before the pick's send runs. The pick must not go to question B, which the owner never saw.
    @Test
    func aPickNeverAnswersAQuestionItsCardDidNotShow() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let engine = SessionEngine.preview(clock: { now })
        let broker = StubBroker()
        engine.hookRequestBroker = broker
        broker.hold("A")
        broker.hold("B")
        engine.takeBrokeredRequest(Self.question("A", "Which branch?", options: ["main", "dev"], at: now))
        engine.takeBrokeredRequest(Self.question("B", "Delete the old backups?", options: ["Yes", "No"], at: now.addingTimeInterval(1)))
        let model = EngineSessionsModel(engine: engine, clock: { now })
        guard case let .question(card)? = model.card(for: "s1") else {
            Issue.record("no question card")
            return
        }
        #expect(card.request?.id == "A" && card.question == "Which branch?")

        // The owner's pick of "main" on A's card: its only question, so the answers go at once.
        #expect(model.answerQuestion("s1", .option(0), request: card.request?.id))
        engine.brokeredRequestEnded("A")
        for _ in 0..<100 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(broker.answered.isEmpty, "a pick on A's card answered \(broker.answered)")
    }
}
