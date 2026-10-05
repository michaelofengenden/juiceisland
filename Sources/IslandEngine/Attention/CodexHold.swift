import Foundation
import OpenIslandCore

/// Settings › Island › Answer Codex on the island (P470; the owner's "do all of them" of 2026-09-28, item 22). Codex
/// awaits its PermissionRequest hook before its own reviewer and before its own prompt (openai/codex
/// `core/src/tools/approvals.rs`: "1. Hooks 2. If StrictAutoReview || Guardian enabled, then Guardian. Else, user."), and
/// honours the hook's `allow` or `deny` for that one call (`hooks/src/events/permission_request.rs`). So, as for a Claude
/// subagent (P350), Allow on the island needs a hold, and the hold takes Codex's own prompt away while it lasts: the TUI
/// shows only "Running PermissionRequest hook", the Codex app nothing. The opt-in trades that for Allow on the island,
/// bounded and only while the owner can see it:
/// - off by default; held only while it is on, and only a main-thread shell command or patch in Codex's `default` mode
///   (`AttentionPolicy.codexHoldable`), read by the broker from the request alone. In Island mode the island shows its
///   card; in Window mode the window's Needs you card does (P1050: the window was left out only because it reported no
///   card, and a hold needs one the owner sees);
/// - handed back at once, before any card, when the thread's reviewer is Codex's auto review, the turn is under strict
///   review, or the reviewer cannot be read (an island Allow would settle what Codex's reviewer decides), or when the owner
///   is looking at where Codex asks: the session's own terminal tab in front, the Codex app for its threads, or, where
///   the tab probe cannot tell the tab (an IDE, a terminal it does not read, a tmux pane), the host app in front (the
///   prompt stays where they look: `Skip.focused`, `look`, P496);
/// - otherwise confirmed and sounded at once (Codex sends no notice), and held only while the island or the window shows
///   its card: the Claude subagent hold's rules and bounds (`SubagentHold.showGrace`, `.limit`, the broker's backstop),
///   with the same ends: a fold, the window closed, covered or minimised, another app, Esc, Open, a jump, another card in
///   its place, the switch off;
/// - an island answer goes over that request's own connection only (P170, P186), as Codex's hook output: Yes is
///   `{"behavior":"allow"}` (Codex's "Yes, proceed", once), No `{"behavior":"deny","message":…}` with the owner's reason;
///   no Always allow (Codex's hook rejects `updatedPermissions`) and no No and stop (it rejects `interrupt`);
/// - released, the helper exits silent: Codex's reviewer or its own prompt decides, as with the switch off, and the card
///   turns read-only (Open, ✕) until the call's own evidence closes it. A quit or a crash ends the connection the same way.
public enum CodexHold {
    /// The Codex hook tools a hold may be for: a shell command (`Bash`, not a network approval) and a patch
    /// (`apply_patch`); the card shows each whole, and its own call's output closes it.
    public static let tools: Set<String> = ["Bash", "apply_patch"]
    /// The hold's bounds are the subagent hold's (P350): the owner's own tuning of how long an agent's own prompt may wait.
    public static var limit: TimeInterval { SubagentHold.limit }
    public static var showGrace: TimeInterval { SubagentHold.showGrace }

    /// Where the owner looks, as far as it is known before the tab probe (P496).
    enum Look: Equatable {
        /// At where Codex asks: handed back.
        case focused
        case notFocused
        /// The session's host is one the tab probe reads: its answer decides.
        case probeTab
    }

    /// The hosts whose front tab the engine's probe reads (upstream's `ForegroundTerminalSessionProbe`: Ghostty's focused
    /// terminal, Terminal's and iTerm's tty or session), outside tmux, whose pane the probe cannot see.
    static let tabReadHosts: Set<String> = [ExactJump.ghosttyBundleID, ExactJump.terminalBundleID, ExactJump.itermBundleID]
    /// Terminals the jump table does not list, where Codex may still run.
    static let otherTerminals: Set<String> = ["net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper", "com.raphaelamorim.rio",
                                              "dev.warp.Warp", "dev.warp.Warp-Preview"]

    /// A request the probe cannot place (an IDE, a terminal it does not read, a tmux pane) counts as looked at when its host
    /// app is in front; with the host not known, when any terminal or IDE is. Releasing is the safe side of a hold: Codex's
    /// own prompt then shows where the owner looks.
    static func look(place: AttentionRequest.Place, host: String?, inTmux: Bool, frontmost: String?) -> Look {
        let probeReads = !inTmux && place != .ide && host.map { tabReadHosts.contains($0) } ?? true
        if probeReads {
            // Host unknown: the probe reads what it can, and a terminal or IDE it cannot read in front counts as looking.
            if host == nil, let frontmost, !tabReadHosts.contains(frontmost), isTerminalOrIDE(frontmost) { return .focused }
            return .probeTab
        }
        guard let frontmost else { return .notFocused }
        if let host { return frontmost == host ? .focused : .notFocused }
        return isTerminalOrIDE(frontmost) ? .focused : .notFocused
    }

    static func isTerminalOrIDE(_ bundleID: String) -> Bool {
        bundleID != ExactJump.codexBundleID && bundleID != "com.anthropic.claudefordesktop"
            && (JumpHosts.isKnown(bundleID: bundleID) || AttentionPolicy.ideBundleIDs.contains(bundleID) || otherTerminals.contains(bundleID))
    }

    /// Why a Codex request the broker held was handed back before its card was entered (Diagnostics › Needs you counts
    /// them with the hold's ends; no text).
    enum Skip: String {
        /// The owner looks at where Codex asks: its terminal tab in front, or the Codex app.
        case focused
        /// The thread's reviewer is Codex's auto review, or the turn is under strict review.
        case reviewer
        /// The thread's rollout could not be read, so its reviewer is not known.
        case unknownReviewer
        /// The helper ended before the card was entered (Esc in Codex, a timeout).
        case hookEnded
        /// The switch went off (or Island mode did) before the card was entered.
        case switchedOff
        /// Not one the island holds: a subagent's (read from its own rollout, shown read-only), a reviewer's or a helper's
        /// thread, bypass, an input not readable, a session gone.
        case notEntered
        /// Its entry took longer than `showGrace`.
        case late
    }
}

extension SessionEngine {
    /// Settings › Island › Answer Codex on the island (P470), in either mode (P1050). Off: every Codex request is handed
    /// back at once and shown read-only (decision 15). Turned off, every Codex hold ends at once.
    public var answersCodex: Bool {
        get { codexHoldSwitch.isOn }
        set {
            codexHoldSwitch.set(newValue)
            guard !newValue else { return }
            for request in attention.all where request.isHeldForIsland && request.tool == .codex { endSubagentHold(request.id, .switchedOff) }
            for id in pendingCodexHolds.keys { skipCodexHold(id, .switchedOff) }
        }
    }

    /// A Codex request the broker held, not entered yet: the engine reads its reviewer and where the owner looks first.
    /// Bounded: not entered within `showGrace`, it is handed back.
    func awaitCodexHold(_ id: String) {
        pendingCodexHolds[id] = true
        dependencies.scheduleAttentionCheck(CodexHold.showGrace) { [weak self] in
            guard let self, self.pendingCodexHolds[id] != nil else { return }
            self.skipCodexHold(id, .late)
        }
    }

    /// Hands a held Codex request back before its card: the helper exits silent and Codex's reviewer or prompt decides.
    func skipCodexHold(_ id: String, _ skip: CodexHold.Skip) {
        guard pendingCodexHolds.removeValue(forKey: id) != nil else { return }
        releaseBrokered(id)
        attentionTally.count(skip.rawValue, in: \.codexHolds)
    }

    /// The helper of a held Codex request ended before its card was entered (Esc in Codex): it is not held when it comes.
    /// False for any other request.
    func noteCodexHoldEnded(_ id: String) -> Bool {
        guard pendingCodexHolds[id] != nil else { return false }
        pendingCodexHolds[id] = false
        return true
    }

    /// Enters a Codex request the broker held (P470): held for the island only while the switch is on, the helper still
    /// waits, the thread's reviewer is the owner, and the owner is not looking at where Codex asks; otherwise handed back
    /// and entered read-only, as with the switch off.
    /// `reviewer`: the thread's latest `approvals_reviewer` (every Codex that has a reviewer writes it in each turn's
    /// `turn_context`); nil when it could not be read, which never holds.
    func enterHeldCodexRequest(_ request: AttentionRequest, reviewer: String?, strictAutoReview: Bool,
                               afterEntry: @escaping @MainActor () -> Void) {
        let id = request.id
        let skip: CodexHold.Skip? =
            pendingCodexHolds[id] == nil ? .late
            : pendingCodexHolds[id] == false ? .hookEnded
            : !answersCodex ? .switchedOff
            : request.agentID != nil ? .notEntered
            : reviewer == nil ? .unknownReviewer
            : reviewer != "user" || strictAutoReview ? .reviewer
            : nil
        if let skip {
            skipCodexHold(id, skip)
            releaseBrokered(id)
            guard state.session(id: request.sessionID) != nil else { return }
            openRequest(request)
            return afterEntry()
        }
        guard let session = state.session(id: request.sessionID) else {
            skipCodexHold(id, .notEntered)
            return
        }
        if session.isCodexAppSession || request.place == .codexApp {
            return finishHeldCodexRequest(request, focused: dependencies.frontmostBundleID() == ExactJump.codexBundleID,
                                          afterEntry: afterEntry)
        }
        let target = withEffectiveJumpTarget(session)
        let context = hookNotes.contexts[request.sessionID]
        let host = context?.hostBundleID ?? target.jumpTarget.flatMap { JumpHosts.bundleIdentifier(forTerminalApp: $0.terminalApp) }
        let inTmux = context?.tmuxPane != nil || target.jumpTarget?.tmuxTarget != nil
        switch CodexHold.look(place: request.place, host: host, inTmux: inTmux, frontmost: dependencies.frontmostBundleID()) {
        case .focused: return finishHeldCodexRequest(request, focused: true, afterEntry: afterEntry)
        case .notFocused: return finishHeldCodexRequest(request, focused: false, afterEntry: afterEntry)
        case .probeTab: break
        }
        let probe = dependencies.isSessionFrontmost
        Task { [weak self] in
            let focused = await probe(target)
            self?.finishHeldCodexRequest(request, focused: focused, afterEntry: afterEntry)
        }
    }

    private func finishHeldCodexRequest(_ incoming: AttentionRequest, focused: Bool, afterEntry: @escaping @MainActor () -> Void) {
        let id = incoming.id
        guard pendingCodexHolds[id] == true, answersCodex, !focused else {
            // The owner looks at Codex's own prompt, or the hold ended meanwhile: entered read-only, as with the switch off.
            skipCodexHold(id, pendingCodexHolds[id] == false ? .hookEnded : !answersCodex ? .switchedOff : .focused)
            releaseBrokered(id)
            guard attention.request(id) == nil, state.session(id: incoming.sessionID) != nil else { return }
            openRequest(incoming)
            return afterEntry()
        }
        pendingCodexHolds[id] = nil
        var request = incoming
        request.channel = .answer(.broker)
        request.state = .confirmed
        request.confirmedAt = request.openedAt
        request.holdEndsAt = request.openedAt.addingTimeInterval(CodexHold.limit)
        openRequest(request)
        if let opened = attention.request(id) { scheduleSubagentHold(opened) }
        afterEntry()
    }

    /// Codex's hook output for an island answer: Yes is Codex's "Yes, proceed" for this call only; No carries the owner's
    /// reason (or the island's) as the message the model reads. Nil for what Codex's hook cannot say: new permissions
    /// (Always allow) and an interrupt (No and stop) make Codex reject the output as unsupported, which would read as a
    /// failed hook, not the owner's answer.
    nonisolated static func codexDecision(for resolution: PermissionResolution) -> CodexPermissionRequestDecision? {
        switch resolution {
        case let .allowOnce(updatedInput, updatedPermissions):
            guard updatedInput == nil, updatedPermissions.isEmpty else { return nil }
            return .allow
        case let .deny(message, interrupt):
            guard !interrupt else { return nil }
            return .deny(message: message ?? ApprovalChoices.denyMessage)
        }
    }
}
