import AppKit
import Foundation
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The desktop panel (Juice spec §2, Juice Island spec §4.3 and §4.5, amendment 12): geometry, the model it draws,
/// placement per display and corner, the menus, and the controller's wiring to Settings. No window is ever created:
/// the controller runs against `FakePanelSurface`.
@MainActor
struct PanelGeometryTests {
    @Test func theFullPanelIsJuicesSizeInsideItsShadowMargin() throws {
        let size = try #require(PanelGeometry.panelSize(providerRows: 2, showsMoney: true))
        #expect(size == CGSize(width: 362, height: 184))
        #expect(PanelGeometry.windowSize(for: size) == CGSize(width: 410, height: 232))
    }

    /// Amendment 12: six Claude batteries fill their 300 pt row; five Codex batteries take 249 pt of theirs.
    @Test func sixClaudeBatteriesFillTheRowAndFiveCodexTake249() {
        #expect(PanelGeometry.batteryAreaWidth == 300)
        #expect(PanelGeometry.rowWidth(batteries: 6) == 300)
        #expect(PanelGeometry.rowWidth(batteries: 5) == 249)
        #expect(PanelGeometry.rowWidth(batteries: 0) == 0)
        #expect(PanelGeometry.maxBatteriesPerRow == 6)
    }

    /// The same widths measured on the real views, so the arithmetic above and the drawing cannot drift apart.
    @Test func theDrawnRowsAreSixAt300AndFiveAt249() {
        _ = NSApplication.shared
        let env = AppEnvironment.demo()
        let battery = NSHostingView(rootView: BatteryView(battery: env.usage.allBatteries[0], now: env.usage.now).environment(env))
        #expect(battery.fittingSize.width == Theme.Battery.cellWidth)
        let widths = env.usage.panel.rows.map { row in
            NSHostingView(rootView: PanelBatteryRun(batteries: row.batteries, now: env.usage.now).environment(env)).fittingSize.width
        }
        #expect(widths == [300, 249])
    }

    /// Nothing that is not configured takes room: no money band without money, no second row without a second provider.
    @Test func thePanelDropsWhatIsNotThere() throws {
        #expect(try #require(PanelGeometry.panelSize(providerRows: 2, showsMoney: false)).height == 98)
        #expect(try #require(PanelGeometry.panelSize(providerRows: 1, showsMoney: true)).height == 147)
        #expect(try #require(PanelGeometry.panelSize(providerRows: 0, showsMoney: true)).height == 98)
        #expect(try #require(PanelGeometry.panelSize(providerRows: 1, showsMoney: false)).height == 61)
        #expect(PanelGeometry.panelSize(providerRows: 0, showsMoney: false) == nil)
        // Up to six accounts, Juice's three rows; past six, a row more for each two, so none is left out.
        #expect(try #require(PanelGeometry.panelSize(providerRows: 2, showsMoney: true, moneyCount: 6)).height == 184)
        #expect(try #require(PanelGeometry.panelSize(providerRows: 2, showsMoney: true, moneyCount: 7)).height == 206)
        #expect(try #require(PanelGeometry.panelSize(providerRows: 2, showsMoney: true, moneyCount: 11)).height == 250)
    }
}

@MainActor
struct PanelContentTests {
    @Test func theDemoPanelDrawsElevenBatteriesAndFiveSources() throws {
        let env = AppEnvironment.demo()
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        #expect(content.rows.map(\.provider) == [.claude, .codex])
        #expect(content.rows.map(\.batteries.count) == [6, 5])
        #expect(content.money.map(\.id) == MoneyRowModel.sourceNames)
        #expect(content.size == CGSize(width: 362, height: 184))
        #expect(content.now == env.usage.now)
        // P41: the panel draws the model's batteries, never its own states.
        #expect(content.rows == env.usage.panel.rows)
    }

    @Test func moneyTheOwnerSwitchedOffLeavesThePanel() {
        let settings = AppSettings.ephemeral()
        settings.moneyShown[.hetzner] = false
        let env = AppEnvironment.demo(settings: settings)
        #expect(DesktopPanelContent.make(usage: env.usage, settings: settings).money.map(\.id) == ["OpenRouter", "Anthropic", "OpenAI", "RunPod"])
        for id in MoneyAccount.allCases { settings.moneyShown[id] = false }
        let content = DesktopPanelContent.make(usage: env.usage, settings: settings)
        #expect(content.money.isEmpty)
        #expect(content.size == CGSize(width: 362, height: 98))
    }

    /// P34: an account the owner stops monitoring leaves the panel too.
    @Test func anUnmonitoredAccountLeavesThePanel() throws {
        let demo = DemoUsageModel()
        let env = AppEnvironment.demo()
        env.followUsageSource { _ in demo }
        let id = try #require(demo.accounts.first { $0.provider == .codex }?.id)
        demo.setMonitored(id, false)
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        #expect(content.rows.map(\.batteries.count) == [6, 4])
        #expect(!content.rows.flatMap(\.batteries).contains { $0.id == id })
    }

    @Test func aPanelWithNothingToDrawHasNoSize() {
        let env = AppEnvironment.demo()
        env.followUsageSource { _ in PanelFixtureUsage(accounts: []) }
        for id in MoneyAccount.allCases { env.settings.moneyShown[id] = false }
        #expect(DesktopPanelContent.make(usage: env.usage, settings: env.settings).size == nil)
    }
}

@MainActor
struct PanelPlacementTests {
    private let main = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
    private let side = PanelScreen(id: "side", name: "Studio", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                   visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))
    private let size = CGSize(width: 362, height: 184)

    /// Juice §2.6: 24 pt inside the usable screen edges, bottom right by default; the other corners on request.
    @Test func eachCornerSits24PointsInsideTheUsableArea() {
        let v = main.visibleFrame
        #expect(PanelPlacement.defaultOrigin(corner: .bottomRight, panelSize: size, visible: v) == CGPoint(x: 1512 - 24 - 362, y: 70 + 24))
        #expect(PanelPlacement.defaultOrigin(corner: .bottomLeft, panelSize: size, visible: v) == CGPoint(x: 24, y: 94))
        #expect(PanelPlacement.defaultOrigin(corner: .topRight, panelSize: size, visible: v) == CGPoint(x: 1126, y: 949 - 24 - 184))
        #expect(PanelPlacement.defaultOrigin(corner: .topLeft, panelSize: size, visible: v) == CGPoint(x: 24, y: 741))
        #expect(AppSettings.ephemeral().panelCorner == .bottomRight)
    }

    @Test func clampKeepsTheWholePanelOnItsDisplay() {
        let v = main.visibleFrame
        #expect(PanelPlacement.clamp(CGPoint(x: -50, y: 2000), panelSize: size, visible: v) == CGPoint(x: 0, y: 949 - 184))
        #expect(PanelPlacement.clamp(CGPoint(x: 5000, y: 0), panelSize: size, visible: v) == CGPoint(x: 1512 - 362, y: 70))
        #expect(PanelPlacement.clamp(CGPoint(x: 100, y: 100), panelSize: size, visible: v) == CGPoint(x: 100, y: 100))
    }

    /// P38: the chosen display while it exists, else the primary display; nil (never a crash) with no display at all.
    @Test func theChosenDisplayWinsWhileItIsConnected() {
        #expect(PanelPlacement.resolve([main, side], preferredID: "side") == side)
        #expect(PanelPlacement.resolve([main, side], preferredID: "gone") == main)
        #expect(PanelPlacement.resolve([main, side], preferredID: nil) == main)
        #expect(PanelPlacement.resolve([], preferredID: "side") == nil)
    }

    @Test func aDraggedPanelBelongsToTheDisplayItCoversMost() {
        let straddling = CGRect(x: 1400, y: 100, width: 362, height: 184)
        #expect(PanelPlacement.screen(bestFor: straddling, in: [main, side]) == side)
        #expect(PanelPlacement.screen(bestFor: CGRect(x: -9000, y: 0, width: 10, height: 10), in: [main, side]) == nil)
    }

    /// A panel that grows or shrinks keeps the edge nearest its screen edge: the bottom in the lower half, the top above.
    @Test func aResizedPanelKeepsItsNearEdge() {
        let v = main.visibleFrame
        let low = CGRect(x: 100, y: 94, width: 362, height: 184)
        #expect(PanelPlacement.origin(keeping: low, newSize: CGSize(width: 362, height: 98), visible: v) == CGPoint(x: 100, y: 94))
        let high = CGRect(x: 100, y: 741, width: 362, height: 184)
        #expect(PanelPlacement.origin(keeping: high, newSize: CGSize(width: 362, height: 98), visible: v) == CGPoint(x: 100, y: 827))
    }

    @Test func theDesiredFrameUsesTheSavedFrameElseTheCorner() {
        let store = PanelPositionStore(defaults: nil)
        let fresh = PanelPlacement.desiredFrame(panelSize: size, screens: [main, side], preferredID: "side", corner: .bottomRight, store: store)
        #expect(fresh == CGRect(x: 1512 + 2560 - 24 - 362, y: 24, width: 362, height: 184))
        store.save(CGRect(x: 2000, y: 600, width: 362, height: 184), for: "side")
        let saved = PanelPlacement.desiredFrame(panelSize: size, screens: [main, side], preferredID: "side", corner: .bottomRight, store: store)
        #expect(saved == CGRect(x: 2000, y: 600, width: 362, height: 184))
        // The side display went away: the primary display's own saved frame or its corner, never the side's frame.
        let fallback = PanelPlacement.desiredFrame(panelSize: size, screens: [main], preferredID: "side", corner: .bottomRight, store: store)
        #expect(fallback == CGRect(x: 1126, y: 94, width: 362, height: 184))
        #expect(PanelPlacement.desiredFrame(panelSize: size, screens: [], preferredID: nil, corner: .bottomRight, store: store) == nil)
    }
}

@MainActor
struct PanelPositionStoreTests {
    @Test func framesAreRememberedPerDisplay() {
        let store = PanelPositionStore(defaults: nil)
        store.save(CGRect(x: 10, y: 20, width: 362, height: 184), for: "a")
        store.save(CGRect(x: 30, y: 40, width: 362, height: 98), for: "b")
        #expect(store.frame(for: "a") == CGRect(x: 10, y: 20, width: 362, height: 184))
        #expect(store.frame(for: "b") == CGRect(x: 30, y: 40, width: 362, height: 98))
        store.forget("a")
        #expect(store.frame(for: "a") == nil && store.frame(for: "b") != nil)
        store.forgetAll()
        #expect(store.frame(for: "b") == nil)
    }

    @Test func framesPersistThroughTheirDefaults() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        PanelPositionStore(defaults: defaults).save(CGRect(x: 1.5, y: 2, width: 362, height: 184), for: "display-1")
        #expect(defaults.string(forKey: "ji.panel.frame.display-1") != nil)
        #expect(PanelPositionStore(defaults: defaults).frame(for: "display-1") == CGRect(x: 1.5, y: 2, width: 362, height: 184))
        defaults.set("garbage", forKey: "ji.panel.frame.display-2")
        #expect(PanelPositionStore(defaults: defaults).frame(for: "display-2") == nil)
    }

    @Test func theCornerPersists() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        AppSettings(defaults: defaults).panelCorner = .topLeft
        #expect(defaults.string(forKey: "ji.panel.corner") == "topLeft")
        #expect(AppSettings(defaults: defaults).panelCorner == .topLeft)
    }
}

@MainActor
struct PanelMenuTests {
    @Test func theBackgroundMenuIsRefreshLockHideSettings() {
        let env = AppEnvironment.demo()
        let items = PanelMenu.items(usage: env.usage, settings: env.settings)
        #expect(items.map { $0?.title } == ["Refresh all", nil, "Unlock position", "Hide panel", nil, "Settings…"])
        // Demo data cannot refresh.
        #expect(items.first??.isEnabled == false)
        env.settings.panelLocked = false
        #expect(PanelMenu.items(usage: env.usage, settings: env.settings)[2]?.title == "Lock position")
    }

    @Test func aRunningRefreshShowsItsProgress() {
        let env = AppEnvironment.demo()
        let usage = PanelFixtureUsage(accounts: DemoUsageData.accounts, progress: 3)
        env.followUsageSource { _ in usage }
        let first = PanelMenu.items(usage: env.usage, settings: env.settings).first ?? nil
        #expect(first?.title == "Refreshing 3 of 11…" && first?.isEnabled == false)
        usage.progress = nil
        #expect(PanelMenu.items(usage: env.usage, settings: env.settings).first??.isEnabled == true)
    }

    @Test func theMenuActsThroughSettingsAndTheApp() {
        let env = AppEnvironment.demo()
        var opened: [SettingsPane] = []
        env.actions.openSettings = { opened.append($0) }
        let usage = PanelFixtureUsage(accounts: DemoUsageData.accounts)
        env.followUsageSource { _ in usage }
        PanelMenu.perform(.refreshAll, env: env)
        #expect(usage.refreshes == 1)
        PanelMenu.perform(.toggleLock, env: env)
        #expect(!env.settings.panelLocked)
        PanelMenu.perform(.hide, env: env)
        #expect(!env.settings.panelShowOnDesktop)
        PanelMenu.perform(.settings, env: env)
        #expect(opened == [.desktopPanel])
    }

    @Test func batteryAndMoneyMenusOpenTheRightPanes() {
        let env = AppEnvironment.demo()
        var opened: [SettingsPane] = []
        env.actions.openSettings = { opened.append($0) }
        let actions = PanelActions.desktop(env: env)
        actions.signIn("x")
        actions.manageAccount("x")
        actions.manageSource("RunPod")
        actions.openSettings()
        #expect(opened == [.accounts, .accounts, .money, .desktopPanel])
        actions.toggleLock()
        #expect(!env.settings.panelLocked && !actions.isLocked())
        actions.hidePanel()
        #expect(!env.settings.panelShowOnDesktop)
        actions.toggleShown()
        #expect(env.settings.panelShowOnDesktop)
    }

    /// Settings › Desktop Panel › Display: the chosen display, else the first listed (where the panel actually is).
    @Test func theDisplayPopUpShowsWhereThePanelIs() {
        let choices: [(String?, String)] = [("a", "Built-in"), ("b", "Studio")]
        #expect(PanelDisplays.selection(stored: "b", in: choices) == "b")
        #expect(PanelDisplays.selection(stored: nil, in: choices) == "a")
        #expect(PanelDisplays.selection(stored: "gone", in: choices) == "a")
        #expect(PanelDisplays.selection(stored: nil, in: DisplayChoices.panel) == nil)
    }
}

/// The controller against a fake surface: Settings drive what the window does, and a drag is remembered.
@MainActor
struct PanelControllerTests {
    private let main = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
    private let side = PanelScreen(id: "side", name: "Studio", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                   visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    private func make(_ env: AppEnvironment = .demo(), screens: [PanelScreen]? = nil)
        -> (DesktopPanelController, FakePanelSurface, PanelPositionStore, ScreenList) {
        let store = PanelPositionStore(defaults: nil)
        let surface = FakePanelSurface()
        let list = ScreenList(screens ?? [main, side])
        let controller = DesktopPanelController(env: env, store: store, screens: { list.screens }, makeSurface: { surface })
        return (controller, surface, store, list)
    }

    @Test func showOnDesktopShowsTheLockedPanelInTheBottomRightCorner() {
        let (controller, surface, _, _) = make()
        controller.apply()
        #expect(surface.isShown && !surface.movesByDragging)
        #expect(surface.panelFrame == CGRect(x: 1126, y: 94, width: 362, height: 184))
    }

    @Test func theSwitchesTakeEffect() {
        let env = AppEnvironment.demo()
        let (controller, surface, _, _) = make(env)
        controller.apply()
        env.settings.panelLocked = false
        controller.apply()
        #expect(surface.movesByDragging)
        env.settings.panelShowOnDesktop = false
        controller.apply()
        #expect(!surface.isShown)
    }

    @Test func settingsChangesReachTheSurfaceByObservation() async {
        let env = AppEnvironment.demo()
        let (controller, surface, _, _) = make(env)
        controller.start(live: false)
        #expect(surface.isShown)
        env.settings.panelShowOnDesktop = false
        for _ in 0..<20 where surface.isShown { await Task.yield() }
        #expect(!surface.isShown)
        env.settings.panelShowOnDesktop = true
        for _ in 0..<20 where !surface.isShown { await Task.yield() }
        #expect(surface.isShown)
        controller.stop()
    }

    @Test func aDragIsRememberedForItsDisplayAndBecomesTheChosenDisplay() {
        let env = AppEnvironment.demo()
        env.settings.panelLocked = false
        let (controller, surface, store, _) = make(env)
        controller.apply()
        surface.userMove(to: CGRect(x: 2000, y: 600, width: 362, height: 184))
        controller.commitMove()
        #expect(env.settings.panelDisplay == "side")
        #expect(store.frame(for: "side") == CGRect(x: 2000, y: 600, width: 362, height: 184))
        controller.apply()
        #expect(surface.panelFrame == CGRect(x: 2000, y: 600, width: 362, height: 184))
    }

    @Test func aDragPastTheEdgeIsPulledBackOnScreen() {
        let env = AppEnvironment.demo()
        env.settings.panelLocked = false
        let (controller, surface, store, _) = make(env)
        controller.apply()
        surface.userMove(to: CGRect(x: -100, y: 94, width: 362, height: 184))
        controller.commitMove()
        #expect(surface.panelFrame.origin == CGPoint(x: 0, y: 94))
        #expect(store.frame(for: "main")?.origin == CGPoint(x: 0, y: 94))
    }

    @Test func theDisplayChoiceMovesThePanel() {
        let env = AppEnvironment.demo()
        let (controller, surface, _, _) = make(env)
        controller.apply()
        env.settings.panelDisplay = "side"
        controller.apply()
        #expect(surface.panelFrame == CGRect(x: 4072 - 24 - 362, y: 24, width: 362, height: 184))
    }

    /// Juice §2.6: it moves to a remaining display only when its own display disappears, and back when it returns.
    @Test func aGoneDisplaySendsThePanelToThePrimaryAndBack() {
        let env = AppEnvironment.demo()
        env.settings.panelDisplay = "side"
        let (controller, surface, _, list) = make(env)
        controller.apply()
        #expect(side.visibleFrame.contains(surface.panelFrame))
        list.screens = [main]
        controller.screensChanged()
        #expect(main.visibleFrame.contains(surface.panelFrame))
        #expect(env.settings.panelDisplay == "side")
        list.screens = [main, side]
        controller.screensChanged()
        #expect(side.visibleFrame.contains(surface.panelFrame))
    }

    @Test func noDisplayAtAllNeverCrashesAndDrawsNothing() {
        let (controller, surface, _, list) = make(screens: [])
        controller.apply()
        #expect(!surface.isShown)
        list.screens = [main]
        controller.screensChanged()
        #expect(surface.isShown)
    }

    @Test func resetAndCornerPutThePanelBackInItsCorner() {
        let env = AppEnvironment.demo()
        env.settings.panelLocked = false
        let (controller, surface, store, _) = make(env)
        controller.apply()
        surface.userMove(to: CGRect(x: 300, y: 300, width: 362, height: 184))
        controller.commitMove()
        controller.resetPosition()
        #expect(surface.panelFrame.origin == CGPoint(x: 1126, y: 94))
        #expect(store.frame(for: "main") == nil)
        surface.userMove(to: CGRect(x: 300, y: 300, width: 362, height: 184))
        controller.commitMove()
        env.settings.panelCorner = .topLeft
        controller.apply()
        #expect(surface.panelFrame.origin == CGPoint(x: 24, y: 949 - 24 - 184))
    }

    /// A new reading or a switch during a drag never pulls the panel back under the pointer; it applies once the drag
    /// is saved.
    @Test func aDragNotYetSavedIsNeverPulledBack() {
        let env = AppEnvironment.demo()
        env.settings.panelLocked = false
        let (controller, surface, store, _) = make(env)
        controller.apply()
        let dropped = CGRect(x: 300, y: 300, width: 362, height: 184)
        surface.userMove(to: dropped)
        let placed = surface.frameSets
        for id in MoneyAccount.allCases { env.settings.moneyShown[id] = false }
        controller.apply()
        #expect(surface.panelFrame == dropped && surface.frameSets == placed)
        controller.commitMove()
        #expect(store.frame(for: "main") == dropped)
        #expect(surface.panelFrame == CGRect(x: 300, y: 300, width: 362, height: 98))
    }

    @Test func switchingOffAllMoneyShrinksThePanelAndKeepsItsBottomEdge() {
        let env = AppEnvironment.demo()
        let (controller, surface, _, _) = make(env)
        controller.apply()
        for id in MoneyAccount.allCases { env.settings.moneyShown[id] = false }
        controller.apply()
        #expect(surface.panelFrame == CGRect(x: 1126, y: 94, width: 362, height: 98))
    }

    @Test func thePanelHidesWhenThereIsNothingToDraw() {
        let env = AppEnvironment.demo()
        env.followUsageSource { _ in PanelFixtureUsage(accounts: []) }
        for id in MoneyAccount.allCases { env.settings.moneyShown[id] = false }
        let (controller, surface, _, _) = make(env)
        controller.apply()
        #expect(!surface.isShown)
    }

    /// The panel never takes focus and sits just above the desktop icons on every Space (Juice §2.6). Checked on the
    /// class, without creating a window.
    @Test func theWindowKindIsDesktopLevelAndNeverKey() {
        #expect(DesktopPanelWindow.panelLevel.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        #expect(DesktopPanelWindow.behaviour == [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone])
        #expect(DesktopPanelWindow.style == [.borderless, .nonactivatingPanel])
    }

    /// The same on a real window, created and never ordered on screen: never key or main, at the desktop level on every
    /// Space, kept when the app hides, never animated; and a move the controller makes is never taken for a drag.
    @Test func theRealWindowNeverTakesFocusAndStaysOnTheDesktop() {
        _ = NSApplication.shared
        let window = DesktopPanelWindow()
        defer { window.close() }
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        #expect(window.level == DesktopPanelWindow.panelLevel)
        #expect(window.collectionBehavior == DesktopPanelWindow.behaviour)
        #expect(window.styleMask == DesktopPanelWindow.style)
        #expect(!window.canHide && !window.hidesOnDeactivate && !window.hasShadow && !window.isOpaque)
        #expect(window.animationBehavior == .none)
        #expect(!window.isVisible)
        var drags = 0
        window.onUserMove = { drags += 1 }
        window.movesByDragging = true
        window.setPanelFrame(CGRect(x: 100, y: 100, width: 362, height: 184))
        #expect(window.panelFrame == CGRect(x: 100, y: 100, width: 362, height: 184))
        #expect(window.frame.size == CGSize(width: 410, height: 232))
        #expect(drags == 0 && !window.isVisible)
    }
}

/// The hover chip sits 12 pt from the panel on the roomiest side where it fits (Juice §2.5).
struct PanelHoverPlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1500, height: 900)

    /// Juice's rule: the roomiest side where the chip fits. Bottom right on a wide screen: to its left.
    @Test func aPanelInTheBottomRightGetsItsLabelOnItsLeft() {
        let panel = CGRect(x: 1114, y: 24, width: 362, height: 184)
        let origin = PanelHoverPlacement.origin(labelSize: CGSize(width: 300, height: 30), panelFrame: panel, visibleFrame: visible)
        #expect(origin == CGPoint(x: panel.minX - 12 - 300, y: panel.midY - 15))
    }

    @Test func aPanelAtTheTopGetsItsLabelBelow() {
        let panel = CGRect(x: 600, y: 700, width: 362, height: 184)
        let origin = PanelHoverPlacement.origin(labelSize: CGSize(width: 300, height: 30), panelFrame: panel, visibleFrame: visible)
        #expect(origin.y == panel.minY - 12 - 30)
    }

    @Test func theLabelStaysOnScreen() {
        let panel = CGRect(x: 1114, y: 24, width: 362, height: 184)
        let origin = PanelHoverPlacement.origin(labelSize: CGSize(width: 900, height: 30), panelFrame: panel, visibleFrame: visible)
        #expect(origin.x + 900 <= visible.maxX - 4)
    }
}

// MARK: Fakes

@MainActor
final class FakePanelSurface: DesktopPanelSurface {
    private(set) var panelFrame: CGRect = .zero
    private(set) var isShown = false
    var movesByDragging = false
    var isDragging = false
    var onUserMove: (@MainActor () -> Void)?
    var onUserDrop: (@MainActor () -> Void)?
    private(set) var frameSets = 0

    func setPanelFrame(_ frame: CGRect) {
        frameSets += 1
        panelFrame = frame
    }

    func show() { isShown = true }
    func hide() { isShown = false }

    /// A drag by the owner: the frame changes without the controller asking.
    func userMove(to frame: CGRect) {
        panelFrame = frame
        onUserMove?()
    }
}

@MainActor
final class ScreenList {
    var screens: [PanelScreen]
    init(_ screens: [PanelScreen]) { self.screens = screens }
}

/// A usage model with any account list (the demo figures for the accounts it knows), for the menus, the empty panel
/// and the two-account render.
@MainActor
@Observable
final class PanelFixtureUsage: UsageModel {
    private(set) var panel: PanelModel
    let now: Date
    let accounts: [Account]
    let records: [String: AccountRecord]
    let moneyDetails: [String: MoneyDetail]
    let signingIn: Set<String> = []
    var progress: Int?
    var refreshProgress: Int? { progress }
    let refreshUnavailableReason: String? = nil
    private(set) var refreshes = 0

    init(accounts: [Account], money: [DemoUsageData.MoneySource] = DemoUsageData.money(), progress: Int? = nil, now: Date = DemoClock.now) {
        self.now = now
        self.accounts = accounts
        let all = DemoUsageData.records(now: now)
        records = all.filter { key, _ in accounts.contains { $0.id == key } }
        moneyDetails = Dictionary(uniqueKeysWithValues: money.map { ($0.detail.id, $0.detail) })
        self.progress = progress
        panel = PanelModelBuilder.build(accounts: accounts, records: records, signingIn: [], money: money.map(\.row), now: now)
    }

    func refreshAll() { refreshes += 1 }
}
