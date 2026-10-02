import Foundation

/// The mockup's numbers (`minimal-3.html`), so demo mode draws exactly what was approved.
public enum FixtureData {
    public static let accounts: [Account] = [
        Account(provider: .claude, folder: "/demo/.claude", alias: "blue-heron", knownEmail: "blue-heron@example.com"),
        Account(provider: .claude, folder: "/demo/.claude-lab", alias: "lab", knownEmail: "lab@example.com"),
        Account(provider: .claude, folder: "/demo/.claude-night", alias: "night", knownEmail: "night@example.com"),
        Account(provider: .claude, folder: "/demo/.claude-desk", alias: "desk", knownEmail: "desk@example.com"),
        Account(provider: .claude, folder: "/demo/.claude-studio", alias: "studio", knownEmail: "studio@example.com"),
        Account(provider: .claude, folder: "/demo/.claude-atlas", alias: "atlas", knownEmail: "atlas@example.com"),
        Account(provider: .codex, folder: "/demo/.codex", alias: "default", knownEmail: "default@example.com"),
        Account(provider: .codex, folder: "/demo/.codex-side", alias: "side", knownEmail: "side@example.com"),
        Account(provider: .codex, folder: "/demo/.codex-work", alias: "work", knownEmail: "work@example.com"),
        Account(provider: .codex, folder: "/demo/.codex-spare", alias: "spare", knownEmail: "spare@example.com"),
    ]

    private static func good(_ account: Account, readAgo: TimeInterval, used5h: Double, used7d: Double, reset5h: TimeInterval, now: Date, plan: String) -> AccountRecord {
        let readAt = now - readAgo
        return AccountRecord(lastGood: AccountReading(accountID: account.id, readAt: readAt, plan: plan, windows: [
            UsageWindow(seconds: 18_000, usedPercent: used5h, resetsAt: now + reset5h),
            UsageWindow(seconds: 604_800, usedPercent: used7d, resetsAt: now + 3 * 86_400),
        ]), lastAttemptAt: readAt)
    }

    public static func records(now: Date) -> [String: AccountRecord] {
        let a = accounts
        return [
            a[0].id: good(a[0], readAgo: 8 * 60, used5h: 31, used7d: 20, reset5h: 45 * 60, now: now, plan: "max"),
            a[1].id: good(a[1], readAgo: 6 * 60, used5h: 88, used7d: 40, reset5h: 2 * 3_600 + 5 * 60, now: now, plan: "pro"),
            a[2].id: good(a[2], readAgo: 7 * 60, used5h: 100, used7d: 61, reset5h: 22 * 60, now: now, plan: "max"),
            a[3].id: good(a[3], readAgo: 4 * 60, used5h: 23, used7d: 12, reset5h: 3 * 3_600, now: now, plan: "max"),
            a[4].id: good(a[4], readAgo: 2 * 60, used5h: 0, used7d: 0, reset5h: 5 * 3_600, now: now, plan: "team"),
            a[5].id: AccountRecord(lastError: .signInRequired, lastErrorAt: now - 3_600, lastAttemptAt: now - 3_600),
            a[6].id: good(a[6], readAgo: 12, used5h: 46, used7d: 30, reset5h: 90 * 60, now: now, plan: "pro"),
            a[7].id: good(a[7], readAgo: 20, used5h: 92, used7d: 70, reset5h: 40 * 60, now: now, plan: "plus"),
            a[8].id: good(a[8], readAgo: 15, used5h: 67, used7d: 50, reset5h: 3_000, now: now, plan: "pro"),
            a[9].id: good(a[9], readAgo: 3 * 3_600, used5h: 40, used7d: 10, reset5h: 600, now: now, plan: "pro"),
        ]
    }

    public static let money: [MoneyRowModel] = [
        MoneyRowModel(id: "OpenRouter", name: "OpenRouter", amount: "$4,120", hoverLabel: "OpenRouter · $4,120 balance · $38.20 today · read 2m ago"),
        MoneyRowModel(id: "Anthropic", name: "Anthropic", amount: "$354", hoverLabel: "Anthropic · $354 left of $1,400 since 7 Sep · $61 today"),
        MoneyRowModel(id: "OpenAI", name: "OpenAI", amount: "$212", isSpent: true, hoverLabel: "OpenAI · $212 spent in September"),
        MoneyRowModel(id: "RunPod", name: "RunPod", amount: "$2,310", suffix: "52d", hoverLabel: "RunPod · $2,310 balance · $1.84/h · about 52 days",
                      suffixIsRunway: true),
        MoneyRowModel(id: "Hetzner", name: "Hetzner", amount: "€153", suffix: "/mo", hoverLabel: "Hetzner · 3 servers · €0.21/h · about €153 this month"),
    ]

    public static func panel(now: Date) -> PanelModel {
        PanelModelBuilder.build(accounts: accounts, records: records(now: now), signingIn: [], money: money, now: now)
    }
}
