import Foundation
import OpenIslandCore

extension PromptText {
    /// The event with every prompt it carries run through `human` (P155): a machine prompt (a Claude
    /// `<task-notification>` through UserPromptSubmit, a Codex reply envelope, a slash-command wrapper) keeps the
    /// session's current prompt instead, and a slash command reads as the owner typed it. The "Prompt: " activity is
    /// left as it is: a notification does start a real turn, whose Stop is a real Done.
    static func sanitized(_ event: AgentEvent, current: AgentSession?) -> AgentEvent {
        switch event {
        case var .sessionStarted(payload):
            payload.claudeMetadata = payload.claudeMetadata.map { kept($0, current: current?.claudeMetadata) }
            payload.codexMetadata = payload.codexMetadata.map { kept($0, current: current?.codexMetadata) }
            payload.geminiMetadata = payload.geminiMetadata.map { kept($0, current: current?.geminiMetadata) }
            payload.openCodeMetadata = payload.openCodeMetadata.map { kept($0, current: current?.openCodeMetadata) }
            payload.cursorMetadata = payload.cursorMetadata.map { kept($0, current: current?.cursorMetadata) }
            payload.piMetadata = payload.piMetadata.map { kept($0, current: current?.piMetadata) }
            return .sessionStarted(payload)
        case var .claudeSessionMetadataUpdated(payload):
            payload.claudeMetadata = kept(payload.claudeMetadata, current: current?.claudeMetadata)
            return .claudeSessionMetadataUpdated(payload)
        case var .sessionMetadataUpdated(payload):
            payload.codexMetadata = kept(payload.codexMetadata, current: current?.codexMetadata)
            return .sessionMetadataUpdated(payload)
        case var .geminiSessionMetadataUpdated(payload):
            payload.geminiMetadata = kept(payload.geminiMetadata, current: current?.geminiMetadata)
            return .geminiSessionMetadataUpdated(payload)
        case var .openCodeSessionMetadataUpdated(payload):
            payload.openCodeMetadata = kept(payload.openCodeMetadata, current: current?.openCodeMetadata)
            return .openCodeSessionMetadataUpdated(payload)
        case var .cursorSessionMetadataUpdated(payload):
            payload.cursorMetadata = kept(payload.cursorMetadata, current: current?.cursorMetadata)
            return .cursorSessionMetadataUpdated(payload)
        case var .piSessionMetadataUpdated(payload):
            payload.piMetadata = kept(payload.piMetadata, current: current?.piMetadata)
            return .piSessionMetadataUpdated(payload)
        default:
            return event
        }
    }

    /// A prompt field after `human`: the owner's words, else what the session had (when that was the owner's), else
    /// nothing. A field the event leaves empty stays empty, as upstream's reducer sets it.
    static func keptPrompt(_ incoming: String?, current: String?) -> String? {
        guard let incoming else { return nil }
        return human(incoming) ?? current.flatMap(human)
    }

    private static func kept<M: PromptCarrying>(_ metadata: M, current: M?) -> M {
        var result = metadata
        result.initialUserPrompt = keptPrompt(metadata.initialUserPrompt, current: current?.initialUserPrompt)
        result.lastUserPrompt = keptPrompt(metadata.lastUserPrompt, current: current?.lastUserPrompt)
        return result
    }
}

/// The metadata blocks that carry the owner's prompts.
protocol PromptCarrying {
    var initialUserPrompt: String? { get set }
    var lastUserPrompt: String? { get set }
}

extension ClaudeSessionMetadata: PromptCarrying {}
extension CodexSessionMetadata: PromptCarrying {}
extension GeminiSessionMetadata: PromptCarrying {}
extension OpenCodeSessionMetadata: PromptCarrying {}
extension CursorSessionMetadata: PromptCarrying {}
extension PiSessionMetadata: PromptCarrying {}
