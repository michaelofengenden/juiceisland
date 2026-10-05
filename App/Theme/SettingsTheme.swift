import AppKit
import SwiftUI

/// The Settings window (prototype.md §1.5, §5.1; CSS `--s-*`), in the look of Settings › General › Appearance (P763):
/// every token is a pair of twins (`Color.adaptive`, resolved in the window's colour scheme), the dark twin today's value
/// exactly, the light one the same role on a light window. Text holds 4.5:1 and marks 3:1 on the window, a group and
/// the sidebar in either look (`SettingsLightTests`), except where the dark twin never did (today's values are kept).
enum SettingsTheme {
    static let window = Color.adaptive(0xF5F5F7, 0x1C1C1E)
    /// The window's own background as AppKit draws it before SwiftUI does.
    static let windowBackground = NSColor.adaptive(light: NSColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1),
                                                   dark: NSColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1))
    static let edge = pair(black: 0.12, white: 0.16)
    /// The full-height sidebar column, a shade off the detail, with a hairline on its right edge.
    static let sidebar = pair(black: 0.035, white: 0.035)
    static let sidebarStroke = pair(black: 0.08, white: 0.08)
    static let itemHover = pair(black: 0.05, white: 0.05)
    static let itemSelected = pair(black: 0.09, white: 0.11)
    /// A group of rows: white on the light window, a veil on the dark one.
    static let group = Color.adaptive(light: .white, dark: Color.white(0.05))
    static let groupStroke = pair(black: 0.07, white: 0.06)
    static let separator = pair(black: 0.08, white: 0.07)
    static let ink = Color.adaptive(0x1D1D1F, 0xEBEBF0)
    static let ink2 = Color.adaptive(0x5E5E63, 0x98989D)
    static let ink3 = Color.adaptive(0x6E6E73, 0x6C6C70)
    static let control = Color.adaptive(0xE3E3E8, 0x3A3A3C)
    static let segmentSelected = Color.adaptive(0xFFFFFF, 0x636366)
    static let accent = Color.adaptive(0x0064D2, 0x0A84FF)
    static let switchOff = Color.adaptive(0xAEAEB2, 0x4A4A4E)
    static let push = Color.adaptive(0xE3E3E8, 0x56565A)
    /// A push button's title: white on the dark push grey, the ink on the light one.
    static let pushInk = Color.adaptive(light: Color(hex: 0x1D1D1F), dark: .white)
    /// A quiet push button's fill.
    static let pushQuiet = pair(black: 0.05, white: 0.07)
    static let destructive = Color.adaptive(0xD1242F, 0xFF4A4A)
    static let popupCircle = pair(black: 0.07, white: 0.10)
    static let statusAmber = Color.adaptive(0xA35A00, 0xFFC16E)
    static let statusRed = Color.adaptive(0xC42B22, 0xFF7C75)
    /// A control's thin edge (a push button's top, a field's border), and a hovered round button.
    static let controlEdge = pair(black: 0.12, white: 0.12)
    static let roundHover = pair(black: 0.12, white: 0.16)
    /// A key cap or a badge's fill.
    static let chip = pair(black: 0.06, white: 0.08)
    /// A text field's ground.
    static let field = Color.adaptive(0xFFFFFF, 0x0F0F11)

    /// The ink at `black` where the window is light, white at `white` where it is dark (`Color.white(_:)`'s twin).
    static func pair(black: Double, white: Double) -> Color {
        .adaptive(light: Color.black.opacity(black), dark: Color.white(white))
    }

    /// Sidebar icon colours per pane.
    enum Icon {
        static let general = Color(hex: 0x98989D)
        static let island = Color(hex: 0x0A84FF)
        static let sound = Color(hex: 0x32D74B)
        static let shortcuts = Color(hex: 0x98989D)
        static let accounts = Color(hex: 0xFFD60A)
        static let money = Color(hex: 0x30D158)
        static let desktopPanel = Color(hex: 0x5E5CE6)
        static let diagnostics = Color(hex: 0x66D4CF)
        static let agents = Color(hex: 0xFF9F0A)
        static let about = Color(hex: 0x0A84FF)
    }

    /// Money source monogram tints (Money pane).
    enum SourceTint {
        static let openRouter = Color(hex: 0x6467F2)
        static let anthropic = Color(hex: 0xB8674A)
        static let runPod = Color(hex: 0x7B4AE2)
        static let hetzner = Color(hex: 0xD50C2D)
        static let deepSeek = Color(hex: 0x3F63E6)
        static let moonshot = Color(hex: 0x15803D)
        static let xAI = Color(hex: 0x55555C)
        static let fireworks = Color(hex: 0xD9681E)
        static let fal = Color(hex: 0xC73A83)
        static let elevenLabs = Color(hex: 0x8A7A1E)
        static let vastAI = Color(hex: 0x14937A)
        static let digitalOcean = Color(hex: 0x0A8FD8)
    }

    enum Metrics {
        static let width: CGFloat = 780
        static let minHeight: CGFloat = 560
        static let defaultHeight: CGFloat = 640
        static let radius: CGFloat = 20
        /// The sidebar column, full height from the top edge; its items start under the traffic lights' line.
        static let sidebarWidth: CGFloat = 200
        static let sidebarPadding: CGFloat = 10
        /// Space between the sidebar's unlabelled groups.
        static let sidebarGroupGap: CGFloat = 12
        /// Where AppKit draws the traffic lights in this window (measured from the offscreen chrome render), for the
        /// headless renders' stand-ins: the close button's left edge, the buttons' diameter and the gap between them.
        static let trafficLight = (x: CGFloat(19), diameter: CGFloat(14), gap: CGFloat(9))
        static let itemHeight: CGFloat = 28
        static let itemRadius: CGFloat = 6
        static let itemIcon: CGFloat = 16
        /// The title line: 52 pt, the height AppKit gives the unified title bar, so the detail's title and the traffic
        /// lights share one centre line. Pane padding 0 22 22.
        static let titleBarHeight: CGFloat = 52
        static let panePadding = EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22)
        static let sectionTop: CGFloat = 20
        /// Under the title line, the sidebar's first item and the pane's first section start at the same height.
        static let firstSectionTop: CGFloat = 4
        static let groupRadius: CGFloat = 10
        static let rowMinHeight: CGFloat = 38
        static let rowPadding = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        static let switchSize = CGSize(width: 32, height: 19)
        static let switchKnob: CGFloat = 15
        static let pushHeight: CGFloat = 22
    }

    enum TypeScale {
        static let title = Fonts.sys(15, .bold)
        static let item = Fonts.sys(13)
        static let sectionHeader = Fonts.sys(13, .bold)
        static let row = Fonts.sys(13)
        static let rowSubtitle = Fonts.sys(11)
        static let footnote = Fonts.sys(11.5)
        static let segment = Fonts.sys(12.5)
    }
}
