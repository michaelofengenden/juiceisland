import JuiceCore
import SwiftUI

/// A battery's window as a line (P125, `UsageSparkline`): its use from the window's start (left) to its reset (right),
/// 0 at the bottom and 100 % at a dotted ceiling, so where the line stops is how far the window has gone and how high
/// it is, how much of it is used. The battery's own inks: `ink2` with a faint fill, the latest reading a dot in `ink`;
/// the warning amber when the window runs out before its reset. Pure drawing, one `Canvas`, nothing animates.
struct UsageSparklineView: View {
    let line: UsageSparkline
    @Environment(\.juiceTheme) private var theme

    static let size = CGSize(width: 48, height: 16)

    var body: some View {
        // The theme's inks (Black's are `Theme`'s own; on a light window, Glass's twins for it).
        let panel = theme.panel, warn = theme.panel.tone(Theme.warn)
        Canvas { context, size in
            let inset: CGFloat = 1.5
            let width = size.width - 2 * inset, height = size.height - 2 * inset
            func place(_ point: UsageSparkline.Point) -> CGPoint {
                CGPoint(x: inset + CGFloat(point.x) * width, y: inset + CGFloat(1 - point.y) * height)
            }
            var ceiling = Path()
            ceiling.move(to: CGPoint(x: inset, y: inset))
            ceiling.addLine(to: CGPoint(x: size.width - inset, y: inset))
            context.stroke(ceiling, with: .color(panel.line.opacity(0.55)), style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2]))
            let points = line.points.map(place)
            guard let first = points.first, let last = points.last else { return }
            let colour = line.runsOut ? warn : panel.ink2
            var path = Path()
            path.addLines(points)
            var area = path
            area.addLine(to: CGPoint(x: last.x, y: inset + height))
            area.addLine(to: CGPoint(x: first.x, y: inset + height))
            area.closeSubpath()
            context.fill(area, with: .color(colour.opacity(0.14)))
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: last.x - 1.75, y: last.y - 1.75, width: 3.5, height: 3.5)),
                         with: .color(line.runsOut ? warn : panel.ink))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}
