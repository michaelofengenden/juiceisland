import Foundation
import JuiceCore
import OpenIslandCore

public enum ApprovalDecision: Equatable, Sendable {
    case deny
    /// No, and what to do instead, in the owner's words: the agent gets them as the reason and carries on (Claude
    /// Code's "No, and tell Claude what to do differently").
    case denyWithReason(String)
    /// No, and the turn ends there (Claude Code's Esc): Claude stops and waits for the owner. Claude only
    /// (`ApprovalChoices.canStop`).
    case denyAndStop
    case allowOnce
    /// Allow now and keep the rule Claude itself suggested (for example `Bash(git push:*)` in this project).
    case alwaysAllow
    /// Allow (approve the plan), and switch the session to `mode` for the rest of the session: a plan approved into Accept
    /// edits, Manual or Bypass permissions, or an approval with Claude's own "Yes, allow all edits during this session".
    /// Sent only when the owner clicked that mode's button, and only for a mode `ApprovalChoices.modes` offers for the
    /// request (P450, P451).
    case allowSwitchingMode(ClaudePermissionMode)
}

public enum ApprovalChoices {
    /// "Denied from Juice Island." (the public flavor names its product, P820).
    public static var denyMessage: String { "Denied from \(AppFlavor.current.productName)." }
    /// The longest reason sent: a line or two of steering, never a pasted file.
    public static let reasonLimit = 2_000

    /// Claude's own "always allow" suggestion: the first rule it offered to add with behaviour `allow`. Deny or ask rules
    /// are never offered as a button; a mode change is its own button (`modes`), never part of Always allow.
    public static func alwaysAllowUpdate(for request: PermissionRequest?) -> ClaudePermissionUpdate? {
        request?.suggestedUpdates.first { update in
            if case let .addRules(_, rules, behavior) = update { return behavior == .allow && !rules.isEmpty }
            return false
        }
    }

    /// The button text for the third approval button, in Claude Code's own words; nil hides the button.
    public static func alwaysAllowLabel(for request: PermissionRequest?) -> String? {
        alwaysAllowUpdate(for: request)?.displayLabel
    }

    /// The modes a Claude request on the main thread offers to switch to with its Allow, the island's only door into a
    /// session's permission mode (nothing is ever typed into a terminal):
    /// - a plan: Accept edits, or Bypass permissions in its place in a session known to have bypass (`bypassAvailable`),
    ///   and Manual, as Claude's own plan prompt words them ("Yes, auto-accept edits" / "Yes, and bypass permissions",
    ///   "Yes, manually approve edits"). The plain Approve sends no mode: Claude then goes back to the mode it planned
    ///   from, as its own ExitPlanMode does (P452). Manual stays beside it: which mode that was is not known here, since
    ///   ⇧⇥ goes from Manual through Accept edits into plan with no hook between, so a session last heard in Manual may
    ///   have planned from Accept edits (P499);
    /// - an approval: a mode Claude itself suggested for it (Accept edits, for a file change in Manual or plan mode), and
    ///   Bypass permissions in a session known to have it.
    /// Never Auto: a hook's `setMode` of `auto` assigns the mode without Claude's own switch into it (its availability
    /// check, the classifier's start and the setting aside of broad allow rules, P451); never plan or dontAsk; never the
    /// mode the request says the session is in. Bypass only where Claude takes it (it ignores it in a session not
    /// launched with bypass available, which would leave a button that does nothing).
    public static func modes(for request: AttentionRequest, bypassAvailable: Bool) -> [ClaudePermissionMode] {
        guard request.tool == .claudeCode, request.isRoot, let permission = request.permissionRequest else { return [] }
        var offered: [ClaudePermissionMode]
        if request.kind == .plan {
            offered = [bypassAvailable ? .bypassPermissions : .acceptEdits, .default]
        } else {
            offered = permission.suggestedUpdates.compactMap { update in
                guard case let .setMode(_, mode) = update, mode == .acceptEdits || mode == .default else { return nil }
                return mode
            }
            if bypassAvailable { offered.append(.bypassPermissions) }
        }
        var seen: Set<ClaudePermissionMode> = []
        return offered.filter { $0.rawValue != request.permissionMode && seen.insert($0).inserted }
    }

    /// The one update a mode button sends: the mode for this session only, whatever destination Claude's suggestion
    /// named, so no settings file and no later session changes (P450).
    public static func modeUpdate(_ mode: ClaudePermissionMode) -> ClaudePermissionUpdate {
        .setMode(destination: .session, mode: mode)
    }

    /// Whether a No can also end the turn: Claude's PermissionRequest hook takes `interrupt`; Codex's hooks have no
    /// such field, so a Codex approval is never offered it.
    public static func canStop(_ tool: AgentTool) -> Bool { tool == .claudeCode }

    /// The owner's reason as it is sent: trimmed, at most `reasonLimit` characters; nil when nothing is left, so an
    /// empty reason is never sent as one.
    public static func reason(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(reasonLimit))
    }

    public static func resolution(for decision: ApprovalDecision, request: PermissionRequest?) -> PermissionResolution? {
        switch decision {
        case .deny:
            return .deny(message: denyMessage, interrupt: false)
        case let .denyWithReason(text):
            return .deny(message: reason(text) ?? denyMessage, interrupt: false)
        case .denyAndStop:
            return .deny(message: denyMessage, interrupt: true)
        case .allowOnce:
            return .allowOnce()
        case .alwaysAllow:
            return alwaysAllowUpdate(for: request).map { .allowOnce(updatedPermissions: [$0]) }
        case let .allowSwitchingMode(mode):
            return .allowOnce(updatedPermissions: [modeUpdate(mode)])
        }
    }
}
