import JuiceCore
import SwiftUI

/// The usage header's and Clean block's layout maths (prototype L437-483, L161-169, L1208-1220; spec §4.1-4.2),
/// kept pure so it is unit-tested.
enum UsageLayout {
    // MARK: Window header

    static let padding = WindowTheme.Metrics.headerPadding          // 0 22 (the band sits right under the title line)
    static let bottomPadding: CGFloat = 8                            // under the band
    static let rowHeight = WindowTheme.Metrics.headerRowHeight       // 31 (min)
    static let rowGap: CGFloat = 4                                   // between the Claude and Codex rows
    static let lineGap: CGFloat = 10                                 // between wrapped lines (money, a second strip line)
    static let markGapSection: CGFloat = 12
    static let markGapStrip: CGFloat = 10                            // 6 gap + 4 margin
    static let groupGap: CGFloat = 22                                // between provider groups (and the money) on a line
    static let titleLineGap: CGFloat = 18                            // the toolbar's start → the batteries on the title line
    static let captionLeading: CGFloat = 24, captionTrailing: CGFloat = 24
    static let moneyLeading: CGFloat = 24                            // after a 1 pt rule
    static let moneyTopPadding: CGFloat = 8                          // below the rule when the money sits under
    static let stripMoneyGap = CGSize(width: 22, height: 8)
    static let nameGap: CGFloat = 5, nameHeight: CGFloat = 13

    /// A battery row's height: the mark (20) or, with names, the mark and its blank label (20 + 5 + 13).
    static func batteryLineHeight(names: Bool) -> CGFloat { names ? Theme.Mark.row + nameGap + nameHeight : Theme.Mark.row }

    /// One provider group's width on a line: mark, gap, n batteries of 45 with 6 between.
    static func groupWidth(batteries: Int, markGap: CGFloat = markGapStrip) -> CGFloat {
        guard batteries > 0 else { return Theme.Mark.row }
        return Theme.Mark.row + markGap + CGFloat(batteries) * Theme.Battery.cellWidth + CGFloat(batteries - 1) * Theme.Battery.gap
    }

    /// The money the window header draws: only sources with a figure. A source with no reader or no key has nothing
    /// to say here (Settings › Money lists it), so it takes no room: no empty rails, and with none, no money area.
    static func headerMoney(_ rows: [MoneyRowModel]) -> [MoneyRowModel] {
        rows.filter { $0.amount != nil }
    }

    // MARK: Clean usage block (island)

    static let cleanPadding = EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8)
    static let cleanMarkGap: CGFloat = 10
    static let cleanMoneyGap: CGFloat = IslandTheme.Metrics.cleanMoneyGap   // 14
    static let cleanItemGap: CGFloat = 4                                    // name → amount
    static let cleanRowOne: Set<String> = ["OpenRouter", "Anthropic"]

    /// The source an account's id names (`OpenRouter 2` is OpenRouter's), so each of a source's keys sits and leaves
    /// where its first does.
    static func sourceName(_ id: String) -> String { MoneyAccount(rawValue: id)?.source.rawValue ?? id }

    /// Which sources sit in which Clean row: OpenRouter's and Anthropic's keys beside Claude, the rest (at most three)
    /// beside Codex, each in panel order.
    static func cleanRows(_ ids: [String]) -> (claude: [String], codex: [String]) {
        (ids.filter { cleanRowOne.contains(sourceName($0)) }, Array(ids.filter { !cleanRowOne.contains(sourceName($0)) }.prefix(3)))
    }

    /// The order amounts leave a Clean row that is too narrow (spec §4.2): Hetzner, OpenAI, RunPod; then, beside
    /// Claude, Anthropic before OpenRouter.
    static let cleanDropOrder = ["Hetzner", "OpenAI", "RunPod", "Anthropic", "OpenRouter"]

    /// The amounts that fit whole in `width` (never clipped), dropping per `cleanDropOrder`; ids in `keep` (RunPod while
    /// its runway is amber or red) leave last. `widths` are each item's drawn width (name, gap, figure).
    static func fitCleanRow(_ ids: [String], widths: [String: CGFloat], in width: CGFloat, keep: Set<String> = []) -> [String] {
        func total(_ list: [String]) -> CGFloat {
            list.map { widths[$0] ?? 0 }.reduce(0, +) + CGFloat(max(0, list.count - 1)) * cleanMoneyGap
        }
        var shown = ids
        let ranked = cleanDropOrder.flatMap { name in ids.filter { sourceName($0) == name }.reversed() }
        let order = ranked.filter { !keep.contains($0) } + ranked.filter { keep.contains($0) }
        let rest = ids.filter { !cleanDropOrder.contains(sourceName($0)) }
        for id in rest.reversed() + order where total(shown) > width && shown.contains(id) {
            shown.removeAll { $0 == id }
        }
        return shown
    }

    /// Room for money beside a Clean row: the block's inner width minus the row's mark and batteries and a 10 pt gap
    /// (620 inner: 280 beside six batteries, 331 beside five).
    static func cleanMoneyRoom(blockWidth: CGFloat, batteries: Int) -> CGFloat {
        let inner = blockWidth - cleanPadding.leading - cleanPadding.trailing
        return max(0, inner - groupWidth(batteries: batteries, markGap: cleanMarkGap) - cleanMarkGap)
    }
}
