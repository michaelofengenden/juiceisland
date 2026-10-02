import JuiceCore
import SwiftUI

/// The money as columns of up to three rows, filled column by column like `MoneyRowsView` (prototype `moneyGrid`):
/// name (12.5 ink) then amount, rows 22 tall. Only as many rows and columns as there are sources (one column for up
/// to three), so a short list leaves no empty cells.
/// - `.wide` (window header, money beside the batteries; Detailed island): columns `auto 1fr 24 auto 1fr`, gap 10;
///   both amount columns as wide as the widest amount, amounts right-aligned.
/// - `.narrow` (window header, money under the batteries): columns `auto auto 40 auto auto`, gap 14, packed to the left.
struct UsageMoneyGrid: View {
    @Environment(\.juiceTheme) private var theme
    enum Mode: Sendable { case wide, narrow }

    let rows: [MoneyRowModel]
    var details: [String: MoneyDetail] = [:]
    var mode: Mode = .wide

    static let rowHeight: CGFloat = 22

    var body: some View {
        let gap: CGFloat = mode == .wide ? 10 : 14
        let gutter: CGFloat = mode == .wide ? 24 : 40
        let amountWidth = mode == .wide ? Self.amountColumnWidth(rows, details: details) : nil
        let shape = Self.shape(count: rows.count)
        Grid(alignment: .leading, horizontalSpacing: gap, verticalSpacing: 0) {
            ForEach(0..<shape.rows, id: \.self) { index in
                GridRow {
                    name(row(index))
                    amount(row(index), width: amountWidth)
                    if shape.columns > 1 {
                        Color.clear.frame(width: gutter, height: 1)
                        name(row(index + shape.rows))
                        amount(row(index + shape.rows), width: amountWidth)
                    }
                }
                .frame(height: Self.rowHeight)
            }
        }
        .fixedSize()
    }

    /// Rows and columns for `count` accounts: one column of up to three, then a second; past six, both columns grow a
    /// row for each two, so none is left out.
    static func shape(count: Int) -> (rows: Int, columns: Int) {
        let count = max(count, 0)
        return (count > 6 ? (count + 1) / 2 : min(count, 3), count > 3 ? 2 : (count > 0 ? 1 : 0))
    }

    private func row(_ index: Int) -> MoneyRowModel? { index < rows.count ? rows[index] : nil }

    @ViewBuilder private func name(_ row: MoneyRowModel?) -> some View {
        if let row {
            Text(row.name)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.panel.ink)
                .lineLimit(1)
                .fixedSize()
                .contextMenuForMoney(row.id)
        } else {
            Color.clear.frame(width: 0, height: 1)
        }
    }

    @ViewBuilder private func amount(_ row: MoneyRowModel?, width: CGFloat?) -> some View {
        if let row {
            MoneyFigureView(row: row, style: .full, detail: details[row.id])
                .moneyTarget(row.id)
                .frame(minWidth: width, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        } else {
            Color.clear.frame(width: width ?? 0, height: 1)
        }
    }

    /// CSS `1fr` columns in a grid sized to its content: both amount columns take the widest amount of every row (the
    /// grid grows past six, so every row is measured).
    @MainActor
    static func amountColumnWidth(_ rows: [MoneyRowModel], details: [String: MoneyDetail]) -> CGFloat {
        rows.map { MoneyFigureText.width($0, style: .full, detail: details[$0.id]) }.max() ?? 0
    }
}

/// One source in the Strip header: "Name amount" (name 12.5 ink, 6 pt, the amount); only the amount is a hover target.
struct UsageMoneyItem: View {
    @Environment(\.juiceTheme) private var theme
    let row: MoneyRowModel
    var detail: MoneyDetail?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.name).font(.system(size: 12.5)).foregroundStyle(theme.panel.ink)
                .contextMenuForMoney(row.id)
            MoneyFigureView(row: row, style: .full, detail: detail)
                .moneyTarget(row.id)
        }
        .frame(height: 22)
        .fixedSize()
    }
}

private struct MoneyNameMenu: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let id: String

    func body(content: Content) -> some View {
        content.contextMenu { UsageMenus.money(id, env: env) }
    }
}

extension View {
    /// Money names are not hover targets; they raise the source's menu (prototype.md §3).
    func contextMenuForMoney(_ id: String) -> some View { modifier(MoneyNameMenu(id: id)) }
}
