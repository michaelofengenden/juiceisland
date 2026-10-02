import Foundation
import Testing
@testable import JuiceCore

private let readAt = Date(timeIntervalSince1970: 1_790_082_000)

private func claude(_ limits: String) throws -> ClaudeUsageResponse {
    let json = #"{"subscription_type":"max","rate_limits_available":true,"rate_limits":"# + limits + "}"
    return try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
}

private func codex(_ json: String) throws -> CodexRateLimitsResult {
    try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(json.utf8))
}

/// Every five_hour… or seven_day… key becomes a window. Model weeks count; the OAuth-apps week and keys Juice does
/// not know yet show in the hover only, and never make an account look used up.
@Test func claudeReadsEveryWindowKeyAndCountsOnlyTheTableOnes() throws {
    let response = try claude(#"""
    {"five_hour":{"utilization":10,"resets_at":"2026-09-22T17:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-09-25T17:00:00Z"},
     "seven_day_opus":null,"seven_day_sonnet":{"utilization":30,"resets_at":"2026-09-26T17:00:00Z"},
     "seven_day_fable":{"utilization":40,"resets_at":"2026-09-27T17:00:00Z"},
     "seven_day_oauth_apps":{"utilization":70,"resets_at":"2026-09-27T17:00:00Z"},
     "seven_day_new_model":{"utilization":100,"resets_at":"2026-09-28T17:00:00Z"},
     "extra_usage":{"is_enabled":false,"utilization":null},"limits":[{"kind":"session","percent":10}]}
    """#)
    let reading = try response.reading(accountID: "claude:/x", readAt: readAt)
    #expect(reading.windows.map(\.displayLabel) == ["5h", "week", "week · Sonnet", "week · Fable", "week · OAuth apps", "week · new model"])
    #expect(reading.windows.map(\.isCounted) == [true, true, true, true, false, false])
    #expect(Rules.percentLeft(reading) == 60)
    #expect(!Rules.isExhausted(reading))
    #expect(Rules.state(reading: reading, lastError: nil, signingIn: false, provider: .claude, now: readAt)
            == .available(percentLeft: 60, isLow: false))
}

/// A `five_hour_…` key Juice does not know yet is a 5-hour window named from the key. It shows in the hover and does
/// not count, so even at 100% it never makes the account used up.
@Test func anUnknownFiveHourKeyIsAnUncountedFiveHourWindow() throws {
    let response = try claude(#"{"five_hour":{"utilization":10,"resets_at":null},"five_hour_fable":{"utilization":100,"resets_at":null}}"#)
    let reading = try response.reading(accountID: "claude:/x", readAt: readAt)
    #expect(reading.windows.map(\.displayLabel) == ["5h", "5h · fable"])
    #expect(reading.windows.map(\.seconds) == [18_000, 18_000])
    #expect(reading.windows.map(\.isCounted) == [true, false])
    #expect(!Rules.isExhausted(reading))
    #expect(Rules.percentLeft(reading) == 90)
}

/// A counted window that is there but no longer decodes (its utilization sent as text, or not an object at all) could
/// hide a used-up limit, so the reading is incomplete instead of available on the other windows. A null window, a
/// window that does not count and a key that is not a window still drop out without failing the read.
@Test func aCountedWindowThatNoLongerDecodesMakesTheReadingIncomplete() throws {
    let textUtilization = try claude(#"{"five_hour":{"utilization":"31","resets_at":null},"seven_day":{"utilization":20,"resets_at":null}}"#)
    #expect(throws: ReadError.incomplete("five_hour window unreadable")) { try textUtilization.reading(accountID: "claude:/x", readAt: readAt) }
    let notAnObject = try claude(#"{"five_hour":{"utilization":10,"resets_at":null},"seven_day_opus":95}"#)
    #expect(throws: ReadError.incomplete("seven_day_opus window unreadable")) { try notAnObject.reading(accountID: "claude:/x", readAt: readAt) }
    let others = try claude(#"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":null,"seven_day_oauth_apps":{"utilization":"x"},"# +
                            #""seven_day_new_model":[1],"extra_usage":{"is_enabled":"no"},"limits":[{"kind":"session","percent":10}]}"#)
    #expect(try others.reading(accountID: "claude:/x", readAt: readAt).windows.map(\.displayLabel) == ["5h"])
}

/// All-null windows, or only windows that do not count, are "no reading yet", never 0%.
@Test func claudeWithoutACountedWindowIsIncompleteNeverZero() throws {
    let allNull = try claude(#"{"five_hour":null,"seven_day":{"utilization":null,"resets_at":null},"seven_day_opus":null}"#)
    #expect(throws: ReadError.incomplete("no windows reported")) { try allNull.reading(accountID: "claude:/x", readAt: readAt) }
    let onlyApps = try claude(#"{"five_hour":null,"seven_day_oauth_apps":{"utilization":5,"resets_at":null}}"#)
    #expect(throws: ReadError.incomplete("no windows reported")) { try onlyApps.reading(accountID: "claude:/x", readAt: readAt) }
}

@Test func windowsThatDoNotCountShowInTheHoverOnly() throws {
    let response = try claude(#"{"five_hour":{"utilization":31,"resets_at":null},"seven_day_oauth_apps":{"utilization":90,"resets_at":null}}"#)
    let reading = try response.reading(accountID: "claude:/x", readAt: readAt)
    let hover = PanelModelBuilder.batteryLabel(alias: "work", state: .available(percentLeft: 69, isLow: false),
                                               record: AccountRecord(lastGood: reading), now: readAt)
    #expect(hover == "work · 69% left, 5h · resets ? · read just now · week · OAuth apps 10% left")

    // The refill of a used-up account comes from the counted windows only: the 5h window in 1 hour, not the used-up
    // OAuth-apps week in 3 days.
    let usedUp = try claude(#"{"five_hour":{"utilization":100,"resets_at":"2026-09-22T14:00:00Z"},"# +
                            #""seven_day_oauth_apps":{"utilization":100,"resets_at":"2026-09-25T13:00:00Z"}}"#)
    let blocked = try usedUp.reading(accountID: "claude:/x", readAt: readAt)
    #expect(Rules.isExhausted(blocked))
    #expect(Rules.refillDate(blocked) == readAt.addingTimeInterval(3_600))
}

/// Windows that do not count follow the hover only in the states that show usage, each of which says how old the
/// reading is. Sign-in needed and signing in have no current reading, so an old OAuth-apps figure stays out of them.
@Test func windowsThatDoNotCountShowOnlyBesideUsage() throws {
    let account = Account(provider: .claude, folder: "/h/.claude-work", alias: "work")
    let response = try claude(#"{"five_hour":{"utilization":31,"resets_at":null},"seven_day_oauth_apps":{"utilization":90,"resets_at":null}}"#)
    let record = AccountRecord(lastGood: try response.reading(accountID: account.id, readAt: readAt),
                               lastError: .signInRequired, lastErrorAt: readAt + 3_600, consecutiveFailures: 1)
    let later = readAt + 7_200
    let panel = PanelModelBuilder.build(accounts: [account], records: [account.id: record], signingIn: [], money: [], now: later)
    let battery = try #require(panel.rows.first?.batteries.first)
    #expect(battery.state == .signInNeeded)
    #expect(battery.hoverLabel == "work · sign-in needed")
    #expect(PanelModelBuilder.batteryLabel(alias: "work", state: .signingIn, record: record, now: later) == "work · signing in…")
    #expect(PanelModelBuilder.batteryLabel(alias: "work", state: .stale(lastPercentLeft: 69), record: record, now: later)
            == "work · last 69% left, 5h · read 2h ago · week · OAuth apps 10% left")
    #expect(PanelModelBuilder.batteryLabel(alias: "work", state: .usedUp(refill: nil), record: record, now: later)
            == "work · 0% left, 5h · back ? · read 2h ago · week · OAuth apps 10% left")
}

/// Readings saved before `counted` existed decode with every window counted.
@Test func aStoredReadingWithoutCountedFlagsStillCounts() throws {
    let json = #"""
    {"accountID":"claude:/x","readAt":"2026-09-22T17:00:00Z","ordinaryUsageAllowed":true,
     "windows":[{"seconds":18000,"usedPercent":100},{"seconds":604800,"usedPercent":13,"label":"week · Opus"}]}
    """#
    let reading = try JSONDecoder.juice.decode(AccountReading.self, from: Data(json.utf8))
    #expect(reading.windows.allSatisfy { $0.isCounted })
    #expect(Rules.isExhausted(reading))
}

/// A window that does not count stays that way across a save and reload of readings.json: a used-up OAuth-apps week
/// must not make the account read as used up after a relaunch.
@MainActor
@Test func anUncountedWindowStaysUncountedAfterASaveAndReload() throws {
    let response = try claude(#"{"five_hour":{"utilization":20,"resets_at":null},"seven_day_oauth_apps":{"utilization":100,"resets_at":null}}"#)
    let reading = try response.reading(accountID: "claude:/x", readAt: readAt)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = ReadingsStore(fileURL: url)
    store.apply(.success(reading), for: "claude:/x", at: readAt)
    try store.save()
    let reloaded = ReadingsStore(fileURL: url)
    reloaded.load()
    let restored = try #require(reloaded.record(for: "claude:/x").lastGood)
    #expect(restored.windows.map(\.isCounted) == [true, false])
    #expect(!Rules.isExhausted(restored))
    #expect(Rules.state(reading: restored, lastError: nil, signingIn: false, provider: .claude, now: readAt)
            == .available(percentLeft: 80, isLow: false))
}

/// A missing duration is never "5h": a reset more than 5 hours away is the week's, anything nearer is "window".
@Test func aCodexWindowWithoutADurationIsInferredOrCalledWindow() throws {
    let weekReset = Int(readAt.timeIntervalSince1970) + 3 * 86_400
    let nearReset = Int(readAt.timeIntervalSince1970) + 2 * 3_600
    let result = try codex(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":40,"resetsAt":"# + "\(nearReset)" +
                           #"},"secondary":{"usedPercent":12,"resetsAt":"# + "\(weekReset)" + #"},"planType":"plus"}}"#)
    let reading = result.reading(accountID: "codex:/x", readAt: readAt, email: nil)
    #expect(reading.windows.map(\.displayLabel) == ["window", "week"])
    #expect(reading.windows.map(\.seconds) == [0, 604_800])
    // A reset further away than a week is a length Codex did not report before: "window", not "week".
    let monthReset = Int(readAt.timeIntervalSince1970) + 30 * 86_400
    let month = try codex(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":5,"resetsAt":"# + "\(monthReset)" + #"}}}"#)
    #expect(month.reading(accountID: "codex:/x", readAt: readAt, email: nil).windows.map(\.displayLabel) == ["window"])
    // The limits: more than 5 hours plus 60 s and at most a week plus an hour away is the week; the rest is "window".
    func inferred(resetIn seconds: Int) throws -> [String] {
        let reset = Int(readAt.timeIntervalSince1970) + seconds
        let one = try codex(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":5,"resetsAt":"# + "\(reset)" + #"}}}"#)
        return one.reading(accountID: "codex:/x", readAt: readAt, email: nil).windows.map { "\($0.displayLabel) \($0.seconds)" }
    }
    #expect(try inferred(resetIn: 4 * 3_600 + 59 * 60) == ["window 0"])
    #expect(try inferred(resetIn: 5 * 3_600 + 60) == ["window 0"])
    #expect(try inferred(resetIn: 5 * 3_600 + 61) == ["week 604800"])
    #expect(try inferred(resetIn: 5 * 3_600 + 30 * 60) == ["week 604800"])
    #expect(try inferred(resetIn: 7 * 86_400 + 3_600) == ["week 604800"])
    #expect(try inferred(resetIn: 7 * 86_400 + 3_600 + 1) == ["window 0"])
    #expect(try inferred(resetIn: 8 * 86_400) == ["window 0"])
    let secondaryOnly = try codex(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":null,"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":null}}}"#)
    #expect(secondaryOnly.reading(accountID: "codex:/x", readAt: readAt, email: nil).windows.map(\.displayLabel) == ["week"])
}

/// Not allowed, or a rate-limit-reached type, with no window is used up with an unknown refill, not stale.
@Test func aCodexLimitWithNoWindowIsUsedUp() throws {
    let blocked = try JSONDecoder().decode(CodexRateLimitsResult.self, from: fixture("codex-ratelimits-blocked-nowindow"))
    let reading = blocked.reading(accountID: "codex:/x", readAt: readAt, email: nil)
    #expect(reading.windows.isEmpty)
    #expect(!reading.ordinaryUsageAllowed)
    #expect(Rules.state(reading: reading, lastError: nil, signingIn: false, provider: .codex, now: readAt) == .usedUp(refill: nil))
    #expect(PanelModelBuilder.batteryLabel(alias: "side", state: .usedUp(refill: nil), record: AccountRecord(lastGood: reading), now: readAt)
            == "side · 0% left, window · back ? · read just now")

    let reachedButAllowed = try codex(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":null,"secondary":null,"rateLimitReachedType":"rate_limit_reached"}}"#)
    #expect(!reachedButAllowed.reading(accountID: "codex:/x", readAt: readAt, email: nil).ordinaryUsageAllowed)
    // A reached type next to a window is not "no window at all": the home stays allowed and the window decides.
    let reachedWithWindow = try codex(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300,"resetsAt":null},"# +
                                      #""secondary":null,"rateLimitReachedType":"rate_limit_reached"}}"#)
    let withWindow = reachedWithWindow.reading(accountID: "codex:/x", readAt: readAt, email: nil)
    #expect(withWindow.ordinaryUsageAllowed)
    #expect(Rules.state(reading: withWindow, lastError: nil, signingIn: false, provider: .codex, now: readAt)
            == .available(percentLeft: 50, isLow: false))
    let empty = try JSONDecoder().decode(CodexRateLimitsResult.self, from: fixture("codex-ratelimits-empty"))
    #expect(empty.reading(accountID: "codex:/x", readAt: readAt, email: nil).ordinaryUsageAllowed)
}

@Test func theCodexReaderReturnsAUsedUpHomeWithNoWindow() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: "/tmp/juice-test-codex", timeout: .seconds(10),
                                      extraEnvironment: ["FAKE_ACCOUNT": try fixtureURL("codex-account", "json").path,
                                                         "FAKE_LIMITS": try fixtureURL("codex-ratelimits-blocked-nowindow", "json").path])
    let account = Account(provider: .codex, folder: "/tmp/juice-test-codex", alias: "default")
    let reading = try await reader.read(account, now: readAt).get()
    #expect(reading.windows.isEmpty)
    #expect(!reading.ordinaryUsageAllowed)
    await reader.shutdown()
}
