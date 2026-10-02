import Foundation
import Testing
@testable import JuiceCore

/// The three figure kinds (Juice Island spec §8 decision 14): the five sources draw exactly what they drew before the
/// kinds, a money.json from before them still reads, and every kind survives a save.
@Suite struct MoneyKindsTests {
    let now = MoneyReaderTests.now
    let sep7 = MoneyReaderTests.september7
    let sep1 = Date(timeIntervalSince1970: 1_788_220_800)

    /// A presentation as the pinned file holds it: every field, as text.
    func describe(_ p: MoneyPresentation?) -> [String: String] {
        guard let p else { return ["nil": "true"] }
        func d(_ v: Double?) -> String { v.map { String(format: "%.6f", $0) } ?? "nil" }
        return ["id": p.row.id, "name": p.row.name, "amount": p.row.amount ?? "nil", "suffix": p.row.suffix ?? "nil",
                "isSpent": "\(p.row.isSpent)", "emphasis": "\(p.row.emphasis)", "hover": p.row.hoverLabel,
                "parts": p.parts.joined(separator: "|"), "short": p.shortParts.joined(separator: "|"), "runway": d(p.runwayHours),
                "share": d(p.creditLeftShare), "denominator": p.denominator, "lastRead": p.lastRead, "status": p.status,
                "readable": "\(p.isReadable)"]
    }

    /// The five sources over 218 records and settings, drawn now through the kinds, against what the code before the kinds
    /// drew for the same inputs (`presentation-before-kinds.json`, recorded from 00250a0's `MoneyPresentation`). The one
    /// field allowed to differ is Settings' grey measure (`denominator`, drawn nowhere) for a RunPod balance that has a
    /// top-up but no burn: it now names the top-up it is measured against, as OpenRouter's does.
    @Test func theFiveSourcesDrawWhatTheyDrewBeforeTheKinds() throws {
        let pinned = try JSONDecoder().decode([String: [String: String]].self, from: try moneyFixture("presentation-before-kinds"))
        var drawn: [String: [String: String]] = [:]
        func add(_ name: String, _ source: MoneySource, _ record: MoneySourceRecord?, _ settings: MoneySourceSettings = MoneySourceSettings(),
                 amber: Int = 72, red: Int = 24) {
            drawn[name] = describe(MoneyPresentation.make(source: source, record: record, settings: settings, now: now, amber: amber, red: red))
        }
        func good(_ source: MoneySource, _ figures: MoneyReading.Figures, ago: TimeInterval = 120, error: MoneyReadError? = nil,
                  errorAgo: TimeInterval = 60) -> MoneySourceRecord {
            MoneySourceRecord(lastGood: MoneyReading(source: source, readAt: now - ago, figures: figures), lastError: error,
                              lastErrorAt: error == nil ? nil : now - errorAgo)
        }
        let routers: [(String, OpenRouterFigures)] = [
            ("credits", OpenRouterFigures(usageDaily: 38.2, usageMonthly: 512.75, usageTotal: 880, totalCredits: 5_000, totalUsage: 880)),
            ("limit", OpenRouterFigures(usageDaily: 3.1, usageMonthly: 20, usageTotal: 25.5, limit: 100, limitRemaining: 74.5)),
            ("usageOnly", OpenRouterFigures(usageTotal: 25.5)),
            ("nothing", OpenRouterFigures()),
            ("monthOnly", OpenRouterFigures(usageDaily: 1.25, usageMonthly: 12)),
            ("negative", OpenRouterFigures(usageDaily: 0, totalCredits: 10, totalUsage: 22.5)),
        ]
        for (name, figures) in routers {
            for topUp in [nil, 5_000.0, 100.0] {
                add("openRouter.\(name).topUp\(topUp.map { "\(Int($0))" } ?? "nil")", .openRouter, good(.openRouter, .balance(figures.kind)),
                    MoneySourceSettings(topUp: topUp))
            }
            add("openRouter.\(name).stale", .openRouter, good(.openRouter, .balance(figures.kind), ago: 1_500, error: .offline))
            add("openRouter.\(name).staleNoError", .openRouter, good(.openRouter, .balance(figures.kind), ago: 1_500))
            add("openRouter.\(name).failingFresh", .openRouter, good(.openRouter, .balance(figures.kind), ago: 300, error: .http(502)))
        }
        let costs: [(String, CostFigures)] = [
            ("month", CostFigures(daily: ["2026-09-23": 150.25, "2026-09-24": 61.75, "2026-08-31": 999], coveredFrom: sep1)),
            ("sep7", CostFigures(daily: ["2026-09-06": 999, "2026-09-07": 300, "2026-09-20": 685, "2026-09-24": 61], coveredFrom: sep7)),
            ("empty", CostFigures(daily: [:], coveredFrom: sep1)),
            ("big", CostFigures(daily: ["2026-09-10": 12_345.6, "2026-09-24": 0.004], coveredFrom: sep1)),
        ]
        let costSettings: [(String, MoneySourceSettings)] = [
            ("none", MoneySourceSettings()),
            ("credit1400sep7", MoneySourceSettings(credit: 1_400, creditDate: sep7)),
            ("credit500sep1", MoneySourceSettings(credit: 500, creditDate: sep1)),
            ("creditNoDate", MoneySourceSettings(credit: 800)),
            ("creditFuture", MoneySourceSettings(credit: 50, creditDate: now + 86_400 * 3)),
        ]
        for source in [MoneySource.anthropic, .openAI] {
            for (name, figures) in costs {
                for (settingsName, settings) in costSettings {
                    add("\(source.rawValue).\(name).\(settingsName)", source, good(source, .spend(figures)), settings)
                }
                add("\(source.rawValue).\(name).stale", source, good(source, .spend(figures), ago: 1_500, error: .timeout))
            }
        }
        for balance in [2_310.0, 110, 33, 50, 0.5, -4, 1e13] {
            for burn in [1.84, 0, nil] as [Double?] {
                for topUp in [nil, 250.0] {
                    let pod = RunPodFigures(balance: balance, burnPerHour: burn, spendLimit: 80, pods: [.init(name: "a", costPerHour: 1, running: true)])
                    add("runPod.\(balance).burn\(burn.map { "\($0)" } ?? "nil").topUp\(topUp.map { "\(Int($0))" } ?? "nil")", .runPod,
                        good(.runPod, .balance(pod.kind)), MoneySourceSettings(topUp: topUp))
                }
            }
            add("runPod.\(balance).stale", .runPod, good(.runPod, .balance(RunPodFigures(balance: balance, burnPerHour: 1).kind), ago: 3_600))
            add("runPod.\(balance).amber48red12", .runPod, good(.runPod, .balance(RunPodFigures(balance: balance, burnPerHour: 1.84).kind)),
                amber: 48, red: 12)
        }
        let clouds: [(String, HetznerFigures)] = [
            ("three", HetznerFigures(items: [.init(kind: .server, name: "a", monthly: 100), .init(kind: .server, name: "b", monthly: 40),
                                             .init(kind: .backup, name: "a", monthly: 20), .init(kind: .floatingIP, name: "f", monthly: 3),
                                             .init(kind: .server, name: "c", monthly: 10)])),
            ("one", HetznerFigures(items: [.init(kind: .server, name: "a", monthly: 3.79), .init(kind: .volume, name: "v", monthly: 4.4)])),
            ("none", HetznerFigures(items: [])),
            ("ipsOnly", HetznerFigures(items: [.init(kind: .primaryIP, name: "ip", monthly: 0.5)])),
        ]
        for (name, cloud) in clouds {
            add("hetzner.\(name)", .hetzner, good(.hetzner, .spend(cloud.spend(from: sep1))))
            add("hetzner.\(name).stale", .hetzner, good(.hetzner, .spend(cloud.spend(from: sep1)), ago: 900, error: .rateLimited(retryAfter: 30)))
        }
        for source in MoneySource.allCases.prefix(5) {
            add("\(source.rawValue).nil", source, nil)
            add("\(source.rawValue).empty", source, MoneySourceRecord())
            add("\(source.rawValue).notConfigured", source, MoneySourceRecord(lastError: .notConfigured, lastErrorAt: now))
            for error in [MoneyReadError.keyNotUsable, .notAvailableWithThisKey, .keyFileRefused("a CLI credential file"),
                          .keyFileUnreadable("missing"), .refusedByPolicy("x"), .rateLimited(retryAfter: 60), .http(500), .timeout,
                          .offline, .unreadableResponse("x")] {
                add("\(source.rawValue).error.\(error.logName)", source, MoneySourceRecord(lastError: error, lastErrorAt: now - 30))
            }
            add("\(source.rawValue).attemptOnly", source, MoneySourceRecord(lastAttemptAt: now - 10))
        }

        #expect(Set(drawn.keys) == Set(pinned.keys))
        #expect(pinned.count == 218)
        let measured = { (name: String) in name.hasPrefix("runPod.") && name.hasSuffix(".burnnil.topUp250") }
        for (name, before) in pinned.sorted(by: { $0.key < $1.key }) {
            var now = drawn[name] ?? [:]
            if measured(name), before["readable"] == "true" {
                #expect(now["denominator"] == "of $250 top-up", "\(name)")
                now["denominator"] = before["denominator"]
            }
            // P363: a refused key's word says what to do for OpenAI and Hetzner; nothing else they draw changed.
            let told = ["OpenAI.error.notAvailableWithThisKey": "Needs an Admin key (sk-admin-…)",
                        "Hetzner.error.notAvailableWithThisKey": "Token rejected · make a Read token"]
            if let word = told[name] {
                #expect(now["status"] == word, "\(name)")
                now["status"] = before["status"]
            }
            #expect(now == before, "\(name)")
        }
    }

    /// money.json as the builds before the kinds wrote it: every reading reads as its kind and draws the same, and the
    /// 429 pause beside them holds.
    @Test func aMoneyFileFromBeforeTheKindsStillReads() throws {
        let home = try MoneyTempDir()
        let url = home.url.appendingPathComponent("money.json")
        try moneyFixture("money-before-kinds").write(to: url)
        let records = MoneyStore(url: url).load()
        #expect(Set(records.keys) == Set(MoneyAccount.firsts.prefix(5)))
        let router = try #require(records[.openRouter]?.lastGood)
        #expect(router.figures == .balance(BalanceFigures(currency: .usd, amount: 4_120, spentToday: 38.2, spentThisMonth: 512.75,
                                                          spentTotal: 880)))
        #expect(records[.runPod]?.lastGood?.figures == .balance(BalanceFigures(currency: .usd, amount: 2_310.42, burnPerHour: 1.84)))
        guard case .spend(let costs) = records[.anthropic]?.lastGood?.figures else { Issue.record("not spend"); return }
        #expect(costs.currency == .usd && costs.daily == ["2026-09-07": 300, "2026-09-24": 61] && costs.coveredFrom == sep7)
        guard case .spend(let cloud) = records[.hetzner]?.lastGood?.figures else { Issue.record("not spend"); return }
        #expect(cloud.currency == .eur && cloud.estimate?.map(\.kind) == ["server", "backup"] && cloud.serverCount == 1)
        #expect(records[.hetzner]?.pausedUntil == now + 960 && records[.hetzner]?.lastError == .rateLimited(retryAfter: 60))
        // Drawn as before.
        let settings = MoneySourceSettings(credit: 1_400, creditDate: sep7)
        let anthropic = MoneyPresentation.make(source: .anthropic, record: records[.anthropic], settings: settings, now: now, amber: 72, red: 24)
        #expect(anthropic?.row.amount == "$1,039" && anthropic?.row.hoverLabel == "Anthropic · $1,039 left of $1,400 since 7 Sep · $61.00 today · read 2m ago")
        let runPod = MoneyPresentation.make(source: .runPod, record: records[.runPod], settings: MoneySourceSettings(), now: now, amber: 72, red: 24)
        #expect(runPod?.row.amount == "$2,310" && runPod?.row.suffix == "52d" && runPod?.row.suffixIsRunway == true)
        // Saved again, it is written in the kinds' shape and reads back the same.
        MoneyStore(url: url).save(records)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"balance\"") && text.contains("\"spend\"") && !text.contains("\"_0\""))
        #expect(MoneyStore(url: url).load() == records)
        #expect(MoneyStore.isReadable(try Data(contentsOf: url)))
    }

    @Test func everyKindSurvivesASave() throws {
        let home = try MoneyTempDir()
        let url = home.url.appendingPathComponent("money.json")
        let records: [MoneyAccount: MoneySourceRecord] = [
            .deepSeek: MoneySourceRecord(lastGood: MoneyReading(source: .deepSeek, readAt: now,
                                                                figures: .balance(BalanceFigures(currency: .cny, amount: 110)))),
            .fireworks: MoneySourceRecord(lastGood: MoneyReading(source: .fireworks, readAt: now, figures: .spend(
                SpendFigures(currency: .usd, daily: [:], coveredFrom: sep1, monthToDate: 35.925)))),
            .elevenLabs: MoneySourceRecord(lastGood: MoneyReading(source: .elevenLabs, readAt: now, figures: .quota(
                QuotaFigures(used: 2_600, limit: 10_000, unit: "characters", resetsAt: now + 86_400)))),
            MoneyAccount(.openRouter, slot: 2): MoneySourceRecord(lastError: .idMissing("Team ID"), lastErrorAt: now, consecutiveFailures: 1),
        ]
        MoneyStore(url: url).save(records)
        #expect(MoneyStore(url: url).load() == records)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"OpenRouter 2\"") && text.contains("\"cny\""))
    }

    @Test func currenciesDrawTheirOwnSymbol() {
        #expect(MoneyRules.amount(110, .cny) == "¥110")
        #expect(MoneyRules.amount(12.5, .cny) == "¥12.50")
        #expect(MoneyRules.amount(1_234.56, .cny) == "¥1,235")
        #expect(MoneyRules.amount(-3, .cny) == "\u{2212}¥3.00")
        #expect(MoneyRules.rate(0.5, .cny) == "¥0.50/h")
        #expect(MoneyCurrency(code: "CNY") == .cny && MoneyCurrency(code: "usd") == .usd && MoneyCurrency(code: " EUR ") == .eur)
        #expect(MoneyCurrency(code: "JPY") == nil && MoneyCurrency(code: "") == nil)
        // A DeepSeek balance in yuan reads in yuan everywhere it is drawn.
        let record = MoneySourceRecord(lastGood: MoneyReading(source: .deepSeek, readAt: now - 120,
                                                              figures: .balance(BalanceFigures(currency: .cny, amount: 110))))
        let presentation = MoneyPresentation.make(account: .deepSeek, record: record, settings: MoneySourceSettings(), now: now, amber: 72, red: 24)
        #expect(presentation?.row.amount == "¥110" && presentation?.row.hoverLabel == "DeepSeek · ¥110 balance · read 2m ago")
        var stale = record
        stale.lastGood?.readAt = now - 1_500
        let old = MoneyPresentation.make(account: .deepSeek, record: stale, settings: MoneySourceSettings(), now: now, amber: 72, red: 24)
        #expect(old?.row.hoverLabel == "DeepSeek · stale · last ¥110 balance · read 25m ago")
    }

    @Test func aQuotaReadsAsTheShareLeft() {
        let quota = QuotaFigures(used: 2_600, limit: 10_000, unit: "characters", resetsAt: Date(timeIntervalSince1970: 1_790_899_200))
        let record = MoneySourceRecord(lastGood: MoneyReading(source: .elevenLabs, readAt: now - 120, figures: .quota(quota)))
        let presentation = MoneyPresentation.make(account: .elevenLabs, record: record, settings: MoneySourceSettings(), now: now,
                                                  amber: 72, red: 24)
        #expect(presentation?.row.amount == "74%" && presentation?.row.isSpent == false && presentation?.row.suffix == nil)
        #expect(presentation?.row.hoverLabel == "ElevenLabs · 74% left · 2,600 of 10,000 characters used · resets 2 Oct · read 2m ago")
        #expect(presentation?.shortParts == ["74% left"] && presentation?.creditLeftShare == 0.74)
        #expect(presentation?.row.emphasis == .normal)
        // Toned as a battery is: amber under 15 % left, whatever is left of it rounded down as drawn.
        func tone(_ used: Double) -> MoneyRowModel.Emphasis? {
            let low = MoneySourceRecord(lastGood: MoneyReading(source: .elevenLabs, readAt: now - 120,
                                                               figures: .quota(QuotaFigures(used: used, limit: 10_000, unit: "characters"))))
            return MoneyPresentation.make(account: .elevenLabs, record: low, settings: MoneySourceSettings(), now: now, amber: 72, red: 24)?
                .row.emphasis
        }
        #expect(tone(8_500) == .normal && tone(8_501) == .warn && tone(9_700) == .warn && tone(10_000) == .warn)
        #expect(MoneyRules.percent(0.004) == "1%" && MoneyRules.percent(0) == "0%" && MoneyRules.percent(1) == "100%")
        #expect(QuotaFigures(used: 5, limit: 0, unit: "characters").leftShare == 0)
    }

    @Test func aMonthToDateTotalIsThisMonthsOnly() {
        let total = SpendFigures(currency: .usd, daily: [:], coveredFrom: sep1, monthToDate: 11.21)
        let record = MoneySourceRecord(lastGood: MoneyReading(source: .digitalOcean, readAt: now - 120, figures: .spend(total)))
        let presentation = MoneyPresentation.make(account: .digitalOcean, record: record, settings: MoneySourceSettings(), now: now,
                                                  amber: 72, red: 24)
        #expect(presentation?.row.amount == "$11.21" && presentation?.row.isSpent == true)
        #expect(presentation?.row.hoverLabel == "DigitalOcean · $11.21 spent in September · read 2m ago")
        // Read on the last day of August, drawn on the first of September: rails until the next read, no August total.
        let august = SpendFigures(currency: .usd, daily: [:], coveredFrom: Date(timeIntervalSince1970: 1_785_542_400), monthToDate: 99)
        let turned = MoneySourceRecord(lastGood: MoneyReading(source: .digitalOcean, readAt: sep1 - 60, figures: .spend(august)))
        let early = MoneyPresentation.make(account: .digitalOcean, record: turned, settings: MoneySourceSettings(), now: sep1 + 120,
                                           amber: 72, red: 24)
        #expect(early?.row.amount == nil && early?.status == "Reading…")
    }

    @Test func aLabelNamesTheRowAndAFurtherKeyHasItsOwnID() {
        let record = MoneySourceRecord(lastGood: MoneyReading(source: .openRouter, readAt: now - 120,
                                                              figures: .balance(BalanceFigures(currency: .usd, amount: 12))))
        let second = MoneyAccount(.openRouter, slot: 2)
        let plain = MoneyPresentation.make(account: second, record: record, settings: MoneySourceSettings(), now: now, amber: 72, red: 24)
        #expect(plain?.row.id == "OpenRouter 2" && plain?.row.name == "OpenRouter 2")
        let named = MoneyPresentation.make(account: second, record: record, settings: MoneySourceSettings(label: "OR lab"), now: now,
                                           amber: 72, red: 24)
        #expect(named?.row.id == "OpenRouter 2" && named?.row.name == "OR lab" && named?.row.hoverLabel == "OR lab · $12.00 balance · read 2m ago")
        #expect(MoneyAccount(rawValue: "OpenRouter 2") == second && MoneyAccount(rawValue: "OpenRouter") == .openRouter)
        #expect(MoneyAccount(rawValue: "Vast.ai 4") == MoneyAccount(.vastAI, slot: 4))
        for bad in ["OpenRouter 1", "OpenRouter 5", "OpenRouter 02", "OpenRouter  2", "Nope 2", "OpenRouter2", ""] {
            #expect(MoneyAccount(rawValue: bad) == nil, "\(bad)")
        }
        #expect(MoneyAccount.allCases.count == MoneySource.allCases.count * MoneyAccount.maximumSlots)
        #expect(MoneyAccount.allCases.sorted() == MoneyAccount.allCases)
    }
}
