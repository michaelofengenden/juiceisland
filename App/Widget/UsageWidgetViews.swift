import AppKit
import JuiceCore
import SwiftUI
import WidgetKit

/// The Usage widget's ink (P1224): white, as macOS draws its own widgets' on the desktop, with each state still its own
/// shape (P346). In full colour the providers' marks keep their colours and a low battery its amber; in the system's
/// one-colour looks (`mono`: the dimmed desktop's accented or vibrant rendering) everything is white at its own strength,
/// and nothing is an opaque grey, which those looks would turn into a white block. Veils (the track, the divider) are
/// white at a little opacity in both.
struct UsageInk: Equatable, Sendable {
    var mono: Bool

    static let ink = Color.white
    static let ink2 = Color.white.opacity(0.78)
    static let line = Color.white.opacity(0.66)
    static let track = Color.white.opacity(0.2)
    static let divider = Color.white.opacity(0.32)

    var warn: Color { mono ? Self.ink : Theme.warn }
    var attention: Color { mono ? Self.ink : Theme.attention }
    /// A provider's mark: its own colour (nil) in full colour, white in the one-colour looks.
    var markTint: Color? { mono ? Self.ink : nil }
    /// An amount's colour: amber or red where the panel draws them, in full colour.
    func amount(_ row: WidgetSnapshot.Money) -> Color {
        guard !mono else { return row.isSpent ? Self.ink2 : Self.ink }
        switch row.emphasis {
        case .attention: return Theme.attention
        case .warn: return Theme.warn
        case .normal: return row.isSpent ? Self.ink2 : Self.ink
        }
    }
}

/// What a face holds and how it spaces it, worked out from the snapshot and the content's size (the widget less the
/// margins the system gives its family): the providers with batteries, their rows' pitch and scale, and the money's
/// lines. Medium is the panel, row for row, its money's line fitted to the height; large the panel larger, each provider
/// under a line with its name and how many are ready; small the batteries alone, two to a line, the account in use first.
struct UsageWidgetLayout: Equatable, Sendable {
    var providers: [Provider]
    /// The batteries' scale (large grows them to the width, never past `maxScale`).
    var scale: CGFloat
    /// Lines of money in each column, and their height; 0 lines: no money.
    var moneyLines: Int
    var moneyColumns: Int
    var moneyLineHeight: CGFloat
    /// Small: the battery slots each provider gets (two to a line), the last one "+N" when more are left.
    var slots: [Provider: Int] = [:]

    typealias P = Theme.Panel
    typealias B = Theme.Battery

    /// A battery and the gap after it, at scale 1.
    static let cell = B.cellWidth + B.gap
    /// Large's header line over a provider's batteries.
    static let headerHeight: CGFloat = 18
    static let headerGap: CGFloat = 8
    /// Large: the gap after a provider, to the next one or to the money's hairline. Fixed, so the sections stack from the
    /// top with no band of empty glass between them (P1284).
    static let largeGap: CGFloat = 14
    static let maxScale: CGFloat = 1.6
    /// The hairline's room above and below it.
    static let dividerAbove: CGFloat = 6
    static let dividerBelow: CGFloat = 8
    static let moneyLineMax: CGFloat = 22
    static let moneyLineMin: CGFloat = 16
    /// Small: a line of batteries and the gap to the next (room for the in-use dot over it and the next bar under the one
    /// above), the room over the first line and under the last for them, the gap between two providers, and the stale
    /// word's line.
    static let smallLine: CGFloat = B.height + 13
    static let smallLineRoom: CGFloat = 7
    static let smallProviderGap: CGFloat = 6
    static let smallWordHeight: CGFloat = 13

    static func batteries(_ snapshot: WidgetSnapshot, _ provider: Provider) -> [WidgetSnapshot.Battery] {
        provider == .claude ? snapshot.claude : snapshot.codex
    }

    /// The width of `count` batteries in a row, at scale 1.
    static func runWidth(_ count: Int) -> CGFloat { count > 0 ? CGFloat(count) * cell - B.gap : 0 }

    static func make(_ snapshot: WidgetSnapshot, face: WidgetFace, size: CGSize, stale: Bool = false) -> UsageWidgetLayout {
        let providers = [Provider.claude, .codex].filter { !batteries(snapshot, $0).isEmpty }
        let money = snapshot.moneyRows.count
        switch face {
        case .small:
            return UsageWidgetLayout(providers: providers, scale: 1, moneyLines: 0, moneyColumns: 0, moneyLineHeight: 0,
                               slots: smallSlots(snapshot, providers, height: size.height - (stale ? smallProviderGap + smallWordHeight : 0)))
        case .medium, .large:
            let large = face == .large
            let most = providers.map { batteries(snapshot, $0).count }.max() ?? 0
            let natural = large ? runWidth(most) : P.markSize + P.markGap + runWidth(most)
            var scale = natural > 0 ? min(large ? maxScale : 1, size.width / natural) : 1
            if !large { scale = min(scale, 1) }
            let rows = rowsHeight(providers.count, scale: scale, large: large)
            // Money in one column up to three rows, as the panel draws them, else two; as many lines as fit.
            let columns = money > 3 ? 2 : (money > 0 ? 1 : 0)
            var lines = columns == 0 ? 0 : (money + columns - 1) / columns
            let room = size.height - rows - (providers.isEmpty ? 0 : (large ? largeGap : dividerAbove) + 1 + dividerBelow)
            var lineHeight = lines > 0 ? min(large ? moneyLineMax + 4 : moneyLineMax, room / CGFloat(lines)) : 0
            if lines > 0, lineHeight < moneyLineMin {
                lines = max(0, Int(room / moneyLineMin))
                lineHeight = moneyLineMin
            }
            return UsageWidgetLayout(providers: providers, scale: scale, moneyLines: lines, moneyColumns: lines > 0 ? columns : 0,
                               moneyLineHeight: lineHeight)
        }
    }

    /// The provider rows' height: medium the panel's (29 pt rows, 8 pt apart); large each under its header, `largeGap`
    /// apart.
    static func rowsHeight(_ count: Int, scale: CGFloat, large: Bool) -> CGFloat {
        guard count > 0 else { return 0 }
        let row = P.rowHeight * scale + (large ? headerHeight + headerGap : 0)
        return CGFloat(count) * row + CGFloat(count - 1) * (large ? largeGap : P.rowGap)
    }

    /// Small's slots: two batteries to a line, as many lines as `height` holds and four at most, shared between the
    /// providers as their batteries ask, each provider at least one line.
    static func smallSlots(_ snapshot: WidgetSnapshot, _ providers: [Provider], height: CGFloat) -> [Provider: Int] {
        guard !providers.isEmpty else { return [:] }
        let fixed = CGFloat(providers.count) * (2 * smallLineRoom - (smallLine - B.height)) + CGFloat(providers.count - 1) * smallProviderGap
        let fit = max(providers.count, min(4, Int((height - fixed) / smallLine)))
        var lines = Dictionary(uniqueKeysWithValues: providers.map { ($0, 1) })
        var left = fit - providers.count
        while left > 0 {
            // The provider with the most batteries still hidden takes the next line.
            let wanting = providers.filter { batteries(snapshot, $0).count > 2 * lines[$0]! }
            guard let next = wanting.max(by: { batteries(snapshot, $0).count - 2 * lines[$0]! < batteries(snapshot, $1).count - 2 * lines[$1]! })
            else { break }
            lines[next]! += 1
            left -= 1
        }
        return lines.mapValues { 2 * $0 }
    }

    /// Small: a provider's batteries in the order they show, the accounts in use first (P815), then the rest in the
    /// panel's order; `more` is how many did not fit.
    static func smallOrder(_ batteries: [WidgetSnapshot.Battery], slots: Int) -> (shown: [(Int, WidgetSnapshot.Battery)], more: Int) {
        let indexed = Array(batteries.enumerated())
        let ordered = indexed.filter { $0.element.showsInUse } + indexed.filter { !$0.element.showsInUse }
        guard ordered.count > slots else { return (ordered.map { ($0.offset, $0.element) }, 0) }
        let shown = ordered.prefix(max(0, slots - 1))
        return (shown.map { ($0.offset, $0.element) }, ordered.count - shown.count)
    }
}

/// The Usage widget's face (spec §4.7): the desktop panel's batteries and money in WidgetKit. It only draws, from the
/// snapshot and the entry's date; nothing in it holds state, reads a file or a clock, or animates. `live`: the widget,
/// whose countdowns are WidgetKit's timer text; renders draw the label for `date` instead.
struct UsageWidgetView: View {
    let snapshot: WidgetSnapshot?
    let face: WidgetFace
    var size: CGSize
    var date: Date
    var mono = false
    var live = false

    private var ink: UsageInk { UsageInk(mono: mono) }
    private typealias L = UsageWidgetLayout
    private typealias P = Theme.Panel

    static let notRunningText = "Not running"
    static let emptyText = "No accounts yet"

    var body: some View {
        Group {
            if let snapshot, snapshot.appRunning {
                let stale = UsageFreshness.isStale(snapshot, at: date)
                let layout = UsageWidgetLayout.make(snapshot, face: face, size: size, stale: stale)
                if layout.providers.isEmpty && snapshot.moneyRows.isEmpty {
                    caption(Self.emptyText)
                } else {
                    running(snapshot, layout, stale: stale)
                }
            } else {
                notRunning
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .modifier(UsageInkLift(enabled: !mono))
        .environment(\.sessionGlyphsAnimated, false)
    }

    @ViewBuilder private func running(_ snapshot: WidgetSnapshot, _ layout: UsageWidgetLayout, stale: Bool) -> some View {
        switch face {
        case .small: small(snapshot, layout, stale: stale)
        case .medium, .large: panel(snapshot, layout, stale: stale)
        }
    }

    // MARK: Medium and large: the panel

    private func panel(_ snapshot: WidgetSnapshot, _ layout: UsageWidgetLayout, stale: Bool) -> some View {
        let large = face == .large
        let money = layout.moneyLines > 0 || stale
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layout.providers.enumerated()), id: \.element) { index, provider in
                let batteries = L.batteries(snapshot, provider)
                if index > 0 {
                    // Large stacks its sections from the top, a fixed gap apart (P1284).
                    Color.clear.frame(height: large ? L.largeGap : P.rowGap)
                }
                if large {
                    VStack(alignment: .leading, spacing: L.headerGap) {
                        header(provider, batteries, stale: stale)
                        run(batteries, scale: layout.scale, stale: stale)
                            .frame(height: P.rowHeight * layout.scale, alignment: .center)
                    }
                } else {
                    HStack(spacing: P.markGap) {
                        ProviderMarkView(provider: provider, size: P.markSize, tint: ink.markTint).widgetAccentable()
                        run(batteries, scale: layout.scale, stale: stale)
                    }
                    .frame(height: P.rowHeight * layout.scale)
                }
            }
            if money {
                divider(stale: stale)
                    .padding(.top, layout.providers.isEmpty ? 0 : (large ? L.largeGap : L.dividerAbove))
                    .padding(.bottom, L.dividerBelow)
            }
            if layout.moneyLines > 0 {
                UsageWidgetMoney(rows: snapshot.moneyRows, width: size.width, lines: layout.moneyLines, columns: layout.moneyColumns,
                                 lineHeight: layout.moneyLineHeight, ink: ink, stale: stale)
            }
        }
        .frame(width: size.width, height: size.height, alignment: large ? .topLeading : .leading)
    }

    /// Large's line over a provider: its mark and name, and how many of its accounts are ready, as the panel's hover says.
    /// Stale, it says nothing of how many are ready: that is as old as the batteries.
    private func header(_ provider: Provider, _ batteries: [WidgetSnapshot.Battery], stale: Bool) -> some View {
        HStack(spacing: 6) {
            ProviderMarkView(provider: provider, size: 15, tint: ink.markTint).widgetAccentable()
            Text(provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UsageInk.ink)
            Spacer(minLength: 8)
            if !stale {
                Text(Self.readyText(batteries))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(UsageInk.ink2)
            }
        }
        .frame(height: L.headerHeight)
    }

    /// "2 of 3 ready": the accounts that could take a turn now, of those with a plan (`Rules.availability`).
    static func readyText(_ batteries: [WidgetSnapshot.Battery]) -> String {
        let states = batteries.enumerated().map { $0.element.model($0.offset, provider: .claude).state }
        let availability = Rules.availability(states: states)
        return "\(availability.available) of \(availability.total) ready"
    }

    /// A provider's batteries in the panel's order, 6 pt apart, at `scale`.
    private func run(_ batteries: [WidgetSnapshot.Battery], scale: CGFloat, stale: Bool) -> some View {
        HStack(spacing: Theme.Battery.gap) {
            ForEach(Array(batteries.enumerated()), id: \.offset) { _, battery in
                UsageBattery(battery: battery, date: date, stale: stale, ink: ink, live: live)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .frame(width: L.runWidth(batteries.count) * scale, alignment: .leading)
    }

    /// The hairline over the money; stale, "Not updated" closes it on the right.
    private func divider(stale: Bool) -> some View {
        HStack(spacing: 8) {
            UsageVeil(colour: UsageInk.divider).frame(height: 1)
            if stale {
                Text(UsageFreshness.word)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UsageInk.ink2)
                    .fixedSize()
            }
        }
        .frame(height: stale ? 13 : 1)
    }

    // MARK: Small: the batteries alone

    private func small(_ snapshot: WidgetSnapshot, _ layout: UsageWidgetLayout, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: L.smallProviderGap) {
            ForEach(layout.providers, id: \.self) { provider in
                let (shown, more) = L.smallOrder(L.batteries(snapshot, provider), slots: layout.slots[provider] ?? 2)
                HStack(alignment: .top, spacing: 8) {
                    ProviderMarkView(provider: provider, size: 18, tint: ink.markTint)
                        .widgetAccentable()
                        .frame(height: Theme.Battery.height)
                    VStack(alignment: .leading, spacing: L.smallLine - Theme.Battery.height) {
                        ForEach(Array(stride(from: 0, to: shown.count + (more > 0 ? 1 : 0), by: 2)), id: \.self) { start in
                            HStack(spacing: Theme.Battery.gap) {
                                ForEach(start..<min(start + 2, shown.count + (more > 0 ? 1 : 0)), id: \.self) { index in
                                    if index < shown.count {
                                        UsageBattery(battery: shown[index].1, date: date, stale: stale, ink: ink, live: live)
                                    } else {
                                        Text("+\(more)")
                                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(UsageInk.ink2)
                                            .frame(width: Theme.Battery.cellWidth, height: Theme.Battery.height)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, L.smallLineRoom)
            }
            if stale {
                Text(UsageFreshness.word)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UsageInk.ink2)
                    .frame(height: L.smallWordHeight)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .center)
    }

    // MARK: Not running

    private var notRunning: some View {
        VStack(spacing: 8) {
            PixelGlyphView(glyph: .brand, colour: mono ? .white : IslandTheme.brand, pixel: face == .small ? 3 : 4,
                           dimmed: true, glow: false, animated: false)
            Text(Self.notRunningText)
                .font(Fonts.sys(11))
                .foregroundStyle(UsageInk.ink2)
        }
        .frame(width: size.width, height: size.height)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Fonts.sys(11))
            .foregroundStyle(UsageInk.ink2)
            .frame(width: size.width, height: size.height)
    }
}

/// A veil that the ink's lift casts no shadow from (`\.inkShadowPass`): the divider.
private struct UsageVeil: View {
    var colour: Color
    @Environment(\.inkShadowPass) private var shadowPass

    var body: some View { Rectangle().fill(shadowPass ? .clear : colour) }
}

/// The Usage widget's lift in full colour (P1224): its white ink on Glass (P1401) sits on whatever the system lays, or
/// on the wallpaper itself, pale ones included, so it is lifted as macOS lifts its desktop labels and the panel its ink
/// (`WidgetInkLift`): a copy of the content with its veils left out casts a tight dark shadow that edges each stroke and
/// a wide faint one around it. The one-colour looks lay the system's own glass and draw none: a shadow would come out
/// a white haze there.
struct UsageInkLift: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.background {
                content
                    .environment(\.inkShadowPass, true)
                    .compositingGroup()
                    .shadow(color: .black.opacity(WidgetInkLift.tight.opacity), radius: WidgetInkLift.tight.radius, y: WidgetInkLift.tight.y)
                    .shadow(color: .black.opacity(WidgetInkLift.wide.opacity), radius: WidgetInkLift.wide.radius, y: WidgetInkLift.wide.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

/// One account's battery in the Usage widget, drawn as the panel's (`BatteryView`: 42 × 18, its nub, its percent cut out
/// of the fill, the next bar under it and the in-use dot over it, P815) from the snapshot, with nothing a widget cannot
/// draw (no hover, no menu). A used-up battery's countdown ticks by itself (`Countdown`). Stale (`stale`, the snapshot
/// older than its rule, P1223), every battery draws as not read lately: its last fill faint and slashed, no number.
struct UsageBattery: View {
    let battery: WidgetSnapshot.Battery
    var date: Date
    var stale = false
    var ink = UsageInk(mono: false)
    var live = false
    @Environment(\.inkShadowPass) private var shadowPass

    private typealias M = Theme.Battery

    /// What it draws: its state, or not read lately when the snapshot is stale.
    var shown: WidgetSnapshot.Battery.State {
        guard stale else { return battery.state }
        switch battery.state {
        case let .available(left, _): return .stale(last: left)
        case .usedUp: return .stale(last: 0)
        case let .stale(last): return .stale(last: last)
        default: return battery.state
        }
    }

    private var track: Color { shadowPass ? .clear : UsageInk.track }

    var body: some View {
        ZStack {
            bodyShape
            content
        }
        .frame(width: M.width, height: M.height)
        .batteryCutGroup()
        .overlay(alignment: .trailing) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 1.5, topTrailingRadius: 1.5)
                .fill(UsageInk.line)
                .frame(width: M.nubWidth - 0.5, height: M.nubHeight)
                .offset(x: M.nubWidth)
        }
        .padding(.trailing, M.nubWidth)
        .opacity(isPlanless ? BatteryView.noPlanOpacity : 1)
        .overlay(alignment: .bottom) {
            if battery.isNext {
                Capsule().fill(UsageInk.ink)
                    .frame(width: M.nextBarSize.width, height: M.nextBarSize.height)
                    .offset(x: -M.nubWidth / 2, y: M.nextBarBelow + M.nextBarSize.height / 2)
            }
        }
        .overlay(alignment: .top) {
            if battery.showsInUse { BatteryView.inUseMark(UsageInk.ink) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var isPlanless: Bool {
        switch shown {
        case .noPlan, .noLimits: true
        default: false
        }
    }

    private var accessibility: String {
        let text = stale ? "Not read lately" : battery.accessibilityText
        return battery.showsInUse ? text + ", in use" : text
    }

    @ViewBuilder private var bodyShape: some View {
        switch shown {
        case .signIn, .signingIn, .loginLapsed:
            RoundedRectangle(cornerRadius: M.radius).strokeBorder(UsageInk.line, style: StrokeStyle(lineWidth: M.outline, dash: [2, 2]))
        case .usedUp, .noPlan, .noLimits:
            RoundedRectangle(cornerRadius: M.radius).strokeBorder(UsageInk.line, lineWidth: M.outline)
        case let .stale(last):
            filled(last ?? 0, colour: shadowPass ? .clear : UsageInk.ink.opacity(0.35))
                .overlay {
                    Rectangle().fill(Color.black).frame(width: 5, height: M.height + 6).rotationEffect(.degrees(25))
                        .modifier(BatteryKnockOut())
                }
                .overlay { Rectangle().fill(UsageInk.ink).frame(width: 1.5, height: M.height + 4).rotationEffect(.degrees(25)) }
        case let .available(left, low):
            filled(left, colour: low ? ink.warn : UsageInk.ink)
        case .unknown:
            filled(0, colour: UsageInk.ink)
        }
    }

    private func filled(_ percent: Int, colour: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: M.radius).fill(track)
            fillShape(percent).fill(colour)
                .frame(width: UsageBatteryView.fillWidth(percent), height: M.height - 2 * M.inset)
                .padding(.leading, M.inset)
                .widgetAccentable()
            RoundedRectangle(cornerRadius: M.radius).strokeBorder(UsageInk.line, lineWidth: M.outline)
        }
    }

    private func fillShape(_ percent: Int) -> UnevenRoundedRectangle {
        let inner = M.radius - M.inset
        let right: CGFloat = percent >= 100 ? inner : 1
        return UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner, bottomTrailingRadius: right, topTrailingRadius: right)
    }

    @ViewBuilder private var content: some View {
        switch shown {
        case let .available(left, low):
            BatteryDigitRow(percent: left, fill: low ? ink.warn : UsageInk.ink, ink: UsageInk.ink, cut: BatteryKnockOut())
        case let .usedUp(refill):
            CountdownLabel(countdown: Countdown.at(date, refill: refill), date: date, live: live)
                .font(Theme.refillFont)
                .foregroundStyle(UsageInk.ink2)
        case .signIn:
            BatteryKeyGlyph(colour: ink.attention).frame(width: 13, height: 8)
        case .loginLapsed:
            BatteryRefreshGlyph(colour: ink.attention).frame(width: 10, height: 10)
        case .signingIn:
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(UsageInk.ink2).frame(width: 2.5, height: 2.5) }
            }
        case .stale:
            EmptyView()
        case .unknown:
            Text("?").font(Theme.digitFont).foregroundStyle(UsageInk.ink2)
        case .noPlan:
            BatteryView.planlessWords(.noPlan, UsageInk.ink2)
        case .noLimits:
            BatteryView.planlessWords(.noLimits, UsageInk.ink2)
        }
    }
}

/// A countdown as it shows in a battery (`Countdown`): a fixed label, or WidgetKit's timer clipped to the panel's
/// hours and minutes (`live`), or in renders the panel's label for `date`.
struct CountdownLabel: View {
    let countdown: Countdown
    var date: Date
    var live = false

    var body: some View {
        switch countdown {
        case let .fixed(label):
            Text(verbatim: label)
        case let .ticking(refill, prefix, suffix):
            if live, refill > date {
                HStack(spacing: 0) {
                    Text(timerInterval: date...refill, countsDown: true, showsHours: true)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: Self.width(prefix), alignment: .leading)
                        .clipped()
                    if !suffix.isEmpty { Text(verbatim: suffix) }
                }
            } else {
                Text(verbatim: countdown.text(at: date))
            }
        }
    }

    /// `prefix` in the refill label's font (`Theme.refillFont`: 10 pt semibold, tabular digits): its advance, which ends
    /// in the gap before the colon that follows it, so no sliver of the colon shows.
    @MainActor static func width(_ prefix: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        return NSAttributedString(string: prefix, attributes: [.font: font]).size().width
    }
}

/// The Usage widget's money: the panel's rows (`MoneyRowsView`'s columns, `MoneyGrid`), one column up to three rows and
/// two past that, as many lines as the face holds. Names in the ink, amounts in it or in their amber or red, a word where
/// there is no amount. Stale, the amounts dim to the second ink: they are as old as the batteries.
struct UsageWidgetMoney: View {
    let rows: [WidgetSnapshot.Money]
    let width: CGFloat
    let lines: Int
    let columns: Int
    let lineHeight: CGFloat
    var ink = UsageInk(mono: false)
    var stale = false

    var body: some View {
        let first = Array(rows.prefix(lines))
        let second = columns > 1 ? Array(rows.dropFirst(lines).prefix(lines)) : []
        let widths = Self.columns(first, second, width: width)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: MoneyGrid.gap, verticalSpacing: 0) {
            ForEach(0..<lines, id: \.self) { index in
                GridRow {
                    name(index < first.count ? first[index] : nil, width: widths.names.0)
                    amount(index < first.count ? first[index] : nil, width: widths.amounts.0)
                    Color.clear.frame(width: Theme.Panel.moneyGutter, height: 1).gridCellUnsizedAxes(.vertical)
                    name(index < second.count ? second[index] : nil, width: widths.names.1)
                    amount(index < second.count ? second[index] : nil, width: widths.amounts.1)
                }
                .frame(height: lineHeight)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The panel's columns for these rows (`MoneyGrid.columns`), measured as the panel measures them.
    @MainActor static func columns(_ first: [WidgetSnapshot.Money], _ second: [WidgetSnapshot.Money], width: CGFloat)
        -> (names: (CGFloat, CGFloat), amounts: (CGFloat, CGFloat)) {
        let a = first.map(model), b = second.map(model)
        return MoneyGrid.columns(names: (MoneyGrid.nameWidth(a), MoneyGrid.nameWidth(b)),
                                 amounts: (MoneyGrid.amountWidth(a), MoneyGrid.amountWidth(b)), width: width)
    }

    static func model(_ row: WidgetSnapshot.Money) -> MoneyRowModel {
        MoneyRowModel(id: row.id, name: row.name, amount: row.amount, suffix: row.suffix, isSpent: row.isSpent, hoverLabel: "",
                      word: row.word)
    }

    @ViewBuilder private func name(_ row: WidgetSnapshot.Money?, width: CGFloat) -> some View {
        if let row {
            MoneyNameText(row: Self.model(row))
                .font(Theme.moneyNameFont)
                .foregroundStyle(UsageInk.ink)
                .frame(width: width, alignment: .leading)
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }

    @ViewBuilder private func amount(_ row: WidgetSnapshot.Money?, width: CGFloat) -> some View {
        if let row {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let amount = row.amount {
                    Text(amount).font(Theme.moneyAmountFont).foregroundStyle(stale ? UsageInk.ink2 : ink.amount(row))
                    if row.isSpent {
                        Text("spent").font(Theme.moneySuffixFont).foregroundStyle(UsageInk.ink2)
                    } else if let suffix = row.suffix {
                        Text(suffix).font(Theme.moneySuffixFont)
                            .foregroundStyle(row.emphasis == .normal || stale ? UsageInk.ink2 : ink.amount(row))
                    }
                } else if let word = row.word {
                    Text(word).font(Theme.moneySuffixFont).foregroundStyle(UsageInk.ink2)
                } else {
                    HStack(spacing: 6) {
                        Rectangle().fill(UsageInk.line).frame(width: 1, height: 9)
                        Rectangle().fill(UsageInk.line).frame(width: 1, height: 9)
                    }
                    .padding(.trailing, 2)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .frame(width: width, alignment: .trailing)
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }
}
