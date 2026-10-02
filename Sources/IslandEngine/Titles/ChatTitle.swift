import Foundation
import OpenIslandCore

/// A session's chat title, as the lists name it in place of upstream's "<Agent> · <folder>": the agent's own title
/// (Claude's name or generated title, Codex's thread name), else the owner's first prompt, which is what Claude and
/// Codex themselves show before a title exists. The repo is the row's own fallback, before any prompt.
///
/// A title is text from the owner's sessions, so it lives in the engine's memory only (P200): never in
/// `AgentSession.title`, which upstream's registries write to disk, never in a log, Diagnostics or a store.
public struct ChatTitle: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The agent's own title.
        case agent
        /// The owner's first prompt: no title yet, or an agent whose titles Juice does not read.
        case prompt
    }

    public var text: String
    public var source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }
}

/// How a title's text is kept.
public enum ChatTitleText {
    /// The longest a title is kept: Claude's own names go to 200 characters. The views cut it at their width.
    public static let limit = 200

    /// One line: whitespace runs as one space, trimmed, at most `limit` characters (the last an ellipsis); nil when
    /// nothing is left.
    public static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// A prompt as a title: the owner's words (`PromptText.human`, so machine text never titles a row), never a slash
    /// command, which neither Claude nor Codex titles a chat from (P203), and never JSON (P212).
    public static func prompt(_ text: String?) -> String? {
        guard let human = PromptText.human(text), !human.hasPrefix("/"), !PromptText.isJSON(human) else { return nil }
        return clean(human)
    }

    /// The session's first prompt that can title it, from its own metadata block: the first prompt, else the latest
    /// (a first prompt that was a slash command).
    public static func firstPrompt(of session: AgentSession) -> String? {
        let first = [session.claudeMetadata?.initialUserPrompt, session.codexMetadata?.initialUserPrompt,
                     session.geminiMetadata?.initialUserPrompt, session.openCodeMetadata?.initialUserPrompt,
                     session.cursorMetadata?.initialUserPrompt, session.piMetadata?.initialUserPrompt]
        let last = [session.claudeMetadata?.lastUserPrompt, session.codexMetadata?.lastUserPrompt,
                    session.geminiMetadata?.lastUserPrompt, session.openCodeMetadata?.lastUserPrompt,
                    session.cursorMetadata?.lastUserPrompt, session.piMetadata?.lastUserPrompt]
        return (first + last).lazy.compactMap(prompt).first
    }
}
