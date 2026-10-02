import Foundation

/// The OpenCode plugin API a session's events came through. Juice Island's plugin names OpenCode 2's sessions
/// `opencode2-<id>`; OpenCode 1's keep Open Island's `opencode-<id>` (its plugin's and ours), so sessions the island
/// already knows keep their ids.
public enum OpenCodeAPI: Equatable, Sendable {
    case one, two

    public static let twoPrefix = "opencode2-"

    public static func of(sessionID: String) -> OpenCodeAPI {
        sessionID.hasPrefix(twoPrefix) ? .two : .one
    }

    /// Whether the island may answer an OpenCode request itself (P481). An approval: yes, under either API (OpenCode 1's
    /// plugin posts the reply to OpenCode's server, OpenCode 2's calls `ctx.permission.reply`). A question: only under
    /// OpenCode 1. OpenCode 2 asks through a form, and a plugin has no way to answer one (its context has no form
    /// domain; the server's `POST /api/session/:id/form/:formID/reply` needs the background service's address and
    /// password, which a plugin is not given), so an answer given on the island would never reach OpenCode. It shows
    /// read-only, with Open, until it is answered in OpenCode.
    public static func islandAnswers(sessionID: String, isQuestion: Bool) -> Bool {
        !(isQuestion && of(sessionID: sessionID) == .two)
    }
}

extension AttentionRequest {
    /// The bridge's one request of its session: answered through it, or an OpenCode 2 question it keeps up read-only
    /// (P481). The bridge letting it go, or a newer request of the session, ends it.
    var holdsBridgeSlot: Bool {
        channel == .answer(.bridge) || (source == .bridge && tool == .openCode)
    }
}
