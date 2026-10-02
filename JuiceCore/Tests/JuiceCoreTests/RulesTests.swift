import Foundation
import Testing
@testable import JuiceCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func reading(_ windows: [UsageWindow], age: TimeInterval = 60, allowed: Bool = true) -> AccountReading {
    AccountReading(accountID: "claude:/x", readAt: now.addingTimeInterval(-age), plan: "max", windows: windows, ordinaryUsageAllowed: allowed)
}
private func window(_ used: Double, seconds: Int = 18_000, resetsIn: TimeInterval? = 45 * 60) -> UsageWindow {
    UsageWindow(seconds: seconds, usedPercent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
}

@Test func percentLeftIsTheSmallestWindow() {
    #expect(Rules.percentLeft(reading([window(31), window(7, seconds: 604_800)])) == 69)
    #expect(Rules.percentLeft(reading([window(12), window(88, seconds: 604_800)])) == 12)
    #expect(Rules.percentLeft(reading([])) == 0)
}

@Test func availableAndLow() {
    #expect(Rules.state(reading: reading([window(31)]), lastError: nil, signingIn: false, provider: .claude, now: now)
            == .available(percentLeft: 69, isLow: false))
    #expect(Rules.state(reading: reading([window(88)]), lastError: nil, signingIn: false, provider: .claude, now: now)
            == .available(percentLeft: 12, isLow: true))
    #expect(Rules.state(reading: reading([window(85)]), lastError: nil, signingIn: false, provider: .claude, now: now)
            == .available(percentLeft: 15, isLow: false))
}

@Test func usedUpUsesTheLatestBlockingReset() {
    let r = reading([window(100, resetsIn: 22 * 60), window(100, seconds: 604_800, resetsIn: 4 * 86_400)])
    #expect(Rules.state(reading: r, lastError: nil, signingIn: false, provider: .claude, now: now)
            == .usedUp(refill: now.addingTimeInterval(4 * 86_400)))
}

@Test func usedUpIgnoresNonBlockingWindowsForRefill() {
    let r = reading([window(100, resetsIn: 22 * 60), window(71, seconds: 604_800, resetsIn: 4 * 86_400)])
    #expect(Rules.refillDate(r) == now.addingTimeInterval(22 * 60))
}

@Test func codexRateLimitedFlagCountsAsUsedUp() {
    let r = reading([window(96, seconds: 604_800, resetsIn: 3_600)], allowed: false)
    #expect(Rules.state(reading: r, lastError: nil, signingIn: false, provider: .codex, now: now)
            == .usedUp(refill: now.addingTimeInterval(3_600)))
}

@Test func staleAfterFreshnessLimitKeepsLastPercent() {
    let r = reading([window(40)], age: 21 * 60)
    #expect(Rules.state(reading: r, lastError: nil, signingIn: false, provider: .claude, now: now) == .stale(lastPercentLeft: 60))
    let codexFresh = reading([window(40)], age: 90)
    #expect(Rules.state(reading: codexFresh, lastError: nil, signingIn: false, provider: .codex, now: now).isAvailable)
    let codexStale = reading([window(40)], age: 121)
    #expect(Rules.state(reading: codexStale, lastError: nil, signingIn: false, provider: .codex, now: now) == .stale(lastPercentLeft: 60))
}

@Test func failedReadDoesNotHideAFreshReading() {
    let r = reading([window(40)])
    #expect(Rules.state(reading: r, lastError: .timeout, signingIn: false, provider: .claude, now: now).isAvailable)
}

@Test func signInStatesWinOverEverything() {
    let r = reading([window(40)])
    #expect(Rules.state(reading: r, lastError: .signInRequired, signingIn: false, provider: .claude, now: now) == .signInNeeded)
    #expect(Rules.state(reading: r, lastError: nil, signingIn: true, provider: .claude, now: now) == .signingIn)
    #expect(Rules.state(reading: nil, lastError: nil, signingIn: false, provider: .claude, now: now) == .unknown)
}

@Test func nextIsFirstAvailableInOrder() {
    let a = Account(provider: .claude, folder: "/a", alias: "a")
    let b = Account(provider: .claude, folder: "/b", alias: "b")
    let c = Account(provider: .claude, folder: "/c", alias: "c", monitored: false)
    let states: [String: AccountState] = [
        a.id: .usedUp(refill: nil),
        b.id: .available(percentLeft: 12, isLow: true),
        c.id: .available(percentLeft: 99, isLow: false),
    ]
    #expect(Rules.next(in: [a, b, c], states: states)?.id == b.id)
    #expect(Rules.next(in: [a], states: states) == nil)
}

@Test func availabilityCountsAndKnowledge() {
    let a = Account(provider: .claude, folder: "/a", alias: "a")
    let b = Account(provider: .claude, folder: "/b", alias: "b")
    let c = Account(provider: .claude, folder: "/c", alias: "c", monitored: false)
    let known = Rules.availability(accounts: [a, b, c], states: [a.id: .available(percentLeft: 50, isLow: false), b.id: .usedUp(refill: nil)])
    #expect(known.available == 1 && known.total == 2 && known.isKnown)
    let unknown = Rules.availability(accounts: [a, b], states: [a.id: .usedUp(refill: nil), b.id: .stale(lastPercentLeft: 5)])
    #expect(unknown.available == 0 && !unknown.isKnown)
}
