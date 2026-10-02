import SwiftUI

/// The island, the closed pill, session rows and cards (prototype.md §1.2-1.3, §5.1, §5.4; CSS `--i-*`).
/// Rows and cards are shared with the window, which uses `WindowTheme` only for its own chrome.
enum IslandTheme {
    // MARK: Ink and surfaces
    static let bg = Color(hex: 0x000000)
    static let ink = Color(hex: 0xF2F2F2)
    static let ink2 = Color(hex: 0x8E8E93)
    /// Small quiet text on the pure black ("No sessions", a card's where line, the "·" between parts): at least 4.5:1.
    static let ink3 = Color(hex: 0x76767B)
    /// Quiet marks, not text: the idle glyph, hollow dots and money rails (3:1 is enough for a mark).
    static let idleMark = Color(hex: 0x5C5C61)
    static let card = Color(hex: 0x1C1C1E)
    static let line = Color.white(0.08)
    static let usageHairline = Color.white(0.07)
    static let headerIcon = Color(hex: 0xB3B3B3)
    static let headerIconHover = Color(hex: 0x141414)
    /// The island's header icons rest dim and brighten under the pointer (no fill behind them).
    static let headerIconRest = Color(hex: 0x5C5C61)

    // MARK: Session rows
    static let rowHover = Color(hex: 0x191919)
    static let rowHoverStroke = Color(hex: 0x2B2B2B)
    /// The one fill the island's own surface keeps: a faint hover highlight, no stroke.
    static let islandHover = Color.white(0.05)
    static let statusClean = Color(hex: 0x9A9A9A)
    static let statusDetailed = Color(hex: 0xB3B3B3)
    static let you = Color(hex: 0x808080)
    static let rowAge = Color(hex: 0x7C7C80)
    static let toolVerb = Color(hex: 0x4674D6)
    static let toolLine = Color(hex: 0x7A7A7A)
    static let jump = Color(hex: 0x5098B6)
    static let footer = Color(hex: 0x7A7A7A)
    static let footerHover = Color(hex: 0x8C8C8C)

    // MARK: States and agents (glyph colours)
    // What needs you (an approval, a question, a failed turn) is Settings › Island › Needs you colour's (`NeedsYouColour`).
    static let run = Color(hex: 0x4E80ED)
    static let done = Color(hex: 0x6FB982)
    /// Delegating: the main turn waits on its subagents. A teal between the running blue and the done green, as far
    /// from both and from Codex's cyan as their gamut allows (CIEDE2000 31.9 from run, 18.9 from done, 20.4 from Codex;
    /// 52.3 from the needs-you pink, 38.0 from the violet, 48.0 from the orange), 7.1:1 on the pure black.
    static let delegate = Color(hex: 0x2BA6A4)
    /// A stalled turn's word (P312): a dim amber, quieter than what needs you and never read as it (40.9 from the
    /// needs-you pink, 48.6 from the violet; 17.0 from the orange, which it was made duller than).
    static let stalled = Color(hex: 0xB39263)
    static let brand = Color(hex: 0xFFB45C)
    /// The agents' colours, on their marks before every title: Claude's brand terracotta; Codex's cyan, the blue
    /// family kept but far from the running blue (CIEDE2000 23.6), and the opposite of Claude's warm.
    static let agentClaude = Color(hex: 0xD97757)
    static let agentCodex = Color(hex: 0x5AC8FA)
    /// Claude's running glyph under By agent: the terracotta, redder (5.8 from it); 23.4 from the needs-you pink, 36.2
    /// from the violet, 14.4 from the orange. The brand itself sits 8.9 from the orange, and in Sand a running stream and
    /// an approval's "!" are both a warm stroke over a pile, so a terracotta one read as one more approval (P207).
    static let agentClaudeRunning = Color(hex: 0xD96A5A)

    // MARK: Cards
    static let optionTitle = Color(hex: 0xE9E8E7)
    static let optionSub = Color(hex: 0x928B85)
    static let optionChevron = Color(hex: 0x70665E)
    static let codeBg = Color(hex: 0x121214)
    static let codeBorder = Color(hex: 0x232326)
    static let codeText = Color(hex: 0xE8E8EC)
    static let codeComment = Color(hex: 0x8E8E93)
    static let message = Color(hex: 0xC9C9CE)
    static let button = Color(hex: 0x1F1F21)
    static let primary = Color(hex: 0xF2F2F2)
    static let primaryText = Color(hex: 0x000000)
    static let kbd = Color(hex: 0x7C7C80)
    static let kbdOnPrimary = Color(hex: 0x555555)
    static let fieldBg = Color(hex: 0x141414)
    static let fieldBorder = Color(hex: 0x2B2B2B)
    static let fieldHoverBg = Color(hex: 0x2B2B2B)
    static let fieldHoverBorder = Color(hex: 0x404040)
    static let fieldPlaceholder = Color(hex: 0x85858A)
    static let send = Color(hex: 0x0A0A0A)
    static let sendText = Color(hex: 0x6C6C70)
    static let sendActive = Color(hex: 0xE5E5E5)

    // MARK: Detailed tags and the Codex group
    struct TagColours: Equatable, Sendable { let bg: Color; let fg: Color }
    static let tagHost = TagColours(bg: Color(hex: 0x191919), fg: Color(hex: 0x8C8C8C))
    static let tagTime = TagColours(bg: Color(hex: 0x0F0F0F), fg: Color(hex: 0x7C7C80))
    static let tagJump = TagColours(bg: Color(hex: 0x0B1519), fg: Color(hex: 0x5098B6))
    static let groupBg = Color(hex: 0x080808)
    static let groupCount = Color(hex: 0x76767B)

    // MARK: Metrics
    enum Metrics {
        /// Opened island: 464 + two 8 pt shoulders (480 pt in all), bottom radius 20, pure black with no shadow.
        static let width: CGFloat = 464
        /// The header's floor; it grows to the notch's height + 2 so its wings sit beside the notch.
        static let headerHeight: CGFloat = 30
        static let bottomRadius: CGFloat = 20
        static let shoulder: CGFloat = 8
        static let horizontalPadding: CGFloat = 10
        static let bottomPadding: CGFloat = 8
        static let contentWidth: CGFloat = width - 2 * horizontalPadding   // 444
        /// Stream B's Clean usage block (`CleanUsageBlock`) keeps its 80 pt; the island's own block is natural height.
        static let cleanUsageHeight: CGFloat = 80
        static let usageRowHeight: CGFloat = 29
        /// Stream B's block keeps 8; the island's own battery rows sit 6 apart.
        static let usageRowGap: CGFloat = 8
        static let islandUsageRowGap: CGFloat = 6
        static let cleanMoneyGap: CGFloat = 14
        static let visibleRows = 4
        /// Show all: the island stops this far above the display's usable bottom (the Dock's top), and its list, then
        /// scrolling, keeps at least `listFloor` whatever the display.
        static let screenMargin: CGFloat = 24
        static let listFloor: CGFloat = 160
        /// A Clean row: title 16 + status 15, padding 5 above and below.
        static let rowTitleHeight: CGFloat = 16
        static let rowStatusHeight: CGFloat = 15
        static let rowVerticalPadding: CGFloat = 5
        /// The row glyph: Pixel 14 pt (pixel 2) in a 16 pt column, 10 pt before the text. Liquid and Sand draw 20 pt,
        /// centred on the column's 16 pt square and 2 pt past each side of it, so a row keeps its height and layout.
        static let rowGlyphPixel: CGFloat = 2
        static let rowGlyphColumn: CGFloat = 16
        static let rowGlyphEngine: CGFloat = 20
        static let rowGlyphGap: CGFloat = 10
        /// The age column at a row's right ("59m" at 11 pt tabular), so the agent marks before it line up.
        static let rowAgeWidth: CGFloat = 24
        /// The same for a Detailed row's age tag ("59m" at 9.5 pt medium), so its tags line up down the list.
        static let tagAgeWidth: CGFloat = 22
        /// The prototype's notch, for renders and previews only. Live code reads the notch from the screen
        /// (`NotchGeometry`, P37) and never uses these numbers.
        static let referenceNotch = CGSize(width: 185, height: 32)
        static let referenceNotchRadius: CGFloat = 9
        /// The menu bar beside the reference notch (the owner's built-in display: 33 pt), for renders and previews only.
        static let referenceMenuBar: CGFloat = 33
        /// Closed pill: the notch and a wing each side, each only as wide as its own content, no taller than the menu
        /// bar (`NotchGeometry.pillBodyHeight`: the notch + 1, or the menu bar when that is less); bottom radius 12.5,
        /// 3 pt ears. The left wing holds the lead (`pillLeadPadding` each side of it), the right one the count
        /// (`pillCountPadding` each side), and a pill with no count has no right wing, only its ear. With nothing to
        /// show it is the notch itself.
        static let pillLeadPadding: CGFloat = 5
        static let pillCountPadding: CGFloat = 5
        static let pillRadius: CGFloat = 12.5
        static let pillEar: CGFloat = 3
        /// The lead's clearance from the top of the body and from the edge line (or the body's bottom).
        static let pillGlyphMargin: CGFloat = 2.5
        /// Liquid and Sand with Pill edge line on: the line lives in the body's own lowest points (the top bar's too),
        /// so it runs full along both wings and shows under the notch only as its last point, a hairline.
        static let pillEdgeLine: CGFloat = 3
        /// No-notch top bar: as tall as the screen's menu bar (28 at most; 24 when the menu bar cannot be measured),
        /// radius half its height, padding 0 9, glyph then count 7 pt after, fluid width.
        static let topBarHeight: CGFloat = 28
        static let topBarFallbackHeight: CGFloat = 24
        static let topBarPadding: CGFloat = 9
        static let topBarGap: CGFloat = 7
        /// The idle notch's own radius on the surface: at least any real notch's corner, so the idle surface hides
        /// inside the hardware outline.
        static let idleRadius: CGFloat = 12
        /// The swell under the pointer: this much wider in all (shared by the two sides in proportion to their reach)
        /// and at most this much taller, never taller than the pill's body (`SurfaceTargets.swollen`), which ends at the
        /// menu bar's bottom on the owner's display: there it only widens.
        static let swellGrowth = CGSize(width: 6, height: 2)
        /// The island's canvas: its 480 pt and this margin each side.
        static let canvasMargin: CGFloat = 8
        /// Room a growth that may overshoot gets in its panel, each side and below.
        static let motionMargin: CGFloat = 2
        /// The brand glyph and the gear show as the surface widens across this span (`ShoulderGate`).
        static let shoulderGate: ClosedRange<CGFloat> = 410...462
        /// Detailed usage: 4 + 29·2 + 6 [+ 8 + 22·3 money] + 8 (its hover label shows in the header, not in a band).
        /// With money, its grid's rows: three, one more for each two accounts past six (`MoneyGrid`).
        static func detailedUsageHeight(money: Bool, moneyCount: Int = 0) -> CGFloat {
            4 + 29 * 2 + 6 + (money ? 8 + 22 * CGFloat(MoneyGrid.rows(count: moneyCount)) : 0) + 8
        }
    }

    // MARK: Type (size / line height)
    enum TypeScale {
        static let cleanLine2 = Fonts.sys(11)            // 11/17
        static let detailedStatus = Fonts.sys(11)        // 11/18
        static let rowRight = Fonts.num(11, .regular)    // 11/18
        static let toolVerb = Fonts.mono(11)
        static let tag = Fonts.sys(9.5, .medium)         // 9.5/15
        /// The closed pill's count: 12 pt medium, tabular, white (`ClosedPillView.countWidth` measures it in this size
        /// and weight, so the wing fits the count as it draws).
        static let pillCountSize: CGFloat = 12
        static let pillCountWeight = Font.Weight.medium
        static let pillCount = Fonts.num(pillCountSize, pillCountWeight)
        static let hoverSlot = Fonts.sys(11.5)
        static let cardHeader = Fonts.sys(11, .semibold) // 11/18
        static let code = Fonts.mono(12.5)
        static let button = Fonts.sys(12.5, .semibold)
        static let kbd = Fonts.sys(11)
    }
}
