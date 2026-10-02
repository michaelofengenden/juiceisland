import SwiftUI

/// Settings › Island › Needs you colour: the colour of what waits on the owner, whichever agent asks. The owner's ask of
/// 2026-10-01: "I associate orange with claude but codex can also arise questions". Pink by default, Violet, or Orange,
/// the waiting orange the island had until then, every render the same as before it (P780).
///
/// It is the colour of an approval's "!", a question's "?" and a failed turn's "×" in every glyph style and wherever a
/// glyph shows (the pill, the rows, the cards, the window, the widget, Settings' previews); of the words that say so
/// ("Needs approval", "Question", a limit's warning, "Not sent"); of State tint's veil and Black's edge while something
/// waits; and of a question's picked option (its number badge, its edge, its check). Claude's colours, the brand glyph's
/// orange and a stalled turn's dim amber stay as they are (P781).
///
/// Each choice is one hue at two lightnesses, as the orange pair was: `wait`, which every one of those draws, and
/// `question`, its lighter tint (the prototype's question header, which no view draws). Both are held to the same
/// floors, in CIEDE2000 from every colour a glyph or a mark shows, and on the pure black (`NeedsYouColourTests`):
/// - Pink #ED68AF: 23.4 from Claude's running red, 28.1 from Claude's terracotta, 28.8 from OpenCode's silver, 34.5
///   from the running blue, 40.9 from stalled's amber, 47.1 from the brand, 52.3 from the delegate teal, 68.1 from
///   done; 7.2:1, and 4.66:1 as the widget's word on Smoke over a white wallpaper. Its tint #F58AC3: 24.7 from Claude's
///   running red, 24.8 from OpenCode's silver; 9.3:1.
/// - Violet #BD7AFF, a blue-violet turned toward purple until it left the running blue: 20.8 from it, 28.3 from
///   OpenCode's silver, 34.7 from Codex's cyan, 39.6 from Claude's terracotta; 7.4:1. Its tint #D4A8FF: 21.4 from
///   OpenCode's silver, 25.2 from the running blue; 10.8:1.
/// - Orange #E97B36 and #F0A35E, as they were: 8.9 from Claude's terracotta, which is why it moved.
/// An agent whose own colour sits within 12 of the one chosen runs in the running blue under By agent (`AgentLook`).
enum NeedsYouColour: String, CaseIterable, Sendable {
    case pink, violet, orange

    /// A stored choice; anything else (a later build's) reads as Pink, the default.
    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .pink }

    var title: String {
        switch self {
        case .pink: "Pink"
        case .violet: "Violet"
        case .orange: "Orange"
        }
    }

    /// What needs you: every glyph, word, tint and mark that says so.
    var wait: Color {
        switch self {
        case .pink: Color(hex: 0xED68AF)
        case .violet: Color(hex: 0xBD7AFF)
        case .orange: Color(hex: 0xE97B36)
        }
    }

    /// `wait`'s lighter tint.
    var question: Color {
        switch self {
        case .pink: Color(hex: 0xF58AC3)
        case .violet: Color(hex: 0xD4A8FF)
        case .orange: Color(hex: 0xF0A35E)
        }
    }
}

extension EnvironmentValues {
    /// Settings › Island › Needs you colour, for every view under this one. Pink unless a root sets it
    /// (`juiceThemeFromSettings()`, `windowLookFromSettings()`); the widget reads its snapshot's (`WidgetSnapshot.needsYou`).
    @Entry var needsYouColour: NeedsYouColour = .pink
}
