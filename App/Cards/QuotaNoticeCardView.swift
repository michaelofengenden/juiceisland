import JuiceCore
import SwiftUI

/// A quota notice as an island card (P125): an account crossed 90 % of a window, will run out within 30 minutes at its
/// pace, or is back after it was used up. Brief like a finish's Done card, and it folds away by itself the same way
/// (`IslandHoverMachine.doneCardLife`, held while the pointer is on the island); something that needs you takes its
/// place. Its id is the notice's (`prefix`), never a session's, so it reaches no session's actions or keys.
struct QuotaNoticeCard: Equatable, Sendable {
    var notice: QuotaNotice

    static let prefix = "quota:"
    var sessionID: String { Self.prefix + notice.id }
    static func isNotice(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// The body's line split for its colours: the news (amber when the account runs low, green when it is back), then
    /// the rest ("resets in 1h 12m") in the status grey.
    func line(now: Date) -> (news: String, rest: String?, back: Bool) {
        let parts = notice.text(now: now).components(separatedBy: " · ")
        let back = if case .back = notice.kind { true } else { false }
        return (parts.first ?? "", parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil, back)
    }
}

/// Whether the island shows a quota notice now (P125): only with Quota alerts on, never over a card the owner is at (it
/// waits for that card to go), and never once it is `shelfLife` old.
enum QuotaNoticeGate {
    enum Decision: Equatable, Sendable { case show, wait, drop }

    static let shelfLife: TimeInterval = 10 * 60

    static func decide(_ notice: QuotaNotice, alertsOn: Bool, ownerAtCard: Bool, now: Date) -> Decision {
        guard alertsOn, now.timeIntervalSince(notice.at) < shelfLife else { return .drop }
        return ownerAtCard ? .wait : .show
    }
}

/// The notice's header, the title line of a one-line row: the account's battery as the panel draws it now, its name,
/// and its provider's mark where a row has its agent's. No age: the notice is now.
struct QuotaNoticeHeader: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let card: QuotaNoticeCard
    @Environment(AppEnvironment.self) private var env

    /// The battery's column: its cell (45) and the gap a row's glyph column leaves before the title.
    static let leading: CGFloat = Theme.Battery.cellWidth + 9

    var body: some View {
        let battery = env.usage.battery(id: card.notice.account)
        HStack(alignment: .center, spacing: 0) {
            Group {
                if let battery { UsageBatteryView(battery: battery, now: env.usage.now, theme: theme) }
            }
            .frame(width: Self.leading, alignment: .leading)
            Text(battery?.alias ?? card.notice.provider.displayName)
                .font(Fonts.sys(12, .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProviderMarkView(provider: card.notice.provider, size: Theme.Mark.sessionRow, opacity: Theme.Mark.sessionRowOpacity, theme: theme)
                .padding(.leading, 12)
        }
        .lineBox(18)
        .accessibilityElement(children: .combine)
    }
}

/// The notice's one line under the name: "5h out in ~25m · resets in 1h 12m", "5h almost out · resets in 1h 12m",
/// "back".
struct QuotaNoticeBody: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let card: QuotaNoticeCard
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let line = card.line(now: env.usage.now)
        var runs = TextRuns()
        runs.add(line.news, palette.toneText(line.back ? IslandTheme.done : Theme.warn), size: 11)
        if let rest = line.rest {
            runs.add(" · ", palette.statusClean, size: 11)
            runs.add(rest, palette.statusClean, size: 11)
        }
        return runs.text
            .lineLimit(1).truncationMode(.tail)
            .padding(.leading, QuotaNoticeHeader.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
