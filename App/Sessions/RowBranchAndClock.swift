import SwiftUI

/// "Compacting 0:42" (P433): a compaction's own time, counted from the PreCompact that began it, in minutes and seconds
/// (hours ahead of them past the hour). "Compacting" alone when the start is not known (a session restored mid-way) or
/// no clock is given.
enum CompactionText {
    static let word = "Compacting"

    static func word(since: Date?, now: Date?) -> String {
        guard let since, let now else { return word }
        return word + " " + clock(now.timeIntervalSince(since))
    }

    /// `42` → "0:42", `754` → "12:34", `3_725` → "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600, minutes = total % 3_600 / 60, rest = total % 60
        let tail = String(format: "%02d", rest)
        return hours > 0 ? "\(hours):" + String(format: "%02d", minutes) + ":" + tail : "\(minutes):" + tail
    }

    /// Whether the clock moves: only while its row can be seen (its surface on a display, the island open, the row in
    /// its list's view) and moving glyphs are wanted (a render or a still island holds it at the sessions' clock).
    static func ticks(animated: Bool, hidden: Bool, still: Bool, scrolledAway: Bool) -> Bool {
        animated && !hidden && !still && !scrolledAway
    }
}

/// Draws `content` with the time a compacting row's clock reads (P433): once a second from the compaction's start, and
/// only while the row can be seen (`CompactionText.ticks`); still, it reads the sessions' clock (real time live, the
/// fixture's in renders). With no start (`since` nil: not compacting, or not known) it draws `content(nil)` and runs
/// nothing, so a row at rest costs nothing.
struct CompactionClock<Content: View>: View {
    let since: Date?
    @ViewBuilder var content: (Date?) -> Content
    @Environment(AppEnvironment.self) private var env
    @Environment(\.glyphMotionPaused) private var hidden
    @Environment(\.glyphsStill) private var still
    @Environment(\.sessionGlyphsAnimated) private var animated
    @State private var scrolledAway = false

    var body: some View {
        if let since {
            let now = env.sessions.now
            Group {
                if CompactionText.ticks(animated: animated, hidden: hidden, still: still, scrolledAway: scrolledAway) {
                    // The sessions' clock may run apart from the real one (a fixture's): its ticks keep that offset.
                    let offset = now.timeIntervalSinceNow
                    TimelineView(.periodic(from: since.addingTimeInterval(-offset), by: 1)) { context in
                        content(context.date.addingTimeInterval(offset))
                    }
                } else {
                    content(now)
                }
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible in scrolledAway = !visible }
        } else {
            content(nil)
        }
    }
}

/// The branch a row's session has checked out (P434), as a Detailed row's tag, in a Clean row's peek and before the age
/// on the window's rows: a small branch mark and the name, dim, a long name cut in its middle (whole in the tooltip), so
/// the tag never takes the title's room.
struct RowBranchTag: View {
    let branch: String
    /// The island's tags' 500 9.5 pt; the window's rows give their age's.
    var font: Font = IslandTheme.TypeScale.tag
    var colour: Color = IslandTheme.tagTime.fg
    var height: CGFloat = 15
    var maxWidth: CGFloat = 90
    /// Short of room, cut shorter than `maxWidth` (its natural width up to that, otherwise).
    var yields = false

    var body: some View {
        HStack(spacing: 3) {
            BranchIcon(colour: colour).frame(width: 7, height: 9)
            CappedWidth(max: maxWidth) {
                Text(branch)
                    .font(font)
                    .foregroundStyle(colour)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: height)
        .fixedSize(horizontal: !yields, vertical: true)
        .help(branch)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Branch \(branch)")
    }
}

/// Its content at its own width, never wider than `max` or than what is offered (where `frame(maxWidth:)` would take all
/// that is offered up to `max`).
struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, max, proposal.width ?? .infinity)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A git branch: a trunk between two nodes, and a branch from a third node curving into it.
struct BranchIcon: View {
    let colour: Color

    var body: some View {
        ZStack {
            BranchShape().stroke(colour, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            BranchNodes().stroke(colour, lineWidth: 1)
        }
    }
}

private struct BranchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let left = rect.minX + 1.5, right = rect.maxX - 1.5
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY + 3))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - 3))
        path.move(to: CGPoint(x: right, y: rect.minY + 3))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - 3.5), control: CGPoint(x: right, y: rect.midY + 1.5))
        return path
    }
}

private struct BranchNodes: Shape {
    func path(in rect: CGRect) -> Path {
        let left = rect.minX + 1.5, right = rect.maxX - 1.5, r: CGFloat = 1.3
        var path = Path()
        for centre in [CGPoint(x: left, y: rect.minY + 1.5), CGPoint(x: left, y: rect.maxY - 1.5), CGPoint(x: right, y: rect.minY + 1.5)] {
            path.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
        }
        return path
    }
}
