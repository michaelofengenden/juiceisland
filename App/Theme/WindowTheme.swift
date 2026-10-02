import SwiftUI

/// The app window's own chrome (prototype.md §1.1, §5.1). Rows and cards inside it use `IslandTheme` (Black) or, on a
/// light window, Solid's palette (`WindowLook`). Every token is a pair of twins resolved in the window's colour scheme
/// (P762): the dark twin today's value exactly, the light one the same role on the white window, words at 4.5:1 and
/// counts and marks at 3:1 or more on it. On Black and Smoke the window is always dark, so only the dark twins show.
enum WindowTheme {
    static let bg = Color.adaptive(0xFFFFFF, 0x000000)
    static let edge = pair(black: 0.14, white: 0.20)
    static let hairline = pair(black: 0.08, white: 0.08)          // i-line: the header's bottom
    static let card = Color.adaptive(0xF7F7F8, 0x0A0A0B)
    static let cardStroke = Color.adaptive(0xE3E3E6, 0x232325)
    static let filterText = Color.adaptive(0x6E6E73, 0x6C6C70)
    static let filterCount = Color.adaptive(0x8A8A8E, 0x48484C)
    static let filterSelectedBg = Color.adaptive(0xEDEDF0, 0x161618)
    static let filterSelectedText = Color.adaptive(0x1D1D1F, 0xE5E5E5)
    static let filterSelectedCount = Color.adaptive(0x636368, 0x8E8E93)
    /// Section labels and their counts, small on the pure black: both at least 4.5:1, the count the quieter.
    static let sectionHeader = Color.adaptive(0x5E5E63, 0x86868B)
    static let sectionCount = Color.adaptive(0x6E6E73, 0x76767B)
    static let segmentBg = Color.adaptive(0xEDEDF0, 0x111113)
    static let segmentStroke = pair(black: 0.10, white: 0.10)
    static let segmentSelectedBg = Color.adaptive(0xFFFFFF, 0x2C2C2E)
    static let segmentSelectedText = Color.adaptive(0x1D1D1F, 0xF2F2F2)
    static let iconButton = Color.adaptive(0x6E6E73, 0xB3B3B3)
    static let iconButtonHover = Color.adaptive(light: Color.black.opacity(0.06), dark: Color(hex: 0x141414))
    static let scrollbar = Color.adaptive(0xD1D1D6, 0x2A2A2C)
    static let accountName = Color.adaptive(0x6E6E73, 0x76767B)   // i-ink3 under batteries
    static let emptyText = Color.adaptive(0x6E6E73, 0x8E8E93)
    static let popoverBg = Color.adaptive(0xFFFFFF, 0x1C1C1E)
    static let popoverEdge = pair(black: 0.12, white: 0.18)
    static let chipBg = Color.adaptive(0xFFFFFF, 0x000000)
    static let chipEdge = pair(black: 0.16, white: 0.26)
    /// The window's cards (`CardTheme.windowFill`, `windowStroke`): the window's own ground, ringed.
    static let cardGround = Color.adaptive(light: .white, dark: CardTheme.windowFill)
    static let cardEdge = Color.adaptive(light: Color.black.opacity(0.09), dark: CardTheme.windowStroke)

    /// The ink at `black` where the window is light, white at `white` where it is dark.
    static func pair(black: Double, white: Double) -> Color {
        .adaptive(light: Color.black.opacity(black), dark: Color.white(white))
    }

    enum Metrics {
        static let defaultSize = CGSize(width: 1200, height: 760)
        static let minSize = CGSize(width: 900, height: 560)
        static let radius: CGFloat = 16
        /// The toolbar line shares the title bar with the traffic lights (`WindowChromeMetrics`: 40 tall on macOS 26);
        /// 12 pt after its last button.
        static let toolbarTrailing: CGFloat = 12
        static let segmentHeight: CGFloat = 26
        static let iconButton: CGFloat = 30
        /// The usage band under the title line (when the usage does not fit on it): padding 0 22 8; rows min 31.
        static let headerPadding = EdgeInsets(top: 0, leading: 22, bottom: 8, trailing: 22)
        static let headerRowHeight: CGFloat = 31
        /// Below this container width Running/Done become one column.
        static let narrowBreakpoint: CGFloat = 1000
        /// Session list: padding 4 16 20; needs-you grid min column 430, gap 10; card radius 14, padding 9 10 12.
        static let listPadding = EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16)
        static let needsGridMinColumn: CGFloat = 430
        static let gridGap: CGFloat = 10
        static let cardRadius: CGFloat = 14
        static let cardBodyIndent: CGFloat = 49
        static let popoverRadius: CGFloat = 14
        /// 560 (the prototype's 520 cut "resets in 1h 40m"): the detail column holds the longest reset in words.
        static let accountListWidth: CGFloat = 560
    }

    enum TypeScale {
        static let segment = Fonts.sys(12.5, .medium)
        static let filter = Fonts.sys(11.5, .semibold)
        static let sectionHeader = Fonts.sys(11, .semibold)
        static let rowTitle = Fonts.sys(13)     // 13/20
        static let rowStatus = Fonts.sys(12)    // 12/19
        static let rowTool = Fonts.sys(11.5)    // 11.5/19
        static let rowTag = Fonts.sys(10, .medium) // 10/16, h16, padding 0 6
        static let accountName = Fonts.sys(10.5, .medium)
    }
}
