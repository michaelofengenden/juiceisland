import Foundation
import OpenIslandCore

/// A Claude conversation that goes on under another id in the same process (P441). A rewind (Esc Esc, `/rewind`,
/// "Restore conversation") keeps the session's id and its transcript, fires no hook, and appends the new timeline to
/// the same file: it is the same row, and a prompt sent again after it is a new turn of that row (P5). A fork is
/// another matter: `/branch` copies the conversation into a new session, whose SessionStart says `source: "fork"`, and the
/// same process writes only to the copy from then on. The parent gets no SessionEnd: it stays open, so it would stay a
/// row, a duplicate of the fork's card up to the fork, whose jump lands in the fork's terminal.
///
/// The parent is ended only when the fork names it: the copy's lines carry `forkedFrom.sessionId` (read from the head of
/// the fork's own transcript, bounded, off the main thread), its notes came from the same process, and it does not wait on
/// the owner. So a `/fork` into a background session, a teammate or any other session a process starts beside the one the
/// owner is in ends nothing.
extension SessionEngine {
    static let forkSource = "fork"

    /// A fork's SessionStart note: remembered until its bridge event names its transcript (the helper sends the note
    /// first), or checked at once when the session is already known.
    func noteForkStart(_ child: String, pid: Int32) {
        if let path = state.session(id: child)?.claudeMetadata?.transcriptPath, !path.isEmpty {
            checkFork(child, pid: pid, transcriptPath: path)
        } else {
            pendingForks[child] = pid
            if pendingForks.count > Self.pendingForkLimit, let any = pendingForks.keys.sorted().first { pendingForks[any] = nil }
        }
    }

    /// The bridge's start of a session a fork note announced.
    func noteForkSessionStarted(_ child: String) {
        guard let pid = pendingForks.removeValue(forKey: child),
              let path = state.session(id: child)?.claudeMetadata?.transcriptPath, !path.isEmpty else { return }
        checkFork(child, pid: pid, transcriptPath: path)
    }

    static let pendingForkLimit = 16

    private func checkFork(_ child: String, pid: Int32, transcriptPath: String) {
        let reader = dependencies.readForkParent
        Task { @MainActor [weak self] in
            let parent = await Task.detached(priority: .utility) { reader(transcriptPath) }.value
            guard let self, let parent else { return }
            self.endForkParent(parent, of: child, pid: pid)
        }
    }

    /// Ends `parent` as a SessionEnd would end it (`dismiss`): out of the lists, and back with its next prompt or real
    /// start (`claude --resume` in another process). Only a Claude session whose own notes came from `pid` last, that
    /// has not ended, and that waits on nothing: a request stays with its card.
    func endForkParent(_ parent: String, of child: String, pid: Int32) {
        guard parent != child, hookNotes.contexts[parent]?.agentPID == pid, let session = state.session(id: parent),
              session.tool == .claudeCode, !session.isSessionEnded, !session.isSubagentSession, !needsAttention(session) else { return }
        dismiss(sessionID: parent)
        forkEndedCount += 1
    }
}

/// The session a fork's transcript names as its parent: the first `forkedFrom.sessionId` among the lines of its first
/// `window` bytes (a `/branch` copy carries it on every copied line, P441). Only a `.jsonl` under a transcript folder
/// (`ToolCallReader.isTranscript`), read-only, one bounded read; nothing of it is kept but the id.
enum ForkParentReader {
    static let window = 64 * 1_024

    static func read(path: String) -> String? {
        guard ToolCallReader.isTranscript(path) else { return nil }
        return autoreleasepool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: window), !data.isEmpty else { return nil }
            return parent(in: data)
        }
    }

    /// The first complete line's `forkedFrom.sessionId` that names one; a line the window cuts is not read.
    static func parent(in data: Data) -> String? {
        var start = data.startIndex
        while start < data.endIndex, let end = data[start...].firstIndex(of: 0x0A) {
            defer { start = data.index(after: end) }
            let line = data[start..<end]
            guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["forkedFrom"] as? [String: Any])?["sessionId"] as? String, !id.isEmpty, id.count <= 128 else { continue }
            return id
        }
        return nil
    }
}
