import SwiftUI

/// `LiveSessions.badge`: "Live" or "Demo" in a development build; in the production app only a word or two for why
/// the hooks wait ("Open Island running"), or nothing. The window's toolbar only (the island header dropped it);
/// nothing in renders, whose environment has no switch. `quietLive` (the toolbar) draws Live, the usual state, as a
/// green dot with no word; Demo keeps its word, since it means the sessions are not real. Its colours are the window's
/// tokens (`\.juiceTheme`): Black's, today's, where the window is dark; Glass's twins where it is light (P762).
struct SessionSourceBadge: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    var quietLive = false

    static let liveGreen = Color(hex: 0x30D158)
    static let problemAmber = Color(hex: 0xFFC16E)

    /// What the badge says.
    enum Kind { case live, demo, problem }

    /// A word's colour in `theme` (the Live dot's, a mark's, for `.live` with `mark`).
    static func colour(_ kind: Kind, _ theme: JuiceTheme, mark: Bool = false) -> Color {
        let palette = theme.island
        return switch kind {
        case .live: mark ? palette.tone(liveGreen) : palette.toneText(liveGreen)
        case .demo: palette.ink2
        case .problem: palette.toneText(problemAmber)
        }
    }

    /// The capsule's fill: white at 8 % on Black, as always; Glass's veil of the look where the window takes it.
    static func capsule(_ theme: JuiceTheme) -> Color { theme.adapts ? GlassVeil.colour(light: 0.06, dark: 0.08) : Color.white(0.08) }

    var body: some View {
        if let live = env.liveSessions, let text = live.badge {
            if live.hooksReachApp {
                let help = "Live sessions: the hook connection is on"
                if quietLive {
                    Circle()
                        .fill(Self.colour(.live, theme, mark: true))
                        .frame(width: 6, height: 6)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .help(help)
                        .accessibilityLabel(text)
                } else {
                    badge(text, colour: Self.colour(.live, theme), help: help)
                }
            } else if live.mode != .live, live.identity.showsDemoSessions {
                badge(text, colour: Self.colour(.demo, theme), help: "Demo sessions: Live sessions is off (Settings › General)")
            } else {
                badge(text, colour: Self.colour(.problem, theme), help: live.hooksProblem ?? text)
            }
        }
    }

    private func badge(_ text: String, colour: Color, help: String) -> some View {
        Text(text)
            .font(Fonts.sys(10, .semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.capsule(theme)))
            .fixedSize()
            .help(help)
    }
}
