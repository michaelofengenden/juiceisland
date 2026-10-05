import AppKit
import IslandEngine
import OpenIslandCore
import SwiftUI

/// What is approved · why · No, Yes and, only when Claude suggested a rule, "Always allow <the rule>" (C4), then a
/// button per mode the session can be switched to with the Yes ("Accept edits" where Claude suggested it, "Bypass" in a
/// session launched with bypass; `ModeButtons`, P450); on a
/// read-only card (the agent's own prompt is where it is answered), Open and ✕ in place of the answers; on a subagent's
/// card the island holds for a while (P350), No and Yes, with the time left running out along Yes's foot (along the
/// reason field's once ⌥-click opened it). The box
/// holds the whole command, the change as a diff, or the URL (`ApprovalContent`), scrolling when long; the dim line
/// under it says why, in the agent's words (Bash's description, Codex's justification). The header's status line
/// already says "Needs approval · Bash". The third button always names what it allows; Claude's full wording (with
/// its scope) is its tooltip. Owner: stream C.
///
/// No can say why: ⌥-click No (it reads "No…" while ⌥ is held) and a field takes the buttons' place; Return sends the
/// No with what was typed, which the agent gets as the reason and carries on from (Claude Code's "No, and tell Claude
/// what to do differently"). ⌃⇧D is No and stop, which ends Claude's turn (Codex has no such answer). A decision that
/// could not be sent keeps the card, with "Not sent · Retry" over the buttons (P129).
struct ApprovalCardView: View {
    let card: ApprovalCardModel
    var style: CardStyle = .window
    @Environment(AppEnvironment.self) private var env
    @Environment(\.previewReasonField) private var previewReason
    @Environment(\.cardKeys) private var keys

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A prompt with no hook behind it has nothing to show: its header says what and where.
            if !card.isNotice {
                ApprovalBodyView(content: card.body, maxLines: style.codeLines)
                if let reason = Self.reason(card.reason, headerBranch: headerBranch) { CardReasonLine(text: reason).padding(.top, 4) }
            }
            if card.isAnswerable {
                DenyChoices(sessionID: card.sessionID, request: card.request?.id, canStop: card.canStop, send: card.send, style: style,
                            noTitle: "No", reasonPrompt: "Tell \(card.agent.displayName) what to do instead…",
                            startsWithReason: previewReason, holdEnds: card.request?.holdEnds) {
                    CardActionButton(title: "Yes", key: keys.hint(.allow), primary: true, fills: style.buttonsFill) { decide(.allowOnce) }
                        // A subagent's request the island holds: the time left before its card turns read-only (P350).
                        .overlay { if let ends = card.request?.holdEnds { HoldCountdown(ends: ends).id(card.request?.id) } }
                    if let label = card.alwaysAllowLabel {
                        CardActionButton(title: Self.shortTitle(label), key: keys.hint(.alwaysAllow), help: Self.buttonTitle(label),
                                         fills: style.buttonsFill) { decide(.alwaysAllow) }
                    }
                    ModeButtons(modes: card.modes, plan: false, fills: style.buttonsFill, decide: decide)
                }
                // Allow all and Deny all, while two or more approvals wait (P1031); the window has them on its Needs you line.
                if style.isIsland { IslandAnswerAll(card: card) }
            } else {
                // Read-only: the agent's own prompt is where it is answered (the needs-you design §3.5).
                ReadOnlyActions(sessionID: card.sessionID, request: card.request, style: style,
                                top: card.isNotice ? 0 : 8)
            }
        }
    }

    private func decide(_ decision: ApprovalDecision) { env.sessions.approve(card.sessionID, decision, request: card.request?.id) }

    /// The branch a Clean card's header says with Show branch on (P1015), which the reason line then leaves out.
    private var headerBranch: String? {
        guard style == .islandClean, let row = env.sessions.row(id: card.sessionID) else { return nil }
        return CleanRowShown(row, settings: env.settings).branch
    }

    /// The reason line without "branch <name>" when the header names that branch already (every fact once); nil when
    /// nothing is left.
    static func reason(_ reason: String?, headerBranch: String?) -> String? {
        guard let reason, let headerBranch else { return reason }
        let kept = reason.components(separatedBy: " · ").filter { $0 != "branch \(headerBranch)" }.joined(separator: " · ")
        return kept.isEmpty ? nil : kept
    }

    /// Claude's own words, minus the "/" upstream appends to every rule as if it were a folder: a Bash rule such as
    /// `git push:*` reads "Yes, allow running git push:*", not "…git push:*/", also before a scope ("…git push:*
    /// from this project"). The button's tooltip.
    static func buttonTitle(_ label: String) -> String {
        var text = label.replacingOccurrences(of: "*/ ", with: "* ")
        if text.hasSuffix("*/") { text.removeLast() }
        return text
    }

    /// The button: Claude's words cut to "Always allow" and the rule, which is never dropped. "Yes, allow running
    /// git push:*/" → "Always allow git push:*"; "Yes, allow writing to src/" → "Always allow writes to src/";
    /// "Yes, always allow Bash globally" → "Always allow Bash globally". Only "from this project" goes (the tooltip
    /// keeps it); "globally" and "for this session" stay on the button.
    static func shortTitle(_ label: String) -> String {
        var text = buttonTitle(label).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Yes, ") { text.removeFirst("Yes, ".count) }
        let projectScope = " from this project"
        if text.hasSuffix(projectScope) { text.removeLast(projectScope.count) }
        let rewrites: [(String, String)] = [
            ("always allow ", ""), ("allow running ", ""), ("allow writing to ", "writes to "),
            ("allow reading from ", "reads from "), ("allow searching ", "searching "), ("allow ", ""),
        ]
        for (prefix, verb) in rewrites where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? "Always allow" : "Always allow \(verb)\(rest)"
        }
        return text == "always allow" || text.isEmpty ? "Always allow" : text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// A waiting card's row of answers with its No first, shared by the approval and plan cards: the No button (`noTitle`)
/// and the card's other buttons, or, once ⌥-click on No asked for it, one field for the reason in their place (Esc in
/// the window's field brings the buttons back). "Not sent · Retry" sits over them when the last decision did not go.
struct DenyChoices<Others: View>: View {
    let sessionID: String
    /// The engine request the card shows: a No goes to it only while it still waits (P170).
    var request: String?
    let canStop: Bool
    let send: CardSend?
    let style: CardStyle
    let noTitle: String
    let reasonPrompt: String
    /// Space over the buttons (none when they are all the card holds).
    var top: CGFloat = 8
    var startsWithReason = false
    /// A subagent's request the island holds (P350): while the reason's field is open, the time left runs along its foot.
    var holdEnds: Date? = nil
    @ViewBuilder let others: Others
    @Environment(AppEnvironment.self) private var env
    @Environment(\.optionKeyHeld) private var optionHeld
    @Environment(\.cardDraftSlot) private var draftSlot
    @Environment(\.cardKeys) private var keys
    @State private var reasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let send { CardSendLine(state: send) { env.sessions.retry(sessionID) }.padding(.top, top == 0 ? 0 : 6) }
            if reasoning || startsWithReason {
                AnswerFieldView(placeholder: reasonPrompt, focused: true, cancel: { reasoning = false }, holdEnds: holdEnds) { text in
                    env.sessions.approve(sessionID, .denyWithReason(text), request: request)
                }
                .padding(.top, send == nil ? top : 6)
            } else {
                CardActionsRow(fills: style.buttonsFill, top: send == nil ? top : 6) {
                    CardActionButton(title: optionHeld ? noTitle + "…" : noTitle, key: keys.hint(.deny),
                                     tip: Self.tip(canStop: canStop, stopKey: keys.hint(.denyAndStop)),
                                     refuses: true, fills: style.buttonsFill) {
                        if NSEvent.modifierFlags.contains(.option) {
                            reasoning = true
                        } else {
                            env.sessions.approve(sessionID, .deny, request: request)
                        }
                    }
                    others
                }
            }
        }
        // A reason half-typed before the island folded comes back with its field open (P273).
        .onAppear(perform: reopenReason)
        .onChange(of: draftSlot?.key) { old, new in
            // Another request in this card's place: its reason's field only if it has a draft of its own.
            if let old, let new, old != new { reasoning = draftSlot?.text(for: reasonPrompt) != nil } else { reopenReason() }
        }
    }

    private func reopenReason() {
        if !reasoning, draftSlot?.text(for: reasonPrompt) != nil { reasoning = true }
    }

    /// The No button's tooltip: the other ways to say no (No and stop's key only while the keys are on).
    static func tip(canStop: Bool, stopKey: String? = CardKeys.standard.display(.denyAndStop)) -> String {
        guard canStop, let stopKey else { return "⌥-click to say why" }
        return "⌥-click to say why · \(stopKey) to stop the turn"
    }
}

/// A card's mode buttons (`ApprovalCardModel.modes`, `PlanCardModel.modes`), after its answers: each allows (approves
/// the plan) and switches the session to its mode for the rest of the session, named as Claude names its modes. They
/// have no key and no ⌃ hint: a mode changes only on a click on its own button, never with ⌃A or a Retry of another
/// answer (P450).
struct ModeButtons: View {
    let modes: [ClaudePermissionMode]
    /// A plan's (Approve and switch) or an approval's (Yes and switch): only the tooltip differs.
    let plan: Bool
    let fills: Bool
    let decide: (ApprovalDecision) -> Void

    var body: some View {
        ForEach(modes, id: \.self) { mode in
            CardActionButton(title: Self.title(mode), help: Self.help(mode, plan: plan), fills: fills) {
                decide(.allowSwitchingMode(mode))
            }
            // Short of room, the answers and Always allow's rule stay whole; these give way: the window cuts them, the
            // island puts them on a line of their own (`FlexRowLayout`, P490).
            .layoutPriority(-1)
        }
    }

    /// Claude's own names for its modes (the status bar's and the plan prompt's), Bypass permissions cut to its first word
    /// so a row with Always allow keeps the rule whole (the tooltip says it in full).
    static func title(_ mode: ClaudePermissionMode) -> String {
        switch mode {
        case .acceptEdits: "Accept edits"
        case .default: "Manual"
        case .bypassPermissions: "Bypass"
        case .auto: "Auto"
        case .plan: "Plan"
        case .dontAsk: "Don't ask"
        }
    }

    /// The tooltip, and what VoiceOver reads: what the click does, in full.
    static func help(_ mode: ClaudePermissionMode, plan: Bool) -> String {
        let yes = plan ? "Approve" : "Yes"
        switch mode {
        case .acceptEdits: return "\(yes), and accept edits for the rest of the session"
        case .default: return "\(yes), and ask before each edit (Manual)"
        case .bypassPermissions: return "\(yes), and bypass permissions for the rest of the session"
        default: return "\(yes), and switch to \(title(mode))"
        }
    }
}
