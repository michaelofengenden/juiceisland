import Foundation
import Testing
@testable import JuiceCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func record(readAgo: TimeInterval, used5h: Double, used7d: Double = 20, resetIn5h: TimeInterval = 45 * 60, resetIn7d: TimeInterval = 3 * 86_400,
                    error: ReadError? = nil, id: String = "x") -> AccountRecord {
    let readAt = now - readAgo
    return AccountRecord(lastGood: AccountReading(accountID: id, readAt: readAt, plan: "max", windows: [
        UsageWindow(seconds: 18_000, usedPercent: used5h, resetsAt: now + resetIn5h),
        UsageWindow(seconds: 604_800, usedPercent: used7d, resetsAt: now + resetIn7d),
    ]), lastError: error, lastErrorAt: error == nil ? nil : now, lastAttemptAt: now)
}

@Test func hoverLabelsMatchTheSpec() {
    let available = PanelModelBuilder.batteryLabel(alias: "blue-heron", state: .available(percentLeft: 69, isLow: false),
                                                   record: record(readAgo: 8 * 60, used5h: 31), now: now)
    #expect(available == "blue-heron · 69% left, 5h · resets in 45m · read 8m ago")

    let usedUp = PanelModelBuilder.batteryLabel(alias: "night", state: .usedUp(refill: now + 22 * 60),
                                                record: record(readAgo: 7 * 60, used5h: 100, resetIn5h: 22 * 60), now: now)
    #expect(usedUp == "night · 0% left, 5h · back in 22m · read 7m ago")

    let stale = PanelModelBuilder.batteryLabel(alias: "desk", state: .stale(lastPercentLeft: 60),
                                               record: record(readAgo: 3 * 3_600, used5h: 40), now: now)
    #expect(stale == "desk · last 60% left, 5h · read 3h ago")

    #expect(PanelModelBuilder.batteryLabel(alias: "atlas", state: .signInNeeded, record: nil, now: now) == "atlas · sign-in needed")
    #expect(PanelModelBuilder.batteryLabel(alias: "lab", state: .unknown, record: nil, now: now) == "lab · no reading yet")
    #expect(PanelModelBuilder.batteryLabel(alias: "lab", state: .unknown, record: AccountRecord(lastError: .cliNotFound, lastErrorAt: now), now: now)
            == "lab · no reading yet · CLI not found")
    #expect(PanelModelBuilder.batteryLabel(alias: "lab", state: .signingIn, record: nil, now: now) == "lab · signing in…")

    let weekly = PanelModelBuilder.batteryLabel(alias: "w", state: .available(percentLeft: 12, isLow: true),
                                                record: record(readAgo: 10, used5h: 5, used7d: 88, resetIn7d: 2 * 86_400 + 3_600), now: now)
    #expect(weekly.hasPrefix("w · 12% left, week · resets "))
    #expect(weekly.hasSuffix(" · read 10s ago"))
}

@Test func providerLabelMatchesTheSpec() {
    let known = PanelModelBuilder.providerLabel(provider: .claude, availability: .init(available: 4, total: 6, isKnown: true), nextAlias: "blue-heron", oldestAge: "8m ago")
    #expect(known == "Claude · 4 of 6 available · next blue-heron · oldest reading 8m ago")
    let unknown = PanelModelBuilder.providerLabel(provider: .codex, availability: .init(available: 0, total: 4, isKnown: false), nextAlias: nil, oldestAge: nil)
    #expect(unknown == "Codex · availability unknown")
    let none = PanelModelBuilder.providerLabel(provider: .codex, availability: .init(available: 0, total: 4, isKnown: true), nextAlias: nil, oldestAge: "12s ago")
    #expect(none == "Codex · 0 of 4 available · oldest reading 12s ago")
}

@Test func buildProducesTheMockupPanel() {
    let panel = FixtureData.panel(now: now)
    #expect(panel.rows.map(\.provider) == [.claude, .codex])
    let claude = panel.rows[0]
    #expect(claude.batteries.map(\.state) == [
        .available(percentLeft: 69, isLow: false), .available(percentLeft: 12, isLow: true), .usedUp(refill: now + 22 * 60),
        .available(percentLeft: 77, isLow: false), .available(percentLeft: 100, isLow: false), .signInNeeded,
    ])
    #expect(claude.batteries.map(\.isNext) == [true, false, false, false, false, false])
    #expect(claude.availability == .init(available: 4, total: 6, isKnown: true))
    #expect(claude.nextAlias == "blue-heron")
    let codex = panel.rows[1]
    #expect(codex.batteries.map(\.state) == [
        .available(percentLeft: 54, isLow: false), .available(percentLeft: 8, isLow: true), .available(percentLeft: 33, isLow: false), .stale(lastPercentLeft: 60),
    ])
    #expect(codex.availability == .init(available: 3, total: 4, isKnown: true))
    #expect(panel.money.map(\.amount) == ["$4,120", "$354", "$212", "$2,310", "€153"])
    #expect(panel.money.map(\.suffix) == [nil, nil, nil, "52d", "/mo"])
    #expect(panel.money[2].isSpent)
    #expect(panel.attentionNeeded)
}

@Test func unmonitoredAccountsAreLeftOutAndSigningInWins() {
    let a = Account(provider: .claude, folder: "/h/.claude", alias: "a")
    let b = Account(provider: .claude, folder: "/h/.claude-b", alias: "b", monitored: false)
    let records = [a.id: record(readAgo: 60, used5h: 10, error: .signInRequired, id: a.id)]
    let panel = PanelModelBuilder.build(accounts: [a, b], records: records, signingIn: [a.id], money: MoneyRowModel.notConnected, now: now)
    #expect(panel.rows.count == 1)
    #expect(panel.rows[0].batteries.map(\.id) == [a.id])
    #expect(panel.rows[0].batteries[0].state == .signingIn)
    #expect(panel.money.allSatisfy { $0.amount == nil })
    #expect(!panel.attentionNeeded)
}

@Test func twoFoldersWithOneIdentityAreDrawnAndCountedOnce() {
    let first = Account(provider: .claude, folder: "/h/.claude", alias: "first", knownEmail: "me@x.com")
    let second = Account(provider: .claude, folder: "/h/.claude-second", alias: "second", knownEmail: "ME@x.com")
    let records = [first.id: record(readAgo: 60, used5h: 10, id: first.id),
                   second.id: record(readAgo: 60, used5h: 100, id: second.id)]
    let panel = PanelModelBuilder.build(accounts: [first, second], records: records, signingIn: [],
                                        money: MoneyRowModel.notConnected, now: now)
    #expect(panel.rows.count == 1)
    #expect(panel.rows[0].batteries.map(\.alias) == ["first"])
    #expect(panel.rows[0].availability == .init(available: 1, total: 1, isKnown: true))
}
