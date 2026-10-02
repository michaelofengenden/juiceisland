import Foundation
import Testing
@testable import JuiceCore

/// Juice spec §2.3, §2.5, §8.2 and Juice Island spec §7 amendment 11.
@Suite struct MoneyRulesTests {
    static let now = MoneyReaderTests.now

    @Test func runwayRoundsDownAndSwitchesToDaysAt72Hours() {
        let cases: [(Double, String)] = [(0.5, "<1h"), (1, "1h"), (18.9, "18h"), (71.9, "71h"), (72, "3d"), (95.9, "3d"),
                                         (96, "4d"), (1_250, "52d")]
        for (hours, label) in cases { #expect(MoneyRules.runwayLabel(hours: hours) == label, "\(hours)") }
        #expect(MoneyRules.runwayHover(hours: 60.4) == "about 60 hours")
        #expect(MoneyRules.runwayHover(hours: 1_250) == "about 52 days")
        #expect(MoneyRules.runwayHover(hours: 1.5) == "about 1 hour")
        #expect(MoneyRules.runwayHover(hours: 0.4) == "under an hour")
        #expect(MoneyRules.runwayInspector(hours: 60.4) == "~60h")
        #expect(MoneyRules.runwayInspector(hours: 1_250) == "~52d")
    }

    @Test func runwayIsOmittedWithoutBurnOrWhenStale() {
        #expect(MoneyRules.runwayHours(balance: 100, burnPerHour: 0, stale: false) == nil)
        #expect(MoneyRules.runwayHours(balance: 100, burnPerHour: nil, stale: false) == nil)
        #expect(MoneyRules.runwayHours(balance: 100, burnPerHour: 2, stale: true) == nil)
        #expect(MoneyRules.runwayHours(balance: 100, burnPerHour: 2, stale: false) == 50)
        #expect(MoneyRules.runwayHours(balance: -5, burnPerHour: 2, stale: false) == 0)
        // A burn so small the division overflows still gives a label, never a trap.
        let long = MoneyRules.runwayHours(balance: 1e300, burnPerHour: 1e-300, stale: false)
        #expect(long == MoneyRules.runwayLimit)
        #expect(MoneyRules.runwayLabel(hours: long ?? 0) == "41666d")
        #expect(MoneyRules.runwayHours(balance: .infinity, burnPerHour: 1, stale: false) == nil)
    }

    @Test func amberAndRedCompareTheUnroundedHours() {
        #expect(MoneyRules.runwayEmphasis(hours: 18.9, amber: 72, red: 24) == .attention)
        #expect(MoneyRules.runwayEmphasis(hours: 23.99, amber: 72, red: 24) == .attention)
        #expect(MoneyRules.runwayEmphasis(hours: 24, amber: 72, red: 24) == .warn)
        #expect(MoneyRules.runwayEmphasis(hours: 71.9, amber: 72, red: 24) == .warn)
        #expect(MoneyRules.runwayEmphasis(hours: 72, amber: 72, red: 24) == .normal)
        #expect(MoneyRules.runwayEmphasis(hours: nil, amber: 72, red: 24) == .normal)
        // Moving the amber threshold does not move the switch from hours to days.
        #expect(MoneyRules.runwayEmphasis(hours: 90, amber: 120, red: 24) == .warn)
        #expect(MoneyRules.runwayLabel(hours: 90) == "3d")
        #expect(MoneyRules.runwayLabel(hours: 71) == "71h")
    }

    @Test func amountsHaveNoDecimalsFrom100() {
        #expect(MoneyRules.amount(4_120.4, .usd) == "$4,120")
        #expect(MoneyRules.amount(1_234_567, .usd) == "$1,234,567")
        #expect(MoneyRules.amount(354, .usd) == "$354")
        #expect(MoneyRules.amount(38.2, .usd) == "$38.20")
        #expect(MoneyRules.amount(99.996, .usd) == "$100")
        #expect(MoneyRules.amount(0, .usd) == "$0.00")
        #expect(MoneyRules.amount(-12.5, .usd) == "\u{2212}$12.50")
        #expect(MoneyRules.amount(153.2, .eur) == "€153")
        #expect(MoneyRules.rate(1.84, .usd) == "$1.84/h")
        #expect(MoneyRules.rate(0.2096, .eur) == "€0.21/h")
        // Out of range: a dash, never a trap.
        for value in [Double.infinity, -.infinity, .nan, 1e300, -1e300] { #expect(MoneyRules.amount(value, .usd) == "\u{2014}") }
    }

    @Test func creditLeftCountsSpendSinceTheCreditDate() {
        let september7 = MoneyReaderTests.september7
        let costs = CostFigures(daily: ["2026-09-06": 999, "2026-09-07": 300, "2026-09-20": 685, "2026-09-24": 61], coveredFrom: september7)
        #expect(costs.spent(from: september7) == 1_046)
        #expect(costs.today(Self.now) == 61)
        let settings = MoneySourceSettings(credit: 1_400, creditDate: september7)
        #expect(MoneyRules.costsFrom(settings: settings, now: Self.now) == september7)
        #expect(MoneyRules.costsFrom(settings: MoneySourceSettings(), now: Self.now) == Date(timeIntervalSince1970: 1_788_220_800))
        let presentation = MoneyPresentation.make(source: .anthropic, record: record(.spend(costs)), settings: settings,
                                                  now: Self.now, amber: 72, red: 24)
        #expect(presentation?.row.amount == "$354")
        #expect(presentation?.row.isSpent == false)
        #expect(presentation?.row.hoverLabel == "Anthropic · $354 left of $1,400 since 7 Sep · $61.00 today · read 2m ago")
        #expect(presentation?.creditLeftShare.map { abs($0 - 354.0 / 1_400) < 0.0001 } == true)
        #expect(presentation?.denominator == "of $1,400 · 7 Sep")
    }

    @Test func withoutACreditSpendIsGreyAndNamesTheMonth() {
        let costs = CostFigures(daily: ["2026-09-23": 150.25, "2026-09-24": 61.75], coveredFrom: Date(timeIntervalSince1970: 1_788_220_800))
        let presentation = MoneyPresentation.make(source: .openAI, record: record(.spend(costs)), settings: MoneySourceSettings(),
                                                  now: Self.now, amber: 72, red: 24)
        #expect(presentation?.row.amount == "$212")
        #expect(presentation?.row.isSpent == true)
        #expect(presentation?.parts.first == "$212 spent in September")
        #expect(presentation?.shortParts == ["spent in September"])
        #expect(presentation?.status == "Connected")
    }

    @Test func runPodShowsRunwayAndTone() {
        func runPod(_ balance: Double) -> MoneyPresentation? {
            MoneyPresentation.make(source: .runPod, record: record(.balance(RunPodFigures(balance: balance, burnPerHour: 1.84).kind)),
                                   settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24)
        }
        let rich = runPod(2_310)
        #expect(rich?.row.amount == "$2,310" && rich?.row.suffix == "52d" && rich?.row.emphasis == .normal)
        #expect(rich?.row.hoverLabel == "RunPod · $2,310 balance · $1.84/h · about 52 days · read 2m ago")
        #expect(rich?.shortParts == ["$1.84/h", "52 days"])
        let amber = runPod(110)
        #expect(amber?.row.suffix == "59h" && amber?.row.emphasis == .warn)
        let red = runPod(33)
        #expect(red?.row.suffix == "17h" && red?.row.emphasis == .attention)
        let idle = MoneyPresentation.make(source: .runPod, record: record(.balance(RunPodFigures(balance: 50, burnPerHour: 0).kind)),
                                          settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24)
        #expect(idle?.row.suffix == nil && idle?.runwayHours == nil && idle?.row.emphasis == .normal)
    }

    @Test func hetznerReadsPerMonth() {
        let cloud = HetznerFigures(items: [.init(kind: .server, name: "a", monthly: 100), .init(kind: .server, name: "b", monthly: 40),
                                           .init(kind: .backup, name: "a", monthly: 20), .init(kind: .floatingIP, name: "f", monthly: 3)])
        let presentation = MoneyPresentation.make(source: .hetzner, record: record(.spend(cloud.spend)), settings: MoneySourceSettings(),
                                                  now: Self.now, amber: 72, red: 24)
        #expect(presentation?.row.amount == "€163" && presentation?.row.suffix == "/mo")
        #expect(presentation?.row.hoverLabel == "Hetzner · 2 servers · €0.22/h · about €163 this month · read 2m ago")
    }

    @Test func staleAndFailingSourcesDrawRailsAndSayWhy() {
        let reading = MoneyReading(source: .openRouter, readAt: Self.now - 1_500,
                                   figures: .balance(OpenRouterFigures(totalCredits: 5_000, totalUsage: 880).kind))
        var failing = MoneySourceRecord(lastGood: reading, lastError: .offline, lastErrorAt: Self.now - 60)
        let stale = MoneyPresentation.make(source: .openRouter, record: failing, settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24)
        #expect(stale?.row.amount == nil && stale?.isReadable == false)
        #expect(stale?.row.hoverLabel == "OpenRouter · offline · last $4,120 balance · read 25m ago")
        #expect(stale?.status == "Offline")
        // A failure younger than the freshness limit keeps the figure.
        failing.lastGood?.readAt = Self.now - 300
        let fresh = MoneyPresentation.make(source: .openRouter, record: failing, settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24)
        #expect(fresh?.row.amount == "$4,120" && fresh?.status == "Offline")
        // A key without the role: rails and the exact words.
        let role = MoneyPresentation.make(source: .anthropic, record: MoneySourceRecord(lastError: .keyNotUsable, lastErrorAt: Self.now),
                                          settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24)
        #expect(role?.row.amount == nil && role?.status == "Not available with this key")
        #expect(role?.row.hoverLabel == "Anthropic · not available with this key")
        // P363: a 401 or 403 says what to do where the source tells it: OpenAI's costs need an Admin key, Hetzner a token
        // it knows. Its hover and every other source's word stay as they were.
        func refused(_ account: MoneyAccount) -> MoneyPresentation? {
            MoneyPresentation.make(account: account, record: MoneySourceRecord(lastError: .notAvailableWithThisKey, lastErrorAt: Self.now),
                                   settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24)
        }
        #expect(refused(MoneyAccount(.openAI))?.status == "Needs an Admin key (sk-admin-…)")
        #expect(refused(MoneyAccount(.hetzner))?.status == "Token rejected · make a Read token")
        #expect(refused(MoneyAccount(.hetzner))?.row.hoverLabel == "Hetzner · not available with this key")
        #expect(refused(MoneyAccount(.anthropic))?.status == "Not available with this key")
        #expect(MoneyReadError.keyNotUsable.statusWord(for: .openAI) == "Not available with this key")
        #expect(MoneyReadError.http(401).statusWord(for: .hetzner) == "Read failed (401)")
        // A runway from a stale reading is omitted.
        let oldPod = MoneyReading(source: .runPod, readAt: Self.now - 3_600, figures: .balance(RunPodFigures(balance: 10, burnPerHour: 1).kind))
        let pod = MoneyPresentation.make(source: .runPod, record: MoneySourceRecord(lastGood: oldPod), settings: MoneySourceSettings(),
                                         now: Self.now, amber: 72, red: 24)
        #expect(pod?.runwayHours == nil && pod?.row.suffix == nil && pod?.row.emphasis == .normal)
    }

    @Test func unconfiguredSourcesAreHidden() {
        #expect(MoneyPresentation.make(source: .hetzner, record: nil, settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24) == nil)
        let none = MoneySourceRecord(lastError: .notConfigured, lastErrorAt: Self.now)
        #expect(MoneyPresentation.make(source: .hetzner, record: none, settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24) == nil)
    }

    private func record(_ figures: MoneyReading.Figures) -> MoneySourceRecord {
        MoneySourceRecord(lastGood: MoneyReading(source: .openRouter, readAt: Self.now - 120, figures: figures))
    }
}
