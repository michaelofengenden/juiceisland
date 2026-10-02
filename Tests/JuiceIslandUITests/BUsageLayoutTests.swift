import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Stream B: the usage header's layout maths, the Clean money fit, the hover dwell and the money and account-list text.
@MainActor
struct BUsageLayoutTests {
    // MARK: Header money and grid

    @Test func theHeaderLeavesOutMoneyWithNoFigure() {
        let rows = MoneyRowModel.sourceNames.map { MoneyRowModel(id: $0, name: $0, amount: nil, hoverLabel: $0) }
        #expect(UsageLayout.headerMoney(rows).isEmpty)
        let noKey = DemoUsageModel(variant: .hetznerNoKey).panel.money
        #expect(UsageLayout.headerMoney(noKey).map(\.id) == ["OpenRouter", "Anthropic", "OpenAI", "RunPod"])
        #expect(UsageLayout.headerMoney(DemoUsageModel().panel.money).count == 5)
    }

    @Test func theMoneyGridHasOnlyTheCellsItNeeds() {
        #expect(UsageMoneyGrid.shape(count: 0) == (0, 0))
        #expect(UsageMoneyGrid.shape(count: 1) == (1, 1))
        #expect(UsageMoneyGrid.shape(count: 3) == (3, 1))
        #expect(UsageMoneyGrid.shape(count: 4) == (3, 2))
        #expect(UsageMoneyGrid.shape(count: 6) == (3, 2))
        // Past six (a second key, a new source), both columns grow a row for each two: none is left out.
        #expect(UsageMoneyGrid.shape(count: 7) == (4, 2))
        #expect(UsageMoneyGrid.shape(count: 11) == (6, 2))
        #expect([0, 1, 5, 6].allSatisfy { MoneyGrid.rows(count: $0) == 3 } && MoneyGrid.rows(count: 7) == 4 && MoneyGrid.rows(count: 11) == 6)
    }

    /// The panel's and the Detailed island's money columns fill their width exactly, as the prototype's
    /// `auto 1fr 24 auto 1fr`: names whole and the amounts sharing the rest while they fit; past that an amount keeps
    /// its width (never cut, never past the edge) and the names share what is left, a short column keeping its name
    /// whole.
    @Test func theMoneyColumnsFillTheirWidthAndNeverCutAnAmount() {
        func total(_ c: (names: (CGFloat, CGFloat), amounts: (CGFloat, CGFloat))) -> CGFloat {
            c.names.0 + c.names.1 + c.amounts.0 + c.amounts.1 + Theme.Panel.moneyGutter + 4 * MoneyGrid.gap
        }
        let fits = MoneyGrid.columns(names: (70, 50), amounts: (40, 60), width: 330)
        #expect(fits.names == (70, 50) && fits.amounts == (73, 73) && total(fits) == 330)
        let wide = MoneyGrid.columns(names: (70, 50), amounts: (40, 100), width: 330)
        #expect(wide.names == (70, 50) && wide.amounts == (46, 100) && total(wide) == 330)
        let tight = MoneyGrid.columns(names: (90, 85), amounts: (50, 80), width: 330)
        #expect(tight.names == (68, 68) && tight.amounts == (50, 80) && total(tight) == 330)
        let short = MoneyGrid.columns(names: (90, 30), amounts: (60, 130), width: 330)
        #expect(short.names == (46, 30) && short.amounts == (60, 130) && total(short) == 330)
        // Two keys of one source keep apart where their names are cut: a further key's own name keeps its number, and a
        // label gives way in its middle.
        func parts(_ id: String, _ name: String) -> MoneyNameText.Parts {
            MoneyNameText.parts(MoneyRowModel(id: id, name: name, amount: "$1", hoverLabel: name))
        }
        #expect(parts("OpenRouter 2", "OpenRouter 2") == .slot("OpenRouter", " 2"))
        #expect(parts("OpenRouter", "OpenRouter") == .whole("OpenRouter", .tail))
        #expect(parts("OpenRouter 3", "Client work for Acme Co") == .whole("Client work for Acme Co", .middle))
    }

    /// Every key of a source sits and leaves the Clean rows where its first does: `OpenRouter 2` beside Claude, and a new
    /// source's amount leaves before Hetzner's.
    @Test func aSourcesFurtherKeysFollowItsFirstInClean() {
        let placed = UsageLayout.cleanRows(["OpenRouter", "OpenRouter 2", "Anthropic", "RunPod", "DeepSeek", "Vast.ai"])
        #expect(placed.claude == ["OpenRouter", "OpenRouter 2", "Anthropic"] && placed.codex == ["RunPod", "DeepSeek", "Vast.ai"])
        let widths = Dictionary(uniqueKeysWithValues: ["OpenRouter", "OpenRouter 2", "Hetzner", "DeepSeek"].map { ($0, CGFloat(100)) })
        #expect(UsageLayout.fitCleanRow(["OpenRouter", "OpenRouter 2", "Hetzner", "DeepSeek"], widths: widths, in: 214)
            == ["OpenRouter", "OpenRouter 2"])
        #expect(UsageLayout.fitCleanRow(["OpenRouter", "OpenRouter 2", "Hetzner", "DeepSeek"], widths: widths, in: 328)
            == ["OpenRouter", "OpenRouter 2", "Hetzner"])
    }

    @Test func aGroupOfSixIs330() {
        #expect(UsageLayout.groupWidth(batteries: 6) == 330)
        #expect(UsageLayout.groupWidth(batteries: 1) == 75)
    }

    // MARK: Clean money

    @Test func cleanRoomIs280BesideSixAnd331BesideFive() {
        #expect(UsageLayout.cleanMoneyRoom(blockWidth: 636, batteries: 6) == 280)
        #expect(UsageLayout.cleanMoneyRoom(blockWidth: 636, batteries: 5) == 331)
    }

    @Test func cleanRowsSplitOpenRouterAndAnthropicFromTheRest() {
        let rows = UsageLayout.cleanRows(["OpenRouter", "Anthropic", "OpenAI", "RunPod", "Hetzner"])
        #expect(rows.claude == ["OpenRouter", "Anthropic"])
        #expect(rows.codex == ["OpenAI", "RunPod", "Hetzner"])
        #expect(UsageLayout.cleanRows(["OpenAI", "RunPod"]).claude.isEmpty)
    }

    @Test func cleanFitDropsHetznerThenOpenAIThenRunPod() {
        let ids = ["OpenAI", "RunPod", "Hetzner"]
        let widths: [String: CGFloat] = ["OpenAI": 70, "RunPod": 110, "Hetzner": 70]
        #expect(UsageLayout.fitCleanRow(ids, widths: widths, in: 400) == ids)
        #expect(UsageLayout.fitCleanRow(ids, widths: widths, in: 200) == ["OpenAI", "RunPod"])
        #expect(UsageLayout.fitCleanRow(ids, widths: widths, in: 150) == ["RunPod"])
        #expect(UsageLayout.fitCleanRow(ids, widths: widths, in: 50).isEmpty)
    }

    @Test func cleanFitKeepsRunPodWhileItsRunwayIsToned() {
        let ids = ["OpenAI", "RunPod", "Hetzner"]
        let widths: [String: CGFloat] = ["OpenAI": 70, "RunPod": 110, "Hetzner": 70]
        #expect(UsageLayout.fitCleanRow(ids, widths: widths, in: 120, keep: ["RunPod"]) == ["RunPod"])
        #expect(UsageLayout.fitCleanRow(ids, widths: widths, in: 200, keep: ["RunPod"]) == ["OpenAI", "RunPod"])
    }

    @Test func cleanFitNeverClipsAnAmount() {
        let widths: [String: CGFloat] = ["OpenRouter": 120, "Anthropic": 90]
        for room in stride(from: CGFloat(0), through: 260, by: 7) {
            let shown = UsageLayout.fitCleanRow(["OpenRouter", "Anthropic"], widths: widths, in: room)
            let used = shown.map { widths[$0]! }.reduce(0, +) + CGFloat(max(0, shown.count - 1)) * 14
            #expect(used <= room)
        }
    }

    // MARK: Money text

    @Test func cleanMoneyDropsSpentAndMonthButKeepsRunway() {
        let usage = DemoUsageModel()
        let row = { (id: String) in usage.panel.money.first { $0.id == id }! }
        #expect(MoneyFigureText.suffix(row("OpenAI"), style: .full, detail: usage.moneyDetails["OpenAI"]) == "spent")
        #expect(MoneyFigureText.suffix(row("OpenAI"), style: .clean, detail: usage.moneyDetails["OpenAI"]) == nil)
        #expect(MoneyFigureText.suffix(row("Hetzner"), style: .full, detail: usage.moneyDetails["Hetzner"]) == "/mo")
        #expect(MoneyFigureText.suffix(row("Hetzner"), style: .clean, detail: usage.moneyDetails["Hetzner"]) == nil)
        #expect(MoneyFigureText.suffix(row("RunPod"), style: .clean, detail: usage.moneyDetails["RunPod"]) == "52d")
        let red = DemoUsageModel(variant: .runway18h)
        #expect(red.panel.money.first { $0.id == "RunPod" }?.suffix == "18h")
    }

    @Test func gridAmountColumnsShareTheWidestAmount() {
        let usage = DemoUsageModel()
        let width = UsageMoneyGrid.amountColumnWidth(usage.panel.money, details: usage.moneyDetails)
        for row in usage.panel.money {
            #expect(MoneyFigureText.width(row, style: .full, detail: usage.moneyDetails[row.id]) <= width)
        }
        #expect(width > 50 && width < 90)
    }

    /// Past six accounts the grid grows, and its amount columns still take the widest amount of every row, the ninth's
    /// `$11.21 spent` included.
    @Test func gridAmountColumnsShareTheWidestAmountPastSix() {
        let rows = (1...8).map { MoneyRowModel(id: "S\($0)", name: "S\($0)", amount: "$1", hoverLabel: "") }
            + [MoneyRowModel(id: "Wide", name: "Wide", amount: "$11.21", isSpent: true, hoverLabel: "")]
        let widest = MoneyFigureText.width(rows[8], style: .full, detail: nil)
        #expect(UsageMoneyGrid.amountColumnWidth(rows, details: [:]) == widest && widest > MoneyFigureText.width(rows[0], style: .full, detail: nil))
    }

    // MARK: Account list text

    @Test func accountListWords() throws {
        let usage = DemoUsageModel()
        let claude = try #require(usage.claudeRow)
        #expect(AccountListText.summary(claude) == "3 of 6 available · next Main")
        let byAlias = { (alias: String) in usage.allBatteries.first { $0.alias == alias }! }
        #expect(AccountListText.detail(byAlias("Research"), usage: usage).text == "0% left, 5h · back in 22m")
        #expect(AccountListText.detail(byAlias("Studio"), usage: usage) == ("sign-in needed", .red))
        #expect(AccountListText.detail(byAlias("Alt"), usage: usage) == ("no reading yet", .secondary))
        #expect(AccountListText.detail(byAlias("Spare"), usage: usage) == ("last 60% left, 5h · stale", .amber))
        // A No plan login: its dimmed battery says "No plan", so the detail says only what may be behind it.
        var ended = byAlias("Spare")
        ended.state = .noPlan
        #expect(AccountListText.detail(ended, usage: usage) == ("subscription ended?", .secondary))
        #expect(!AccountListText.detail(byAlias("Lab"), usage: usage).text.contains("read "))
        #expect(AccountListText.readAge(byAlias("Research").id, usage: usage) == "read 2m ago")
        #expect(AccountListText.readAge(byAlias("Alt").id, usage: usage) == "read never")
        #expect(AccountListText.plan(byAlias("Main").id, usage: usage) == "Max 20×")
        // Any other source shows the reading's own plan, even for an account that shares a demo alias.
        let main = try #require(DemoUsageData.accounts.first { $0.alias == "Main" })
        #expect(AccountListText.plan(main.id, usage: PanelFixtureUsage(accounts: [main])) == "Max")
    }

    @Test func fullHoverLabelsFeedTheCaption() throws {
        let usage = DemoUsageModel()
        let research = try #require(usage.allBatteries.first { $0.alias == "Research" })
        let label = try #require(HoverLabelText.full(.account(research.id), usage: usage))
        #expect(label.name == "Research" && label.parts == ["0% left, 5h", "back in 22m", "read 2m ago"])
        #expect(HoverLabelText.full(.money("RunPod"), usage: usage)?.parts == ["$2,310 balance", "$1.84/h", "about 52 days"])
        let fitted = HoverLabelText.fit(label, width: HoverLabelText.measure(HoverLabel(name: "Research", parts: ["0% left, 5h"])) + 1)
        #expect(fitted.parts == ["0% left, 5h"])
    }
}

/// The hover dwell (Juice HoverController timing): 350 ms to show, 100 ms to move, 100 ms grace on leaving.
struct BHoverDwellTests {
    private let a = HoverTargetID.account("a"), b = HoverTargetID.account("b"), m = HoverTargetID.money("RunPod")

    @Test func firstLabelWaitsThreeHundredFiftyMilliseconds() {
        var dwell = HoverDwell()
        let wait = dwell.point(at: a)
        let shows = dwell.settle(a)
        #expect(wait == .milliseconds(350) && shows && dwell.shown == a)
    }

    @Test func movingBetweenTargetsTakesOneHundred() {
        var dwell = HoverDwell(shown: a)
        let grace = dwell.leave(a)
        let move = dwell.point(at: b)
        let staleGrace = dwell.settle(nil)      // the grace for leaving a is stale: b took over
        let shows = dwell.settle(b)
        #expect(grace == .milliseconds(100) && move == .milliseconds(100) && !staleGrace && shows && dwell.shown == b)
    }

    @Test func leavingHidesAfterTheGrace() {
        var dwell = HoverDwell(shown: m)
        let grace = dwell.leave(m)
        let hides = dwell.settle(nil)
        #expect(grace == .milliseconds(100) && hides && dwell.shown == nil)
    }

    @Test func leavingBeforeTheDwellShowsNothing() {
        var dwell = HoverDwell()
        _ = dwell.point(at: a)
        let grace = dwell.leave(a)
        let shows = dwell.settle(a)
        #expect(grace == nil && !shows && dwell.shown == nil)
    }

    @Test func aLateExitFromTheLastTargetIsIgnored() {
        var dwell = HoverDwell(shown: a)
        _ = dwell.point(at: b)                  // enter b arrives before a's exit
        let late = dwell.leave(a)
        let shows = dwell.settle(b)
        #expect(late == nil && shows && dwell.shown == b)
    }

    @Test func comingBackDuringTheGraceKeepsTheLabel() {
        var dwell = HoverDwell(shown: a)
        _ = dwell.leave(a)
        let back = dwell.point(at: a)
        let hides = dwell.settle(nil)
        #expect(back == .zero && !hides && dwell.shown == a)
    }
}
