import Foundation
import IslandEngine
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Lane c14/keys: U steps through the island's usage (P461) and the system-wide key's Switch sessions (P462). Pure
/// routing and models only: no panel or window is ordered in, no key is registered, nothing jumps.
@MainActor
struct UsageKeyAndSwitcherTests {
    typealias ID = FixtureSessionFeed.ID

    // MARK: U (P461)

    @Test
    func uStepsThroughUsageOnlyOverTheList() {
        let u = IslandKeyPress(characters: "u")
        #expect(IslandKeyRouter.command(for: u, card: nil, listing: true) == .cycleUsage)
        // Shift or not, the key that types U on this layout (characters, never a key code, P40).
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "U", shift: true), card: nil, listing: true) == .cycleUsage)
        // A held U's repeats are eaten: the block does not run through every battery and fold.
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "u", isRepeat: true), card: nil, listing: true) == .swallow)
        // Over a card, in a field (a No's reason, a reply), with a modifier, or composing: not U's.
        #expect(IslandKeyRouter.command(for: u, card: nil, listing: false) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "u", editing: true), card: nil, listing: true) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "u", control: true), card: nil, listing: true) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "u", option: true), card: nil, listing: true) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "u", command: true), card: nil, listing: true) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "u", hasMarkedText: true), card: nil, listing: true) == nil)
        #expect(IslandKeyCommand.cycleUsage.sessionID == nil)
    }

    @Test
    func theCycleRunsThroughEveryBatteryThenNone() {
        let ids = ["c1", "c2", "x1"]
        #expect(UsageCycle.next(after: nil, in: ids) == "c1")
        #expect(UsageCycle.next(after: .account("c1"), in: ids) == "c2")
        #expect(UsageCycle.next(after: .account("c2"), in: ids) == "x1")
        #expect(UsageCycle.next(after: .account("x1"), in: ids) == nil)
        // The pointer on a mark or an amount, or a battery no longer drawn: from the first.
        #expect(UsageCycle.next(after: .provider(.claude), in: ids) == "c1")
        #expect(UsageCycle.next(after: .money("openrouter"), in: ids) == "c1")
        #expect(UsageCycle.next(after: .account("gone"), in: ids) == "c1")
        #expect(UsageCycle.next(after: nil, in: []) == nil)
    }

    @Test
    func theCycleFollowsTheBlocksOrder() {
        let env = AppEnvironment.demo()
        let order = UsageCycle.order(env.usage)
        let claude = env.usage.claudeRow?.batteries.map(\.id) ?? []
        let codex = env.usage.codexRow?.batteries.map(\.id) ?? []
        #expect(!claude.isEmpty && !codex.isEmpty)
        #expect(order == claude + codex)
    }

    @Test
    func aKeysLabelShowsAtOnceAndThePointerTakesItOver() async {
        let ui = IslandUIState()
        ui.keyHover(.account("c1"))
        #expect(ui.hover == .account("c1") && ui.hoverByKey)
        ui.keyHover(nil)
        #expect(ui.hover == nil && !ui.hoverByKey)
        ui.keyHover(.account("c2"))
        // The pointer rests on another battery: after its dwell the label is the pointer's.
        ui.report(HoverTarget(id: "x1", label: "x1"))
        for _ in 0..<100 where ui.hover != .account("x1") { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(ui.hover == .account("x1"))
        #expect(!ui.hoverByKey)
        // The pointer leaving a battery U has since moved away from clears nothing.
        ui.keyHover(.account("c1"))
        ui.report(HoverTarget(id: "x1", label: "x1", isExit: true))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(ui.hover == .account("c1") && ui.hoverByKey)
    }

    // MARK: Switch sessions (P462)

    @Test
    func switchSessionsIsAThirdActionWithOneLine() {
        #expect(GlobalKeyAction.allCases.map(\.title) == ["Jump to what needs you", "Open Juice Island", "Switch sessions", "Send to island"])
        #expect(GlobalKeyAction.jump.detail == nil && GlobalKeyAction.open.detail == nil)
        #expect(GlobalKeyAction.switcher.detail != nil)
        // It jumps nowhere by itself: no row shows the key's hint.
        let settings = AppSettings.ephemeral()
        settings.globalJumpEnabled = true
        settings.globalJumpKey = "ctrl+opt+j"
        settings.globalKeyAction = .switcher
        #expect(!SessionCardView.showsJumpHint(settings, problem: nil))
        #expect(ShortcutsPane.localKeys.contains { $0.1 == "U" })
    }

    @Test
    func switchSessionsIsKeptInDefaults() throws {
        let suite = "ji-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppSettings(defaults: defaults, identity: .development).globalKeyAction = .switcher
        #expect(defaults.string(forKey: AppSettings.Key.globalKeyAction) == "switcher")
        #expect(AppSettings(defaults: defaults, identity: .development).globalKeyAction == .switcher)
    }

    @Test
    func theWindowsSwitcherStepWrapsToTheFirstRow() {
        let ids = ["a", "b", "c"]
        #expect(RowSelection.cycled(nil, in: ids) == "a")
        #expect(RowSelection.cycled("a", in: ids) == "b")
        #expect(RowSelection.cycled("c", in: ids) == "a")
        #expect(RowSelection.cycled("gone", in: ids) == "a")
        #expect(RowSelection.cycled("a", in: []) == nil)
    }

    @Test
    func theIslandsSwitcherShowsTheRestThenWraps() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let sessions = env.sessions
        let folded = RowSelection.islandOrder(sessions, style: .clean, showAll: false)
        try #require(folded.showsFooter)
        let all = RowSelection.islandOrder(sessions, style: .clean, showAll: true).shown
        // The first press after the island opened on its first row moves down, as ↓ does.
        let first = RowSelection.islandSwitch(nil, sessions: sessions, style: .clean, showAll: false)
        #expect(first.row?.id == folded.shown.first?.id && !first.showsAll)
        let second = RowSelection.islandSwitch(folded.shown[0].id, sessions: sessions, style: .clean, showAll: false)
        #expect(second.row?.id == folded.shown[1].id)
        // From the last row the folded list shows: the rest show, as ↓ shows them.
        let past = RowSelection.islandSwitch(folded.shown.last?.id, sessions: sessions, style: .clean, showAll: false)
        #expect(past.showsAll)
        #expect(past.row?.id == all[folded.shown.count].id)
        // From the very last row: the first again.
        let wrapped = RowSelection.islandSwitch(all.last?.id, sessions: sessions, style: .clean, showAll: true)
        #expect(wrapped.row?.id == all.first?.id && !wrapped.showsAll)
    }

    @Test
    func returnJumpsInTheSwitcherAndOpensACardOtherwise() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let waiting = try #require(env.sessions.rows.first { $0.hasCard })
        let running = try #require(env.sessions.rows.first { !$0.hasCard })
        #expect(RowSelection.onReturn(waiting, switching: false) == .openCard)
        #expect(RowSelection.onReturn(running, switching: false) == .jump)
        #expect(RowSelection.onReturn(waiting, switching: true) == .jump)
        #expect(RowSelection.onReturn(running, switching: true) == .jump)
    }
}
