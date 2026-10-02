import Foundation
import IslandEngine
import JuiceCore
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// The shared base every stream builds on. Streams add tests in their own files.
@MainActor
struct SharedModelTests {
    @Test
    func settingsDefaultsMatchTheSpec() {
        let s = AppSettings.ephemeral()
        #expect(s.showAs == .window && s.launchAtLogin && !s.dockIconInIslandMode && !s.menuBarItem)
        #expect(s.windowHeader == .strip && s.windowShowsMoney && !s.accountNamesUnderBatteries)
        #expect(!s.keepOpenUntilDecision && !s.replyFromCompletionCard && s.suppressForFocusedSessions && s.showCodexAppThreads)
        #expect(s.modeChoicesOnCards)
        #expect(s.islandStyle == .clean && s.islandShowsUsage && s.islandUsagePlacement == .headerStrip && s.islandShowsMoney)
        #expect(s.hoverDetails && s.glyphColour == .byState && s.closedPillCount == .active)
        #expect(s.whenSessionFinishes == .card && !s.hidePillWhenIdle && s.islandDisplay == nil && !s.hapticOnHover && !s.showScriptedRuns)
        #expect(!s.soundsMuted && s.needsYouSound == AppSettings.defaultNeedsYouSound && s.doneSound == .none)
        #expect(!s.globalJumpEnabled && s.globalJumpKey == nil)
        #expect(s.panelShowOnDesktop && s.panelLocked && s.panelDisplay == nil)
        #expect(MoneyAccount.allCases.allSatisfy { s.moneyShown[$0] == true })
        #expect(s.runwayAmberHours == 72 && s.runwayRedHours == 24)
    }

    @Test
    func settingsPersistThroughTheirDefaults() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: defaults)
        s.showAs = .island
        s.glyphColour = .byAgent
        s.doneSound = .system("Tink")
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.showAs == .island && reloaded.glyphColour == .byAgent && reloaded.doneSound == .system("Tink"))
    }

    @Test
    func demoUsageHasSixClaudeAndFiveCodexBatteriesAndFiveMoneyRows() {
        let usage = DemoUsageModel()
        #expect(usage.claudeRow?.batteries.count == 6)
        #expect(usage.codexRow?.batteries.count == 5)
        #expect(usage.panel.money.map(\.id) == ["OpenRouter", "Anthropic", "OpenAI", "RunPod", "Hetzner"])
        #expect(usage.claudeRow?.nextAlias == "Main" && usage.codexRow?.nextAlias == "Home")
        let states = usage.allBatteries.map(\.state)
        #expect(states.contains(.signInNeeded) && states.contains(.unknown))
        #expect(states.contains { if case .usedUp = $0 { true } else { false } })
        #expect(states.contains { if case .stale = $0 { true } else { false } })
        #expect(states.contains(.available(percentLeft: 12, isLow: true)))
        usage.setMonitored(usage.accounts[1].id, false)
        #expect(usage.claudeRow?.batteries.count == 5)
    }

    @Test
    func urgentMoneyAndRunwayTones() {
        let red = DemoUsageModel(variant: .runway18h)
        #expect(red.panel.money.first { $0.id == "RunPod" }?.emphasis == .attention)
        #expect(MoneyDetail.urgent(red.panel.money, details: red.moneyDetails, amber: 72, red: 24)?.id == "RunPod")
        let noKey = DemoUsageModel(variant: .hetznerNoKey)
        #expect(MoneyDetail.urgent(noKey.panel.money, details: noKey.moneyDetails, amber: 72, red: 24)?.id == "Hetzner")
        let standard = DemoUsageModel()
        #expect(MoneyDetail.urgent(standard.panel.money, details: standard.moneyDetails, amber: 72, red: 24)?.id == "RunPod")
    }

    @Test
    func hoverLabels() {
        let usage = DemoUsageModel()
        let research = usage.accounts[2].id
        #expect(HoverLabelText.short(.account(research), usage: usage)?.parts == ["back in 22m"])
        #expect(HoverLabelText.short(.provider(.claude), usage: usage)?.parts == ["3 of 6 ready", "next Main"])
        #expect(HoverLabelText.short(.money("RunPod"), usage: usage)?.parts == ["$1.84/h", "52 days"])
        #expect(HoverLabelText.full(.money("OpenRouter"), usage: usage)?.text == "OpenRouter · $4,120 balance · $38.20 today")
        let long = HoverLabel(name: "Anthropic", parts: ["$354 left of $1,400 since 7 Sep", "$61 today"])
        #expect(HoverLabelText.fit(long, width: 120).parts == ["$354 left of $1,400 since 7 Sep"])
    }

    @Test
    func fixtureSessionsCoverEveryState() throws {
        let feed = FixtureSessionFeed(scenario: .allStates)
        let model = feed.makeModel()
        #expect(model.needsYou.map(\.id).sorted() == [FixtureSessionFeed.ID.approval, FixtureSessionFeed.ID.plan, FixtureSessionFeed.ID.question].sorted())
        #expect(Set(model.running.map(\.id)) == [FixtureSessionFeed.ID.running, FixtureSessionFeed.ID.codexRunning, FixtureSessionFeed.ID.thinking])
        #expect(Set(model.done.map(\.id)) == [FixtureSessionFeed.ID.codexDone, FixtureSessionFeed.ID.codexIdle,
                                              FixtureSessionFeed.ID.claudeDone, FixtureSessionFeed.ID.interrupted])
        #expect(model.row(id: FixtureSessionFeed.ID.interrupted)?.status == .interrupted)
        #expect(model.row(id: FixtureSessionFeed.ID.thinking)?.status == .thinking)
        #expect(model.row(id: FixtureSessionFeed.ID.running)?.status == .tool(name: "Edit", detail: "Juice/Sources/JuiceUI/Island/JuiceIslandSectionView.swift"))
        #expect(model.row(id: FixtureSessionFeed.ID.codexDone)?.agent == .codex)

        guard case let .question(question) = model.card(for: FixtureSessionFeed.ID.question) else { Issue.record("no question card"); return }
        #expect(question.options.count == 4 && question.topic == "App name")
        guard case let .approval(approval) = model.card(for: FixtureSessionFeed.ID.approval) else { Issue.record("no approval card"); return }
        #expect(approval.body == .command("git push -u origin window-mode"))
        #expect(approval.reason == "Push window-mode to origin and track it · branch window-mode")
        let label = try #require(approval.alwaysAllowLabel)
        #expect(label.contains("git push"))
        guard case let .plan(plan) = model.card(for: FixtureSessionFeed.ID.plan) else { Issue.record("no plan card"); return }
        #expect(plan.steps == 4)
        guard case let .done(done) = model.card(for: FixtureSessionFeed.ID.claudeDone) else { Issue.record("no done card"); return }
        #expect(done.message.hasPrefix("Wrote docs/release-checklist.md"))
    }

    @Test
    func cardsSendThroughTheRecorderOnly() async {
        let feed = FixtureSessionFeed(scenario: .prototype)
        let model = feed.makeModel()
        model.approve(FixtureSessionFeed.ID.approval, .alwaysAllow)
        model.answerQuestion(FixtureSessionFeed.ID.question, .option(0))
        model.jump(FixtureSessionFeed.ID.running)
        // Sent first, resolved once sent (P129): the cards go after the commands went.
        for _ in 0..<50 where feed.sentCommands.count < 2 || model.needsYouCount > 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(feed.sentCommands.count == 2)
        #expect(model.requestedJumps == [FixtureSessionFeed.ID.running])
        #expect(model.card(for: FixtureSessionFeed.ID.approval) == nil)
        #expect(model.needsYouCount == 0)
    }

    @Test
    func pillSummary() {
        let model = FixtureSessionFeed(scenario: .allStates).makeModel()
        let active = PillSummary.make(rows: model.rows, countMode: .active, now: model.now)
        // Ten rows; the Codex done (60m), the Codex idle (18m) and the interrupted turn (44m) are past the window.
        #expect(model.totalCount == 10 && active.count == 7)
        #expect(PillSummary.make(rows: model.rows, countMode: .needsYou, now: model.now).count == 3)
        #expect(PillSummary.make(rows: [], countMode: .needsYou, now: model.now).count == nil)
        #expect(PillSummary.make(rows: [], countMode: .active, now: model.now).count == nil)
    }

    @Test
    func activationPolicy() {
        #expect(ActivationPolicyRule.policy(showAs: .window, dockIconInIslandMode: false, auxiliaryWindowOpen: false) == .regular)
        #expect(ActivationPolicyRule.policy(showAs: .island, dockIconInIslandMode: false, auxiliaryWindowOpen: false) == .accessory)
        #expect(ActivationPolicyRule.policy(showAs: .island, dockIconInIslandMode: true, auxiliaryWindowOpen: false) == .regular)
        #expect(ActivationPolicyRule.policy(showAs: .island, dockIconInIslandMode: false, auxiliaryWindowOpen: true) == .regular)
    }
}
