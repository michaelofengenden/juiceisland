import Foundation
import OpenIslandCore

/// A waiting approval's tool call as its transcript has it, for the request it was read for.
public struct ToolCallRecord: Equatable, Sendable {
    public var requestID: UUID
    public var input: ClaudeHookJSONValue
}

/// How the engine reads a waiting approval's tool call (`ToolCallReader`).
struct ToolCallReads: Sendable {
    var read: @Sendable (ToolCallQuery) -> ClaudeHookJSONValue?
    /// The waits before each read, from the request's arrival: the transcript can lag the hook, so the card keeps
    /// trying for 1 s. nil reads once, at once, on the main actor (the preview's fixtures, which open no file).
    var waits: [Duration]?

    static let transcript = ToolCallReads(read: ToolCallReader.read,
                                          waits: [.zero, .milliseconds(250), .milliseconds(250), .milliseconds(500)])

    /// The preview's: the fixtures' inputs by call id.
    static func fixtures(_ inputs: [String: ClaudeHookJSONValue]) -> ToolCallReads {
        ToolCallReads(read: { query in query.toolUseID.flatMap { inputs[$0] } }, waits: nil)
    }
}

extension SessionEngine {
    /// The input of the tool call a session's approval waits on, from its transcript: the whole command, the edit,
    /// the plan. nil until it is read, when it is not found, for Codex (whose request carries its whole command) and
    /// once the approval is gone.
    public func toolCallInput(for sessionID: String) -> ClaudeHookJSONValue? {
        guard let record = toolCalls[sessionID], waits(sessionID, on: record.requestID) else { return nil }
        return record.input
    }

    /// A new approval: read its tool call off the main thread (a Claude session's transcript, bounded), again at
    /// 250 ms, 500 ms and 1 s while it is not there yet, and only while the session still waits on this request.
    func readToolCall(sessionID: String, request: PermissionRequest) {
        forgetToolCall(sessionID)
        guard let session = state.session(id: sessionID), session.tool != .codex, session.claudeMetadata != nil else { return }
        let query = ToolCallQuery(transcriptPath: session.claudeMetadata?.transcriptPath, toolUseID: request.toolUseID,
                                  toolName: request.toolName, preview: request.affectedPath)
        let reads = dependencies.toolCallReads
        guard let waits = reads.waits else {
            if let input = reads.read(query) { toolCalls[sessionID] = ToolCallRecord(requestID: request.id, input: input) }
            return
        }
        let read = reads.read
        let requestID = request.id
        toolCallTasks[sessionID] = Task { [weak self] in
            for wait in waits {
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard !Task.isCancelled, self?.waits(sessionID, on: requestID) == true else { return }
                let input = await Task.detached(priority: .utility) { read(query) }.value
                guard !Task.isCancelled, let self, self.waits(sessionID, on: requestID) else { return }
                if let input {
                    self.toolCalls[sessionID] = ToolCallRecord(requestID: requestID, input: input)
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.toolCallTasks[sessionID] = nil
        }
    }

    /// Drops what was read for an approval that no longer waits (answered, resolved elsewhere, ended).
    func forgetToolCallIfResolved(_ sessionID: String) {
        guard let record = toolCalls[sessionID], !waits(sessionID, on: record.requestID) else { return }
        forgetToolCall(sessionID)
    }

    func forgetToolCall(_ sessionID: String) {
        toolCallTasks.removeValue(forKey: sessionID)?.cancel()
        if toolCalls[sessionID] != nil { toolCalls[sessionID] = nil }
    }

    private func waits(_ sessionID: String, on requestID: UUID) -> Bool {
        guard let session = state.session(id: sessionID) else { return false }
        return session.phase == .waitingForApproval && session.permissionRequest?.id == requestID
    }
}
