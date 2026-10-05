import SwiftUI

/// Settings › Island › Width and Text size (P401, P402): how wide the opened island is, shoulders included (480 until
/// the owner picks), and how large its session text is (a Clean row's title: 12 until then). Every width the island is
/// laid out at comes from here, never from a fixed number: its surface (`SurfaceTargets.island`), its canvas
/// (`IslandPanelSizing`), its content and header wings (`OpenedIslandView`, `IslandHeaderLayout`), the usage block, the
/// soft edge and the shoulder gate, so the choreography measures and plays any width as it plays 480. The text size
/// steps each row line, the Codex group, the peek and a card's reading text (its header row, message, command, change,
/// question, options and field) by the same points, their line boxes with them, so what the island measures follows;
/// the header, the usage block, the footer and the buttons keep their sizes. `IslandTheme.Metrics`' widths are the
/// standard size's.
struct IslandSize: Equatable, Sendable {
    /// The opened island's width, its 8 pt shoulders included.
    var outer: CGFloat
    /// A Clean row's title size; every other island text it scales steps by as many points.
    var text: CGFloat

    static let standard = IslandSize(outer: 480, text: 12)
    /// The widths Settings › Island offers. 460 is the narrowest whose header wing still holds the brand glyph and the
    /// usage strip's pair beside a 185 pt notch (P401).
    static let widths = [460, 480, 520, 580, 640]
    /// The text sizes it offers: 16 since wave 3 (P1012), as large as a Clean row's lines grow before its card's buttons
    /// and the usage strip, which keep their sizes, look small beside them.
    static let textSizes = [12, 13, 14, 15, 16]

    init(outer: CGFloat, text: CGFloat) {
        self.outer = outer
        self.text = text
    }

    /// The stored choices, each snapped to the nearest step offered: a value written elsewhere never lays the island out
    /// at a size nobody measured.
    init(width: Int, text: Int) {
        self.init(outer: CGFloat(Self.snapped(width, to: Self.widths)), text: CGFloat(Self.snapped(text, to: Self.textSizes)))
    }

    @MainActor init(_ settings: AppSettings) {
        self.init(width: settings.islandWidth, text: settings.islandTextSize)
    }

    static func snapped(_ value: Int, to steps: [Int]) -> Int {
        steps.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    // MARK: Width

    private typealias M = IslandTheme.Metrics

    /// The island between its shoulders (464 at the standard size).
    var width: CGFloat { outer - 2 * M.shoulder }
    /// Its content, between the side paddings (444).
    var contentWidth: CGFloat { width - 2 * M.horizontalPadding }
    /// The still canvas the island is drawn on: its full width and `canvasMargin` each side.
    var canvasWidth: CGFloat { outer + 2 * M.canvasMargin }
    /// The header's brand glyph and gear show as the widening surface crosses this span: from 70 to 18 pt short of the
    /// island's full width (410...462 at 480), so they ride out with the shoulders at every width.
    var shoulderGate: ClosedRange<CGFloat> { Self.shoulderGate(outer: outer) }

    static func shoulderGate(outer: CGFloat) -> ClosedRange<CGFloat> { (outer - 70)...(outer - 18) }

    // MARK: Text

    /// How many points the text is off the standard size.
    var delta: CGFloat { text - Self.standard.text }

    /// Text of `size` pt at the standard size, at this one.
    func text(_ size: CGFloat) -> CGFloat { size + delta }

    /// A line box of `base` pt holding text of `size` pt at the standard size, grown by as much as that text's line
    /// grows here (4/3 of its size, to the point): the Clean title's 16 at 12 pt is 20 at 15.
    func line(_ base: CGFloat, for size: CGFloat) -> CGFloat {
        base + Self.lineHeight(text(size)) - Self.lineHeight(size)
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat { (size * 4 / 3).rounded() }

    /// A width measured for text of `size` pt at the standard size (a column of ages), grown with the text.
    func scaled(_ width: CGFloat, for size: CGFloat) -> CGFloat {
        delta == 0 ? width : (width * text(size) / size).rounded(.up)
    }

    /// A Clean row's two lines.
    var rowTitleHeight: CGFloat { line(M.rowTitleHeight, for: 12) }
    var rowStatusHeight: CGFloat { line(M.rowStatusHeight, for: 11) }
}

extension EnvironmentValues {
    /// The island's width and text size (`IslandSize`): the live island's from Settings, the standard size elsewhere
    /// (the window and the desktop panel draw at theirs).
    @Entry var islandSize = IslandSize.standard
}
