import AppKit
import JuiceCore
import SwiftUI

/// The ring on the hovered battery or amount (1 pt white 35 %, 2 pt out; Glass: `IslandPalette.hoverRing`).
private struct HoverRing: ViewModifier {
    var shown: Bool
    var radius: CGFloat
    var colour = Color.white(0.35)
    func body(content: Content) -> some View {
        content.overlay {
            if shown {
                RoundedRectangle(cornerRadius: radius).strokeBorder(colour, lineWidth: 1).padding(-2.5)
            }
        }
    }
}

/// A provider mark (16) and its batteries, 29 pt tall (the island's own row; stream B's window rows are separate). An
/// account in use wears its dot (P811).
struct IslandBatteryRow: View {
    let row: ProviderRowModel
    /// Read once for the row and passed to its batteries (`BatteryView.glass`, P559).
    @Environment(\.juiceTheme) private var theme
    var now: Date
    var hover: HoverTargetID?
    var inUse = AccountsInUse.none

    static let markSize: CGFloat = Theme.Mark.strip
    static let markGap: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.markGap) {
            ProviderMarkView(provider: row.provider, size: Self.markSize, theme: theme)
                .hoverTarget(id: IslandHoverIDs.provider(row.provider), label: row.hoverLabel)
            HStack(spacing: Theme.Battery.gap) {
                ForEach(row.batteries) { battery in
                    BatteryView(battery: battery, now: now, theme: theme, inUse: inUse.contains(battery.id))
                        .modifier(HoverRing(shown: hover == .account(battery.id), radius: 7.5, colour: theme.island.hoverRing))
                }
            }
        }
        .frame(height: IslandTheme.Metrics.usageRowHeight)
    }
}

/// One Clean money item: name 11 pt `ink2`, amount 600 12 pt (spent grey, runway toned), a runway after it,
/// rails when unreadable. The amount is the hover target.
struct IslandMoneyItem: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let row: MoneyRowModel
    var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CleanMoneyLayout.nameGap) {
            Text(row.name).font(Fonts.sys(11)).foregroundStyle(theme.panel.ink2)
            amount
                .modifier(HoverRing(shown: hovered, radius: 5, colour: palette.hoverRing))
                .hoverTarget(id: IslandHoverIDs.money(row.id), label: row.hoverLabel)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.hoverLabel)
    }

    @ViewBuilder private var amount: some View {
        if let figure = row.amount {
            HStack(alignment: .firstTextBaseline, spacing: CleanMoneyLayout.suffixGap) {
                Text(figure).font(Fonts.num(12, .semibold)).foregroundStyle(IslandMoneyTone.amount(row, theme.panel))
                if CleanMoneyLayout.showsSuffix(row), let suffix = row.suffix {
                    Text(suffix).font(Fonts.sys(11)).foregroundStyle(IslandMoneyTone.suffix(row, theme.panel))
                }
            }
        } else {
            HStack(spacing: 6) {
                Rectangle().fill(palette.idleMark).frame(width: 1, height: 12)
                Rectangle().fill(palette.idleMark).frame(width: 1, height: 12)
            }
            .frame(minWidth: 26)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        }
    }
}

enum IslandMoneyTone {
    static func amount(_ row: MoneyRowModel, _ palette: PanelPalette = .black) -> Color {
        switch row.emphasis {
        case .attention: palette.toneText(Theme.attention)
        case .warn: palette.toneText(Theme.warn)
        case .normal: row.isSpent ? palette.ink2 : palette.ink
        }
    }

    static func suffix(_ row: MoneyRowModel, _ palette: PanelPalette = .black) -> Color {
        row.emphasis == .normal ? palette.ink2 : amount(row, palette)
    }
}

/// Clean usage: the two battery rows, then one line of money under the batteries when any source is configured and
/// read (no placeholders). An amount is shown whole or not at all: a line too narrow leaves sources out in the order
/// Hetzner, OpenAI, then from the end (a runway stays while it is amber or red). No rule under it: spacing
/// separates it from the rows.
struct CleanUsageView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.islandSize) private var size
    var hover: HoverTargetID?
    /// The accounts in use as the island took them at its open (`IslandUIState.inUse`, P812).
    var inUse = AccountsInUse.none

    static let padding = EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8)
    /// The money line starts under the batteries.
    static var moneyIndent: CGFloat { IslandBatteryRow.markSize + IslandBatteryRow.markGap }
    /// The money line's width in content `contentWidth` wide (Settings › Island › Width, P401).
    static func moneyWidth(contentWidth: CGFloat = IslandSize.standard.contentWidth) -> CGFloat {
        contentWidth - padding.leading - padding.trailing - moneyIndent
    }

    var body: some View {
        let usage = env.usage
        let money = env.settings.islandShowsMoney ? usage.shownMoney(env.settings).filter { $0.amount != nil } : []
        let fitted = CleanMoneyLayout.fit(money, width: Self.moneyWidth(contentWidth: size.contentWidth), dropOrder: CleanMoneyLayout.dropOrder,
                                          measure: CleanMoneyLayout.measure)
        VStack(alignment: .leading, spacing: IslandTheme.Metrics.islandUsageRowGap) {
            ForEach(IslandUsageRows.rows(usage, inUse: inUse, first: env.settings.usageFirst)) { row in
                IslandBatteryRow(row: row, now: usage.now, hover: hover, inUse: inUse)
            }
            if !fitted.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: CleanMoneyLayout.itemGap) {
                    ForEach(fitted) { item in IslandMoneyItem(row: item, hovered: hover == .money(item.id)) }
                }
                .frame(height: 18)
                .padding(.leading, Self.moneyIndent)
            }
        }
        .padding(Self.padding)
        .frame(width: size.contentWidth, alignment: .topLeading)
    }
}

/// Detailed usage: the two battery rows, then the money grid across the content's width (`MoneyRowsView`), so long
/// names and several keys of a source fit whole. Its hover label shows in the header across the notch, like Clean's,
/// so no empty caption band waits under the block.
struct DetailedUsageView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.islandSize) private var size
    /// Read once and passed to the money grid (P559).
    @Environment(\.juiceTheme) private var theme
    var hover: HoverTargetID?
    /// The accounts in use as the island took them at its open (`IslandUIState.inUse`, P812).
    var inUse = AccountsInUse.none

    static let horizontalPadding: CGFloat = 6
    /// The money grid's width: the content's, less the block's sides.
    static func moneyWidth(contentWidth: CGFloat = IslandSize.standard.contentWidth) -> CGFloat { contentWidth - 2 * horizontalPadding }

    var body: some View {
        let usage = env.usage
        let showsMoney = env.settings.islandShowsMoney && !usage.shownMoney(env.settings).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: IslandTheme.Metrics.islandUsageRowGap) {
                ForEach(IslandUsageRows.rows(usage, inUse: inUse, first: env.settings.usageFirst)) { row in
                    IslandBatteryRow(row: row, now: usage.now, hover: hover, inUse: inUse)
                }
            }
            if showsMoney {
                MoneyRowsView(rows: usage.shownMoney(env.settings), width: Self.moneyWidth(contentWidth: size.contentWidth), palette: theme.panel)
                    .padding(.top, 8)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(width: size.contentWidth,
               height: IslandTheme.Metrics.detailedUsageHeight(money: showsMoney, moneyCount: usage.shownMoney(env.settings).count),
               alignment: .topLeading)
    }
}

/// The island's battery rows, Claude's then Codex's, each as Usage shows first arranges it (P812): the usage block, and
/// U's order over it (`UsageCycle`).
enum IslandUsageRows {
    @MainActor static func rows(_ usage: any UsageModel, inUse: AccountsInUse, first: UsageFirst) -> [ProviderRowModel] {
        [usage.claudeRow, usage.codexRow].compactMap { $0 }.map { inUse.arranged($0, first: first) }
    }
}

/// A header hover label split across the notch: the name must fit the left wing, the details the right one. Parts
/// leave from the end (one always stays), then the size steps down from 11.5 to 10 pt until both halves fit, so
/// nothing is cut mid-word or reaches the notch.
enum IslandSlotText {
    static let size: CGFloat = 11.5
    static let minimumSize: CGFloat = 10

    @MainActor static func fitSplit(_ label: HoverLabel, left: CGFloat, right: CGFloat) -> (label: HoverLabel, size: CGFloat) {
        var size = Self.size
        while true {
            var fitted = label
            while fitted.parts.count > 1, partsWidth(fitted.parts, size: size) > right { fitted.parts.removeLast() }
            let fits = nameWidth(fitted.name, size: size) <= left && partsWidth(fitted.parts, size: size) <= right
            if fits || size <= minimumSize { return (fitted, size) }
            size -= 0.5
        }
    }

    @MainActor static func nameWidth(_ name: String, size: CGFloat) -> CGFloat {
        ceil(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).size().width)
    }

    /// The details as drawn: parts joined by "·" with 5 pt each side.
    @MainActor static func partsWidth(_ parts: [String], size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        let text = parts.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.reduce(0, +)
        let dot = NSAttributedString(string: "·", attributes: [.font: font]).size().width + 10
        return ceil(text + CGFloat(max(0, parts.count - 1)) * dot)
    }
}
