import JuiceCore
import SwiftUI

/// Spec §2.3: two column pairs, three rows, one amount and at most one grey suffix per source; more than six accounts
/// take a row more for each two (`MoneyGrid`), so none is left out. `width` is what the grid fills (the panel's 330 pt,
/// the Detailed island's content): its columns are the prototype's `auto 1fr 24 auto 1fr` (`MoneyGrid.columns`).
struct MoneyRowsView: View {
    let rows: [MoneyRowModel]
    let width: CGFloat
    /// The parent's theme's tokens, passed down (P559): Black's `Theme` unless it draws on Glass.
    var palette = PanelPalette.black
    @Environment(\.panelActions) private var actions

    var body: some View {
        let lines = MoneyGrid.rows(count: rows.count)
        let columns = MoneyGrid.columns(rows, width: width)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: MoneyGrid.gap, verticalSpacing: 0) {
            ForEach(0..<lines, id: \.self) { index in
                GridRow {
                    name(row(index), width: columns.names.0)
                    amount(row(index), width: columns.amounts.0)
                    Color.clear.frame(width: Theme.Panel.moneyGutter, height: 1).gridCellUnsizedAxes(.vertical)
                    name(row(index + lines), width: columns.names.1)
                    amount(row(index + lines), width: columns.amounts.1)
                }
                .frame(height: Theme.Panel.moneyRowHeight)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func row(_ index: Int) -> MoneyRowModel? { index < rows.count ? rows[index] : nil }

    @ViewBuilder private func name(_ row: MoneyRowModel?, width: CGFloat) -> some View {
        if let row {
            MoneyNameText(row: row)
                .font(Theme.moneyNameFont)
                .foregroundStyle(palette.ink)
                .contextMenu { menu(row) }
                .frame(width: width, alignment: .leading)
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }

    @ViewBuilder private func amount(_ row: MoneyRowModel?, width: CGFloat) -> some View {
        if let row {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let amount = row.amount {
                    Text(amount).font(Theme.moneyAmountFont).foregroundStyle(amountColour(row))
                    if row.isSpent {
                        Text("spent").font(Theme.moneySuffixFont).foregroundStyle(palette.ink2)
                    } else if let suffix = row.suffix {
                        Text(suffix).font(Theme.moneySuffixFont).foregroundStyle(suffixColour(row))
                    }
                } else {
                    rails
                }
            }
            .lineLimit(1)
            // An amount is never cut: with long names (DigitalOcean, ElevenLabs) the name gives way.
            .fixedSize()
            // The hooks take the amount's own bounds; the column's width that right-aligns it comes after them, so
            // the blank space left of a number is neither a hover target nor a right-click target.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.hoverLabel)
            .hoverTarget(id: "money:\(row.id)", label: row.hoverLabel)
            .contextMenu { menu(row) }
            .frame(width: width, alignment: .trailing)
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }

    /// Spec §2.6 gives the menu to the whole row, so the name and the amount both raise it.
    @ViewBuilder private func menu(_ row: MoneyRowModel) -> some View {
        Button("Refresh source") { actions.refreshSource(row.id) }.disabled(!actions.canRefreshSource(row.id))
        Button("Open billing page") { actions.openBillingPage(row.id) }
        Button("Manage source…") { actions.manageSource(row.id) }
    }

    /// Two open vertical rails: the source exists but cannot be read.
    private var rails: some View {
        HStack(spacing: 6) {
            Rectangle().fill(palette.line).frame(width: 1, height: 9)
            Rectangle().fill(palette.line).frame(width: 1, height: 9)
        }
        .padding(.trailing, 2)
    }

    private func amountColour(_ row: MoneyRowModel) -> Color {
        switch row.emphasis {
        case .attention: palette.toneText(Theme.attention)
        case .warn: palette.toneText(Theme.warn)
        case .normal: row.isSpent ? palette.ink2 : palette.ink
        }
    }

    private func suffixColour(_ row: MoneyRowModel) -> Color {
        row.emphasis == .normal ? palette.ink2 : amountColour(row)
    }
}

/// A money name that may be cut, so two keys of one source never read alike: a further key's own name keeps its number
/// (`OpenR… 2` beside `OpenRou…`), and the owner's label gives way in its middle (`Clie…e Co`, `Clie…Beta`).
struct MoneyNameText: View {
    let row: MoneyRowModel

    var body: some View {
        switch Self.parts(row) {
        case let .slot(source, number):
            HStack(spacing: 0) {
                Text(source).lineLimit(1).truncationMode(.tail)
                Text(number).lineLimit(1).fixedSize()
            }
        case let .whole(name, cut):
            Text(name).lineLimit(1).truncationMode(cut)
        }
    }

    enum Parts: Equatable {
        /// A further key's own name: the source's name, cut at its end, then ` 2`.
        case slot(String, String)
        case whole(String, Text.TruncationMode)
    }

    static func parts(_ row: MoneyRowModel) -> Parts {
        guard let account = MoneyAccount(rawValue: row.id), row.name == account.defaultName else { return .whole(row.name, .middle) }
        return account.isFirst ? .whole(row.name, .tail) : .slot(account.source.name, " \(account.slot)")
    }
}

/// How the panel's and the Detailed island's money fill their two columns, the first column first: three rows for up to
/// six accounts (Juice spec §2.3), and one row more for each two past six (a second key, a new source).
enum MoneyGrid {
    /// Between a name and its amount, and on either side of the gutter.
    static let gap: CGFloat = 10

    static func rows(count: Int) -> Int { max(3, (count + 1) / 2) }

    /// The four columns' widths in `width`, as the prototype's `auto 1fr 24 auto 1fr` lays them out: each name column
    /// as wide as its longest name, the two amount columns sharing the rest (a wider amount taking what it needs). When
    /// the names and amounts do not fit, an amount keeps its whole width (it is never cut, nor pushed past the edge)
    /// and the names share what is left, the shorter column keeping its longest name whole.
    @MainActor static func columns(_ rows: [MoneyRowModel], width: CGFloat) -> (names: (CGFloat, CGFloat), amounts: (CGFloat, CGFloat)) {
        let lines = self.rows(count: rows.count)
        let (first, second) = (rows.prefix(lines), rows.dropFirst(lines))
        return columns(names: (nameWidth(first), nameWidth(second)), amounts: (amountWidth(first), amountWidth(second)), width: width)
    }

    /// `columns` from the measured widths: the names' longest and the amounts' widest per column.
    static func columns(names: (CGFloat, CGFloat), amounts: (CGFloat, CGFloat), width: CGFloat)
        -> (names: (CGFloat, CGFloat), amounts: (CGFloat, CGFloat)) {
        let room = max(0, width - Theme.Panel.moneyGutter - 4 * gap)
        let forAmounts = room - names.0 - names.1
        if forAmounts >= amounts.0 + amounts.1 {
            // Everything fits: 1fr each, unless one amount is wider than half.
            let half = forAmounts / 2
            let first = amounts.0 > half ? amounts.0 : (amounts.1 > half ? forAmounts - amounts.1 : half)
            return ((names.0, names.1), (first, forAmounts - first))
        }
        let forNames = max(0, room - amounts.0 - amounts.1)
        let half = forNames / 2
        let first = names.0 <= half ? names.0 : (names.1 <= half ? forNames - names.1 : half)
        return ((first, forNames - first), amounts)
    }

    /// A column's longest name as drawn.
    @MainActor static func nameWidth(_ rows: some Collection<MoneyRowModel>) -> CGFloat {
        rows.map { ceil(measure($0.name, NSFont.systemFont(ofSize: 12.5))) + 1 }.max() ?? 0
    }

    /// A column's amount width: its widest amount with its suffix (`$11.21 spent`), or the rails.
    @MainActor static func amountWidth(_ rows: some Collection<MoneyRowModel>) -> CGFloat {
        rows.map { row in
            guard let amount = row.amount else { return 10 }
            var width = measure(amount, NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold))
            if let suffix = row.isSpent ? "spent" : row.suffix { width += 5 + measure(suffix, NSFont.systemFont(ofSize: 11)) }
            return ceil(width) + 1
        }.max() ?? 0
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }
}
