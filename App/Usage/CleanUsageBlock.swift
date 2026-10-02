import JuiceCore
import SwiftUI

/// The island's Clean usage block (prototype `cleanSectionHTML`, L149-172, L1205-1227; spec §4.2), for D to place
/// under the island header: 80 pt (6 + 29 · 2 + 8 + 8), padding 6 8 0, two rows of mark + batteries (gap 10), and the
/// money right-aligned on the same rows (gap 14): OpenRouter and Anthropic beside Claude, OpenAI, RunPod and Hetzner
/// beside Codex. Clean money is "Name amount" (name 11 `ink2`, amount 600 12) with no "spent" and no "/mo"; only a
/// runway keeps its suffix. An amount is shown whole or not at all: a row too narrow leaves amounts out in the order
/// Hetzner, OpenAI, RunPod (RunPod stays while its runway is amber or red).
struct CleanUsageBlock: View {
    @Environment(\.juiceTheme) private var theme
    @Environment(AppEnvironment.self) private var env
    /// The block's width (the island's content width, 636 at the prototype's 660).
    var width: CGFloat = IslandTheme.Metrics.contentWidth
    var showsMoney = true
    /// The 0.5 pt `white 7 %` rule along the bottom, inset 6.
    var showsRule = true

    private typealias L = UsageLayout

    var body: some View {
        let rows = env.usage.panel.rows
        let money = showsMoney ? env.usage.shownMoney(env.settings) : []
        let placed = L.cleanRows(money.map(\.id))
        VStack(alignment: .leading, spacing: IslandTheme.Metrics.usageRowGap) {
            ForEach(0..<max(rows.count, placed.codex.isEmpty ? 1 : 2), id: \.self) { index in
                line(rows.indices.contains(index) ? rows[index] : nil,
                     money: fitted(index == 0 ? placed.claude : placed.codex, beside: rows.indices.contains(index) ? rows[index] : nil, from: money))
            }
        }
        .padding(.top, L.cleanPadding.top)
        .padding(.horizontal, L.cleanPadding.leading)
        .frame(width: width, height: IslandTheme.Metrics.cleanUsageHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if showsRule { theme.island.usageHairline.frame(height: 0.5).padding(.horizontal, 6) }
        }
    }

    private func line(_ row: ProviderRowModel?, money: [MoneyRowModel]) -> some View {
        HStack(spacing: L.cleanMarkGap) {
            if let row { UsageBatteryRow(row: row, now: env.usage.now, markGap: L.cleanMarkGap).fixedSize() }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: L.cleanMoneyGap) {
                ForEach(money, id: \.id) { CleanMoneyItem(row: $0, detail: env.usage.moneyDetails[$0.id]) }
            }
        }
        .frame(height: IslandTheme.Metrics.usageRowHeight)
    }

    private func fitted(_ ids: [String], beside row: ProviderRowModel?, from money: [MoneyRowModel]) -> [MoneyRowModel] {
        let rows = ids.compactMap { id in money.first { $0.id == id } }
        let widths = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, CleanMoneyItem.width($0, detail: env.usage.moneyDetails[$0.id])) })
        let room = row.map { L.cleanMoneyRoom(blockWidth: width, batteries: $0.batteries.count) }
            ?? width - L.cleanPadding.leading - L.cleanPadding.trailing
        let keep = Set(rows.filter { $0.emphasis != .normal }.map(\.id))
        let shown = L.fitCleanRow(ids, widths: widths, in: room, keep: keep)
        return rows.filter { shown.contains($0.id) }
    }
}

/// One Clean amount: the name (11 `ink2`), 4 pt, the figure. Hover target; right-click raises the source menu.
struct CleanMoneyItem: View {
    @Environment(\.juiceTheme) private var theme
    let row: MoneyRowModel
    var detail: MoneyDetail?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UsageLayout.cleanItemGap) {
            Text(row.name).font(.system(size: 11)).foregroundStyle(theme.panel.ink2)
            MoneyFigureView(row: row, style: .clean, detail: detail)
        }
        .fixedSize()
        .moneyTarget(row.id)
    }

    @MainActor
    static func width(_ row: MoneyRowModel, detail: MoneyDetail?) -> CGFloat {
        ceil(MoneyFigureText.measure(row.name, font: .systemFont(ofSize: 11))) + UsageLayout.cleanItemGap
            + MoneyFigureText.width(row, style: .clean, detail: detail)
    }
}
