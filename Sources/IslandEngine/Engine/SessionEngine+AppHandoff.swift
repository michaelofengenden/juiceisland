import Foundation
import JuiceCore
import OpenIslandCore

/// The engine's side of Open in <App> (wave 8, P1510 to P1529; `SessionHandoff` does the hand-over): a folded card whose
/// conversation an app holds takes no reply, offers no Continue, and gets no "Stopped" verdict from its old CLI's exit.
extension SessionEngine {
    /// The app holds the folded session's conversation now, or is about to (`SessionHandoff.app(holding:)`).
    func foldIsInApp(_ sessionID: String) -> Bool { appHandoff?.app(holding: sessionID) != nil }

    /// Its tab takes a reply now: the session has not ended, its tab is known exactly, and its agent holds that tab's
    /// controls (P139). Whatever an app holds.
    func foldTabIsLive(_ sessionID: String) -> Bool {
        guard let session = state.session(id: sessionID), !session.isSessionEnded, replyRoute(for: session) != nil else { return false }
        return agentPID(awaitingReply: session) != nil
    }

    /// A move into Claude Code's background is under way or unsure for the folded session (`/background` waits for its
    /// turn's end, was typed and is not seen yet, or may have gone where the list cannot tell): no hand-over is offered
    /// then, so `/desktop` and `/background` never both go to one tab, and Claude never opens a conversation that may run
    /// in the background under an id the island does not know (P1533).
    func foldMoveUnsettled(_ sessionID: String) -> Bool {
        guard let background = folds[sessionID]?.background else { return false }
        return background.stage == .waitsForTurnEnd || background.stage == .moving || background.leftItUnsure
    }

    /// An app took the folded session's conversation (`SessionHandoff`, `.inApp`): a background copy it came from was seen
    /// stopped first, so the card is no background card any more. Its way back is the conversation's own resume in a
    /// new window once the app lets go, never `claude attach` on the stopped copy, which would wake it beside the app
    /// (P1534). The interactive session it moved from stays out of the list.
    func appTookConversation(_ sessionID: String) {
        guard folds[sessionID]?.background != nil else { return }
        folds[sessionID]?.background = nil
        // No turn of the island's runs there now: the app has it.
        folds[sessionID]?.turnOpen = false
        backgroundMoveChecks.remove(sessionID)
    }

    /// One line in the fold's log (`JuiceLog.fold`) and Copy Report's notes: the session's id and the hand-over's words,
    /// never a reply's text (P1429, P1430).
    func noteHandoff(_ sessionID: String, _ said: String) {
        JuiceLog.fold.notice("\(sessionID, privacy: .public) \(said, privacy: .public)")
        foldNotes.append(FoldNote(at: dependencies.now(), sessionID: sessionID, said: said))
        if foldNotes.count > Self.foldNoteLimit { foldNotes.removeFirst(foldNotes.count - Self.foldNoteLimit) }
    }
}
