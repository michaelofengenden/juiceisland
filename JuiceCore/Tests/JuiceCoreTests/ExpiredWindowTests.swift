import Foundation
import Testing
@testable import JuiceCore

/// P460: a window whose reset time has passed counts as refilled until the next read replaces the reading. Every test
/// moves a fake clock past a reset; nothing reads.
private let readAt = Date(timeIntervalSince1970: 1_800_000_000)

private func reading(_ windows: [UsageWindow], allowed: Bool = true, id: String = "a") -> AccountReading {
    AccountReading(accountID: id, readAt: readAt, plan: "max", windows: windows, ordinaryUsageAllowed: allowed)
}

private func window(_ used: Double, seconds: Int = 18_000, resetsIn: TimeInterval?) -> UsageWindow {
    UsageWindow(seconds: seconds, usedPercent: used, resetsAt: resetsIn.map { readAt.addingTimeInterval($0) })
}

private func state(_ r: AccountReading, at now: Date, provider: Provider = .claude) -> AccountState {
    Rules.state(reading: r, lastError: nil, signingIn: false, provider: provider, now: now)
}

@Test func aUsedUpWindowIsFullOnceItsResetPasses() {
    let r = reading([window(100, resetsIn: 10 * 60), window(40, seconds: 604_800, resetsIn: 3 * 86_400)])
    #expect(state(r, at: readAt.addingTimeInterval(9 * 60)) == .usedUp(refill: readAt.addingTimeInterval(10 * 60)))
    // At the reset itself and after it, with no read: the week is what is left.
    #expect(state(r, at: readAt.addingTimeInterval(10 * 60)) == .available(percentLeft: 60, isLow: false))
    #expect(state(r, at: readAt.addingTimeInterval(12 * 60)) == .available(percentLeft: 60, isLow: false))
}

@Test func thePercentFollowsTheWindowThatReset() {
    let r = reading([window(92, resetsIn: 5 * 60), window(30, seconds: 604_800, resetsIn: 3 * 86_400)])
    #expect(state(r, at: readAt.addingTimeInterval(60)) == .available(percentLeft: 8, isLow: true))
    #expect(state(r, at: readAt.addingTimeInterval(6 * 60)) == .available(percentLeft: 70, isLow: false))
    // Every counted window past its reset: full.
    let both = reading([window(92, resetsIn: 5 * 60), window(30, seconds: 604_800, resetsIn: 8 * 60)])
    #expect(state(both, at: readAt.addingTimeInterval(9 * 60)) == .available(percentLeft: 100, isLow: false))
}

@Test func aWindowWithNoResetTimeNeverRefillsByItself() {
    let r = reading([window(100, resetsIn: nil)])
    #expect(state(r, at: readAt.addingTimeInterval(19 * 60)) == .usedUp(refill: nil))
}

@Test func theVendorsNotAllowedEndsWithTheLastResetItWaitsOn() {
    // Codex says "not allowed" with no window at 100 %: it waits on the latest reset of all counted windows.
    let r = reading([window(96, resetsIn: 30), window(50, seconds: 604_800, resetsIn: 90)], allowed: false)
    #expect(state(r, at: readAt.addingTimeInterval(60), provider: .codex) == .usedUp(refill: readAt.addingTimeInterval(90)))
    #expect(state(r, at: readAt.addingTimeInterval(100), provider: .codex) == .available(percentLeft: 100, isLow: false))
    // An exhausted window blocks: its reset ends the block, whatever the other window does.
    let blocked = reading([window(100, resetsIn: 30), window(50, seconds: 604_800, resetsIn: 86_400)], allowed: false)
    #expect(state(blocked, at: readAt.addingTimeInterval(40), provider: .codex) == .available(percentLeft: 50, isLow: false))
    // No reset time at all: the vendor's word stands.
    let unknown = reading([window(40, resetsIn: nil)], allowed: false)
    #expect(state(unknown, at: readAt.addingTimeInterval(100), provider: .codex) == .usedUp(refill: nil))
}

@Test func aStaleReadingShowsTheWindowRefilledToo() {
    let r = reading([window(100, resetsIn: 10 * 60)])
    #expect(state(r, at: readAt.addingTimeInterval(25 * 60)) == .stale(lastPercentLeft: 100))
}

@Test func theStoredReadingKeepsWhatTheVendorSaid() {
    let r = reading([window(100, resetsIn: 60)], allowed: false)
    let current = Rules.current(r, now: readAt.addingTimeInterval(120))
    #expect(current.windows.first?.usedPercent == 0)
    #expect(current.windows.first?.resetsAt == readAt.addingTimeInterval(60))
    #expect(current.ordinaryUsageAllowed)
    #expect(r.windows.first?.usedPercent == 100)
    #expect(!r.ordinaryUsageAllowed)
    // Before the reset nothing changes, and a reading with no reset passed is returned as it is.
    #expect(Rules.current(r, now: readAt.addingTimeInterval(30)) == r)
    // The raw rules the quota notices and floors use are the vendor's.
    #expect(Rules.isExhausted(r))
    #expect(Rules.percentLeft(r) == 0)
}

@Test func nextMovesToAnAccountWhoseWindowReset() {
    let entries = [PanelEntry(id: "a", alias: "first", provider: .claude), PanelEntry(id: "b", alias: "second", provider: .claude)]
    let records: [String: AccountRecord] = [
        "a": AccountRecord(lastGood: reading([window(100, resetsIn: 10 * 60)], id: "a")),
        "b": AccountRecord(lastGood: reading([window(20, resetsIn: 3 * 3_600)], id: "b")),
    ]
    func next(at now: Date) -> String? {
        PanelModelBuilder.build(entries: entries, records: records, signingIn: [], money: [], now: now)
            .rows.first?.batteries.first(where: \.isNext)?.id
    }
    #expect(next(at: readAt.addingTimeInterval(5 * 60)) == "b")
    #expect(next(at: readAt.addingTimeInterval(11 * 60)) == "a")
}

@Test func theHoverSaysResetAndReadingUntilTheNextRead() {
    let now = readAt.addingTimeInterval(12 * 60)
    let full = AccountRecord(lastGood: reading([window(100, resetsIn: 10 * 60)]))
    #expect(PanelModelBuilder.batteryLabel(alias: "night", state: state(full.lastGood!, at: now), record: full, now: now)
            == "night · 100% left, 5h · reset · reading…")
    // The week stands for the battery; the 5h window that reset is named.
    let week = AccountRecord(lastGood: reading([window(100, resetsIn: 10 * 60), window(40, seconds: 604_800, resetsIn: 3 * 86_400)]))
    let weekLabel = PanelModelBuilder.batteryLabel(alias: "desk", state: state(week.lastGood!, at: now), record: week, now: now)
    #expect(weekLabel.hasPrefix("desk · 60% left, week · resets "))
    #expect(weekLabel.hasSuffix(" · 5h reset · reading…"))
    #expect(!weekLabel.contains("read 12m ago"))
    // Stale: the read's age stays, and a refilled battery is not "last".
    let later = readAt.addingTimeInterval(25 * 60)
    #expect(PanelModelBuilder.batteryLabel(alias: "night", state: state(full.lastGood!, at: later), record: full, now: later)
            == "night · 100% left, 5h · reset · read 25m ago")
    // Before the reset, the label is as ever.
    let before = readAt.addingTimeInterval(5 * 60)
    #expect(PanelModelBuilder.batteryLabel(alias: "night", state: state(full.lastGood!, at: before), record: full, now: before)
            == "night · 0% left, 5h · back in 5m · read 5m ago")
}

@Test func aRunOutForAWindowPastItsResetIsDropped() {
    // Samples that ran the 5h window up fast, then its reset passes with no read.
    var history = UsageHistory.empty
    // 200 % an hour: out 12 minutes after the read, 3 before the reset.
    let window5h = window(60, resetsIn: 15 * 60)
    for (minutes, used) in [(-12.0, 20.0), (-6, 40), (0, 60)] {
        let at = readAt.addingTimeInterval(minutes * 60)
        history.record(AccountReading(accountID: "a", readAt: at, windows: [
            UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: window5h.resetsAt)]), for: "a")
    }
    let records = ["a": AccountRecord(lastGood: reading([window5h], id: "a"))]
    let entries = [PanelEntry(id: "a", alias: "a", provider: .claude)]
    let soon = PanelModelBuilder.build(entries: entries, records: records, signingIn: [], money: [], now: readAt.addingTimeInterval(60),
                                       history: history)
    #expect(soon.rows.first?.batteries.first?.runOut != nil)
    let after = PanelModelBuilder.build(entries: entries, records: records, signingIn: [], money: [], now: readAt.addingTimeInterval(16 * 60),
                                        history: history)
    #expect(after.rows.first?.batteries.first?.runOut == nil)
    #expect(after.rows.first?.batteries.first?.state == .available(percentLeft: 100, isLow: false))
}
