import SwiftUI

/// Many sessions (P400): Show all's list builds at once only the rows the tallest list could show, and the rest in a lazy
/// stack under them, built as the list scrolls to them, so 100 sessions and more open, scroll and close as smoothly as a
/// few. The choreography is told which rows are lazy (`IslandMeasure.lazyRows`): one that comes into view as the list
/// scrolls is there at once, never coming into focus as a new row does, and it still leaves with the others (a close, a
/// card) and lifts into a card's header when tapped, as any row the list shows.
extension IslandListLayout {
    /// How many of `count` rows the live list builds at once under a scroll cap of `maximum`: every row the tallest list
    /// could show without scrolling, at the shortest a row can be, and one more; the rest are built as the list scrolls
    /// to them. So the list is always taller than its cap while any row waits, and its measured height is the cap's,
    /// whatever a lazy row turns out to measure. With no cap (renders) every row is built.
    static func eagerCount(_ count: Int, maximum: CGFloat?) -> Int {
        guard let maximum else { return count }
        let fits = Int((max(0, maximum) / shortestRow).rounded(.up)) + 1
        return min(count, max(IslandTheme.Metrics.visibleRows, fits))
    }

    /// Below any row's height: a Clean row is 41 pt at the smallest text, a Detailed one 49.
    static let shortestRow: CGFloat = 36
}

/// Tells the choreography which rows the list builds only as it scrolls to them, whenever that changes, and that there
/// are none once they go.
struct IslandLazyRows: ViewModifier {
    let ids: [String]
    let report: @MainActor @Sendable (IslandMeasure) -> Void

    func body(content: Content) -> some View {
        let report = report
        content
            .onChange(of: ids, initial: true) { _, ids in report(.lazyRows(Set(ids))) }
            .onDisappear { report(.lazyRows([])) }
    }
}
