import AppKit
import IslandEngine
import Observation

/// Owns the windows and switches modes. Window mode: the app window and a Dock icon. Island mode: the island panel,
/// accessory policy unless "Show icon in Dock". Owner: stream A (stream D fills `IslandPanelController`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env: AppEnvironment
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var island: IslandPanelController?
    private var desktopPanel: DesktopPanelController?
    private var menu: MainMenu?
    /// The Dock tile's art in the Glyph style, while the app has a tile.
    private var dockIcon: DockIcon?
    /// The mode the windows were last switched to; other observed changes (the Dock icon) only update the policy.
    private var appliedMode: ShowAs?
    /// Settings › Shortcuts' system-wide jump key: registered only while it is on and recorded.
    private var globalJump: GlobalJumpHotKey?
    /// Settings › General › Menu bar icon: the status item exists only while it is on.
    private var menuBarIcon: MenuBarIconSwitch?
    /// The desktop widget's snapshot (spec §4.7); nil in a build its App Group does not vouch for (P342).
    private var widgetFeed: WidgetFeed?
    /// Settings › General › Appearance on the app, which every window inherits (P761, P766).
    private var appearance: AppAppearance?
    /// The first run's welcome while it shows (P950): the island shows above it whatever Show as says, and the chosen
    /// mode applies as it ends.
    private var welcome: WelcomeWindowController?

    init(environment: AppEnvironment) {
        env = environment
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window: each one is born in the Appearance's look.
        appearance = AppAppearance(settings: env.settings, target: NSApp)
        env.actions = AppActions(
            openSettings: { [weak self] pane in self?.showSettings(pane) },
            setShowAs: { [weak self] mode in self?.env.settings.showAs = mode },
            quit: { AppQuit.request() })
        env.actions.showWelcome = { [weak self] in self?.showWelcome() }
        env.actions.foldIn = { [weak self] bounds in self?.playFoldIn(bounds) }
        // The welcome shows by itself only on a Mac where this app never ran and no Juice hooks are installed: never on
        // the owner's (P950). Decided before any window, so Window mode's window waits for it; the few hook files are
        // read only where there was no earlier launch. The welcome's own mark counts as one.
        let firstRun = WelcomeGate.atLaunch(env.settings, juiceHooks: WelcomeGate.juiceHooksPresent())
        let menu = MainMenu(env: env)
        NSApp.mainMenu = menu.build()
        self.menu = menu
        // Settings › Island › Display lists this Mac's screens, never the renders' names (P940).
        IslandDisplays.provider = { IslandDisplays.live() }
        island = IslandPanelController(env: env)
        let desktopPanel = DesktopPanelController(env: env)
        self.desktopPanel = desktopPanel
        env.actions.resetPanelPosition = { [weak desktopPanel] in desktopPanel?.resetPosition() }
        // Only a build that feeds the widget lets it take the panel's place (P1280); the first such launch looks at the
        // widgets placed before the panel shows (P1281).
        widgetFeed = WidgetFeed.app(env: env)
        env.settings.widgetFed = widgetFeed != nil
        // A widget on the desktop still running the build this one replaced ends, and WidgetKit starts this one's (P1400).
        DispatchQueue.global(qos: .utility).async { WidgetExtensionRestart.run() }
        PanelWidgetChoice.settle(env.settings) { [weak desktopPanel] in desktopPanel?.start() }
        dockIcon = DockIcon(settings: env.settings)
        if firstRun { showWelcome(firstRun: true) } else { applyMode() }
        observeMode()
        env.hooks.activate()
        if !env.settings.newAgents.isEmpty { env.agentsPane.refreshSources() }
        env.liveSessions?.activate()
        if let sessions = env.liveSessions { env.liveRemoteHosts?.attach(to: sessions) }
        env.launchAtLogin?.applyAtLaunch()
        let globalJump = GlobalJumpHotKey(settings: env.settings, registrar: CarbonHotKey()) { [weak self] in self?.globalKeyPressed() }
        env.globalJump = globalJump
        self.globalJump = globalJump
        globalJump.start()
        let menuBarIcon = MenuBarIconSwitch(settings: env.settings) { [env] in StatusItemController(env: env) }
        self.menuBarIcon = menuBarIcon
        menuBarIcon.start()
        env.updateController.restoreAfterLaunch()
        UpdateQuitSignal.install { [weak self] in self?.env.updateController.scriptAskedToQuit() }
        env.updateChecker.start()
        widgetFeed?.start()
        env.followUps?.looking = { [weak self] in self?.ownerLooks ?? false }
        env.followUps?.start()
        env.banners?.clicked = { [weak self] id in self?.open(.session(id)) }
        env.banners?.windowFront = { [weak self] in self?.windowInFront ?? false }
        env.banners?.start()
        env.snoozeEnd?.start()
        env.autoTidy?.start()
        env.autoInstall?.start()
    }

    /// The bridge stops on quit (Live sessions); the jump key and the menu bar icon go; the hourly update check stops,
    /// and a background prepare with it (P713); what waits for money.json is written. A running update script is
    /// detached and carries on.
    func applicationWillTerminate(_ notification: Notification) {
        globalJump?.stop()
        menuBarIcon?.stop()
        env.liveRemoteHosts?.shutdown()
        env.liveSessions?.shutdown()
        env.updateChecker.stop()
        env.updateController.stopForQuit()
        env.liveMoney?.flush()
        widgetFeed?.stop()
    }

    /// A widget's tap (`WidgetLink`, in the build's own scheme, P345): what a click on that row does where the sessions
    /// show. Island: `IslandPanelController.openFromWidget`. Window: the window, where a card that waits shows in the
    /// Needs you grid, or the jump for any other row. A link answers nothing (P341). One that comes before the launch is
    /// done (a tap that launched the app) is left to the launch, which shows the island or the window by itself.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard island != nil, let scheme = WidgetIdentity.main?.scheme else { return }
        for url in urls {
            guard let link = WidgetLink(url: url, scheme: scheme) else { continue }
            open(link)
        }
    }

    /// A widget's tap or a banner's click (P412): the island opens that session's card (or jumps, for a row with none);
    /// in Window mode the window comes forward, or the jump. The owner went to that session: no reminder comes for it
    /// (P410).
    private func open(_ link: WidgetLink) {
        guard island != nil else { return }
        if case let .session(id) = link { env.followUps?.looked(sessionID: id) }
        if env.settings.showAs == .island {
            island?.openFromWidget(link)
        } else if case let .session(id) = link, let row = env.sessions.row(id: id), !row.hasCard {
            env.sessions.jump(id)
        } else {
            NSApp.activate()
            showMainWindow()
        }
    }

    /// The owner looks at the app now (P410): at the open island (the pointer on it, or its keys), or at the window in
    /// front with the keys.
    private var ownerLooks: Bool {
        switch env.settings.showAs {
        case .island: island?.ownerEngaged ?? false
        case .window: NSApp.isActive && mainWindow?.window.isKeyWindow == true
        }
    }

    /// Window mode: the window is in front, where it shows what a banner would say (P412).
    private var windowInFront: Bool {
        guard NSApp.isActive, let window = mainWindow?.window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if env.settings.showAs == .window { showMainWindow() }
        return true
    }

    // MARK: Modes

    private func applyMode() {
        let mode = env.settings.showAs
        menu?.update(showAs: mode)
        // While the welcome shows, the island stays above it; the chosen mode applies as it ends (P950).
        guard welcome == nil else { return updateActivationPolicy() }
        if mode != appliedMode {
            appliedMode = mode
            if mode == .window {
                // Regular and active before the window shows: from the island (a nonactivating panel, accessory app)
                // it would otherwise open behind the frontmost app and stay out of ⌘Tab.
                updateActivationPolicy()
                NSApp.activate()
            }
            switchWindows(to: mode)
        }
        updateActivationPolicy()
    }

    /// Window: the island goes and the window comes back. Island: the window folds into the notch and the pill
    /// arrives as the fold ends (switching back mid-fold brings the window back and skips the pill).
    private func switchWindows(to mode: ShowAs) {
        switch mode {
        case .window:
            island?.hide()
            showMainWindow()
        case .island:
            if let mainWindow {
                // The window folds into the island's own pill (its display and notch, P37); at 70 % the island's panel
                // orders in black on black under the notch and its pill arrives while the ghost lands in the same place.
                mainWindow.fold(into: island?.pillFrame, landing: { [weak self] in
                    guard self?.env.settings.showAs == .island else { return }
                    self?.island?.show()
                })
            } else {
                island?.show()
            }
        }
    }

    private func observeMode() {
        withObservationTracking {
            _ = env.settings.showAs
            _ = env.settings.dockIconInIslandMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyMode()
                self?.observeMode()
            }
        }
    }

    /// `settingsOpening`: Settings is about to show, so the policy is set (and the app activated) before it orders
    /// front, never after (P32).
    private func updateActivationPolicy(settingsOpening: Bool = false) {
        let policy = ActivationPolicyRule.policy(showAs: env.settings.showAs,
                                                 dockIconInIslandMode: env.settings.dockIconInIslandMode,
                                                 auxiliaryWindowOpen: settingsOpening || (settingsWindow?.isOpen ?? false) || welcome != nil)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        dockIcon?.update(hasTile: policy == .regular)
    }

    /// The system-wide key (P323): Jump to what needs you, or Open Juice Island with the keys: the island (it takes the
    /// keys without making the app active), or the window brought forward with its first row selected. Switch sessions
    /// (P462) opens the same way, and each press after that, while the island or the window has the keys, moves the
    /// ring to the next row, the first again after the last; Return jumps (the window's Return always does).
    private func globalKeyPressed() {
        // The owner is at the Mac, acting on what needs them: no reminder for what shows now (P410).
        env.followUps?.looked()
        let action = env.settings.globalKeyAction
        switch action {
        case .jump:
            env.sessions.jumpToNextNeedsYou()
        case .send:
            // The tab in front, when it is a session's whose tab is known (P1300): the same as its row's Send to island.
            guard env.settings.showAs == .island else { return }
            let env = env
            Task { @MainActor in
                if let id = await env.sessions.frontmostFoldable() { env.sendToIsland(id) }
            }
        case .open, .switcher:
            guard env.settings.showAs == .window else {
                if action == .switcher { island?.switchWithKeys() } else { island?.openWithKeys() }
                return
            }
            let inFront = NSApp.isActive && mainWindow?.window.isKeyWindow == true
            NSApp.activate()
            showMainWindow()
            let order = RowSelection.windowOrder(env)
            if action == .switcher, inFront {
                env.windowSelection = RowSelection.cycled(env.windowSelection, in: order)
            } else if env.windowSelection == nil {
                env.windowSelection = order.first
            }
        }
    }

    /// A session was sent to the island: its window's glass shape flies from where the window is into the pill, whether
    /// the window went into the Dock or stayed for its other tabs (P1302, P1360). The bounds are AppleScript's, from the
    /// main display's top-left corner.
    private func playFoldIn(_ bounds: TuckBounds) {
        guard env.settings.showAs == .island, let main = NSScreen.screens.first,
              let frame = bounds.frame(mainDisplayHeight: main.frame.height) else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? main
        WindowFold.flyIn(from: frame, into: island?.pillFrame ?? WindowFold.target(screenFrame: screen.frame))
    }

    // MARK: Windows

    private func showMainWindow() {
        let controller = mainWindow ?? MainWindowController(env: env)
        mainWindow = controller
        controller.show()
    }

    /// The welcome (P950, P951): by itself on a first run, else from Settings › About › Show welcome. The island shows
    /// above it on every step, whatever Show as says; as it ends, Show as applies (the window comes, or the island stays).
    /// `firstRun`: Pick a look starts from the notch and Launch at Login on; Show welcome's starts from the settings (P973).
    func showWelcome(firstRun: Bool = false) {
        if let welcome {
            NSApp.activate()
            return welcome.window.makeKeyAndOrderFront(nil)
        }
        let controller = WelcomeWindowController(env: env, services: LiveWelcomeServices(settings: env.settings), firstRun: firstRun)
        controller.onFinish = { [weak self] _ in self?.welcomeEnded() }
        welcome = controller
        updateActivationPolicy(settingsOpening: true)
        NSApp.activate()
        island?.show()
        controller.show()
    }

    private func welcomeEnded() {
        welcome = nil
        appliedMode = nil
        applyMode()
    }

    func showSettings(_ pane: SettingsPane) {
        let controller = settingsWindow ?? SettingsWindowController(env: env, onClose: { [weak self] in self?.updateActivationPolicy() })
        settingsWindow = controller
        updateActivationPolicy(settingsOpening: true)
        NSApp.activate()
        controller.show(pane)
    }
}
