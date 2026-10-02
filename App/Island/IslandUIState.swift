import Observation
import SwiftUI

/// The island's transient state (not persisted), shared by the panel controller and the views.
@MainActor
@Observable
final class IslandUIState {
    /// The surface's target is the island: hit testing and accessibility follow it (set without animation).
    var isOpen = false
    var presentation: IslandPresentation = .list
    /// Header strip placement: the usage block is folded into the header until the strip is clicked (reset when the
    /// island closes or the placement changes).
    var stripOpen = false
    /// The footer pressed ("Show 2 more", "Earlier"): every row, not only the first four.
    var showAll = false
    /// The accounts in use as they were when the island last opened (P812): the strip's battery, the usage block's order
    /// and its dots follow them, so nothing moves under the pointer or while the island moves. Taken again at the next
    /// open; renders set their own.
    var inUse = AccountsInUse.none
    /// The row the keys are on (↑ ↓, Return; `RowSelection`, P321): nil until an arrow is pressed, and again after a close.
    var selectedRow: String?
    /// What the pointer (or focus) rests on in the usage block, after the dwell.
    var hover: HoverTargetID?
    /// `hover` was set by U (P461), not the pointer: its label shows whatever Hover details says (a key press asks for
    /// it), and the pointer resting on a target takes it over.
    var hoverByKey = false
    /// The system-wide key set to Switch sessions opened the island: Return jumps to the keys' row (P462). Until the
    /// island closes.
    var switching = false
    /// Glance: a session finished while "When a session finishes" is Glance; the pill shows a green dot until the
    /// island is next opened.
    var glance = false
    /// A just-finished session's check on the pill (fades after 4 s).
    var recentlyFinished: GlyphPalette.Agent?
    /// Remind again (P410): `FollowUps.pulse` as the pill last heard it; each new value pulses its lead once.
    var pillNudge = 0
    /// The card that shows has a field holding text: a finish never takes its place (P96).
    var cardDraft = false
    /// What the owner typed into cards' fields and has not sent, kept when the island folds (P273). Not observed.
    let drafts = CardDrafts()
    /// The row the pointer rests on, and what its peek shows (P311): memory only, while it shows (`IslandPeeker`).
    var peek: SessionPeek?
    /// The height a peek lacks under the list, added to it while the peek shows (`IslandPeekPlacement`).
    var peekRoom: CGFloat = 0
    /// What the shown peek lies over, in the list's space (`IslandPeekCover`); nil while none shows.
    var peekCover: IslandPeekCover?
    /// Where each list row is, for a peek to hang from (`IslandRowFrames`): read only while a peek shows.
    @ObservationIgnored let rowFrames = IslandRowFrames()
    /// The card that has just come in (`IslandMotion.cardSettle`): it takes no click and no card key yet, so the second
    /// click of a double-click on Yes, or a key meant for the card before it, never answers it unseen (P138).
    var arrivingCard: String?

    // Written by `IslandMotionDirector` only, in its one plain transaction per batch (E5): the target, the pill's
    // snapshot, the glyph clocks and the leaving card as they are; the surface and the content channels in their boxes
    // (`live`), each on the curve the model gave it, which the modifier that draws it scopes to its own effect.

    /// The shape the pointer and clicks are judged against: where the surface is going, not where it is.
    var target = SurfaceGeometry.zero
    /// Reduce Motion as the last transition read it: content crossfades with no blur and no drift.
    var reduceMotion = false
    /// Settings › Island › Motion and Hover, for the little the views draw of it: the parts' drift, the pill's own changes.
    var tuning = MotionTuning()
    /// Diagnostics › Motion › Outline, as the panel draws it (`IslandCanvas`): with Core Animation's the root neither fills
    /// nor clips (no view reads the surface's box), the edge line rides in a layer of its own and the shoulder gate reads
    /// its channel's box. Renders keep SwiftUI's.
    var outline = IslandOutline.swiftUI
    /// Theme Glass on Core Animation's outline: the colour scheme the glass hands the island's content, as the content
    /// reads it (`IslandGlassSchemeReader`), for what is drawn outside the glass: the pill's edge line (`IslandInkScheme`)
    /// and the rim (`IslandCanvas`), which then take the glass's look, not the window's (P568). nil until the glass says.
    var glassScheme: ColorScheme?
    /// What the closed pill shows (a departing pill plays out before this empties).
    var pill = PillContent.empty
    /// The card layer's card, kept through its exit.
    var card: SessionCard?
    /// The card another session's card took the place of, fading out in the leaving layer (P133).
    var leavingCard: SessionCard?
    /// The next card, built ahead while another shows, so taking that one's place builds nothing (P133).
    var aheadCard: SessionCard?
    /// Whether the island's and the pill's glyph clocks run: neither ticks while hidden (P61, P75, P89), nor while its
    /// glyphs come or go out of sight (E2: the island's from its first reveal to the close's start, the pill's from its
    /// return to the open's start).
    var islandLive = false
    var pillLive = true
    /// A stopped clock's glyphs hold where they are (their timelines paused on the frame they drew) rather than draw
    /// their still frames: the live island's, whose clocks stop while a glyph may still be fading out, where a still
    /// frame would jump. Renders keep false, so a stopped clock draws its still frame, the same every run.
    var holdsGlyphs = false

    /// The one black surface and every content group's focus, the glides, the card body's ride and the edge line's lift:
    /// a box each, read only by the small modifiers that draw them (E5), never by the root or the pill's body.
    @ObservationIgnored let live = IslandChannelStore()
    /// Motion: Liquid on SwiftUI's outline: the plan or the still values its clip draws (`LiquidBox`, `LiquidClock`).
    @ObservationIgnored let liquid = LiquidBox()
    /// Motion: Liquid's bud (L2): the card layers ride in the bud below the list from the body's height `budBase` (nil: in
    /// the body), and the pointer and clicks count `budHit` as the island (nil: the target shape alone).
    var budBase: CGFloat?
    var budHit: IslandExtent?
    /// Glass's rim's light where the pointer is (`RimLight`): a box of its own, read by the rim's light alone (E5).
    @ObservationIgnored let rimLight = IslandRimLight()

    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// The one black surface, as last written: as it moves with SwiftUI's outline (the views draw it from
    /// `live.surface`), where it goes with Core Animation's (which no view reads).
    var surface: SurfaceGeometry { live.surface.value }
    /// Every content channel, as last written (the views draw them from `live`).
    var channels: IslandChannels { live.channels }

    /// Sets `values` in the current transaction, each on `motion` (a snap, by default: a true snap, P230). The director
    /// writes them in a plain transaction: one that disables animations would stop the scoped curves and leave a spring in
    /// flight running on (P230).
    func apply(_ values: [Channel: Double], motion: ChannelMotion = .snap) {
        live.write(values, motion)
    }

    init(presentation: IslandPresentation = .list, hover: HoverTargetID? = nil, stripOpen: Bool = false) {
        self.presentation = presentation
        self.hover = hover
        self.stripOpen = stripOpen
    }

    /// An open (P812): a fresh one takes the accounts in use as they are now, before anything of the island shows; a
    /// reverse (the close's reset has not run) keeps the ones in sight. With usage hidden no battery shows, so none are
    /// made.
    func opens(reverse: Bool, env: AppEnvironment) {
        guard !reverse else { return }
        let fresh = env.settings.islandShowsUsage ? env.accountsInUseNow : .none
        if inUse != fresh { inUse = fresh }
    }

    /// Juice's hover timing: 350 ms rest to show, 100 ms to move between targets or to clear.
    func report(_ target: HoverTarget?) {
        hoverTask?.cancel()
        guard let target else { keyHover(nil); return }
        let id = IslandHoverIDs.target(target.id)
        if target.isExit {
            guard hover == id else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.pointerHover(nil)
            }
            return
        }
        let delay = hover == nil ? 350 : 100
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.pointerHover(id)
        }
    }

    /// U's target (P461), at once; nil clears whatever rests (a close, or U past the last battery). A dwell the pointer
    /// started before it is dropped.
    func keyHover(_ id: HoverTargetID?) {
        hoverTask?.cancel()
        if hover != id { hover = id }
        let byKey = id != nil
        if hoverByKey != byKey { hoverByKey = byKey }
    }

    private func pointerHover(_ id: HoverTargetID?) {
        if hover != id { hover = id }
        if hoverByKey { hoverByKey = false }
    }
}

/// The island's content channels as last written (`IslandChannelStore.channels`, whose boxes the views read): each
/// group's focus (0 hidden, 1 shown), the rows' glides, the card body's ride under its row, the edge line's lift and
/// (Core Animation's outline) the shoulders' gate. A part the director has not surfaced is 0, so nothing new ever flashes
/// in; the maps hold only what is not 0.
struct IslandChannels: Equatable, Sendable {
    var pill = 1.0
    var pillArrive = 1.0
    var header = 0.0
    var rimLift: CGFloat = 0
    var cardRide: CGFloat = 0
    /// Core Animation's outline: the header's brand glyph and gear (`Channel.shoulders`).
    var shoulders = 0.0
    var parts: [PartID: Double] = [:]
    var glides: [String: CGFloat] = [:]

    func part(_ id: PartID) -> Double { parts[id] ?? 0 }
    func glide(_ id: String) -> CGFloat { glides[id] ?? 0 }
}
