import SwiftUI

/// What the island panel hosts: one still canvas (`IslandPanelSizing`: the island's width and a margin each side, the
/// display's height tall, hanging from the top edge) holding the island's one pure black surface and, masked by that
/// same shape, the opened island and the closed pill, both always there. The black is the masked canvas's own
/// background, so a frame builds the surface's path once, for the mask (a fill beside it built it twice, E2), read from
/// the surface's box in a modifier of its own (`IslandSurfaceClip`), so the root reads no channel (E5). Nothing
/// is inserted, removed or scaled as it opens and closes: the surface unfolds and folds (`IslandMotionDirector`
/// animates it), the content held in place comes into focus as the surface uncovers it. The pointer and clicks are
/// judged against the target shape, where the surface is going. The canvas never resizes, so it never re-lays anything
/// out; the panel shows as much of it as the surface needs (P36). With Core Animation's outline (Diagnostics › Motion ›
/// Outline, `IslandCanvas`) the root neither fills nor clips: the render server draws the black under it and masks it
/// with the model's plan, and the pill's edge line rides that plan in a layer of its own (`IslandRimView`).
struct IslandRootView: View {
    let ui: IslandUIState
    /// nil: a display without a notch (the top bar).
    var notch: CGSize?
    var canvas: CGSize
    /// The tallest the opened island may be (`IslandPanelSizing.maxIslandHeight`); nil: no limit (renders).
    var maxHeight: CGFloat? = nil
    /// Settings › Island › Width and Text size (`IslandSize`): the panel builds the root again for a new one.
    var size = IslandSize.standard
    var actions: IslandViewActions
    var pillClicked: @MainActor () -> Void
    var measured: @MainActor @Sendable (IslandMeasure) -> Void
    @Environment(\.outlineProbe) private var outlineProbe

    var body: some View {
        // Core Animation's outline reads none of the surface: its values change no view.
        let outside = ui.outline == .coreAnimation
        ZStack(alignment: .notchTop) {
            // What it presents and its cards are read from `ui` where they are drawn (E4).
            OpenedIslandView(notch: notch ?? .zero, ui: ui, actions: actions,
                             live: IslandLive(reduceMotion: ui.reduceMotion, report: measured, maxHeight: maxHeight))
                .modifier(IslandGlyphsStill(ui: ui))
                .fixedSize(horizontal: false, vertical: true)
                // Motion: Refined's soft edge (F6): its content fades into the outline's sides and bottom.
                .modifier(IslandSoftEdge(ui: ui, extent: canvas.height, outer: size.outer))
                // Its own middle, said outright: the stack asks each child for the notch's middle, and a child that
                // has no guide of its own is searched through all its views for one, on every layout (P102).
                .alignmentGuide(.notchCentre) { $0[HorizontalAlignment.center] }
                .allowsHitTesting(ui.isOpen)
                .accessibilityHidden(!ui.isOpen)
            // Its focus, arrival and edge line are read from their boxes inside it (E5): the root reads no channel.
            ClosedPillView(notch: notch, animated: ui.pillLive || ui.holdsGlyphs, content: ui.pill, surface: false,
                           leadFocus: ui.tuning.pillFocus, rides: ui.tuning.pillRides, live: ui.live,
                           parts: outside ? .withoutEdgeLine : .all, nudge: ui.pillNudge)
                .modifier(GlyphsHeld(held: !ui.pillLive && ui.holdsGlyphs))
                .contentShape(Rectangle())
                .onTapGesture { pillClicked() }
                // Snooze (P724): a right-click on the pill mutes for a while.
                .contextMenu { SnoozeMenuItems() }
                .allowsHitTesting(!ui.isOpen)
                .accessibilityHidden(ui.isOpen)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .notchTop)
        // Black: the pure black (nothing with Core Animation's outline); Smoke: the glass, its rim and the notch plate.
        .background { IslandSurfaceBackground(ui: ui, notch: notch, outside: outside) }
        // Black and Smoke: the dark scheme; Glass: the content in the glass, its rim over it (P561).
        .modifier(IslandGlassContent(ui: ui, notch: notch, outside: outside))
        // The same modifier either way, so switching the outline keeps every view below it.
        .modifier(IslandSurfaceClip(surface: ui.live.surface, clips: !outside, continuous: ui.tuning.continuousCorners, probe: outlineProbe,
                                    liquid: ui.tuning.liquid ? ui.liquid : nil))
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        // Motion: Liquid's bud (L2): the card in its bud and the gap above it take clicks too.
        .contentShape(IslandHitShape(geometry: ui.target, hit: ui.budHit))
        .environment(\.islandSize, size)
    }
}

/// Core Animation's outline: the closed pill's edge line alone, where it sits in the whole pill, in a hosting view of its
/// own at the top of the canvas (`IslandCanvas`) whose layer the render server moves down and up with the outline's
/// plan (the edge line's lift, `IslandChoreography.SurfacePlan.rim`), so the line rides the edge exactly as the edge
/// moves, never a late job's frames behind it. Its focus and arrival stay SwiftUI's, as the rest of the pill's. It takes
/// no click and says nothing to VoiceOver: the main root's pill does.
struct IslandRimView: View {
    let ui: IslandUIState
    var notch: CGSize?
    var width: CGFloat
    /// The band at the canvas's top it is laid out in: taller than any pill.
    static let band: CGFloat = 64

    var body: some View {
        ZStack(alignment: .notchTop) {
            // Its focus and arrival from their boxes inside it (E5); its lift is the carrier layer's, never a box's.
            ClosedPillView(notch: notch, animated: ui.pillLive || ui.holdsGlyphs, content: ui.pill, surface: false,
                           live: ui.live, parts: .edgeLineOnly)
                .modifier(GlyphsHeld(held: !ui.pillLive && ui.holdsGlyphs))
        }
        .frame(width: width, height: Self.band, alignment: .notchTop)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .modifier(IslandInkScheme(ui: ui))
    }
}

/// The opened island's glyphs stand still while its clock is off (`IslandUIState.islandLive`: closed, folding away, or
/// opening before its first reveal): held where they are in the live island (`holdsGlyphs`), their still frames in a
/// render. Set in the environment by this small modifier, so an open or a close re-evaluates the glyphs alone; passed
/// down as the island's `animated`, it re-evaluated every row and card, 8 ms in the open's first frame (P102).
private struct IslandGlyphsStill: ViewModifier {
    let ui: IslandUIState

    func body(content: Content) -> some View {
        let stopped = !ui.islandLive, holds = ui.holdsGlyphs
        content
            .environment(\.glyphsStill, stopped && !holds)
            .modifier(GlyphsHeld(held: stopped && holds))
    }
}

/// Glyphs whose clock stopped while they may still be seen hold the frame they drew: their timelines pause, as a hidden
/// surface's do (`glyphMotionPaused`), and a paused timeline draws its last moment again, so nothing jumps (E2).
private struct GlyphsHeld: ViewModifier {
    let held: Bool

    func body(content: Content) -> some View {
        content.transformEnvironment(\.glyphMotionPaused) { if held { $0 = true } }
    }
}
