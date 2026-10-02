import JuiceCore
import SwiftUI

/// The account list a battery or mark opens (prototype `appPopHTML` "acct:", prototype.md §1.1 Popovers): 560 wide,
/// `#1C1C1E`, radius 14, padding 12. Header: mark 16 + provider name (700 13) and "3 of 6 available · next Main".
/// Rows (`45 96 58 1fr auto`, gap 12, min 36, padding 4 12): battery · alias (500) + Next badge · plan · detail ·
/// Sign In, Cancel or "read 2m ago". The detail starts with the window's sparkline (P125) when any row has one, a
/// 48 pt column the rows without one leave blank, and the list is that much wider. An account that runs out before its
/// reset says so in its detail, in amber, in place of its percent (its battery shows that). The clicked account's row
/// is highlighted. Footer: Manage Accounts….
struct AccountListView: View {
    @Environment(\.juiceTheme) private var theme
    @Environment(AppEnvironment.self) private var env
    let provider: Provider
    var selected: String?
    var onClose: @MainActor () -> Void = {}

    static let width: CGFloat = WindowTheme.Metrics.accountListWidth
    /// The sparklines' column and its gap.
    static let sparklineColumn: CGFloat = UsageSparklineView.size.width + 12

    /// The list's width for `provider`: wider by the sparklines' column when a row has one.
    static func width(_ provider: Provider, usage: any UsageModel) -> CGFloat {
        let lines = usage.row(provider)?.batteries.contains { usage.sparkline($0.id) != nil } ?? false
        return width + (lines ? sparklineColumn : 0)
    }

    var body: some View {
        let row = env.usage.row(provider)
        let lines = Dictionary(uniqueKeysWithValues: (row?.batteries ?? []).compactMap { battery in
            env.usage.sparkline(battery.id).map { (battery.id, $0) }
        })
        VStack(alignment: .leading, spacing: 0) {
            header(row)
            VStack(spacing: 0) {
                ForEach(Array((row?.batteries ?? []).enumerated()), id: \.element.id) { index, battery in
                    accountRow(battery, first: index == 0, line: lines[battery.id], sparklines: !lines.isEmpty)
                }
            }
            .background(SettingsTheme.group, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsTheme.groupStroke, lineWidth: 0.5))
            HStack {
                Spacer(minLength: 0)
                AccountListButton(title: "Manage Accounts…") {
                    onClose()
                    env.actions.openSettings(.accounts)
                }
            }
            .padding(.top, 10)
        }
        .padding(12)
        .frame(width: Self.width + (lines.isEmpty ? 0 : Self.sparklineColumn), alignment: .leading)
        .font(.system(size: 13))
        .foregroundStyle(SettingsTheme.ink)
        .background(WindowTheme.popoverBg, in: RoundedRectangle(cornerRadius: WindowTheme.Metrics.popoverRadius))
        .overlay(RoundedRectangle(cornerRadius: WindowTheme.Metrics.popoverRadius).strokeBorder(WindowTheme.popoverEdge, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) accounts")
    }

    private func header(_ row: ProviderRowModel?) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                ProviderMarkView(provider: provider, size: Theme.Mark.strip, theme: theme)
                // The prototype's `.apop-h > span` rule greys the title too.
                Text(provider.displayName).font(.system(size: 13, weight: .bold)).foregroundStyle(SettingsTheme.ink2)
            }
            Spacer(minLength: 0)
            Text(row.map(AccountListText.summary) ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.ink2)
        }
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 9, trailing: 6))
    }

    private func accountRow(_ battery: BatteryModel, first: Bool, line: UsageSparkline?, sparklines: Bool) -> some View {
        let detail = AccountListText.detail(battery, usage: env.usage)
        return HStack(spacing: 12) {
            UsageBatteryView(battery: battery, now: env.usage.now, theme: theme)
                .frame(width: 45, alignment: .leading)
            HStack(spacing: 6) {
                Text(battery.alias).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if battery.isNext {
                    Text("Next")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink2)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(SettingsTheme.chip, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(width: 96, alignment: .leading)
            Text(AccountListText.plan(battery.id, usage: env.usage))
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.ink2)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)
            if sparklines {
                Group {
                    if let line { UsageSparklineView(line: line) } else { Color.clear }
                }
                .frame(width: UsageSparklineView.size.width, height: UsageSparklineView.size.height)
            }
            Text(detail.text)
                .foregroundStyle(detail.tone.colour)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            action(battery)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .background {
            if battery.id == selected { RoundedRectangle(cornerRadius: 8).fill(SettingsTheme.pair(black: 0.05, white: 0.06)) }
        }
        .overlay(alignment: .top) {
            if !first { SettingsTheme.separator.frame(height: 1).padding(.horizontal, 12) }
        }
    }

    @ViewBuilder private func action(_ battery: BatteryModel) -> some View {
        switch battery.state {
        case .signInNeeded:
            AccountListButton(title: "Sign In", tint: SettingsTheme.accent, ink: .white, size: 12, horizontalPadding: 9) {
                onClose()
                env.actions.openSettings(.accounts)
            }
        case .signingIn:
            AccountListButton(title: "Cancel", size: 12, horizontalPadding: 9) {}
        default:
            Text(AccountListText.readAge(battery.id, usage: env.usage))
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.ink3)
                .lineLimit(1)
        }
    }
}

/// The prototype's push button (`.pb`): 22 tall, radius 6, `#56565A` (or the accent), white text.
struct AccountListButton: View {
    let title: String
    var tint: Color = SettingsTheme.push
    /// The title: the push grey's ink, or white on the accent.
    var ink: Color = SettingsTheme.pushInk
    var size: CGFloat = 13
    var horizontalPadding: CGFloat = 11
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size))
                .foregroundStyle(ink)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .frame(height: 22)
                .background(tint, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsTheme.controlEdge, lineWidth: 0.5)
                        .mask(alignment: .top) { Rectangle().frame(height: 1) }
                }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// The account list's words, from the panel model (P41: no view computes a state).
@MainActor
enum AccountListText {
    enum Tone: Sendable { case normal, secondary, amber, red
        var colour: Color {
            switch self {
            case .normal: SettingsTheme.ink
            case .secondary: SettingsTheme.ink2
            case .amber: SettingsTheme.statusAmber
            case .red: SettingsTheme.statusRed
            }
        }
    }

    /// "3 of 6 available · next Main": the provider label's first two parts, taken whole from the row (P584).
    static func summary(_ row: ProviderRowModel) -> String {
        row.labelParts.prefix(2).joined(separator: " · ")
    }

    /// The window parts without "read …": `82% left, 5h · resets in 3h 40m`; `sign-in needed` red; `signing in…`;
    /// `no reading yet`; `<last …> · stale` amber; an account that runs out before its reset (P125) `out in ~45m ·
    /// resets in 1h 5m` amber (the window named when the battery's percent is another window's).
    static func detail(_ battery: BatteryModel, usage: any UsageModel) -> (text: String, tone: Tone) {
        let parts = HoverLabelText.split(battery.hoverLabel, name: battery.alias).parts
        switch battery.state {
        case .signInNeeded: return ("sign-in needed", .red)
        case .signingIn: return ("signing in…", .secondary)
        case .unknown: return ("no reading yet", .secondary)
        // Its dimmed battery says "No plan" or "No limits"; the detail says only what may be behind it.
        case .noPlan: return ("subscription ended?", .secondary)
        case .noLimits: return ("billed by usage", .secondary)
        case .stale: return ((parts.first ?? "last reading") + " · stale", .amber)
        case .available, .usedUp:
            if let runOut = battery.runOut {
                let tightest = usage.records[battery.id]?.lastGood.map { Rules.countedWindows(Rules.current($0, now: usage.now)) }?
                    .min { $0.percentLeft < $1.percentLeft }
                return (UsageForecast.line(runOut, now: usage.now, namedWindow: tightest?.displayLabel), .amber)
            }
            return (parts.filter { !$0.hasPrefix("read ") }.joined(separator: " · "), .normal)
        }
    }

    /// "read 2m ago", or "read never" without a reading.
    static func readAge(_ id: String, usage: any UsageModel) -> String {
        guard let read = usage.records[id]?.lastGood?.readAt else { return "read never" }
        return "read " + Formatting.age(of: read, now: usage.now)
    }

    /// The plan as the list shows it ("Max 20×", "Pro"): the demo's table for demo data, else the reading's own plan
    /// word, so a real account that shares a demo alias never shows the demo's plan.
    static func plan(_ id: String, usage: any UsageModel) -> String {
        if usage is DemoUsageModel, let alias = usage.account(id: id)?.alias, let plan = DemoUsageData.plans[alias] { return plan }
        return usage.records[id]?.planWord ?? ""
    }
}
