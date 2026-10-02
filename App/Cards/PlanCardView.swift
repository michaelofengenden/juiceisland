import IslandEngine
import SwiftUI

/// The plan · Keep planning, Approve, a button per mode it can be approved into, Open (spec §4.2, C7). The header's
/// status line says "Plan ready · N steps", so the body is only the plan, read from the transcript and drawn as the
/// Done card draws Markdown, in a box that scrolls when long, and the buttons, the primary second as on the approval
/// card (No · Yes). Approve sends no mode: Claude goes back to the mode it planned from (P452); "Accept edits" (or
/// "Bypass" in a session launched with bypass) and "Manual" approve and switch, as Claude's own plan prompt does
/// (`ModeButtons`, P450). Until the plan is read the card is just the buttons. ⌥-click on Keep planning says what to change, which Claude gets as the reason
/// to plan again; ⌃⇧D ends the turn (`DenyChoices`). Read-only (a plan the island cannot answer): the plan, Open and ✕.
/// Owner: stream C.
struct PlanCardView: View {
    let card: PlanCardModel
    var style: CardStyle = .window
    @Environment(AppEnvironment.self) private var env
    @Environment(\.previewReasonField) private var previewReason

    var body: some View {
        let plan = card.plan.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            if let plan { PlanBlockView(plan: plan, maxLines: style.planLines) }
            if card.isAnswerable {
                DenyChoices(sessionID: card.sessionID, request: card.request?.id, canStop: card.canStop, send: card.send, style: style,
                            noTitle: "Keep planning", reasonPrompt: "Tell \(card.agent.displayName) what to change…",
                            top: plan == nil ? 0 : 8, startsWithReason: previewReason) {
                    CardActionButton(title: "Approve", key: "⌃A", help: card.modes.isEmpty ? nil : Self.approveHelp, primary: true,
                                     fills: style.buttonsFill) {
                        env.sessions.approve(card.sessionID, .allowOnce, request: card.request?.id)
                    }
                    ModeButtons(modes: card.modes, plan: true, fills: style.buttonsFill) { decision in
                        env.sessions.approve(card.sessionID, decision, request: card.request?.id)
                    }
                    CardActionButton(title: "Open", help: "Open the session", fills: style.buttonsFill) { env.sessions.jump(card.sessionID) }
                }
            } else {
                ReadOnlyActions(sessionID: card.sessionID, request: card.request, style: style,
                                top: plan == nil ? 0 : 8)
            }
        }
    }

    /// What the plain Approve does beside the mode buttons: no mode is sent, so Claude picks up where it planned from.
    static let approveHelp = "Approve, and go back to the mode Claude planned from"
}
