import SwiftUI

/// The keyboard's row (P321): ↑ and ↓ move it through the rows a list shows, in the order it draws them, Return opens
/// it as a click would, and over the list a card key acts on the card of the row it is on, and only on that (P351).
/// Nothing is selected until an arrow is pressed (or the system-wide key opens the island), so no row is marked at rest.
enum RowSelection {
    /// The row `step` rows on from `current` among `ids`: it stops at either end. With none selected, or one no longer
    /// listed, ↓ starts at the first row and ↑ at the last.
    static func moved(_ current: String?, in ids: [String], by step: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return step >= 0 ? ids.first : ids.last }
        return ids[min(max(index + step, 0), ids.count - 1)]
    }

    /// The switcher's step (P462): the row after `current`, the first after the last (or with none selected, or one no
    /// longer listed).
    static func cycled(_ current: String?, in ids: [String]) -> String? {
        guard let current, let index = ids.firstIndex(of: current), index + 1 < ids.count else { return ids.first }
        return ids[index + 1]
    }

    /// The switcher's step back, ⇧ with the system-wide key (P1033): the row before `current`, the last after the first
    /// (or with none selected, or one no longer listed).
    static func cycledBack(_ current: String?, in ids: [String]) -> String? {
        guard let current, let index = ids.firstIndex(of: current), index > 0 else { return ids.last }
        return ids[index - 1]
    }

    /// What Return does on the keys' row: its card opens, as a click on it does, and a row with none jumps (P321);
    /// opened by the system-wide key set to Switch sessions, it jumps whatever the row is (P462).
    enum ReturnAction: Equatable { case openCard, jump }

    static func onReturn(_ row: SessionRow, switching: Bool) -> ReturnAction {
        row.hasCard && !switching ? .openCard : .jump
    }

    /// The window's rows in the order it draws them: the Needs you cards, the Running card's rows and its Codex group,
    /// then Done; only the cards while the list shows only what needs you.
    @MainActor static func windowOrder(_ env: AppEnvironment) -> [String] {
        let sessions = env.sessions
        let cards = sessions.needsYou.filter { sessions.card(for: $0.id) != nil }.map(\.id)
        if env.windowFilter == .needsYou { return cards }
        let split = SessionListLayout.columns(SessionActivity.activeFirst(sessions.rows, now: sessions.now))
        return cards + (split.running + split.codexGroup + split.done).map(\.id)
    }

    /// The island's rows as the list shows them (the four, or every row after Show all); the Detailed Codex group's
    /// lines take no click, so no key either.
    @MainActor static func islandOrder(_ sessions: any SessionsModel, style: IslandStyle, showAll: Bool) -> IslandListLayout {
        IslandListLayout.make(rows: sessions.rows, style: style, showAll: showAll, now: sessions.now)
    }

    /// ↑ or ↓ in the island's list: the row the keys move to, and whether the rows behind the footer show first (↓ from
    /// the last row the list shows, with rows behind "Show N more" or "Earlier", as a click on the footer shows them).
    @MainActor static func islandMove(_ current: String?, sessions: any SessionsModel, style: IslandStyle, showAll: Bool,
                                      by step: Int) -> (row: SessionRow?, showsAll: Bool) {
        let layout = islandOrder(sessions, style: style, showAll: showAll)
        if step > 0, layout.showsFooter, let current, current == layout.shown.last?.id {
            let all = islandOrder(sessions, style: style, showAll: true).shown
            let id = moved(current, in: all.map(\.id), by: step)
            return (all.first { $0.id == id }, true)
        }
        let id = moved(current, in: layout.shown.map(\.id), by: step)
        return (layout.shown.first { $0.id == id }, false)
    }

    /// The system-wide key's press in Switch sessions (P462): ↓'s move (the rows behind the footer shown first, as ↓
    /// shows them), and after the last row of all the first row again.
    @MainActor static func islandSwitch(_ current: String?, sessions: any SessionsModel, style: IslandStyle,
                                        showAll: Bool) -> (row: SessionRow?, showsAll: Bool) {
        let move = islandMove(current, sessions: sessions, style: style, showAll: showAll, by: 1)
        if let row = move.row, row.id != current { return move }
        return (islandOrder(sessions, style: style, showAll: showAll).shown.first, false)
    }

    /// ⇧ with the system-wide key in Switch sessions (P1033): ↑'s move, and from the first row the last row of all, the
    /// rows behind the footer shown first, as the switcher's way forward reaches them.
    @MainActor static func islandSwitchBack(_ current: String?, sessions: any SessionsModel, style: IslandStyle,
                                            showAll: Bool) -> (row: SessionRow?, showsAll: Bool) {
        let layout = islandOrder(sessions, style: style, showAll: showAll)
        if let current, let index = layout.shown.firstIndex(where: { $0.id == current }), index > 0 {
            return (layout.shown[index - 1], false)
        }
        guard layout.showsFooter else { return (layout.shown.last, false) }
        return (islandOrder(sessions, style: style, showAll: true).shown.last, true)
    }
}

/// How the keys' row is marked: the row's own hover lift, plus a thin ring, so it reads apart from the row under the
/// pointer (the pointer never moves it: a list that scrolls to the selected row slides other rows under a still pointer).
enum SelectionMark {
    static let ring = Color.white(0.2)
    static let ringWidth: CGFloat = 1
}

/// Scrolls the selected row into view in a scroll view it wraps (`ScrollViewReader`), on the glide's curve; reads the
/// selection here, so a key press re-evaluates this modifier alone.
struct SelectionScroll: ViewModifier {
    var selected: String?
    var reduceMotion = false

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: selected) { _, id in
                guard let id else { return }
                if reduceMotion { proxy.scrollTo(id) } else { withAnimation(IslandMotion.glide.animation) { proxy.scrollTo(id) } }
            }
        }
    }
}

/// The island's selection, read where a row draws its highlight or the list scrolls (never in the list's own body).
struct IslandSelectionScroll: ViewModifier {
    let ui: IslandUIState

    func body(content: Content) -> some View {
        content.modifier(SelectionScroll(selected: ui.selectedRow, reduceMotion: ui.reduceMotion))
    }
}

/// The window's selection scroll, reading the selection here (never in the list's body).
struct WindowSelectionScroll: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.modifier(SelectionScroll(selected: env.windowSelection, reduceMotion: reduceMotion))
    }
}

/// A window card's ground: pure black with the faintest edge; the card the keys are on takes the rows' lift (their
/// hover fill) under the ring, as a selected row does, so the card a key answers is plain to see (P321). Read here, so
/// a key press re-evaluates the grounds alone, never the cards.
struct WindowCardGround: View {
    @Environment(\.juiceTheme) private var theme
    let id: String
    let radius: CGFloat
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let selected = env.windowSelection == id
        shape.fill(selected ? theme.island.rowHover : WindowTheme.cardGround)
            .overlay(shape.strokeBorder(selected ? theme.island.selectionRing : WindowTheme.cardEdge,
                                        lineWidth: selected ? SelectionMark.ringWidth : 1))
    }
}
