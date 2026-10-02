import SwiftUI

/// What the closed pill shows, as a value the panel computes from the sessions, Settings and the display: the lead, the
/// count, the Glance dot, the two wings, the edge line and the no-notch bar, all with no layout. The pill draws from it
/// (`ClosedPillView(content:)`), so a departing glyph plays out after the last session has gone, and the motion sizes
/// the surface and the panel from it.
///
/// The pill hugs the notch and stays inside the menu bar: its body is the notch + 1 tall, or the menu bar's height when
/// that is less. The left wing is the lead and `pillLeadPadding` each side of it; the right wing is the count (and
/// Glance's dot) and `pillCountPadding` each side, as narrow as the digits allow, and none at all with no count, so the
/// pill reaches as little as it can toward the status items on the right. It is not symmetric about the notch: `extent`
/// is its reach either side of the notch's middle, ears included.
struct PillContent: Equatable, Sendable {
    var lead: PillLead?
    var count: Int?
    var glance: Bool
    /// An update waits (P403): a small dot after the count, only on a pill that shows something else.
    var update = false
    /// A snooze is set (P726): a small moon after the count (and the update dot), only on a pill that shows something else.
    var snoozed = false
    var style: GlyphStyle
    /// nil: the no-notch top bar.
    var notch: CGSize?
    /// The body (or the bar): never below the menu bar.
    var bodyHeight: CGFloat
    /// The edge line's band in the body's lowest points (`pillEdgeLine`); 0 without the line.
    var edgeLine: CGFloat = 0
    /// The lead's square: Pixel's 7 pixels, Liquid's and Sand's engine side.
    var glyphSide: CGFloat = 0
    /// Pixel's pixel.
    var leadPixel: CGFloat = 2.5
    /// The lead's wing, left of the notch (0 with no lead).
    var leftWing: CGFloat = 0
    /// The count's wing, right of the notch (0 with no count and no dot).
    var rightWing: CGFloat = 0
    /// The Glance dot, the gap, the count (`ClosedPillView.countWidth`), the update dot after a gap, the snooze's moon
    /// after another.
    var countBlockWidth: CGFloat = 0
    /// The no-notch bar: padding, the lead (or the idle brand glyph), the count after a gap, padding.
    var barWidth: CGFloat = 0
    /// The edge line runs (any session running) or has drained.
    var edgeRuns = false
    var edgeColour: Color = .clear
    /// The display's scale, for the lead's pixel grid.
    var displayScale: CGFloat = 2

    static let empty = PillContent(lead: nil, count: nil, glance: false, style: .pixel, notch: nil, bodyHeight: 0)

    /// Nothing to show: the notch alone, or the top bar's dim brand glyph.
    var isEmpty: Bool { lead == nil && count == nil && !glance }
    var topBar: Bool { notch == nil }
    var showsEdgeLine: Bool { edgeLine > 0 }
    var showsCount: Bool { count != nil || glance || update || snoozed }
    /// The height the lead and the count centre in: the body above the edge line.
    var room: CGFloat { bodyHeight - edgeLine }

    /// The pill's reach either side of the notch's middle (the bar's middle without one) and its height, ears
    /// included: exactly what the surface and the panel take at rest. With nothing to show, the notch itself (or the
    /// idle bar).
    var extent: IslandExtent {
        guard let notch else { return IslandExtent(width: barWidth, height: bodyHeight) }
        if isEmpty { return IslandExtent(width: notch.width, height: notch.height) }
        let ear = IslandTheme.Metrics.pillEar
        return IslandExtent(left: notch.width / 2 + leftWing + ear, right: notch.width / 2 + rightWing + ear, height: bodyHeight)
    }

    /// The body without its ears: the wings and the notch between them (the bar without a notch).
    var bodyWidth: CGFloat { notch.map { leftWing + $0.width + rightWing } ?? barWidth }

    /// The pill for `rows` in Settings' style, count and colours, on a display with `notch` (nil: the top bar) whose
    /// menu bar is `menuBar` tall (nil: not measured). With Hide the pill when idle on and no session active
    /// (`SessionActivity`, read on the models' minute clock), it has nothing to show, so the closed pill tucks away and
    /// the panel orders out; hours of finished rows no longer keep it up (P94). `fullScreen`: the frontmost app is in full
    /// screen on the pill's display; with Hide in full screen on, the pill has nothing to show, or with Show needs you
    /// only what needs you: its glyph and how many wait, never a running glyph, a count of the rest or Glance's dot
    /// (P330).
    /// `update`: an update waits; with Update dot on the pill on, a pill that shows something else shows its dot too
    /// (never an idle, hidden or full-screen one, P403). A snooze's moon (P726) joins a pill that shows something the same
    /// way.
    @MainActor static func make(rows: [SessionRow], settings: AppSettings, glance: Bool, recentlyFinished: GlyphPalette.Agent?,
                                now: Date, notch: CGSize?, menuBar: CGFloat?, displayScale: CGFloat = 2,
                                fullScreen: Bool = false, update: Bool = false) -> PillContent {
        // A scripted run or a subagent's thread tells the pill nothing unless its card waits (P254).
        let rows = rows.filter(\.tells)
        if fullScreen, settings.hideInFullScreen {
            let waiting = settings.fullScreenShowsNeedsYou ? rows.filter { $0.bucket == .needsYou } : []
            return make(lead: PillLead.make(rows: waiting, recentlyFinished: nil), count: waiting.isEmpty ? nil : waiting.count,
                        glance: false, style: settings.glyphStyle, edgeLine: settings.glyphEdgeLine,
                        notch: notch, menuBar: menuBar, displayScale: displayScale)
        }
        if settings.hidePillWhenIdle, SessionActivity.isIdle(rows, now: now) {
            return make(lead: nil, count: nil, glance: false, style: settings.glyphStyle, edgeLine: settings.glyphEdgeLine,
                        notch: notch, menuBar: menuBar, displayScale: displayScale)
        }
        let count = PillSummary.make(rows: rows, countMode: settings.closedPillCount, now: now).count
        let lead = PillLead.make(rows: rows, recentlyFinished: recentlyFinished)
        return make(lead: lead, count: count, glance: glance, update: update && settings.pillUpdateDot, snoozed: settings.snoozedUntil != nil,
                    style: settings.glyphStyle,
                    edgeLine: settings.glyphEdgeLine, edgeRuns: ClosedPillView.edgeLineRuns(rows: rows),
                    edgeColour: ClosedPillView.edgeLineColour(rows: rows), notch: notch, menuBar: menuBar, displayScale: displayScale)
    }

    @MainActor static func make(lead: PillLead?, count: Int?, glance: Bool, update: Bool = false, snoozed: Bool = false, style: GlyphStyle,
                                edgeLine: Bool,
                                edgeRuns: Bool = false, edgeColour: Color = .clear,
                                notch: CGSize?, menuBar: CGFloat?, displayScale: CGFloat = 2) -> PillContent {
        let m = IslandTheme.Metrics.self
        // The dot joins what the pill shows; alone it would widen an idle notch for news that can wait.
        let update = update && (lead != nil || count != nil || glance)
        let snoozed = snoozed && (lead != nil || count != nil || glance)
        var content = PillContent(lead: lead, count: count, glance: glance, update: update, snoozed: snoozed, style: style, notch: notch,
                                  bodyHeight: 0, edgeRuns: edgeRuns, edgeColour: edgeColour, displayScale: displayScale)
        let showsLine = ClosedPillView.showsEdgeLine(style: style, edgeLine: edgeLine, showsSomething: !content.isEmpty)
        content.edgeLine = showsLine ? m.pillEdgeLine : 0
        content.bodyHeight = notch.map { NotchGeometry.pillBodyHeight(notch: $0, menuBar: menuBar) } ?? NotchGeometry.topBarHeight(menuBar: menuBar)
        // A notch is always on a 2× display; only the top bar may be on a 1× one.
        content.leadPixel = ClosedPillView.leadPixel(room: content.room, displayScale: notch == nil ? displayScale : 2)
        content.glyphSide = style == .pixel ? content.leadPixel * 7 : ClosedPillView.glyphSide(style, room: content.room)
        content.countBlockWidth = (glance ? ClosedPillView.dotSize : 0) + (glance && count != nil ? ClosedPillView.dotGap : 0)
            + (count.map { ClosedPillView.countWidth($0) } ?? 0)
            + (update ? (glance || count != nil ? ClosedPillView.dotGap : 0) + ClosedPillView.updateDotSize : 0)
            + (snoozed ? (glance || count != nil || update ? ClosedPillView.dotGap : 0) + ClosedPillView.snoozeMarkSize : 0)
        if notch != nil {
            content.leftWing = lead == nil ? 0 : ((content.glyphSide + 2 * m.pillLeadPadding) * 2).rounded(.up) / 2
            content.rightWing = content.showsCount ? ceil(content.countBlockWidth + 2 * m.pillCountPadding) : 0
        }
        let glyph = lead == nil ? ClosedPillView.idleBrandSide : content.glyphSide
        let trailing = content.showsCount ? m.topBarGap + content.countBlockWidth : 0
        content.barWidth = m.topBarPadding + glyph + trailing + m.topBarPadding
        return content
    }
}
