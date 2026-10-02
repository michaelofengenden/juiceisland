import Foundation
import Testing
@testable import JuiceCore

/// P125: each account's readings kept as a bounded history, the run-out forecast made from it, and the quota notices
/// judged from one reading to the next. Every clock is fake.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let minute: TimeInterval = 60
private let hour: TimeInterval = 3_600

private func reading(_ account: String = "claude#a", at date: Date, used: Double, resetsAt: Date?, week: Double? = nil,
                     weekResets: Date? = nil, allowed: Bool = true) -> AccountReading {
    var windows = [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: resetsAt)]
    if let week { windows.append(UsageWindow(seconds: 604_800, usedPercent: week, resetsAt: weekResets)) }
    return AccountReading(accountID: account, readAt: date, windows: windows, ordinaryUsageAllowed: allowed)
}

private func record(_ reading: AccountReading) -> AccountRecord { AccountRecord(lastGood: reading, lastAttemptAt: reading.readAt) }

// MARK: History

@Test func aSampleIsCompactOnDisk() throws {
    let sample = UsageSample(at: t0 + 0.4, used: 42.26, resetsAt: t0 + 3_600.2)
    let data = try JSONEncoder().encode(sample)
    #expect(String(decoding: data, as: UTF8.self) == "[1800000000,42.3,1800003600]")
    let back = try JSONDecoder().decode(UsageSample.self, from: data)
    #expect(back == UsageSample(at: t0, used: 42.3, resetsAt: t0 + 3_600))
    let noReset = try JSONDecoder().decode(UsageSample.self, from: Data("[1800000000,7]".utf8))
    #expect(noReset.resetsAt == nil && noReset.used == 7)
}

/// A Codex account read every 15 s keeps one sample per 5 minutes, the newest always the latest reading.
@Test func frequentReadingsKeepOneSamplePerFiveMinutes() {
    var history = UsageHistory()
    let reset = t0 + 4 * hour
    for step in 0...80 {   // 20 minutes at 15 s
        let at = t0 + Double(step) * 15
        history.record(reading(at: at, used: 10 + Double(step) / 8, resetsAt: reset), for: "codex#a")
    }
    let samples = history.samples("codex#a", window: "5h")
    #expect(samples.last?.at == t0 + 1_200 && samples.last?.used == 20)
    #expect(samples.count <= 6)
    for (a, b) in zip(samples, samples.dropFirst()).dropLast() { #expect(b.at.timeIntervalSince(a.at) >= UsageHistory.fineSpacing) }
    // Uncounted windows are not kept.
    var withOAuth = UsageHistory()
    withOAuth.record(AccountReading(accountID: "x", readAt: t0, windows: [UsageWindow(seconds: 604_800, usedPercent: 3, resetsAt: nil,
                                                                                          label: "week · OAuth apps", counted: false)]), for: "x")
    #expect(withOAuth.sampleCount == 0)
}

/// A reset starts a new window: its first sample is never replaced, and `current` walks back only through its own.
@Test func aResetStartsANewWindow() {
    var history = UsageHistory()
    let first = t0 + hour, second = t0 + 6 * hour
    history.record(reading(at: t0, used: 70, resetsAt: first), for: "a")
    history.record(reading(at: t0 + 20 * minute, used: 90, resetsAt: first), for: "a")
    history.record(reading(at: t0 + 62 * minute, used: 2, resetsAt: second), for: "a")
    history.record(reading(at: t0 + 64 * minute, used: 4, resetsAt: second), for: "a")
    #expect(history.samples("a", window: "5h").map(\.used) == [70, 90, 2, 4])
    let now = UsageWindow(seconds: 18_000, usedPercent: 6, resetsAt: second)
    #expect(history.current("a", now, readAt: t0 + 70 * minute).map(\.used) == [2, 4, 6])
    // With no reset time, use that falls back is the new window.
    #expect(!UsageHistory.sameWindow(UsageSample(at: t0, used: 80, resetsAt: nil), UsageSample(at: t0 + 1, used: 10, resetsAt: nil)))
    #expect(UsageHistory.sameWindow(UsageSample(at: t0, used: 80, resetsAt: t0 + hour), UsageSample(at: t0 + 1, used: 79, resetsAt: t0 + hour + 3)))
}

/// The clock went back: the newest reading holds, and whatever the clock had put after it goes.
@Test func aClockMovedBackKeepsTheNewestReading() {
    var history = UsageHistory()
    let reset = t0 + 4 * hour
    history.record(reading(at: t0, used: 10, resetsAt: reset), for: "a")
    history.record(reading(at: t0 + 10 * minute, used: 12, resetsAt: reset), for: "a")
    history.record(reading(at: t0 + 20 * minute, used: 14, resetsAt: reset), for: "a")
    history.record(reading(at: t0 + 5 * minute, used: 11, resetsAt: reset), for: "a")
    #expect(history.samples("a", window: "5h").map(\.used) == [10, 11])
    history.record(reading(at: t0 + 5 * minute, used: 11.5, resetsAt: reset), for: "a")
    #expect(history.samples("a", window: "5h").map(\.used) == [10, 11.5])
}

/// Pruning drops samples past 14 days, thins those past 6 hours to one an hour, and keeps each window's first and last.
@Test func pruningKeepsFourteenDaysAndThinsTheOld() {
    var history = UsageHistory()
    let now = t0 + 20 * 86_400
    // A day of 5-minute samples 16 days ago (gone), and one 3 days ago (thinned), each one 5-hour window after another.
    for day in [16.0, 3.0] {
        let start = now - day * 86_400
        for step in 0..<288 {
            let at = start + Double(step) * 300
            let window = floor(Double(step) / 60)
            history.record(reading(at: at, used: Double(step % 60), resetsAt: start + (window + 1) * 18_000), for: "a")
        }
    }
    history.prune(now: now)
    let samples = history.samples("a", window: "5h")
    #expect(samples.allSatisfy { $0.at >= now - UsageHistory.keep })
    #expect(samples.count <= 24 + 2 * 5)                 // one an hour, plus each window's first and last
    #expect(samples.first?.at == now - 3 * 86_400)       // the first window's first sample
    #expect(samples.last?.used == 47)                    // the last window's last sample
    // Nothing left of an account: it goes.
    var old = UsageHistory()
    old.record(reading(at: t0, used: 1, resetsAt: nil), for: "gone")
    old.prune(now: t0 + 15 * 86_400)
    #expect(old.accounts.isEmpty)
}

/// Memory and disk stay bounded: 30 days of a Codex account read every 15 s (a 5-hour window and a week), pruned as the
/// store prunes at each save, never hold more than the caps, and the file stays small.
@Test func thirtyDaysOfReadingsStayBounded() throws {
    var history = UsageHistory()
    let interval: TimeInterval = 15
    let steps = Int(30 * 86_400 / interval)
    var maxCount = 0
    for step in 0..<steps {
        let at = t0 + Double(step) * interval
        let fiveHour = floor(Double(step) * interval / 18_000)
        let week = floor(Double(step) * interval / 604_800)
        let used = (Double(step) * interval).truncatingRemainder(dividingBy: 18_000) / 180
        history.record(reading(at: at, used: used, resetsAt: t0 + (fiveHour + 1) * 18_000,
                               week: used / 5, weekResets: t0 + (week + 1) * 604_800), for: "codex#a")
        if step % 240 == 0 {                              // the store's minute save, sampled every hour
            history.prune(now: at)
            maxCount = max(maxCount, history.sampleCount)
        }
    }
    history.prune(now: t0 + 30 * 86_400)
    #expect(maxCount <= 2 * UsageHistory.maxSamples)
    #expect(history.sampleCount <= 2 * UsageHistory.maxSamples)
    #expect(history.samples("codex#a", window: "5h").first.map { $0.at >= t0 + 16 * 86_400 } == true)
    let bytes = try JSONEncoder().encode(history).count
    #expect(bytes < 40_000, "\(bytes) bytes for one account")
}

// MARK: Forecast

/// A 5-hour window burning 1 % a minute at 40 % used, resetting in 2 hours, runs out in about an hour: said with its reset.
@Test func aSteadyBurnRunsOutBeforeTheReset() throws {
    var history = UsageHistory()
    let reset = t0 + 2 * hour
    for step in 0...6 { history.record(reading(at: t0 - 30 * minute + Double(step) * 5 * minute, used: 10 + Double(step) * 5, resetsAt: reset), for: "a") }
    let latest = reading(at: t0, used: 40, resetsAt: reset)
    let runOut = try #require(UsageForecast.runOut(latest, account: "a", history: history))
    #expect(runOut.window == "5h" && abs(runOut.perHour - 60) < 0.01)
    #expect(abs(runOut.at.timeIntervalSince(t0 + hour)) < 1)
    #expect(UsageForecast.part(runOut, namedWindow: "5h", now: t0) == "out in ~1h")
    #expect(UsageForecast.part(runOut, namedWindow: "week", now: t0 + 20 * minute) == "5h out in ~40m, resets in 1h 40m")

    // Reset first: nothing to say.
    let late = reading(at: t0, used: 40, resetsAt: t0 + 50 * minute)
    var calm = UsageHistory()
    for step in 0...6 { calm.record(reading(at: t0 - 30 * minute + Double(step) * 5 * minute, used: 10 + Double(step) * 5, resetsAt: t0 + 50 * minute), for: "a") }
    #expect(UsageForecast.runOut(late, account: "a", history: calm) == nil)
}

@Test func noForecastWithoutEnoughOrRisingSamples() {
    let reset = t0 + 3 * hour
    var short = UsageHistory()
    short.record(reading(at: t0 - 5 * minute, used: 30, resetsAt: reset), for: "a")
    #expect(UsageForecast.runOut(reading(at: t0, used: 40, resetsAt: reset), account: "a", history: short) == nil)
    var flat = UsageHistory()
    for step in 0...6 { flat.record(reading(at: t0 - 30 * minute + Double(step) * 5 * minute, used: 50, resetsAt: reset), for: "a") }
    #expect(UsageForecast.runOut(reading(at: t0, used: 50, resetsAt: reset), account: "a", history: flat) == nil)
    // Last window's samples do not count for this one.
    var reset2 = UsageHistory()
    for step in 0...6 { reset2.record(reading(at: t0 - 40 * minute + Double(step) * 5 * minute, used: 60 + Double(step) * 5, resetsAt: t0 - 5 * minute), for: "a") }
    #expect(UsageForecast.runOut(reading(at: t0, used: 3, resetsAt: t0 + 5 * hour), account: "a", history: reset2) == nil)
    #expect(UsageForecast.approximately(t0 + 20, now: t0) == "~1m")
    #expect(UsageForecast.approximately(t0 + 97 * minute, now: t0) == "~1h 35m")
    #expect(UsageForecast.approximately(t0 + 3 * hour + 90, now: t0) == "~3h")
}

@Test func theSparklineRunsFromTheWindowStartToItsReset() throws {
    var history = UsageHistory()
    let reset = t0 + 2.5 * hour                      // a 5-hour window half gone
    history.record(reading(at: t0 - 2 * hour, used: 10, resetsAt: reset), for: "a")
    history.record(reading(at: t0 - hour, used: 30, resetsAt: reset), for: "a")
    let latest = reading(at: t0, used: 50, resetsAt: reset)
    let line = try #require(UsageSparkline.make(latest, account: "a", history: history, runOut: nil))
    #expect(line.points.map(\.y) == [0.1, 0.3, 0.5])
    #expect(line.points.map { ($0.x * 100).rounded() / 100 } == [0.1, 0.3, 0.5])
    #expect(!line.runsOut && line.window == "5h")
    #expect(UsageSparkline.make(latest, account: "other", history: history, runOut: nil) == nil)
}

// MARK: Panel

@Test func theHoverSaysWhenAWindowRunsOut() {
    var history = UsageHistory()
    let reset = t0 + 2 * hour
    for step in 0...6 { history.record(reading(at: t0 - 30 * minute + Double(step) * 5 * minute, used: 10 + Double(step) * 5, resetsAt: reset), for: "a") }
    let latest = reading(at: t0, used: 40, resetsAt: reset)
    history.record(latest, for: "a")
    let entry = PanelEntry(id: "a", alias: "work", provider: .claude)
    let panel = PanelModelBuilder.build(entries: [entry], records: ["a": record(latest)], signingIn: [], money: [], now: t0, history: history)
    let battery = panel.rows[0].batteries[0]
    #expect(battery.runOut?.window == "5h")
    #expect(battery.hoverLabel == "work · 60% left, 5h · out in ~1h · resets in 2h · read just now")
    // Without history, as before.
    let plain = PanelModelBuilder.build(entries: [entry], records: ["a": record(latest)], signingIn: [], money: [], now: t0)
    #expect(plain.rows[0].batteries[0].runOut == nil && plain.rows[0].batteries[0].hoverLabel == "work · 60% left, 5h · resets in 2h · read just now")
    // A stale battery says nothing about the pace.
    let stale = PanelModelBuilder.build(entries: [entry], records: ["a": record(latest)], signingIn: [], money: [], now: t0 + hour, history: history)
    #expect(stale.rows[0].batteries[0].runOut == nil)
}

@Test func codexCreditsFollowTheWindows() {
    var codex = reading("codex#a", at: t0, used: 20, resetsAt: t0 + hour)
    codex.creditsBalance = 1_579.16
    codex.resetCredits = 2
    codex.resetCreditExpires = Date(timeIntervalSince1970: 1_791_000_000)
    let label = PanelModelBuilder.batteryLabel(alias: "home", state: .available(percentLeft: 80, isLow: false), record: record(codex), now: t0)
    #expect(label.hasSuffix(" · read just now · 1,579 credits · 2 reset credits, first until 3 Oct"))
    codex.creditsBalance = 0
    codex.resetCredits = 1
    codex.resetCreditExpires = nil
    #expect(PanelModelBuilder.creditParts(codex) == ["1 reset credit"])
    codex.resetCredits = nil
    #expect(PanelModelBuilder.creditParts(codex).isEmpty)
}

@Test func codexResetCreditsAreReadLeniently() throws {
    let json = #"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1800003600},"credits":{"hasCredits":true,"balance":"12.5"}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"resetType":"x","grantedAt":1790000000,"expiresAt":1791000000,"title":"t"},{"expiresAt":"2026-10-20T00:00:00Z"}]}}"#
    let result = try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(json.utf8))
    let parsed = result.reading(accountID: "c", readAt: t0, email: nil)
    #expect(parsed.resetCredits == 2 && parsed.resetCreditExpires == Date(timeIntervalSince1970: 1_791_000_000) && parsed.creditsBalance == 12.5)
    let odd = #"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}},"rateLimitResetCredits":{"availableCount":"many","credits":7}}"#
    let lenient = try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(odd.utf8)).reading(accountID: "c", readAt: t0, email: nil)
    #expect(lenient.resetCredits == nil && lenient.windows.count == 1)
    let none = #"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#
    #expect(try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(none.utf8)).reading(accountID: "c", readAt: t0, email: nil).resetCredits == nil)
}

// MARK: Notices

@MainActor
private final class Clock {
    var now = t0
}

@MainActor
private func store(_ clock: Clock, file: URL? = nil) -> UsageHistoryStore {
    UsageHistoryStore(fileURL: file, clock: { clock.now })
}

@MainActor
private func feed(_ store: UsageHistoryStore, _ reading: AccountReading, provider: Provider = .claude) -> QuotaNotice? {
    let before = store.notice
    store.observe([reading.accountID: record(reading)], providers: [reading.accountID: provider])
    return store.notice == before ? nil : store.notice
}

/// Crossing 90 % says so once per window: not again as it climbs or dithers, again in the next window. The first reading
/// of a run (a launch) says nothing, however high.
@MainActor
@Test func crossingNinetyIsSaidOncePerWindow() throws {
    let clock = Clock(), history = store(clock)
    let reset = t0 + 3 * hour
    #expect(feed(history, reading(at: t0, used: 95, resetsAt: reset)) == nil)          // launch: a level, not a crossing
    #expect(feed(history, reading(at: t0 + 5 * minute, used: 96, resetsAt: reset)) == nil)
    let other = store(clock)
    #expect(feed(other, reading(at: t0, used: 85, resetsAt: reset)) == nil)
    let notice = try #require(feed(other, reading(at: t0 + 5 * minute, used: 91, resetsAt: reset)))
    #expect(notice.kind == .low(window: "5h", percentLeft: 9, resetsAt: reset) && notice.text(now: t0 + 5 * minute) == "5h almost out · resets in 2h 55m")
    #expect(feed(other, reading(at: t0 + 20 * minute, used: 89, resetsAt: reset)) == nil)
    #expect(feed(other, reading(at: t0 + 40 * minute, used: 92, resetsAt: reset)) == nil)
    // The next window.
    let next = reset + 5 * hour
    #expect(feed(other, reading(at: reset + 10 * minute, used: 50, resetsAt: next)) == nil)
    #expect(feed(other, reading(at: reset + 2 * hour, used: 93, resetsAt: next)) != nil)
    // Straight to used up.
    let third = store(clock)
    _ = feed(third, reading(at: t0, used: 80, resetsAt: reset))
    // The battery above it shows the wait until the refill: the line does not say it again.
    let usedUp = feed(third, reading(at: t0 + 5 * minute, used: 100, resetsAt: reset))
    #expect(usedUp?.text(now: t0 + 5 * minute) == "5h used up")
}

/// Running out within 30 minutes is said once, and shares its window's one notice with the 90 % crossing.
@MainActor
@Test func runningOutSoonIsSaidOnceAndSharesTheWindow() throws {
    let clock = Clock(), history = store(clock)
    let reset = t0 + 2 * hour
    var notices: [QuotaNotice] = []
    for step in 0...12 {                                   // 2 % a minute from 50 %: out 25 minutes after the last reading
        let at = t0 + Double(step) * 2.5 * minute
        if let notice = feed(history, reading(at: at, used: 50 + Double(step) * 2.5, resetsAt: reset)) { notices.append(notice) }
    }
    let notice = try #require(notices.first)
    #expect(notices.count == 1)
    guard case let .runningOut(runOut) = notice.kind else { Issue.record("not a run-out: \(notice.kind)"); return }
    #expect(runOut.window == "5h" && runOut.at.timeIntervalSince(notice.at) <= QuotaAlerts.soon)
    #expect(notice.text(now: notice.at).hasPrefix("5h out in ~"))
    // Past 90 % in the same window: already said.
    #expect(feed(history, reading(at: t0 + 40 * minute, used: 91, resetsAt: reset)) == nil)
}

/// Back: a used-up account available again, said once per refill, however its availability flaps.
@MainActor
@Test func aSpentAccountSaysItIsBackOnce() throws {
    let clock = Clock(), history = store(clock)
    let reset = t0 + 30 * minute, next = t0 + 30 * minute + 5 * hour
    _ = feed(history, reading("codex#a", at: t0, used: 100, resetsAt: reset), provider: .codex)
    let back = try #require(feed(history, reading("codex#a", at: t0 + 31 * minute, used: 0, resetsAt: next), provider: .codex))
    #expect(back.kind == .back(percentLeft: 100) && back.provider == .codex && back.text(now: back.at) == "back")
    // Codex says not allowed, then allowed, within the same refill: nothing more.
    _ = feed(history, reading("codex#a", at: t0 + 50 * minute, used: 1, resetsAt: next, allowed: false), provider: .codex)
    #expect(feed(history, reading("codex#a", at: t0 + 51 * minute, used: 1, resetsAt: next), provider: .codex) == nil)
}

/// What was said survives a relaunch: the same window's crossing is not said again from the file.
@MainActor
@Test func whatWasSaidSurvivesARelaunch() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let clock = Clock()
    let reset = t0 + 3 * hour
    let first = store(clock, file: url)
    _ = feed(first, reading(at: t0, used: 85, resetsAt: reset))
    #expect(feed(first, reading(at: t0 + 5 * minute, used: 91, resetsAt: reset)) != nil)
    first.flush()
    let saved = try Data(contentsOf: url)
    #expect(saved.count < 2_000)

    let second = store(clock, file: url)
    second.load()
    #expect(second.history.samples("claude#a", window: "5h").count == 2)
    _ = feed(second, reading(at: t0 + 6 * minute, used: 89, resetsAt: reset))          // launch: the baseline
    #expect(feed(second, reading(at: t0 + 30 * minute, used: 92, resetsAt: reset)) == nil)
}

/// P111 for the history: a file this build cannot read starts an empty history and is kept beside it before the first
/// write, never written over as it is.
@MainActor
@Test func anUnreadableHistoryIsKeptBeforeItIsWrittenOver() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = UsageHistoryStore.file(in: folder)
    let junk = Data(#"{"version":2,"history":"from a newer build"}"#.utf8)
    try junk.write(to: url)
    let clock = Clock()
    let history = store(clock, file: url)
    history.load()
    #expect(history.history.samples("claude#a", window: "5h").isEmpty)
    _ = feed(history, reading(at: t0, used: 40, resetsAt: t0 + 3 * hour))
    history.flush()
    #expect(try StoreFile.keptCopies(of: url).map { try Data(contentsOf: $0) } == [junk])
    let reread = store(clock, file: url)
    reread.load()
    #expect(reread.history.samples("claude#a", window: "5h").count == 1)
}

/// Two notices for one account never come within the cooldown.
@MainActor
@Test func oneAccountIsNeverNoisy() {
    let clock = Clock(), history = store(clock)
    let reset = t0 + 3 * hour, week = t0 + 4 * 86_400
    _ = feed(history, reading(at: t0, used: 85, resetsAt: reset, week: 85, weekResets: week))
    #expect(feed(history, reading(at: t0 + 5 * minute, used: 91, resetsAt: reset, week: 85, weekResets: week)) != nil)
    #expect(feed(history, reading(at: t0 + 8 * minute, used: 92, resetsAt: reset, week: 91, weekResets: week)) == nil)
}

/// A reset time that drifts a little on every read (a vendor that reports seconds until the reset) stays one window,
/// however far it drifts in all: once its crossing was said, its run-out later in the same window is not.
@MainActor
@Test func aDriftingResetTimeStaysOneWindow() {
    let clock = Clock(), history = store(clock)
    func reset(_ step: Int) -> Date { t0 + 2 * hour + Double(step) * 60 }     // a minute later every read
    _ = feed(history, reading(at: t0, used: 85, resetsAt: reset(0)))
    #expect(feed(history, reading(at: t0 + 5 * minute, used: 91, resetsAt: reset(1))) != nil)
    for step in 2...20 {
        // Slow for an hour (the reset 14 minutes off where it was said), then fast enough to run out within 30 minutes.
        let used = step <= 14 ? 91 + Double(step) / 10 : 92.4 + Double(step - 14) * 1.5
        #expect(feed(history, reading(at: t0 + Double(step) * 5 * minute, used: used, resetsAt: reset(step))) == nil, "step \(step)")
    }
}
