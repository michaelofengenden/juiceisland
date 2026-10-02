import JuiceCore
import SwiftUI

/// One provider's row: its mark (20 pt) and its batteries (gap 6). Reusable by the island (D).
/// - `markGap`: 12 in the window's Section header, 10 in the Strip header and the island's Clean rows.
/// - `showsNames`: each battery gets its alias under it (500 10.5/13 `ink3`, at most 60 pt, 5 pt below), and the
///   mark a blank label so the row stays aligned; the row then top-aligns. A longer name is cut in the middle, so two
///   that start alike (`jordan.rivera`, `jordan.riverside`) still show their own ends.
/// Batteries and the mark report hover and clicks through `usageInteraction` (no-ops by default).
struct UsageBatteryRow: View {
    @Environment(\.juiceTheme) private var theme
    let row: ProviderRowModel
    var now: Date
    var markGap: CGFloat = 12
    var showsNames = false

    var body: some View {
        HStack(alignment: showsNames ? .top : .center, spacing: markGap) {
            named(nil) {
                ProviderMarkView(provider: row.provider, size: Theme.Mark.row, theme: theme)
                    .accessibilityLabel(row.hoverLabel.replacingOccurrences(of: " · ", with: ", "))
            }
            .usageTarget(.provider(row.provider), provider: row.provider, account: nil)
            HStack(alignment: .top, spacing: Theme.Battery.gap) {
                ForEach(row.batteries) { battery in
                    named(battery.alias) { UsageBatteryView(battery: battery, now: now, theme: theme) }
                        .usageTarget(.account(battery.id), provider: row.provider, account: battery.id)
                }
            }
        }
    }

    @ViewBuilder
    private func named<Content: View>(_ name: String?, @ViewBuilder content: () -> Content) -> some View {
        if showsNames {
            VStack(spacing: 5) {
                content()
                Text(name ?? " ")
                    .font(WindowTheme.TypeScale.accountName)
                    .foregroundStyle(WindowTheme.accountName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.nameWidth(name), height: 13)
                    .opacity(name == nil ? 0 : 1)
            }
        } else {
            content()
        }
    }

    /// The label's own width, at most 60 (longer aliases truncate).
    @MainActor
    static func nameWidth(_ name: String?) -> CGFloat {
        guard let name else { return 1 }
        return min(60, ceil(MoneyFigureText.measure(name, font: .systemFont(ofSize: 10.5, weight: .medium))))
    }
}

/// A hover label as the caption and chip draw it: the name 500 `ink`, then each part after a "·" (`ink3`, 8 pt each
/// side), in `ink2`.
struct HoverLabelView: View {
    @Environment(\.juiceTheme) private var theme
    let label: HoverLabel
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Text(label.name).fontWeight(.medium).foregroundStyle(theme.panel.ink)
            ForEach(Array(label.parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 8) {
                    Text(verbatim: "·").foregroundStyle(theme.island.ink3)
                    Text(part).foregroundStyle(theme.panel.ink2)
                }
            }
        }
        .font(.system(size: size))
        .lineLimit(1)
        .fixedSize()
    }
}

/// A hover label that drops parts from the end until it fits its width (never cuts one; the name and the first part
/// always stay, and then the last part left truncates).
struct FittedHoverLabel: View {
    let label: HoverLabel
    var size: CGFloat = 12

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(0..<max(1, label.parts.count), id: \.self) { drop in
                HoverLabelView(label: HoverLabel(name: label.name, parts: Array(label.parts.dropLast(drop))), size: size)
            }
            HoverLabelView(label: HoverLabel(name: label.name, parts: Array(label.parts.prefix(1))), size: size)
                .fixedSize(horizontal: false, vertical: true)
                .truncationMode(.tail)
        }
    }
}

/// The floating chip the window shows instead of a caption when Hover details is off: black, padding 7 11, radius 9,
/// 12 pt, a 0.5 pt white 26 % edge and a soft shadow.
struct HoverChipView: View {
    let label: HoverLabel

    var body: some View {
        HoverLabelView(label: label, size: 12)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(WindowTheme.chipBg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WindowTheme.chipEdge, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.5), radius: 7, y: 4)
    }
}
