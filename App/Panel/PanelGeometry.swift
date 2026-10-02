import CoreGraphics

/// The desktop panel's size (Juice spec §2.1, Juice Island spec §4.3, amendment 12), from Juice's own tokens in
/// `Theme.Panel` and `Theme.Battery`. With both provider rows and money it is Juice's 362 × 184 pt; a part that is not
/// there (no money shown, one provider only) takes no room, and a panel with nothing to draw has no size at all.
/// The window around it is 24 pt larger on every side, so the panel's shadow is never clipped (410 × 232 pt).
enum PanelGeometry {
    typealias P = Theme.Panel
    typealias B = Theme.Battery

    static let width: CGFloat = P.size.width
    /// Transparent room around the panel inside its window, for the shadow.
    static let margin: CGFloat = 24
    /// The band between the batteries and the money: 6 above, the 1 pt line, 13 below.
    static let moneyBand: CGFloat = P.dividerAbove + 1 + P.dividerBelow
    /// Three money rows (two columns, filled column by column).
    static let moneyHeight: CGFloat = 3 * P.moneyRowHeight

    /// The money rows for `count` accounts: three, and one more for each two past six (`MoneyGrid`).
    static func moneyHeight(count: Int) -> CGFloat { CGFloat(MoneyGrid.rows(count: count)) * P.moneyRowHeight }

    /// Where the batteries go: the panel less its padding, the 20 pt mark and the 10 pt gap after it (300 pt).
    static let batteryAreaWidth: CGFloat = width - 2 * P.padding - P.markSize - P.markGap

    /// The batteries that fit a row: six Claude batteries fill it exactly.
    static var maxBatteriesPerRow: Int { Int((batteryAreaWidth + B.gap) / (B.cellWidth + B.gap)) }

    /// A row of `batteries`: each 45 pt with its nub, 6 pt apart (six: 300 pt, five: 249 pt).
    static func rowWidth(batteries: Int) -> CGFloat {
        guard batteries > 0 else { return 0 }
        return CGFloat(batteries) * B.cellWidth + CGFloat(batteries - 1) * B.gap
    }

    /// The panel for `providerRows` battery rows, with or without the money (`moneyCount` accounts: past six, it grows a
    /// row for each two); nil when there is nothing to draw.
    static func panelSize(providerRows: Int, showsMoney: Bool, moneyCount: Int = 0) -> CGSize? {
        guard providerRows > 0 || showsMoney else { return nil }
        var height = 2 * P.padding
        if providerRows > 0 { height += CGFloat(providerRows) * P.rowHeight + CGFloat(providerRows - 1) * P.rowGap }
        if showsMoney { height += (providerRows > 0 ? moneyBand : 0) + moneyHeight(count: moneyCount) }
        return CGSize(width: width, height: height)
    }

    static func windowSize(for panelSize: CGSize) -> CGSize {
        CGSize(width: panelSize.width + 2 * margin, height: panelSize.height + 2 * margin)
    }
}
