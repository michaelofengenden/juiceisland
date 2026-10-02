import AppKit
import SwiftUI

/// The one glyph the closed pill shows: the most urgent state on the board. An approval's "!" before a question's "?",
/// then a failed turn's "×", then the running equalizer, then a finished session's check (bright for the 4 s after it
/// finishes), then a main agent waiting on its subagents in the delegate teal (P370), then a stalled run's equalizer
/// held still (P312: nothing ticks for it, as its row's glyph), then the dim check.
struct PillLead: Hashable {
    var glyph: PixelGlyph
    var agent: GlyphPalette.Agent
    var state: GlyphPalette.State
    var dimmed = false
    /// Drawn at rest: a stalled run's equalizer.
    var still = false

    static func make(rows: [SessionRow], recentlyFinished: GlyphPalette.Agent?) -> PillLead? {
        let waiting = rows.filter { $0.bucket == .needsYou }
        let urgent = [PixelGlyph.bang, .ques, .cross].lazy.compactMap { glyph in waiting.first { $0.glyph == glyph } }.first
        if let row = urgent ?? waiting.first {
            return PillLead(glyph: row.glyph, agent: row.agent, state: .waiting)
        }
        if let row = rows.first(where: { $0.bucket == .running && !$0.isStalled && $0.glyphState != .delegating }) {
            return PillLead(glyph: .eq, agent: row.agent, state: .running)
        }
        if let agent = recentlyFinished { return PillLead(glyph: .check, agent: agent, state: .done) }
        if let row = rows.first(where: { $0.bucket == .running && $0.glyphState == .delegating }) {
            return PillLead(glyph: .agents, agent: row.agent, state: .delegating)
        }
        if let row = rows.first(where: { $0.bucket == .running }) {
            return PillLead(glyph: .eq, agent: row.agent, state: .running, still: true)
        }
        if let row = rows.first(where: { $0.bucket == .done }) {
            return PillLead(glyph: .check, agent: row.agent, state: .done, dimmed: true)
        }
        return nil
    }
}

/// The closed pill over the notch: it hugs the notch and never reaches below the menu bar (its body is the notch + 1
/// tall, or the menu bar's height when that is less). One glyph (`PillLead`, animated) in the left wing and the count
/// (Closed-pill count; Glance's green dot before it) in the right one, each wing only as wide as its own content, so
/// the pill is not symmetric about the notch; with no count there is no right wing at all, only the ear, and with
/// nothing to show it is the notch itself. Pure black, no border or shadow. `notch` nil draws the no-notch top bar (as
/// tall as its menu bar, the glyph then the count, fluid width; a dim brand glyph when idle). A new lead crossfades in
/// over `leadCrossfade`, or with Motion: Refined pulls into focus on `pillIn` (`leadFocus`), not under Reduce Motion
/// and not in renders. Owner: stream D.
///
/// It draws from a `PillContent` (the live island passes its snapshot; renders and tests let it compute one from the
/// environment). The lead is as large as fits the body with `pillGlyphMargin` above and below it: Pixel 17.5 pt (2.5 pt
/// pixels; 14 when that does not fit), Liquid and Sand 28 pt at most (25 over the edge line in the 33 pt pill).
/// Liquid's and Sand's lead keeps one identity as it changes, so the engine morphs from one mood to the next instead of
/// crossfading. With Pill edge line on, the line lives in the body's lowest `pillEdgeLine` points: full along both wings,
/// and under the notch only its last point shows, a hairline joining them (P72). The live island draws the one black
/// surface itself and passes `surface: false`, a reveal (`reveal`, the pill's focus), the arrival slide (`arrive`) and
/// how far the surface has dropped below the pill (`rimLift`, which the edge line rides), each from its box (`live`,
/// E5). With Core Animation's outline the edge line rides in a layer of its own on the outline's plan (`IslandRimView`,
/// `parts`), which lifts it: that one reads no lift.
struct ClosedPillView: View {
    /// What of the pill it draws: all of it, all but the edge line, or the edge line alone in the place it has in the
    /// whole pill (Core Animation's outline moves that one in a layer of its own, `IslandRimView`).
    enum Parts: Equatable { case all, withoutEdgeLine, edgeLineOnly }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// The count, the dots and the lead's colours (P559): Glass's adapt to its look (P562); Black and Smoke draw today's.
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    /// The notch this pill wraps; renders pass `IslandTheme.Metrics.referenceNotch`. nil draws the no-notch top bar.
    var notch: CGSize? = IslandTheme.Metrics.referenceNotch
    var animated = true
    /// Glance: a session finished while the island stayed closed.
    var glance = false
    /// A session that just finished shows its check for 4 s.
    var recentlyFinished: GlyphPalette.Agent?
    /// The screen's menu bar height; nil when it cannot be measured (the notch + 1, or a 24 pt top bar).
    var menuBar: CGFloat?
    /// What to draw; nil computes it from the environment and the values above.
    var content: PillContent?
    /// Draws its own black shape; the live island draws the one surface and masks this.
    var surface = true
    /// The pill's focus (live: 0 while the island is open); nil is fully shown.
    var reveal: Double?
    /// The glyph and count sliding out from behind the notch (live: 0 before a first session's pill arrives).
    var arrive: Double = 1
    /// How far the surface reaches below the pill: the edge line rides it down as it fades.
    var rimLift: CGFloat = 0
    /// Motion: Refined (`MotionTuning.pillFocus`, live only). A new Pixel lead pulls into focus on `pillIn` as the old one
    /// leaves the same way (`LeadFocus`), in place of the 0.25 s crossfade, and the count's digits roll; the snapshot is
    /// written on `pillIn` for them to play.
    var leadFocus = false
    /// Motion: Refined (`MotionTuning.pillRides`, F7, live only): the glyph and the count ride the wings, each keeping
    /// its place against its own side of the outline while the outline is wider than the pill (`WingRide`), so they come
    /// in with the folding wings instead of fading in where the pill will be, and go out with the unfolding ones.
    var rides = false
    /// The live island's channels (E5): its focus, arrival and edge line's lift are read from their boxes in small
    /// modifiers, each on its own curve, and `reveal`, `arrive` and `rimLift` go unused, so a step of any of them
    /// re-evaluates those modifiers and never this body. nil (renders, the standalone pill): the values above.
    var live: IslandChannelStore?
    var parts = Parts.all
    /// Remind again (P410): each new value pulses the lead once (`NudgePulse`); the first drawn plays nothing.
    var nudge = 0
    /// Renders: the pulse drawn at this moment of it; nil plays it live.
    var nudgePhase: TimeInterval? = nil

    /// Pixel's lead: 2.5 pt pixels, 17.5 pt, on the half-point grid (`leadOrigin`) so each pixel is whole on the display.
    static let leadPixel: CGFloat = 2.5
    static let glyphSize: CGFloat = leadPixel * 7
    /// Pixel's lead on a 1× display (a no-notch external monitor; a notch is always on a 2× one): 3 pt pixels, 21 pt,
    /// on the whole-point grid, where 2.5 pt pixels would render soft in every other column.
    static let wholeLeadPixel: CGFloat = 3
    /// The smallest Pixel lead: 2 pt pixels (14 pt), whole at 1× and 2× alike, when the bigger one would not fit.
    static let smallLeadPixel: CGFloat = 2
    /// Liquid and Sand: 28 pt at most; less when the body is shorter (`glyphSide`), so the margins hold on every notch
    /// and over the edge line.
    static let engineGlyphSize: CGFloat = 28
    /// The idle top bar's brand glyph (2 pt pixels).
    static let idleBrandSide: CGFloat = 14
    static let dotSize: CGFloat = 5
    static let dotGap: CGFloat = 4
    /// The update dot after the count (P403): smaller than Glance's and white, no state's colour.
    static let updateDotSize: CGFloat = 4
    /// The snooze's moon after them (P726): a crescent a little wider than Glance's dot, in the dimmer ink, so it reads
    /// as a quiet mark.
    static let snoozeMarkSize: CGFloat = 7
    static let leadCrossfade: TimeInterval = 0.25
    /// The pill's glyph and edge line draw 20 frames a second, not the rows' 30: the pill sits at rest for hours, its
    /// motion stays well under a pixel a frame at 20, and each frame it skips is CPU the owner gets back (P89).
    static let frameInterval: TimeInterval = 1.0 / 20
    /// How far the glyph and count slide out from behind the notch as a first session's pill arrives.
    static let arriveSlide: CGFloat = 18

    /// Liquid's and Sand's lead: as large as fits `room` with `pillGlyphMargin` above and below, 28 pt at most.
    static func glyphSide(_ style: GlyphStyle, room: CGFloat) -> CGFloat {
        guard style != .pixel else { return glyphSize }
        return max(0, min(engineGlyphSize, room - 2 * IslandTheme.Metrics.pillGlyphMargin))
    }

    /// Pixel's lead pixel in `room`: 2.5 pt at 2× and up, 3 pt at 1×, each only when its 7 pixels fit with the margins;
    /// else 2 pt.
    static func leadPixel(room: CGFloat, displayScale: CGFloat) -> CGFloat {
        let preferred = displayScale >= 2 ? leadPixel : wholeLeadPixel
        return preferred * 7 <= room - 2 * IslandTheme.Metrics.pillGlyphMargin ? preferred : smallLeadPixel
    }

    /// Where a lead `side` wide sits in a box `width` × `room`: centred, on the display's pixel grid (half points at
    /// 2×, whole points at 1×; rounded toward the top-left), so Pixel's pixels land on whole display pixels.
    static func leadOrigin(side: CGFloat, width: CGFloat, room: CGFloat, displayScale: CGFloat = 2) -> CGPoint {
        let step: CGFloat = displayScale >= 2 ? 2 : 1
        func grid(_ v: CGFloat) -> CGFloat { max(0, (v * step).rounded(.down) / step) }
        return CGPoint(x: grid((width - side) / 2), y: grid((room - side) / 2))
    }

    /// Who the lead glyph is to SwiftUI: Pixel's is the lead itself, so a new lead crossfades in; Liquid's and Sand's is
    /// the style alone, so one engine view lives on and morphs between moods.
    static func leadIdentity(_ lead: PillLead, style: GlyphStyle) -> AnyHashable {
        style == .pixel ? AnyHashable(lead) : AnyHashable(style)
    }

    /// Whether the edge line is drawn: Liquid or Sand, Pill edge line on, and the pill showing something.
    static func showsEdgeLine(style: GlyphStyle, edgeLine: Bool, showsSomething: Bool) -> Bool {
        style != .pixel && edgeLine && showsSomething
    }

    /// The line runs while any session runs; otherwise it drains away.
    static func edgeLineRuns(rows: [SessionRow]) -> Bool {
        rows.contains { $0.bucket == .running && !$0.isStalled }
    }

    /// The running blue, whatever Glyph colour says: the pill has no text beside its glyph, so its lead and line keep
    /// the state's colours and a needs-you "!" never sits over an agent's colour (P206).
    static let edgeLineColour = IslandTheme.run

    /// The line's colour for `rows`: the running blue while a main agent works, the delegate's teal while the only work
    /// is subagents a main agent waits on (P370), as the lead says.
    static func edgeLineColour(rows: [SessionRow]) -> Color {
        let mainWorks = rows.contains { $0.bucket == .running && !$0.isStalled && $0.glyphState != .delegating }
        return mainWorks || !rows.contains { $0.bucket == .running && $0.glyphState == .delegating } ? edgeLineColour : IslandTheme.delegate
    }

    /// Where the line starts and ends inside the body: where the bottom corners' curve crosses the middle of its band
    /// (on the half-point grid), so the line reaches into the corners and every point of it stays on the black.
    static func edgeLineInset(radius: CGFloat, band: CGFloat) -> CGFloat {
        guard band > 0, radius > band / 2 else { return 0 }
        let rise = radius - band / 2
        return ((radius - (radius * radius - rise * rise).squareRoot()) * 2).rounded(.up) / 2
    }

    /// The line's length in a body `bodyWidth` wide whose bottom corners have `radius`.
    static func edgeLineWidth(bodyWidth: CGFloat, radius: CGFloat, band: CGFloat) -> CGFloat {
        max(0, bodyWidth - 2 * edgeLineInset(radius: radius, band: band))
    }

    /// How much of the line shows from each end before the notch hides all but its last point: the two wings, less the
    /// inset (the whole line in the top bar).
    static func edgeLineEnds(_ content: PillContent) -> RimEnds {
        let radius = content.topBar ? content.bodyHeight / 2 : IslandTheme.Metrics.pillRadius
        let inset = edgeLineInset(radius: radius, band: content.edgeLine)
        let width = edgeLineWidth(bodyWidth: content.bodyWidth, radius: radius, band: content.edgeLine)
        guard content.notch != nil else { return RimEnds(left: width, right: width) }
        return RimEnds(left: max(0, content.leftWing - inset), right: max(0, content.rightWing - inset))
    }

    /// The count's width in the pill's type (`IslandTheme.TypeScale.pillCount`: 12 pt medium, tabular digits).
    @MainActor static func countWidth(_ count: Int) -> CGFloat {
        let type = IslandTheme.TypeScale.self
        let font = NSFont.monospacedDigitSystemFont(ofSize: type.pillCountSize, weight: NSFont.Weight(type.pillCountWeight))
        return ceil(NSAttributedString(string: "\(count)", attributes: [.font: font]).size().width)
    }

    var body: some View {
        let pill = content ?? PillContent.make(rows: env.sessions.rows, settings: env.settings, glance: glance,
                                               recentlyFinished: recentlyFinished, now: env.sessions.now, notch: notch,
                                               menuBar: menuBar, displayScale: displayScale)
        Group {
            if let notch = pill.notch {
                notchPill(pill, notch: notch)
            } else {
                topBar(pill)
            }
        }
        .environment(\.glyphFrameInterval, Self.frameInterval)
        // Placed by its notch, not its middle: the pill is not symmetric about the notch.
        .alignmentGuide(.notchCentre) { _ in pill.extent.left }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(lead: pill.lead, count: pill.count, glance: pill.glance, update: pill.update,
                                              snoozed: pill.snoozed))
    }

    /// The lead, `side` wide (Pixel's in `pixel` pt pixels), placed by `leadOrigin` in a box `width` × `room`.
    private func glyph(_ pill: PillContent, width: CGFloat) -> some View {
        let side = pill.glyphSide, lead = pill.lead
        let origin = Self.leadOrigin(side: side, width: width, room: pill.room, displayScale: displayScale)
        return ZStack {
            if let lead {
                // By state always (P206): the pill's lead is the one glyph with nothing beside it to say whose it is.
                let colour = GlyphPalette.glyph(agent: lead.agent, state: lead.state, mode: .byState, needsYou: needsYou)
                StateGlyphView(glyph: lead.glyph, colour: colour, pixel: pill.leadPixel, dimmed: lead.dimmed, glow: !lead.dimmed,
                               animated: animated && !lead.still, style: pill.style, engineSide: side)
                    .id(Self.leadIdentity(lead, style: pill.style))
                    .transition(leadFocus && pill.style == .pixel ? AnyTransition(LeadFocus()) : .opacity)
            }
        }
        .modifier(NudgePulse(trigger: nudge, reduceMotion: reduceMotion, phase: nudgePhase))
        .frame(width: side, height: side)
        .animation(animated && !reduceMotion && lead != nil ? (leadFocus ? IslandMotion.pillIn.animation : .easeInOut(duration: Self.leadCrossfade))
            : nil, value: lead)
        .padding(.leading, origin.x)
        .padding(.top, origin.y)
        .frame(width: width, height: pill.room, alignment: .topLeading)
    }

    /// The edge line along the bottom of the body, `pill.edgeLine` tall, from corner to corner. It arrives and leaves
    /// with the glyph and the count (`arrive`), so the last session's line is gone before the pill's snapshot empties.
    private func edgeLine(_ pill: PillContent, radius: CGFloat) -> some View {
        PillRimView(style: pill.style, running: pill.edgeRuns, colour: palette.tone(pill.edgeColour),
                    width: Self.edgeLineWidth(bodyWidth: pill.bodyWidth, radius: radius, band: pill.edgeLine),
                    height: pill.edgeLine, ends: Self.edgeLineEnds(pill), animated: animated)
            .modifier(PillEdgeChannels(live: live, arrive: arrive, reveal: reveal, rimLift: rimLift, lifts: parts != .edgeLineOnly))
    }

    @ViewBuilder private func countView(_ pill: PillContent) -> some View {
        HStack(spacing: Self.dotGap) {
            if pill.glance {
                Circle().fill(palette.tone(IslandTheme.done)).frame(width: Self.dotSize, height: Self.dotSize)
            }
            if let count = pill.count {
                if leadFocus {
                    Text(verbatim: "\(count)").font(IslandTheme.TypeScale.pillCount).foregroundStyle(palette.pillCount).fixedSize()
                        .contentTransition(.numericText(value: Double(count)))
                } else {
                    Text(verbatim: "\(count)").font(IslandTheme.TypeScale.pillCount).foregroundStyle(palette.pillCount).fixedSize()
                }
            }
            if pill.update {
                Circle().fill(palette.ink).frame(width: Self.updateDotSize, height: Self.updateDotSize)
            }
            if pill.snoozed {
                SnoozeMoon().fill(palette.ink2).frame(width: Self.snoozeMarkSize, height: Self.snoozeMarkSize)
            }
        }
    }

    @ViewBuilder private func notchPill(_ pill: PillContent, notch: CGSize) -> some View {
        let ear = IslandTheme.Metrics.pillEar
        if pill.isEmpty {
            // Idle: the surface is the notch itself, hidden in the hardware.
            let idle = SurfaceGeometry(width: notch.width, height: notch.height, ear: 0, radius: IslandTheme.Metrics.idleRadius)
            NotchSurfaceShape(geometry: idle).fill(surface ? IslandTheme.bg : .clear).frame(width: notch.width, height: notch.height)
        } else {
            let slide = Self.arriveSlide * (1 - arrive)
            HStack(spacing: 0) {
                if parts == .edgeLineOnly {
                    // The wings' room alone, so the line sits exactly where it does under the whole pill.
                    Color.clear.frame(width: pill.leftWing, height: pill.room)
                } else {
                    glyph(pill, width: pill.leftWing).modifier(PillSlide(live: live, slide: slide, sign: 1))
                        .modifier(WingRide(surface: rides ? live?.surface : nil, rest: pill.extent.left, side: -1))
                }
                Color.clear.frame(width: notch.width, height: pill.room)
                if parts == .edgeLineOnly {
                    Color.clear.frame(width: pill.rightWing, height: pill.room)
                } else {
                    countView(pill).frame(width: pill.rightWing, height: pill.room).modifier(PillSlide(live: live, slide: slide, sign: -1))
                        .modifier(WingRide(surface: rides ? live?.surface : nil, rest: pill.extent.right, side: 1))
                }
            }
            // The edge line's own canvas draws nothing here: no channel of its empty wings moves in a frame (P302).
            .modifier(PillChannels(live: parts == .edgeLineOnly ? nil : live, arrive: arrive, reveal: reveal, still: parts == .edgeLineOnly))
            // Nothing of the glyph or the count is drawn over the notch, even as they slide out from behind it (P37).
            .clipShape(NotchCut(notchMinX: pill.leftWing, notch: notch), style: FillStyle(eoFill: true))
            .frame(height: pill.bodyHeight, alignment: .top)
            .overlay(alignment: .bottom) {
                if pill.showsEdgeLine, parts != .withoutEdgeLine {
                    // Solid: the line passes under the notch plate (P797). Core Animation's outline cuts the line's carrier
                    // instead, which its lift does not move (`IslandCanvas`); here the cut is outside the lift too.
                    edgeLine(pill, radius: IslandTheme.Metrics.pillRadius)
                        .modifier(PlateCut(notch: theme == .solid && parts == .all ? notch : nil, notchMinX: pill.leftWing))
                }
            }
            .padding(.horizontal, ear)
            .background { if surface { PillShape().fill(IslandTheme.bg) } }
            // The glyph's glow and the line's ends stay on the black, as the live surface's mask keeps them there.
            .modifier(ClipToPill(topBar: false, enabled: surface))
        }
    }

    private func topBar(_ pill: PillContent) -> some View {
        HStack(spacing: IslandTheme.Metrics.topBarGap) {
            if parts == .edgeLineOnly {
                Color.clear.frame(width: 1, height: 1)
            } else if pill.lead == nil {
                // Without a notch there is nothing to hover but the bar: idle keeps a dim brand glyph.
                PixelGlyphView(glyph: .brand, colour: palette.topBarIdle, pixel: 2, dimmed: true, glow: false, animated: false)
            } else {
                glyph(pill, width: pill.glyphSide).modifier(WingRide(surface: rides ? live?.surface : nil, rest: pill.extent.left, side: -1))
            }
            if pill.showsCount, parts != .edgeLineOnly {
                countView(pill).modifier(WingRide(surface: rides ? live?.surface : nil, rest: pill.extent.right, side: 1))
            }
        }
        // No slide without a notch: the brand glyph and the lead crossfade as the bar resizes.
        .modifier(PillChannels(live: parts == .edgeLineOnly ? nil : live, arrive: arrive, reveal: reveal, still: parts == .edgeLineOnly))
        .frame(width: pill.barWidth, height: pill.room)
        .frame(height: pill.bodyHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            if pill.showsEdgeLine, parts != .withoutEdgeLine { edgeLine(pill, radius: pill.bodyHeight / 2) }
        }
        .background { if surface { PillShape(topBar: true).fill(IslandTheme.bg) } }
        .modifier(ClipToPill(topBar: true, enabled: surface))
    }

    /// What VoiceOver reads, from the pill as drawn (the live island sets no `glance` of its own: its snapshot has it).
    private func accessibilityText(lead: PillLead?, count: Int?, glance: Bool, update: Bool, snoozed: Bool) -> String {
        var parts: [String] = []
        switch lead?.state {
        case .waiting:
            parts.append(lead?.glyph == .ques ? "A question is waiting" : lead?.glyph == .cross ? "A turn failed" : "An approval is waiting")
        case .running: parts.append("Running")
        case .delegating: parts.append("Waiting on agents")
        case .done: parts.append("Done")
        case .idle, nil: parts.append(Product.name)
        }
        if glance { parts.append("a session finished") }
        if let count { parts.append(PillSummary.spoken(count, mode: env.settings.closedPillCount)) }
        if update { parts.append("an update is ready") }
        if snoozed { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// The snooze's mark (P726): a crescent moon, a disc less a disc set up and to the right of it, so it draws as one fill
/// with no stroke and reads at 7 pt.
struct SnoozeMoon: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = rect.width * 0.78
        return Path(ellipseIn: rect)
            .subtracting(Path(ellipseIn: CGRect(x: rect.maxX - cut * 0.82, y: rect.minY - cut * 0.22, width: cut, height: cut)))
    }
}

/// Motion: Refined. The Pixel lead's change as a focus pull: the new lead comes in from a 2 pt blur as the old one goes
/// into it, both fading, on the transaction's curve (`pillIn`). At rest it applies nothing, so the pill draws exactly
/// as it does without it and adds no compositing pass to the glyph's frames.
struct LeadFocus: Transition {
    static let blur: CGFloat = 2

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : Self.blur)
    }
}

/// The glyph or the count sliding out from behind the notch: from the live island's `pillArrive` box on its own curve,
/// or by `slide` (renders).
private struct PillSlide: ViewModifier {
    var live: IslandChannelStore?
    var slide: CGFloat
    var sign: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if let live {
            content.modifier(ChannelOffset(box: live.pillArrive, axis: .horizontal, sign: sign, inverse: ClosedPillView.arriveSlide))
        } else {
            content.offset(x: sign * slide)
        }
    }
}

/// Motion: Refined (F7). The glyph (`side` -1) or the count (+1) rides its wing: moved out by as much as the live
/// outline reaches past the closed pill's `rest` on its side, read from the surface's box on the width's curve, so it
/// keeps its place against the moving side; at or inside the pill (at rest, a first session's wings coming out from
/// behind the notch, the last one's tucking in) it is where the pill has it. A geometry effect: no body a frame. nil: none.
struct WingRide: ViewModifier {
    var surface: SurfaceBox?
    var rest: CGFloat
    var side: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if let surface {
            let reach = side < 0 ? surface.value.left : surface.value.right
            content.animation(surface.widthMotion.animation) { $0.modifier(RideOffset(reach: reach, rest: rest, side: side)) }
        } else {
            content
        }
    }
}

/// `WingRide`'s translation: `side × max(0, reach − rest)`, the reach moving on the width's curve.
nonisolated struct RideOffset: GeometryEffect {
    var reach: CGFloat
    var rest: CGFloat
    var side: CGFloat

    var animatableData: CGFloat {
        get { reach }
        set { reach = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: side * max(0, reach - rest), y: 0))
    }
}

/// The glyph and the count's arrival (opacity and a soft 2 pt blur) and the pill's focus: from the live island's
/// `pillArrive` and `pill` boxes, each on its own curve, or from the values (renders), drawn alike.
private struct PillChannels: ViewModifier {
    var live: IslandChannelStore?
    var arrive: Double
    var reveal: Double?
    /// Nothing to show (the edge line's own canvas, whose wings are empty): the content as it is.
    var still = false

    @ViewBuilder func body(content: Content) -> some View {
        if still {
            content
        } else if let live {
            let arriving = live.pillArrive.value, focus = live.pill.value
            content
                .animation(live.pillArrive.motion.animation) { $0.opacity(arriving).blur(radius: 2 * (1 - arriving)) }
                .animation(live.pill.motion.animation) { $0.modifier(FocusReveal(p: focus, blur: 3, drift: 0)) }
        } else {
            content.opacity(arrive).blur(radius: 2 * (1 - arrive)).focusReveal(reveal, blur: 3)
        }
    }
}

/// The edge line's arrival (opacity), the pill's focus and the line's lift as the surface reaches below the pill: from
/// the live island's boxes, each on its own curve, or from the values (renders), drawn alike.
private struct PillEdgeChannels: ViewModifier {
    var live: IslandChannelStore?
    var arrive: Double
    var reveal: Double?
    var rimLift: CGFloat
    /// false: Core Animation's outline lifts the line (`IslandRimView`'s carrier layer), so no lift box is read.
    var lifts = true

    @ViewBuilder func body(content: Content) -> some View {
        if let live {
            let arriving = live.pillArrive.value, focus = live.pill.value, lift = lifts ? CGFloat(live.rimLift.value) : 0
            content
                .animation(live.pillArrive.motion.animation) { $0.opacity(arriving) }
                .animation(live.pill.motion.animation) { $0.modifier(FocusReveal(p: focus, blur: 3, drift: 0)) }
                .animation(lifts ? live.rimLift.motion.animation : nil) { $0.modifier(ScopedOffset(y: lift)) }
        } else {
            content.opacity(arrive).focusReveal(reveal, blur: 3).offset(y: rimLift)
        }
    }
}

/// Solid's plate cut out of the edge line, in the pill's own space so it stays where the notch is as the line rides
/// down (`SolidNotchPlateCut`, P797). nil: nothing cut, the line drawn as it always was.
private struct PlateCut: ViewModifier {
    var notch: CGSize?
    var notchMinX: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if let notch {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipShape(SolidNotchPlateCut(notchMinX: notchMinX, notch: notch), style: FillStyle(eoFill: true))
        } else {
            content
        }
    }
}

/// The standalone pill clips to its own shape; the live one is masked by the island's surface instead.
private struct ClipToPill: ViewModifier {
    var topBar: Bool
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.clipShape(PillShape(topBar: topBar)) } else { content }
    }
}

extension HorizontalAlignment {
    private enum NotchCentre: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[HorizontalAlignment.center] }
    }

    /// The notch's middle: the closed pill aligns by it (its wings differ), everything else by its own middle.
    static let notchCentre = HorizontalAlignment(NotchCentre.self)
}

extension Alignment {
    /// Top, on the notch's middle.
    static let notchTop = Alignment(horizontal: .notchCentre, vertical: .top)
}
