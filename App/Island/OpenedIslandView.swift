import SwiftUI

/// What the opened island shows: the list, or the card of one session.
enum IslandPresentation: Equatable, Sendable {
    case list
    case card(sessionID: String)
}

/// Where the usage shows in the opened island: the header strip (Header strip placement, folded) or the block under
/// the header (Section placement, or the strip clicked open), never both, so no battery shows twice. While a card shows
/// the block goes, and in Header strip placement the strip stays in the header, so the header never changes under the
/// card; with usage off, neither.
struct IslandUsageFold: Equatable {
    var strip: Bool
    var block: Bool

    init(listing: Bool, showsUsage: Bool, placement: UsagePlacement, stripOpen: Bool) {
        let folding = placement == .headerStrip
        strip = showsUsage && folding && (!stripOpen || !listing)
        block = listing && showsUsage && (!folding || stripOpen)
    }
}

/// What the live island passes the opened island's view: Reduce Motion, where its measurements go and how tall it may
/// be. Every group's focus, glide and ride, the surface's width for the shoulder gate, what it presents and its card
/// layers' cards are read from the island's state where they are drawn (`IslandChannelReveal`, `IslandShoulderGate`,
/// `IslandLiveHeader`, `IslandCardStack`), never passed as values: a value that moves on every step would re-evaluate the
/// whole list or card each step (P102), and a card that comes in, goes or changes its role re-evaluates the card layers
/// alone, never the header and the list (E4).
struct IslandLive {
    var reduceMotion: Bool
    var report: @MainActor @Sendable (IslandMeasure) -> Void
    /// The tallest the island may be on its display (`IslandPanelSizing.maxIslandHeight`); nil: no limit.
    var maxHeight: CGFloat? = nil
}

/// One card layer of the live island, keyed by its session, so a card keeps its views (and its half-typed reply) from
/// being built ahead, through showing, to leaving for another.
struct IslandCardLayer: Identifiable {
    var card: SessionCard
    var role: CardReveal.Role
    var id: String { card.sessionID }

    /// The card layers bottom to top, one per session: the leaving card, the one showing, the one built ahead. The one
    /// built ahead is out of focus and takes no clicks, so where it sits never shows; on top, it keeps its place as it
    /// takes the showing one's, and the showing one keeps its own as it leaves, so the swap moves no layer (E4: a layer
    /// that moved took its views out and back in).
    static func stack(card: SessionCard?, leaving: SessionCard?, ahead: SessionCard?) -> [IslandCardLayer] {
        var layers: [IslandCardLayer] = []
        if let leaving, leaving.sessionID != card?.sessionID { layers.append(IslandCardLayer(card: leaving, role: .leaving)) }
        if let card { layers.append(IslandCardLayer(card: card, role: .live)) }
        if let ahead, ahead.sessionID != card?.sessionID, ahead.sessionID != leaving?.sessionID {
            layers.append(IslandCardLayer(card: ahead, role: .ahead))
        }
        return layers
    }

    /// The role `stack` gives `id`'s layer: the showing card's, else the leaving one's, else built ahead.
    static func role(of id: String, card: SessionCard?, leaving: SessionCard?) -> CardReveal.Role {
        if card?.sessionID == id { return .live }
        if leaving?.sessionID == id { return .leaving }
        return .ahead
    }

    /// A card takes clicks only while it shows (not built ahead, not leaving, P133) and once it has come in: the second
    /// click of a double-click on the card it replaced never answers it (P138).
    static func takesClicks(_ id: String, role: CardReveal.Role, presentation: IslandPresentation, arriving: String?) -> Bool {
        role == .live && presentation == .card(sessionID: id) && arriving != id
    }
}

/// A measurement of the live island's content, in the island's coordinates (`OpenedIslandView.space`).
enum IslandMeasure: Equatable, Sendable {
    case header(CGFloat)
    case list(CGFloat)
    case card(String, CGFloat)
    /// A part's frame; nil when it went away. `owner` names the view that reported it (0: the only one it ever has):
    /// a part's views can be replaced in one update, and the old one's going must never take away the frame the new
    /// one reported, in whichever order the two arrive.
    case part(PartID, CGRect?, owner: Int = 0)
    /// A list row's top inset and where a card's header row starts under the header: a tapped row glides by these.
    case insets(row: CGFloat, card: CGFloat)
    /// The rows Show all builds only as the list scrolls to them (`IslandListLayout.eagerCount`, P400).
    case lazyRows(Set<String>)
}

/// The opened island (464 wide plus 8 pt shoulders at the standard width, `IslandSize`; bottom radius 20, pure black:
/// no shadow, rule or grey card): Clean (default) or Detailed per `settings.islandStyle`; the header in the notch's own
/// row, the usage block (hidden while a card shows; in Header strip placement, folded into the header's two pairs until
/// one is clicked, then in their place until it is clicked or the island closes), four compact rows, the footer; cards
/// through `SessionCardView`. Nothing is drawn inside the notch. Owner: stream D.
///
/// Standalone (renders, `live` nil) it draws its own shape and only the layer that shows (`presentation`). Live, the
/// island's one surface masks it: it is laid out once at its final size and never scaled; the header group, the list
/// layer (always there, frozen while hidden) and the card layers (while a card shows, leaves or is built ahead) each
/// come into focus by their own channel, read from `ui` where it is drawn, as is what it presents (`ui.presentation`);
/// rows glide by render offsets, and every part reports its home slot for the choreography.
struct OpenedIslandView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    /// Settings › Island › Width and Text size (P401, P402).
    @Environment(\.islandSize) private var size
    var presentation: IslandPresentation = .list
    var notch: CGSize = IslandTheme.Metrics.referenceNotch
    /// Transient state (hover, strip, Show all); the panel passes its own, renders a configured one.
    var ui = IslandUIState()
    /// The header group's height as last laid out: the list may take what the display leaves under it.
    @State private var headerHeight = IslandTheme.Metrics.headerHeight
    var animated = true
    var actions = IslandViewActions()
    /// The live island's channels; nil draws the standalone island.
    var live: IslandLive?

    /// The coordinate space part frames are measured in: the island's own, from its top-left corner.
    nonisolated static let space = "island.layer"

    var body: some View {
        if let live { liveBody(live) } else { standaloneBody }
    }

    @ViewBuilder private var standaloneBody: some View {
        let settings = env.settings
        let card = cardShown
        let listing = card == nil
        let folding = settings.islandUsagePlacement == .headerStrip
        let usage = IslandUsageFold(listing: listing, showsUsage: settings.islandShowsUsage,
                                    placement: settings.islandUsagePlacement, stripOpen: ui.stripOpen)
        let strip = usage.strip
        let section = usage.block
        VStack(spacing: 0) {
            IslandHeaderView(layout: IslandHeaderLayout(notch: notch, contentWidth: size.contentWidth), strip: strip, hover: ui.hover,
                             hoverByKey: ui.hoverByKey,
                             animated: animated, actions: actions, inUse: ui.inUse)
            IslandJumpNote()
            HookDriftRows(size: .island)
            WhatsNewCard(size: .island)
            NewAgentsLine(size: .island)
            if section {
                Group {
                    if settings.islandStyle == .clean { CleanUsageView(hover: ui.hover, inUse: ui.inUse) } else {
                        DetailedUsageView(hover: ui.hover, inUse: ui.inUse)
                    }
                }
                .environment(\.hoverReporter) { [ui] target in ui.report(target) }
                .contextMenu { UsageBackgroundMenuItems(showing: .island) }
                // Opened from the header strip, the block replaces the strip; a click on it folds it back.
                .contentShape(Rectangle())
                .onTapGesture { if folding { actions.toggleStrip() } }
                .accessibilityAction(named: "Fold usage") { if folding { actions.toggleStrip() } }
            }
            if let card {
                cardBody(card)
                // Detailed keeps its footer under a card (prototype), not under a brief Done card; Clean shows only the card.
                if settings.islandStyle == .detailed, !card.isBrief(in: .islandDetailed), env.sessions.rows.count > 1 {
                    DetailedFooter(label: .underCard(card.sessionID, rows: env.sessions.rows, now: env.sessions.now), action: actions.showAll)
                }
            } else {
                list
            }
        }
        .padding(.horizontal, IslandTheme.Metrics.horizontalPadding)
        .padding(.bottom, IslandTheme.Metrics.bottomPadding)
        .frame(width: size.width)
        .padding(.horizontal, IslandTheme.Metrics.shoulder)
        .themedSurface(IslandShape())
        .environment(\.hoverReporter) { [ui] target in ui.report(target) }
        .environment(\.jumpNoteInIslandHeader, true)
        // A still island (renders) holds its cards' glyphs still too: moving glyphs draw from the clock.
        .transformEnvironment(\.sessionGlyphsAnimated) { if !animated { $0 = false } }
    }


    // MARK: Live

    @ViewBuilder private func liveBody(_ live: IslandLive) -> some View {
        let settings = env.settings
        let folding = settings.islandUsagePlacement == .headerStrip
        // The block stays in the list layer under a card (at no focus), so no row moves while it leaves.
        let block = settings.islandShowsUsage && (!folding || ui.stripOpen)
        let clean = settings.islandStyle == .clean
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                IslandLiveHeader(ui: ui, notch: notch, animated: animated, actions: actions, reduceMotion: live.reduceMotion)
                IslandJumpNote()
                HookDriftRows(size: .island)
                WhatsNewCard(size: .island)
                NewAgentsLine(size: .island)
            }
            .modifier(IslandChannelReveal(ui: ui))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                headerHeight = height
                live.report(.header(height))
            }
            ZStack(alignment: .top) {
                liveList(live, block: block, folding: folding)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { live.report(.list($0)) }
                IslandCardStack(ui: ui, clean: clean, actions: actions, report: live.report)
                    // Motion: Liquid's bud (L2): the card rides in its bud below the list.
                    .modifier(LiquidBudRide(ui: ui, listTop: headerHeight))
            }
        }
        .padding(.horizontal, IslandTheme.Metrics.horizontalPadding)
        .padding(.bottom, IslandTheme.Metrics.bottomPadding)
        .frame(width: size.width)
        .padding(.horizontal, IslandTheme.Metrics.shoulder)
        .coordinateSpace(.named(Self.space))
        .environment(\.hoverReporter) { [ui] target in ui.report(target) }
        .environment(\.jumpNoteInIslandHeader, true)
        .transformEnvironment(\.sessionGlyphsAnimated) { if !animated { $0 = false } }
        .onAppear {
            let style: CardStyle = clean ? .islandClean : .islandDetailed
            live.report(.insets(row: clean ? IslandTheme.Metrics.rowVerticalPadding : 6, card: 2 + style.padding.top))
        }
        .onChange(of: clean) {
            let style: CardStyle = clean ? .islandClean : .islandDetailed
            live.report(.insets(row: clean ? IslandTheme.Metrics.rowVerticalPadding : 6, card: 2 + style.padding.top))
        }
    }

    /// The list layer. With Show all it may be taller than the display leaves under the header: it then scrolls inside
    /// that height, with no scroll bars, its edges fading where more is to see (P133). It is always in its scroll view
    /// (the live island's height is known from the start), which neither scrolls nor clips while the list fits, so Show
    /// all adds its rows to the views already there and rebuilds none (E6: moving the list into a scroll view rebuilt
    /// every row, a first turn of 40 to 60 ms, the old and new copies crossfading). Show all builds at once only the rows
    /// the tallest list can show; the rest wait in a lazy stack under them until the list scrolls to them (P400).
    @ViewBuilder private func liveList(_ live: IslandLive, block: Bool, folding: Bool) -> some View {
        if let maxHeight = live.maxHeight {
            let maximum = max(IslandTheme.Metrics.listFloor, maxHeight - headerHeight - IslandTheme.Metrics.bottomPadding)
            ScrollView(.vertical) {
                listContent(live, block: block, folding: folding, maximum: maximum)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(IslandScrollFade(maximum: maximum))
            .modifier(IslandSelectionScroll(ui: ui))
            .modifier(ScrollHeightCap(maximum: maximum))
        } else {
            listContent(live, block: block, folding: folding)
        }
    }

    /// The list layer's content: the usage block, the rows, the Codex group and the footer, each its own part. Under a
    /// `maximum` (the scroll view's cap), the rows past `IslandListLayout.eagerCount` are built lazily as the list
    /// scrolls to them, and the choreography is told which they are, so one that comes into view is there at once
    /// instead of coming into focus as a new row does (P400).
    @ViewBuilder private func listContent(_ live: IslandLive, block: Bool, folding: Bool, maximum: CGFloat? = nil) -> some View {
        let settings = env.settings
        let style = settings.islandStyle
        let layout = IslandListLayout.make(rows: env.sessions.rows, style: style, showAll: ui.showAll, now: env.sessions.now)
        let shownIDs = layout.shown.map(\.id)
        let sharedHost = DetailedRowText.sharedHost(layout.shown)
        let eager = IslandListLayout.eagerCount(layout.shown.count, maximum: maximum)
        let tail = layout.shown.dropFirst(eager)
        VStack(spacing: 0) {
            // Folded into the header strip, the block stays built, collapsed to no height and out of sight: a click on the
            // strip only unfolds it, never builds its batteries in the frame that starts the motion (13 to 15 ms, P133).
            if settings.islandShowsUsage {
                Group {
                    if style == .clean { CleanUsageView(hover: ui.hover, inUse: ui.inUse) } else {
                        DetailedUsageView(hover: ui.hover, inUse: ui.inUse)
                    }
                }
                .contextMenu { UsageBackgroundMenuItems(showing: .island) }
                .contentShape(Rectangle())
                .onTapGesture { if folding { actions.toggleStrip() } }
                .accessibilityAction(named: "Fold usage") { if folding { actions.toggleStrip() } }
                .islandPart(.usage, live, ui: ui, reports: block)
                .modifier(IslandCollapse(collapsed: !block))
            }
            if layout.total == 0 {
                // Where to start, not just "No sessions" (P965).
                NoSessionsLine()
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .islandPart(.empty, live, ui: ui)
            } else {
                // The rows, the Codex group and the footer, under one peek layer: a row's peek lies over them (P311).
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(layout.shown.prefix(eager)) { row in
                            liveRow(row, style: style, sharedHost: sharedHost, live: live)
                        }
                        if !tail.isEmpty {
                            LazyVStack(spacing: 0) {
                                ForEach(tail) { row in liveRow(row, style: style, sharedHost: sharedHost, live: live) }
                            }
                            .modifier(IslandLazyRows(ids: tail.map(\.id), report: live.report))
                        }
                        if style == .detailed, !layout.codexGroup.isEmpty {
                            IslandCodexGroup(rows: layout.codexGroup).islandPart(.codexGroup, live, ui: ui)
                                .islandPeekCoveredPart("codexGroup", ui: ui)
                        }
                    }
                    .padding(.top, 2)
                    // A row the feed adds, moves or lets go glides; a list change keeps the curve it was written on, the
                    // edge's (E6).
                    .transaction(value: shownIDs) { [reduce = live.reduceMotion] in
                        if reduce { $0.animation = nil } else if $0.animation == nil { $0.animation = IslandMotion.glide.animation }
                    }
                    if layout.showsFooter {
                        Group {
                            if style == .clean { CleanFooter(layout: layout, action: actions.showAll) } else {
                                DetailedFooter(label: layout.footer, action: actions.showAll)
                            }
                        }
                        .islandPart(.footer, live, ui: ui)
                        .islandPeekCoveredPart("footer", ui: ui)
                        .transition(.opacity)
                    }
                }
                .modifier(IslandPeekLayer(ui: ui, reduceMotion: live.reduceMotion))
            }
        }
    }

    /// The card that shows; a card whose session no longer has one falls back to the list (P42).
    private var cardShown: SessionCard? {
        guard case let .card(id) = presentation else { return nil }
        return env.card(for: id)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        let style = env.settings.islandStyle
        let layout = IslandListLayout.make(rows: env.sessions.rows, style: style, showAll: ui.showAll, now: env.sessions.now)
        if layout.total == 0 {
            NoSessionsLine()
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        } else if style == .clean {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(layout.shown) { row in
                        rowButton(row) {
                            CleanSessionRow(row: row, animated: animated, lineFrames: ui.rowFrames)
                                .padding(.vertical, IslandTheme.Metrics.rowVerticalPadding).padding(.horizontal, 8)
                                .islandRowHover(radius: 10, lifted: ui.peek?.sessionID == row.id, selection: (ui, row.id))
                        }
                    }
                }
                .padding(.top, 2)
                if layout.showsFooter { CleanFooter(layout: layout, action: actions.showAll).islandPeekCoveredPart("footer", ui: ui) }
            }
            .modifier(IslandPeekLayer(ui: ui, reduceMotion: true))
        } else {
            let sharedHost = DetailedRowText.sharedHost(layout.shown)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(layout.shown) { row in
                        rowButton(row) {
                            DetailedSessionRow(row: row, animated: animated, sharedHost: sharedHost, lineFrames: ui.rowFrames)
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .islandRowHover(radius: 12, lifted: ui.peek?.sessionID == row.id, selection: (ui, row.id))
                        }
                    }
                    if !layout.codexGroup.isEmpty { IslandCodexGroup(rows: layout.codexGroup).islandPeekCoveredPart("codexGroup", ui: ui) }
                }
                .padding(.top, 2)
                if layout.showsFooter { DetailedFooter(label: layout.footer, action: actions.showAll).islandPeekCoveredPart("footer", ui: ui) }
            }
            .modifier(IslandPeekLayer(ui: ui, reduceMotion: true))
        }
    }

    /// A live list row: its button, its part (its focus, its glide, its home slot reported) and the transition that keeps
    /// it drawn while it leaves.
    private func liveRow(_ row: SessionRow, style: IslandStyle, sharedHost: String?, live: IslandLive) -> some View {
        rowButton(row) {
            if style == .clean {
                CleanSessionRow(row: row, animated: animated, lineFrames: ui.rowFrames)
                    .padding(.vertical, IslandTheme.Metrics.rowVerticalPadding).padding(.horizontal, 8)
                    .islandRowHover(radius: 10, selection: (ui, row.id)) { actions.hoverRow(row, $0) }
            } else {
                DetailedSessionRow(row: row, animated: animated, sharedHost: sharedHost, lineFrames: ui.rowFrames)
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .islandRowHover(radius: 12, selection: (ui, row.id)) { actions.hoverRow(row, $0) }
            }
        }
        .islandPart(.row(row.id), live, ui: ui, glides: true)
        // Its channel brings it into focus and takes it out (E6): the transition only keeps it drawn while it leaves, and
        // moves nothing its report would see (P308).
        .transition(.opacity)
    }

    private func rowButton<Content: View>(_ row: SessionRow, @ViewBuilder content: () -> Content) -> some View {
        Button { actions.openRow(row) } label: { content().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .islandPeekAnchor(row.id, frames: ui.rowFrames)
            .islandPeekCovered(row.id, ui: ui)
            .sessionMenu(row)
    }

    // MARK: Card

    /// A card in place of the list: stream C's `SessionCardView` draws the session's row header (Clean's one line,
    /// Detailed's full row), the body and the lift; the island only places it where the rows start.
    private func cardBody(_ card: SessionCard) -> some View {
        let clean = env.settings.islandStyle == .clean
        return SessionCardView(card: card, style: clean ? .islandClean : .islandDetailed)
            .padding(.top, 2)
    }
}

/// The live island's header. Its strip stays beside the notch under a card (Header strip placement), so what it shows
/// follows what the island presents, read here from `ui`: a present re-evaluates the header alone, never the list and the
/// cards under it (E4). The gate is the island's state, never nil, so turning Reduce Motion on or off keeps the brand
/// glyph's and the gear's identity and state.
private struct IslandLiveHeader: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.islandSize) private var size
    let ui: IslandUIState
    let notch: CGSize
    let animated: Bool
    let actions: IslandViewActions
    let reduceMotion: Bool

    var body: some View {
        let settings = env.settings
        // A card in its bud (Motion: Liquid) leaves the list as it is.
        let usage = IslandUsageFold(listing: ui.presentation == .list || ui.budBase != nil, showsUsage: settings.islandShowsUsage,
                                    placement: settings.islandUsagePlacement, stripOpen: ui.stripOpen)
        IslandHeaderView(layout: IslandHeaderLayout(notch: notch, contentWidth: size.contentWidth), strip: usage.strip, hover: ui.hover,
                         hoverByKey: ui.hoverByKey,
                         animated: animated, actions: actions, gate: ui, reduceMotion: reduceMotion, inUse: ui.inUse)
    }
}

/// The live island's card layers (`IslandCardLayer.stack`), read from `ui` here: a card that comes in, goes or takes
/// another's place re-evaluates these layers alone (E4). Each is one `IslandCardLayerView`, keyed by its session and
/// compared by its card alone, so a layer whose card is the same is never evaluated again when the layers change roles:
/// the card built ahead going live and the showing one leaving re-evaluate only the small modifiers that read the role
/// (E4(c): the switch is a write of the channels and the roles, never a turn that evaluates both cards whole, 12 to 26 ms).
private struct IslandCardStack: View {
    let ui: IslandUIState
    let clean: Bool
    let actions: IslandViewActions
    let report: @MainActor @Sendable (IslandMeasure) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(IslandCardLayer.stack(card: ui.card, leaving: ui.leavingCard, ahead: ui.aheadCard)) { layer in
                IslandCardLayerView(ui: ui, card: layer.card, clean: clean, actions: actions, report: report).equatable()
            }
        }
    }
}

/// A card layer: the card's header row (the tapped row's place), its body hanging under it, and Detailed's footer
/// with the body. A card built `ahead` (out of focus) or `leaving` (another session's took its place, it fades where
/// it is) reports nothing and takes no clicks (P133). Its role is never read here: `IslandCardRole` reads it, and gives
/// the card its reporters while it is the live one, and each part's reveal reads it where it is drawn
/// (`IslandCardPartReveal`), so a change of role re-evaluates those small modifiers and never the card's views. Whether
/// it shows and takes clicks follows what the island presents and the card still arriving, read in `IslandCardGate`.
private struct IslandCardLayerView: View, Equatable {
    @Environment(AppEnvironment.self) private var env
    let ui: IslandUIState
    let card: SessionCard
    let clean: Bool
    let actions: IslandViewActions
    let report: @MainActor @Sendable (IslandMeasure) -> Void

    /// The same layer: its island, its card and its style (the actions and the report are the island's own, and the same
    /// for every layer it ever builds).
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ui === rhs.ui && lhs.card == rhs.card && lhs.clean == rhs.clean
    }

    var body: some View {
        let reveal = CardReveal(ui: ui, id: card.sessionID)
        return VStack(spacing: 0) {
            SessionCardView(card: card, style: clean ? .islandClean : .islandDetailed)
                .environment(\.cardReveal, reveal)
            if !clean, !card.isBrief(in: .islandDetailed), env.sessions.rows.count > 1 {
                DetailedFooter(label: .underCard(card.sessionID, rows: env.sessions.rows, now: env.sessions.now), action: actions.showAll)
                    .cardReveal(reveal, .cardBody)
            }
        }
        .padding(.top, 2)
        .modifier(IslandCardRole(reveal: reveal, drafts: ui.drafts.slot(for: card), report: report))
        .modifier(IslandCardGate(reveal: reveal))
    }
}

/// What a card layer's role gives it, read here: while it is the live one, the reporters its card's parts and its answer
/// field report through (a card built ahead or leaving reports nothing, P133, and its field says nothing of a draft,
/// P96), the card's draft slot its fields keep their text in (P273: a card built ahead gets it once it goes live, and
/// its field restores the draft then), and the layer's height (the card's while it shows; an ahead or leaving card's is
/// nobody's).
private struct IslandCardRole: ViewModifier {
    let reveal: CardReveal
    /// The card's drafts (`CardDrafts.slot(for:)`), given to its fields only while it is the live one.
    let drafts: CardDraftSlot?
    let report: @MainActor @Sendable (IslandMeasure) -> Void

    func body(content: Content) -> some View {
        let ui = reveal.ui, id = reveal.id, report = report
        let live = reveal.role == .live
        var reportPart: (@MainActor @Sendable (PartID, CGRect?) -> Void)?
        var reportDraft: (@MainActor @Sendable (Bool) -> Void)?
        if live {
            reportPart = { part, rect in report(.part(part, rect)) }
            reportDraft = { holds in if ui.cardDraft != holds { ui.cardDraft = holds } }
        }
        return content
            .environment(\.islandPartReporter, reportPart)
            .environment(\.cardDraftReporter, reportDraft)
            .environment(\.cardDraftSlot, live ? drafts : nil)
            .onGeometryChange(for: CGFloat?.self) { live ? $0.size.height : nil } action: { height in
                if let height { report(.card(id, height)) }
            }
    }
}

/// A card layer shows (its glyph moves, it is read out) while it is the live one and the island presents it, and takes
/// clicks once it has come in (P138); built ahead or leaving, its glyph stands still and it takes none (P133).
private struct IslandCardGate: ViewModifier {
    let reveal: CardReveal

    func body(content: Content) -> some View {
        let ui = reveal.ui, id = reveal.id, role = reveal.role
        let presented = role == .live && ui.presentation == .card(sessionID: id)
        let clickable = IslandCardLayer.takesClicks(id, role: role, presentation: ui.presentation, arriving: ui.arrivingCard)
        content
            .transformEnvironment(\.glyphsStill) { if !presented { $0 = true } }
            .allowsHitTesting(clickable)
            .accessibilityHidden(!presented)
    }
}

extension View {
    /// A part of the live island: its focus and, for a row that `glides`, its glide (a render offset, so its layout slot
    /// never moves), read from `ui`, and its home slot reported in the island's coordinates (measured outside the offset).
    /// `reports` false: the part is there but not shown (the folded usage block), and reports as gone.
    /// Its strings never animate (`stillText`).
    func islandPart(_ part: PartID, _ live: IslandLive, ui: IslandUIState, glides: Bool = false, reports: Bool = true) -> some View {
        let motion: IslandChannelReveal.Motion = if glides, case let .row(id) = part { .glide(id) } else { .none }
        return stillText()
            .modifier(IslandChannelReveal(ui: ui, part: part, motion: motion))
            .modifier(IslandPartReport(part: part, reports: reports, report: live.report))
    }
}

/// Reports a part's home slot as its view's own (`IslandMeasure.part`'s owner): when one view of a part gives way to
/// another in one update, the old view's going never takes away the new one's frame.
private struct IslandPartReport: ViewModifier {
    let part: PartID
    var reports = true
    let report: @MainActor @Sendable (IslandMeasure) -> Void
    @State private var owner = IslandPartReport.next()

    private static var count = 0
    @MainActor private static func next() -> Int {
        count += 1
        return count
    }

    func body(content: Content) -> some View {
        let part = part, owner = owner, report = report, reports = reports
        return content
            .onGeometryChange(for: CGRect?.self) { reports ? $0.frame(in: .named(OpenedIslandView.space)) : nil } action: { rect in
                report(.part(part, rect, owner: owner))
            }
            .onDisappear { report(.part(part, nil, owner: owner)) }
    }
}

/// A part kept built while it is not shown: `collapsed`, it takes no height and cannot be seen, clicked or read, and is
/// laid out at its own size all the same, so showing it again only moves what is under it (on the transaction's curve,
/// as an insertion would) and builds nothing.
private struct IslandCollapse: ViewModifier {
    let collapsed: Bool

    func body(content: Content) -> some View {
        CollapseLayout(collapsed: collapsed) { content }
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}

private struct CollapseLayout: Layout {
    let collapsed: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: collapsed ? 0 : size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

/// As tall as its content, and no taller than `maximum`: a scroll view in it gets exactly that height, and scrolls
/// only when its content is taller.
struct ScrollHeightCap: ViewModifier {
    let maximum: CGFloat

    func body(content: Content) -> some View {
        ScrollHeightCapLayout(maximum: maximum) { content }
    }
}

private struct ScrollHeightCapLayout: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maximum))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A scroll view's edges fade out where there is more to see (18 pt), and stay sharp where there is not: the only
/// sign, with no scroll bars, that the list goes on. The fades are the island's own black laid over the edges, not a
/// mask, which would draw the whole list offscreen on every frame it scrolls. While its content fits under `maximum`
/// it neither clips nor scrolls (E6): a row gliding up to the header, a part's drift and blur, and a part leaving while
/// the list grows toward its new height draw past it as they would outside it (read against the cap, never the height
/// the scroll view has in that frame, which a list change animates).
private struct IslandScrollFade: ViewModifier {
    let maximum: CGFloat
    @State private var edges = Edges()
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }

    struct Edges: Equatable {
        var above = false
        var below = false
        var overflows = false
    }

    static let fade: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .scrollClipDisabled(!edges.overflows)
            .scrollDisabled(!edges.overflows)
            .onScrollGeometryChange(for: Edges.self) { [maximum] geometry in
                Edges(above: geometry.contentOffset.y > 1,
                      below: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1,
                      overflows: geometry.contentSize.height > maximum + 0.5)
            } action: { _, new in edges = new }
            .modifier(Fade(edges: edges, bg: palette.bg, masks: theme.adapts))
    }

    /// Black and Smoke lay the surface's own colour over the edges (on Smoke, the floor's black: a vignette on the
    /// glass). Glass has no colour of its own to lay there, so it fades the list itself under a mask: the render server
    /// composites it, and it changes only when an edge's fade comes or goes, never as the list scrolls (P565).
    private struct Fade: ViewModifier {
        let edges: Edges
        let bg: Color
        let masks: Bool
        static let beyond: CGFloat = 400

        @ViewBuilder func body(content: Content) -> some View {
            if masks {
                // Opaque well past the list's frame all round: a list that fits draws its rows' glides and drifts past
                // its frame (E6), and the mask must not cut them.
                content.mask {
                    VStack(spacing: 0) {
                        Rectangle().frame(height: Self.beyond)
                        LinearGradient(colors: [.black.opacity(edges.above ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: IslandScrollFade.fade)
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(edges.below ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: IslandScrollFade.fade)
                        Rectangle().frame(height: Self.beyond)
                    }
                    .padding(-Self.beyond)
                }
            } else {
                content
                    .overlay(alignment: .top) { IslandScrollFade.edge(.top, bg).opacity(edges.above ? 1 : 0) }
                    .overlay(alignment: .bottom) { IslandScrollFade.edge(.bottom, bg).opacity(edges.below ? 1 : 0) }
            }
        }
    }

    /// On glass `bg` is the floor's black: the edge darkens the glass as it fades the rows, a vignette, never a mask.
    fileprivate static func edge(_ from: UnitPoint, _ bg: Color) -> some View {
        LinearGradient(colors: [bg, bg.opacity(0)], startPoint: from,
                       endPoint: from == .top ? .bottom : .top)
            .frame(height: fade)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
