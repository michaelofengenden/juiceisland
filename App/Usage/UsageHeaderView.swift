import JuiceCore
import SwiftUI

/// The window's header: the toolbar line (in the title bar, on the traffic lights' line) and the usage.
/// - When the batteries and the money that has a figure fit between the toolbar's two ends, they sit on that line and
///   the header is one line; the hover caption takes the room left before the trailing buttons.
/// - Otherwise the usage gets one tight band under the line, per General › Window header:
///   **Section** (default): the Claude and Codex rows (min 31, 4 apart), the money grid packed after them behind a
///   1 pt rule (under them when it does not fit beside), the caption in the room left.
///   **Strip**: the batteries stay on the title line while they fit there, with the money alone on one line under it;
///   else every battery on one line (wrapping when it must), the money after them or on the next line, the caption in
///   the room left.
/// - Before the band takes every group, the groups that fit (Claude first) stay on the title line and only the others
///   go under it with the money, so the title line is never an empty black band beside the traffic lights.
/// Money sources with no figure (no reader, no key) are left out, never drawn as empty rails; with none, there is no
/// money area and no rule. Batteries and marks open the account list; with Hover details off a floating chip replaces
/// the caption. Owner: stream B.
struct UsageHeaderView<Leading: View, Trailing: View>: View {
    @Environment(\.juiceTheme) private var theme
    @Environment(AppEnvironment.self) private var env
    @Environment(\.windowChrome) private var chrome
    @State private var hover: UsageHoverModel
    @State private var presenter = UsageOverlayPresenter()
    @State private var targetFrames: [HoverTargetID: CGRect] = [:]
    @State private var moneyBlockFrame: CGRect?
    /// The header's frame in the window (global), to place the floating account list and chip.
    @State private var globalFrame: CGRect = .zero
    private let leading: Leading
    private let trailing: Trailing
    private let allowsTitleLine: Bool

    /// `hover` freezes a caption for renders; `allowsTitleLine: false` keeps the usage in its band.
    init(hover: HoverTargetID? = nil, allowsTitleLine: Bool = true, @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        _hover = State(initialValue: UsageHoverModel(shown: hover))
        self.allowsTitleLine = allowsTitleLine
        self.leading = leading()
        self.trailing = trailing()
    }

    private typealias L = UsageLayout

    var body: some View {
        Group {
            if allowsTitleLine {
                ViewThatFits(in: .horizontal) {
                    titleLine(withMoney: true)
                    if env.settings.windowHeader == .strip, showsMoney { batteriesOnTitleLine }
                    // Too narrow for every group: the groups that fit stay on the title line and the rest go under it,
                    // so the title line is never an empty black band beside the traffic lights.
                    ForEach(splits, id: \.self) { kept in splitLines(keeping: kept) }
                    twoLines
                }
            } else {
                twoLines
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            Color.black.opacity(0.001).contextMenu { UsageBackgroundMenuItems(showing: .window) }
        }
        .coordinateSpace(name: UsageInteraction.space)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { globalFrame = $0 }
        .environment(\.usageInteraction, interaction)
        .onChange(of: hover.shown) { _, shown in updateChip(shown) }
        .onDisappear { presenter.closeList(); presenter.hideChip() }
    }

    // MARK: One line

    /// Everything on the traffic lights' line: toolbar start, batteries, money (unless `withMoney` is false), caption,
    /// toolbar end. The batteries centre on the lights; with account names on, the names hang under the line (the
    /// header grows by what they need past it) instead of lifting the batteries off the lights' line.
    private func titleLine(withMoney: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            leading.frame(height: chrome.lineHeight)
            lineUsage(withMoney: withMoney)
                .padding(.top, (chrome.lineHeight - Theme.Mark.row) / 2)
                .padding(.leading, L.titleLineGap)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Usage")
            fillingCaption.frame(height: chrome.lineHeight)
            trailing.frame(height: chrome.lineHeight)
        }
        .frame(minHeight: chrome.lineHeight, alignment: .top)
        .padding(.bottom, names ? L.bottomPadding / 2 : 0)
        .background(TitleLineDragArea())
    }

    /// Strip, when only the batteries fit on the title line: they stay there, and the money is the one line under it.
    private var batteriesOnTitleLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine(withMoney: false)
            moneyLine
                .padding(.horizontal, L.padding.leading)
                .padding(.bottom, L.bottomPadding)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Money")
        }
    }

    // MARK: Split

    /// How many provider groups the title line may keep when not all fit, most first (none with a single group).
    private var splits: [Int] { Array((1..<max(1, env.usage.panel.rows.count)).reversed()) }

    /// The first `kept` groups on the title line (its spare room left plain: the caption is under it), the other
    /// groups and the money in the band under it, laid out as Section or Strip lays them out.
    private func splitLines(keeping kept: Int) -> some View {
        let rows = env.usage.panel.rows
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                leading.frame(height: chrome.lineHeight)
                HStack(alignment: .center, spacing: L.groupGap) {
                    ForEach(rows.prefix(kept)) { stripGroup($0) }
                }
                .fixedSize()
                .padding(.top, (chrome.lineHeight - Theme.Mark.row) / 2)
                .padding(.leading, L.titleLineGap)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Usage")
                Spacer(minLength: 16)
                trailing.frame(height: chrome.lineHeight)
            }
            .frame(minHeight: chrome.lineHeight, alignment: .top)
            .padding(.bottom, names ? L.bottomPadding / 2 : 0)
            .background(TitleLineDragArea())
            Group {
                switch env.settings.windowHeader {
                case .section: section(Array(rows.dropFirst(kept)))
                case .strip: strip(Array(rows.dropFirst(kept)))
                }
            }
            .padding(.horizontal, L.padding.leading)
            .padding(.bottom, L.bottomPadding)
            // The band wraps to whatever width it gets: only the title line decides whether this fits.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("More usage")
        }
    }

    // MARK: Two lines

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                leading
                Spacer(minLength: 16)
                trailing
            }
            .frame(height: chrome.lineHeight)
            .background(TitleLineDragArea())
            Group {
                switch env.settings.windowHeader {
                case .section: section(env.usage.panel.rows)
                case .strip: strip(env.usage.panel.rows)
                }
            }
            .padding(.horizontal, L.padding.leading)
            .padding(.bottom, L.bottomPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Usage")
        }
    }

    // MARK: Section

    /// The money beside the batteries when it fits, else under them.
    private func section(_ rows: [ProviderRowModel]) -> some View {
        ViewThatFits(in: .horizontal) {
            sectionWide(rows)
            sectionNarrow(rows)
        }
    }

    /// Batteries, then the money packed against them behind a 1 pt rule, then the caption in the room left.
    private func sectionWide(_ rows: [ProviderRowModel]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            batteryRows(rows)
            if showsMoney {
                UsageMoneyGrid(rows: money, details: env.usage.moneyDetails, mode: .wide)
                    .padding(.leading, L.moneyLeading)
                    .overlay(alignment: .leading) { theme.island.line.frame(width: 1) }
                    .padding(.leading, 1 + L.moneyLeading)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(UsageInteraction.space)) } action: { moneyBlockFrame = $0 }
            }
            if env.settings.hoverDetails {
                caption.padding(.leading, L.captionLeading).padding(.trailing, L.captionTrailing)
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionNarrow(_ rows: [ProviderRowModel]) -> some View {
        VStack(alignment: .leading, spacing: L.lineGap) {
            HStack(alignment: .top, spacing: 0) {
                batteryRows(rows)
                if env.settings.hoverDetails {
                    caption.padding(.leading, L.captionLeading).padding(.trailing, L.captionTrailing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if showsMoney {
                UsageMoneyGrid(rows: money, details: env.usage.moneyDetails, mode: .narrow)
                    .padding(.top, L.moneyTopPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { theme.island.line.frame(height: 1) }
                    .padding(.top, 1)
                    .onAppear { moneyBlockFrame = nil }
            }
        }
    }

    private func batteryRows(_ rows: [ProviderRowModel]) -> some View {
        VStack(alignment: .leading, spacing: L.rowGap) {
            ForEach(rows) { row in
                UsageBatteryRow(row: row, now: env.usage.now, markGap: L.markGapSection, showsNames: names)
                    .frame(minHeight: L.rowHeight, alignment: names ? .topLeading : .leading)
            }
        }
        .fixedSize()
    }

    // MARK: Strip

    /// One line when it all fits (batteries, rule, money, caption); else the batteries (wrapping by group) with the
    /// caption beside them, and the money on the next line.
    private func strip(_ rows: [ProviderRowModel]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 0) {
                lineUsage(withMoney: true, rows: rows)
                fillingCaption
            }
            VStack(alignment: .leading, spacing: L.lineGap) {
                HStack(alignment: .center, spacing: 0) {
                    FlowRow(spacing: L.groupGap, lineSpacing: L.lineGap) {
                        ForEach(rows) { stripGroup($0) }
                    }
                    .layoutPriority(1)
                    fillingCaption
                }
                if showsMoney { moneyLine }
            }
        }
    }

    /// The Strip's money, wrapping when it must.
    private var moneyLine: some View {
        FlowRow(spacing: L.stripMoneyGap.width, lineSpacing: L.stripMoneyGap.height) {
            ForEach(money, id: \.id) { UsageMoneyItem(row: $0, detail: env.usage.moneyDetails[$0.id]) }
        }
    }

    /// Batteries, then (when any has a figure and `withMoney`) a short rule and the money, on one line at their own
    /// width.
    private func lineUsage(withMoney: Bool, rows: [ProviderRowModel]? = nil) -> some View {
        HStack(alignment: .center, spacing: L.groupGap) {
            ForEach(rows ?? env.usage.panel.rows) { stripGroup($0) }
            if withMoney, showsMoney {
                moneyRule
                HStack(spacing: L.stripMoneyGap.width) {
                    ForEach(money, id: \.id) { UsageMoneyItem(row: $0, detail: env.usage.moneyDetails[$0.id]) }
                }
                .frame(height: L.batteryLineHeight(names: names), alignment: names ? .top : .center)
            }
        }
        .fixedSize()
    }

    private func stripGroup(_ row: ProviderRowModel) -> some View {
        UsageBatteryRow(row: row, now: env.usage.now, markGap: L.markGapStrip, showsNames: names)
            .frame(height: L.batteryLineHeight(names: names), alignment: names ? .top : .center)
            .fixedSize()
    }

    /// The short rule between the batteries and the money on one line.
    private var moneyRule: some View {
        theme.island.line.frame(width: 1, height: Theme.Mark.row)
    }

    /// The caption in whatever room is left on a line (none needed to fit: it only ever takes what is spare), or a
    /// plain gap with Hover details off.
    @ViewBuilder private var fillingCaption: some View {
        if env.settings.hoverDetails {
            caption
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, L.captionLeading)
                .padding(.trailing, 12)
        } else {
            Spacer(minLength: 16)
        }
    }

    // MARK: Caption, chip, account list

    /// The full hover label (Juice §2.5 wording), dropping parts from the end when the gap is too narrow.
    private var caption: some View {
        HStack(spacing: 0) {
            if let target = hover.shown, let label = HoverLabelText.full(target, usage: env.usage) {
                FittedHoverLabel(label: label, size: 12)
            }
        }
        .frame(height: L.rowHeight, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var interaction: UsageInteraction {
        UsageInteraction(
            hover: { target, inside, frame in
                targetFrames[target] = frame
                if inside { hover.enter(target) } else { hover.leave(target) }
            },
            open: { provider, account, frame in openAccountList(provider, account: account, from: frame) })
    }

    private func openAccountList(_ provider: Provider, account: String?, from frame: CGRect) {
        hover.reset()
        let width = AccountListView.width(provider, usage: env.usage)
        let maxX = max(12, globalFrame.width - width - 12)
        let origin = CGPoint(x: min(max(12, frame.minX - 12), maxX), y: frame.maxY + 10)
        presenter.showList(AccountListView(provider: provider, selected: account) { [presenter] in presenter.closeList() },
                           at: global(origin), env: env, onClose: {})
    }

    /// Hover details off: the chip floats 10 pt under the target, centred; for an amount in the money block beside the
    /// batteries, 14 pt right of the block and centred on the row. Always 8 pt inside the window.
    private func updateChip(_ shown: HoverTargetID?) {
        guard !env.settings.hoverDetails, !presenter.isShowingList, let shown, let frame = targetFrames[shown],
              let label = HoverLabelText.full(shown, usage: env.usage) else {
            presenter.hideChip()
            return
        }
        let chip = HoverChipView(label: label)
        let size = presenter.fittingSize(chip, env: env)
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY + 10)
        if case .money = shown, let block = moneyBlockFrame {
            origin = CGPoint(x: block.maxX + 14, y: frame.midY - size.height / 2)
        }
        origin.x = min(max(8, origin.x), max(8, globalFrame.width - size.width - 8))
        presenter.showChip(chip, at: global(origin), env: env)
    }

    /// A point in the header (which spans the window's width) in the window's global space.
    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: globalFrame.minX + point.x, y: globalFrame.minY + point.y)
    }

    // MARK: Settings

    private var names: Bool { env.settings.accountNamesUnderBatteries }
    private var money: [MoneyRowModel] { UsageLayout.headerMoney(env.usage.shownMoney(env.settings)) }
    private var showsMoney: Bool { env.settings.windowShowsMoney && !money.isEmpty }
}

/// Items left to right, wrapping onto new lines (the Strip band's batteries and money). As wide as its longest line.
struct FlowRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty, needed > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(index)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
