import SwiftUI

/// The window's session list: one quiet "Needs you N" line that is also the filter (a click shows only what needs
/// you, again or Esc shows all), the Needs you cards in masonry columns, then the Running and
/// Done cards: under the shortest Needs you column when those fill two columns or more, else side by side below (one
/// column under 1000 pt). Needs you only: just the cards and "N more running or done · Show all" (the other active
/// sessions), or "Earlier" when the others all finished longer ago.
/// "Nothing needs you" shows only in Needs you only, where nothing else would; with no sessions at all, one quiet
/// "No sessions" sits in the middle. Holding ⌃ shows every card's keys. Owner: stream C.
struct SessionListView: View {
    @Environment(\.juiceTheme) private var theme
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        GeometryReader { proxy in
            if env.sessions.rows.isEmpty {
                // Nothing at all: one quiet line in the middle of the list, the island's own words.
                Text("No sessions")
                    .font(Fonts.sys(12, .medium))
                    .foregroundStyle(theme.island.ink3)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                ScrollView(.vertical) {
                    SessionListContent(width: max(0, proxy.size.width - WindowTheme.Metrics.listPadding.leading - WindowTheme.Metrics.listPadding.trailing),
                                       windowWidth: proxy.size.width)
                        .padding(WindowTheme.Metrics.listPadding)
                }
                .scrollIndicators(.automatic)
                .modifier(WindowSelectionScroll())
            }
        }
        .background(WindowTheme.bg)
        .shortcutHintsWhileControlHeld()
    }
}

/// The list without its scroll view, laid out for a known width.
struct SessionListContent: View {
    /// The list's inner width (inside its 16 pt side padding).
    let width: CGFloat
    /// The window's width, which picks one or two columns for Running and Done.
    let windowWidth: CGFloat
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sessions = env.sessions
        let needsYou = sessions.needsYou
        // Active sessions first in each card, the older finished ones after them.
        let split = SessionListLayout.columns(SessionActivity.activeFirst(sessions.rows, now: sessions.now))
        let needsOnly = env.windowFilter == .needsYou
        VStack(alignment: .leading, spacing: 0) {
            if !needsYou.isEmpty {
                NeedsYouFilterHeader(count: needsYou.count).padding(EdgeInsets(top: 6, leading: 4, bottom: 4, trailing: 4))
            }
            let cards = needsYou.compactMap { row in env.sessions.card(for: row.id) }
            let gap = WindowTheme.Metrics.gridGap
            let needsColumns = SessionListLayout.autoFitColumns(width: width, count: cards.count,
                                                                minColumn: WindowTheme.Metrics.needsGridMinColumn, gap: gap)
            if needsOnly {
                if needsYou.isEmpty { EmptyNeedsYou() } else { needsGrid(cards, columns: needsColumns) }
                if let footer = SessionListLayout.moreFooter(sessions.rows, now: sessions.now) {
                    Button { env.windowFilter = .all } label: {
                        FooterLabel(text: footer)
                    }
                    .buttonStyle(.plain)
                }
            } else if needsYou.isEmpty {
                // Running and Done say what there is; "Nothing needs you" over them would only take a line.
                columns(split).padding(.top, 6)
            } else if SessionListLayout.flowsIntoNeedsColumns(needsColumns: needsColumns, windowWidth: windowWidth) {
                // One masonry: Running and Done go under the shortest Needs you column, so no card leaves a hole.
                MasonryLayout(columns: needsColumns, spacing: gap) {
                    ForEach(cards, id: \.sessionID) { card in SessionCardView(card: card, style: .window).id(card.sessionID) }
                    if split.showsRunningCard { runningCard(split) }
                    if !split.done.isEmpty { doneCard(split) }
                }
            } else {
                needsGrid(cards, columns: needsColumns)
                columns(split).padding(.top, gap)
            }
        }
        .frame(width: width, alignment: .topLeading)
        // A session that asks, finishes or starts moves the cards: they glide to their places and a card that comes or
        // goes fades, on the island rows' own curve, never a jump (P102); under Reduce Motion they simply are there.
        .animation(reduceMotion ? nil : IslandMotion.glide.animation,
                   value: SessionListLayout.arrangement(needsYou: needsYou, columns: split, needsOnly: needsOnly))
    }

    // MARK: Needs you

    private func needsGrid(_ cards: [SessionCard], columns: Int) -> some View {
        MasonryLayout(columns: columns, spacing: WindowTheme.Metrics.gridGap) {
            ForEach(cards, id: \.sessionID) { card in SessionCardView(card: card, style: .window).id(card.sessionID) }
        }
    }

    // MARK: Running | Done

    /// "Running N" counts only what runs; with nothing running, the card holds only Codex sessions idle at the prompt
    /// and is titled by the group itself ("Codex N"), so no idle session is ever counted as running.
    private func runningCard(_ columns: SessionListLayout.Columns) -> RowsCard {
        guard columns.runningCount > 0 else {
            return RowsCard(title: "Codex", count: columns.codexGroup.count, rows: [], codexGroup: columns.codexGroup, groupTitled: false)
        }
        return RowsCard(title: "Running", count: columns.runningCount, rows: columns.running, codexGroup: columns.codexGroup)
    }

    private func doneCard(_ columns: SessionListLayout.Columns) -> RowsCard {
        RowsCard(title: "Done", count: columns.done.count, rows: columns.done, codexGroup: [])
    }

    @ViewBuilder private func columns(_ columns: SessionListLayout.Columns) -> some View {
        let gap = WindowTheme.Metrics.gridGap
        let stacked = SessionListLayout.stacksColumns(windowWidth: windowWidth)
        let showsRunning = columns.showsRunningCard, showsDone = !columns.done.isEmpty
        let running = runningCard(columns)
        let done = doneCard(columns)
        if stacked || !(showsRunning && showsDone) {
            VStack(alignment: .leading, spacing: gap) {
                if showsRunning { running }
                if showsDone { done }
            }
        } else {
            let half = SessionListLayout.columnWidth(width: width, columns: 2, gap: gap)
            HStack(alignment: .top, spacing: gap) {
                running.frame(width: half)
                done.frame(width: half)
            }
        }
    }
}

/// Equal columns, each item under the column that ends highest (`SessionListLayout.masonry`): the first items
/// take the top of each column, and a short card never leaves black space beside a tall one.
struct MasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        SessionListLayout.columnWidth(width: width, columns: max(1, columns), gap: spacing)
    }

    private func heights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let result = SessionListLayout.masonry(heights: heights(subviews, width: columnWidth(width)), columns: columns, gap: spacing)
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = columnWidth(bounds.width)
        let heights = heights(subviews, width: width)
        let result = SessionListLayout.masonry(heights: heights, columns: columns, gap: spacing)
        for (index, subview) in subviews.enumerated() {
            let placement = result.placements[index]
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(placement.column) * (width + spacing), y: bounds.minY + placement.y),
                          anchor: .topLeading, proposal: ProposedViewSize(width: width, height: heights[index]))
        }
    }
}

/// "Needs you N": the list's one filter. A click shows only what needs you; pressed (a faint pill), a click shows all
/// again. The toolbar's pill copy and Esc do the same.
private struct NeedsYouFilterHeader: View {
    let count: Int
    @Environment(AppEnvironment.self) private var env
    @State private var hovered = false

    var body: some View {
        let pressed = env.windowFilter == .needsYou
        Button { env.windowFilter = pressed ? .all : .needsYou } label: {
            HStack(spacing: 7) {
                Text("Needs you").foregroundStyle(pressed || hovered ? WindowTheme.filterSelectedText : WindowTheme.sectionHeader)
                Text("\(count)").monospacedDigit().foregroundStyle(pressed || hovered ? WindowTheme.filterSelectedCount : WindowTheme.sectionCount)
            }
            .font(WindowTheme.TypeScale.sectionHeader)
            .tracking(0.11)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(pressed ? WindowTheme.filterSelectedBg : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(pressed ? "Show all" : "Show only what needs you")
        .accessibilityAddTraits(pressed ? .isSelected : [])
    }
}

/// A section label: 600 11/24 #86868B, count #76767B, gap 7.
private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(WindowTheme.sectionHeader)
            Text("\(count)").monospacedDigit().foregroundStyle(WindowTheme.sectionCount)
        }
        .font(WindowTheme.TypeScale.sectionHeader)
        .tracking(0.11)
        .lineBox(24)
        .accessibilityElement(children: .combine)
    }
}

/// The green check (2 pt pixels) and "Nothing needs you", 600 12 #8E8E93, padding 12, gap 10.
private struct EmptyNeedsYou: View {
    @Environment(\.sessionGlyphsAnimated) private var animated

    var body: some View {
        HStack(spacing: 10) {
            StateGlyphView(glyph: .check, colour: IslandTheme.done,
                           pixel: 2, animated: animated)
            Text("Nothing needs you").font(Fonts.sys(12, .semibold)).foregroundStyle(WindowTheme.emptyText)
        }
        .padding(.vertical, 12).padding(.horizontal, 12)
    }
}

/// `.foot`: full width, 500 11/36 #7A7A7A (#8C8C8C on hover).
private struct FooterLabel: View {
    @Environment(\.juiceTheme) private var theme
    let text: String
    @State private var hovered = false

    var body: some View {
        Text(text)
            .font(Fonts.sys(11, .medium).monospacedDigit())
            .foregroundStyle(hovered ? theme.island.footerHover : theme.island.footer)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// A Running or Done card: pure black with the faintest edge, padding 2 4 6, its label (padding 6 8 0), Detailed rows
/// (padding 7 8, r12, lift on hover) and, in Running, the Codex group.
private struct RowsCard: View {
    @Environment(\.juiceTheme) private var theme
    let title: String
    let count: Int
    let rows: [SessionRow]
    let codexGroup: [SessionRow]
    /// The group carries its own "Codex N" label (false when the card's title already is that label).
    var groupTitled = true
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowTheme.Metrics.cardRadius)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, count: count).padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
            ForEach(rows) { row in ListRow(row: row).id(row.id) }
            if !codexGroup.isEmpty {
                // On the rows' own columns (the rows' 8 pt side padding), a little apart from the last row.
                CodexGroupView(rows: codexGroup, titled: groupTitled)
                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 2, trailing: 8))
            }
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WindowTheme.cardGround).overlay(shape.strokeBorder(WindowTheme.cardEdge, lineWidth: 1)))
    }
}

/// One Detailed row in Running or Done: a click jumps to the session; a jump that missed leaves its note below. The row
/// the keys are on takes the hover's lift with a thin ring (P321).
private struct ListRow: View {
    @Environment(\.juiceTheme) private var theme
    let row: SessionRow
    @Environment(AppEnvironment.self) private var env
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        VStack(alignment: .leading, spacing: 0) {
            DetailedRowView(row: row, metrics: .window, showsBranch: true)
            JumpNoteLine(sessionID: row.id).padding(.leading, DetailedRowMetrics.window.leading)
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background {
            let selected = env.windowSelection == row.id
            if hovered || selected {
                shape.fill(theme.island.rowHover)
                    .overlay(shape.strokeBorder(selected ? theme.island.selectionRing : theme.island.rowHoverStroke,
                                                lineWidth: selected ? SelectionMark.ringWidth : 0.5))
            }
        }
        .contentShape(shape)
        .onHover { hovered = $0 }
        .onTapGesture { env.sessions.jump(row.id) }
        .sessionMenu(row)
        .accessibilityAddTraits(.isButton)
    }
}
