@testable import IslandEngine

extension SessionEngine {
    /// Every pending request's 8 s window, passed now with no notice from its agent (for tests that are not about the
    /// window): each is confirmed, as a request the agent sends no notice for would be.
    func passAttentionWindows() {
        for request in openRequests where request.state == .pending { attentionWindowElapsed(request.id) }
    }
}
