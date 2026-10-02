import Foundation
import Testing
@testable import IslandEngine

/// `CodexAttention` keeps up to 64 calls with no output per watched rollout (and hands each to the engine in its
/// events and state); each call's command must be bounded like a question's text, not the whole line (safety boost
/// S3). Fixture lines in the rollout shapes of the needs-you research; no file.
struct SafetyCodexCallBoundTests {
    @Test
    func aCallKeepsABoundedCommand() {
        let patch = "*** Begin Patch\n*** Add File: big.txt\n" + String(repeating: "+x\n", count: 100_000) + "*** End Patch"
        var attention = CodexAttention()
        for index in 0..<CodexAttention.openCallLimit {
            let payload: [String: Any] = ["type": "custom_tool_call", "name": "apply_patch", "call_id": "call-\(index)",
                                          "status": "completed", "input": patch]
            let object: [String: Any] = ["timestamp": "2026-09-25T10:00:00.000Z", "type": "response_item", "payload": payload]
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            attention.apply(line)
        }
        let events = attention.takeEvents()
        #expect(attention.openCalls.count == CodexAttention.openCallLimit)
        let kept = attention.openCalls.reduce(0) { $0 + ($1.command?.utf8.count ?? 0) }
        // 64 calls of a 300 KB patch each: about 19 MB kept per rollout today, 512 MB at the 8 MB line limit.
        #expect(kept <= CodexAttention.openCallLimit * 4_096, "\(kept) bytes of commands kept")
        let handed = events.reduce(0) { total, event in
            if case let .callSeen(call) = event { return total + (call.command?.utf8.count ?? 0) }
            return total
        }
        #expect(handed <= CodexAttention.openCallLimit * 4_096, "\(handed) bytes of commands handed over")
    }
}
