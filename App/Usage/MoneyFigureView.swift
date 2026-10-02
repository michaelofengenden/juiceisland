import AppKit
import JuiceCore
import SwiftUI

/// How a money amount is drawn on each surface.
enum MoneyFigureStyle: Sendable {
    /// Window header (grid and strip), Detailed island: 600 12.5 amount, 11 pt grey suffix 5 pt after it, "spent" for
    /// money spent, rails (two 1 × 9 `line` bars) when not connected.
    case full
    /// The island's Clean rows: 600 12 amount, no "spent" and no "/mo"; only a runway suffix (RunPod), 4 pt after it;
    /// rails are 12 tall `idleMark`, at least 26 wide.
    case clean

    var amountSize: CGFloat { self == .full ? 12.5 : 12 }
    var suffixGap: CGFloat { self == .full ? 5 : 4 }
    static let suffixSize: CGFloat = 11
}

/// One source's amount (prototype `moneyAmount` / `cleanMoneyHTML`): the figure, at most one grey suffix, toned amber or
/// red by runway, grey when it is money spent; open rails when the source cannot be read.
struct MoneyFigureView: View {
    @Environment(\.juiceTheme) private var theme
    let row: MoneyRowModel
    var style: MoneyFigureStyle = .full
    var detail: MoneyDetail?

    var body: some View {
        if let amount = row.amount {
            HStack(alignment: .firstTextBaseline, spacing: style.suffixGap) {
                Text(amount)
                    .font(.system(size: style.amountSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(amountColour)
                if let suffix = MoneyFigureText.suffix(row, style: style, detail: detail) {
                    Text(suffix)
                        .font(.system(size: MoneyFigureStyle.suffixSize))
                        .foregroundStyle(row.emphasis == .normal ? theme.panel.ink2 : amountColour)
                }
            }
            .fixedSize()
        } else {
            rails
        }
    }

    private var rails: some View {
        let clean = style == .clean
        return HStack(spacing: 6) {
            Rectangle().frame(width: 1, height: clean ? 12 : 9)
            Rectangle().frame(width: 1, height: clean ? 12 : 9)
        }
        .foregroundStyle(clean ? theme.island.idleMark : theme.panel.line)
        .frame(minWidth: clean ? 26 : nil)
        .padding(.leading, clean ? 2 : 0)
        .padding(.trailing, clean ? 0 : 2)
    }

    private var amountColour: Color {
        switch row.emphasis {
        case .attention: theme.panel.toneText(Theme.attention)
        case .warn: theme.panel.toneText(Theme.warn)
        case .normal: row.isSpent ? theme.panel.ink2 : theme.panel.ink
        }
    }
}

/// The text rules behind `MoneyFigureView`, and widths measured with the same fonts (for equal grid columns and the
/// Clean rows' fit).
@MainActor
enum MoneyFigureText {
    static func suffix(_ row: MoneyRowModel, style: MoneyFigureStyle, detail: MoneyDetail?) -> String? {
        guard row.amount != nil else { return nil }
        switch style {
        case .full: return row.isSpent ? "spent" : row.suffix
        case .clean: return detail?.runwayHours != nil ? row.suffix : nil
        }
    }

    /// The drawn width of a figure, suffix included.
    static func width(_ row: MoneyRowModel, style: MoneyFigureStyle, detail: MoneyDetail?) -> CGFloat {
        guard let amount = row.amount else { return style == .clean ? 28 : 10 }
        var width = measure(amount, font: .monospacedDigitSystemFont(ofSize: style.amountSize, weight: .semibold))
        if let suffix = suffix(row, style: style, detail: detail) {
            width += style.suffixGap + measure(suffix, font: .systemFont(ofSize: MoneyFigureStyle.suffixSize))
        }
        return ceil(width)
    }

    static func measure(_ text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }
}
