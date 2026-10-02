import SwiftUI

/// Juice's own tokens (unchanged from standalone Juice's `App/Panel/Theme.swift`): batteries, money rows, the desktop
/// panel and hover chips. The island, window and Settings tokens are in `IslandTheme`, `WindowTheme` and
/// `SettingsTheme` (prototype.md §5.1).
enum Theme {
    static let surface = Color(hex: 0x000000)
    static let ink = Color(hex: 0xF4F4F0)
    static let ink2 = Color(hex: 0xABABA5)
    static let track = Color(hex: 0x272725)
    static let line = Color(hex: 0x787874)
    static let warn = Color(hex: 0xFFC16E)
    static let attention = Color(hex: 0xFF7C75)
    static let claudeMark = Color(hex: 0xD97757)
    /// The OpenAI mark wherever it shows, in Codex's colour (`IslandTheme.agentCodex`): beside Claude's terracotta in the
    /// usage header, the two marks are the legend for the rows' marks.
    static let codexMark = IslandTheme.agentCodex
    static let divider = Color.white.opacity(0.14)
    static let edge = Color.white.opacity(0.24)

    enum Panel {
        static let size = CGSize(width: 362, height: 184)
        static let radius: CGFloat = 22
        static let padding: CGFloat = 16
        static let rowHeight: CGFloat = 29
        static let rowGap: CGFloat = 8
        static let markSize: CGFloat = 20
        static let markGap: CGFloat = 10
        static let dividerAbove: CGFloat = 6
        static let dividerBelow: CGFloat = 13
        static let moneyRowHeight: CGFloat = 22
        static let moneyGutter: CGFloat = 24
    }

    enum Battery {
        static let width: CGFloat = 42
        static let height: CGFloat = 18
        static let radius: CGFloat = 5.5
        static let outline: CGFloat = 1.5
        static let nubWidth: CGFloat = 3
        static let nubHeight: CGFloat = 6.5
        static let inset: CGFloat = 2
        static let gap: CGFloat = 6
        static let nextBarSize = CGSize(width: 14, height: 2)
        static let nextBarBelow: CGFloat = 3.5
        /// The mark over an account in use (P811): a dot this wide, this far over the body's top, where the hover ring
        /// (2.5 pt out) leaves it clear. The Next bar's ink: one pointer under, one over.
        static let inUseDot: CGFloat = 4
        static let inUseDotAbove: CGFloat = 3.5
        static var cellWidth: CGFloat { width + nubWidth }
    }

    /// Provider mark sizes: rows 20, strip and popovers 16, tables 12, session rows 10 (the window's 11), before the
    /// title in the agent's colour. `sessionRowOpacity`: a quota notice's mark.
    enum Mark {
        static let row: CGFloat = 20
        static let strip: CGFloat = 16
        static let table: CGFloat = 12
        static let sessionRow: CGFloat = 10
        static let sessionRowOpacity: Double = 0.55
    }

    static let digitFont = Font.system(size: 11, weight: .semibold).monospacedDigit()
    static let refillFont = Font.system(size: 10, weight: .semibold).monospacedDigit()
    static let moneyNameFont = Font.system(size: 12.5, weight: .regular)
    static let moneyAmountFont = Font.system(size: 12.5, weight: .semibold).monospacedDigit()
    static let moneySuffixFont = Font.system(size: 11, weight: .regular)
    static let labelFont = Font.system(size: 12, weight: .regular)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    /// `rgba(255,255,255,a)` in the prototype.
    static func white(_ alpha: Double) -> Color { Color.white.opacity(alpha) }
}

/// The prototype's fonts: the system font (SF Pro) everywhere, SF Mono for code and tool verbs.
enum Fonts {
    static func sys(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Tabular figures (counts, amounts, ages).
    static func num(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension NSFont.Weight {
    /// AppKit's weight for a SwiftUI one, to measure text in the weight it draws in.
    init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}
