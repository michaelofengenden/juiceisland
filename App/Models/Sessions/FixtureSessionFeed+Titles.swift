import Foundation
import IslandEngine
import OpenIslandCore

/// The fixtures' chat titles, written as each agent writes its own (P200-P205): a Claude session's title as a line of
/// its transcript (`ai-title`, the CLI's generated title), a Codex thread's as a line of its home's
/// `session_index.jsonl`, and folded by the engine's own readers. A session the fixture starts with a title of its
/// own gets one; one titled upstream's way ("Gemini CLI · notes-site", as every other agent's hooks title it) gets
/// none, so its row says its first prompt, as the live island does.
extension FixtureSessionFeed {
    static func loadTitles(into engine: SessionEngine) {
        var index: [String] = []
        for session in engine.state.sessions where !session.title.contains(" · ") {
            switch session.tool {
            case .claudeCode: engine.loadPreviewTranscript(sessionID: session.id, lines: [claudeTitleLine(session.id, kind: .ai, session.title)])
            case .codex: index.append(codexIndexLine(session.id, session.title))
            default: break
            }
        }
        engine.loadPreviewCodexIndex(lines: index)
    }

    enum ClaudeTitleKind { case ai, custom, agentName }

    /// One of Claude Code's title lines (`saveAiGeneratedTitle`, `saveCustomTitle`, `saveAgentName`).
    static func claudeTitleLine(_ sessionID: String, kind: ClaudeTitleKind, _ title: String) -> String {
        let (type, field) = switch kind {
        case .ai: ("ai-title", "aiTitle")
        case .custom: ("custom-title", "customTitle")
        case .agentName: ("agent-name", "agentName")
        }
        return #"{"type":"\#(type)","\#(field)":\#(json(title)),"sessionId":"\#(sessionID)"}"#
    }

    /// One `session_index.jsonl` line (`SessionIndexEntry`).
    static func codexIndexLine(_ threadID: String, _ name: String, at date: String = "2026-09-25T10:00:00Z") -> String {
        #"{"id":"\#(threadID)","thread_name":\#(json(name)),"updated_at":"\#(date)"}"#
    }

    private static func json(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}
