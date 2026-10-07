import AppKit
import Observation

/// Shows the desktop panel per Settings › Desktop Panel, in either mode (Juice Island spec §4.3, §4.5):
/// - Show on desktop shows or hides it (Settings' switch, the menu bar icon's item, the usage block's menu and the
///   panel's own Hide write the same setting); a panel with nothing to draw is not shown. Use the widget instead keeps
///   it hidden whatever Show on desktop says: the Usage widget takes its place (P1226), in a build that feeds it (P1280).
/// - Lock position decides whether a drag on it moves it.
/// - Display and Corner place it; Reset Position forgets where it was left on its display.
/// - A drag is remembered per display, and the display it was left on becomes the chosen one.
/// - A display that goes away sends it to the primary display until it comes back (Juice spec §2.6, P38).
/// Nothing is created until the panel is first shown.
@MainActor
final class DesktopPanelController {
    private let env: AppEnvironment
    private let store: PanelPositionStore
    private let screens: @MainActor () -> [PanelScreen]
    private let makeSurface: @MainActor () -> DesktopPanelSurface
    private var surface: DesktopPanelSurface?
    private var appliedCorner: PanelCorner?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// A move of the owner's not yet saved: every step of a drag posts one, and the drop or, for a move with no drop,
    /// 250 ms of quiet saves it. While it is pending the controller never moves the panel itself.
    private var pendingMove: Task<Void, Never>?

    init(env: AppEnvironment, store: PanelPositionStore = PanelPositionStore(),
         screens: @escaping @MainActor () -> [PanelScreen] = PanelScreen.connected,
         makeSurface: (@MainActor () -> DesktopPanelSurface)? = nil) {
        self.env = env
        self.store = store
        self.screens = screens
        self.makeSurface = makeSurface ?? { DesktopPanelWindow.make(env: env) }
    }

    /// `live` (the app): follow display changes and list the connected displays in Settings. Tests pass false.
    func start(live: Bool = true) {
        guard !started else { return }
        started = true
        if live {
            let screens = screens
            PanelDisplays.provider = { screens().map { ($0.id, $0.name) } }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            })
        }
        observe()
    }

    func stop() {
        started = false
        env.watchAccountsInUse(false)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        // Hidden first: a drag it cuts short posts its move, which goes with the rest.
        surface?.hide()
        pendingMove?.cancel()
        pendingMove = nil
    }

    /// Settings › Desktop Panel › Reset Position: back to the corner on the panel's display.
    func resetPosition() {
        pendingMove?.cancel()
        pendingMove = nil
        if let id = currentScreen()?.id { store.forget(id) }
        apply()
    }

    func screensChanged() { apply() }

    /// Whether the panel shows (`AppSettings.panelShown`, spelled out here where it acts): Show on desktop, unless Use the
    /// widget instead gives its place to the Usage widget (P1226), which only a build that feeds the widget does (P1280).
    private var shown: Bool {
        env.settings.panelShowOnDesktop && !(env.settings.panelUseWidget && env.settings.widgetFed)
    }

    /// Brings the window in line with the settings and the usage model. Idempotent: it moves the panel only when its
    /// place changed (a display, the corner, a reset, the panel's size), never on a new reading alone.
    func apply() {
        let settings = env.settings
        let content = DesktopPanelContent.make(usage: env.usage, settings: settings)
        if let corner = appliedCorner, corner != settings.panelCorner { store.forgetAll() }
        appliedCorner = settings.panelCorner
        guard shown, let size = content.size,
              let frame = PanelPlacement.desiredFrame(panelSize: size, screens: screens(), preferredID: settings.panelDisplay,
                                                      corner: settings.panelCorner, store: store) else {
            surface?.hide()
            return
        }
        let surface = surface ?? makeSurface()
        if self.surface == nil {
            self.surface = surface
            surface.onUserMove = { [weak self] in self?.userMoved() }
            surface.onUserDrop = { [weak self] in self?.commitMove() }
        }
        surface.movesByDragging = !settings.panelLocked
        // A drag not yet saved: moving now would pull the panel back under the owner's pointer. `commitMove` catches up.
        if pendingMove == nil, surface.panelFrame != frame { surface.setPanelFrame(frame) }
        surface.show()
    }

    // MARK: Drags

    /// A step of the owner's drag, or a move left behind by one cut short. Saved at the drop (`commitMove`, from the
    /// surface), or 250 ms after the last step if no drop comes; never while the button is still down, since the save
    /// pulls the panel onto the visible frame and the next step would put it back under the pointer (P1215).
    private func userMoved() {
        pendingMove?.cancel()
        pendingMove = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.surface?.isDragging != true else { return }
            self.commitMove()
        }
    }

    /// Where a drag left the panel: pulled whole onto the display it covers most, remembered for that display, and
    /// that display becomes the chosen one. At the drop, or once a move with no drop has rested.
    func commitMove() {
        pendingMove?.cancel()
        pendingMove = nil
        guard let surface, let screen = PanelPlacement.screen(bestFor: surface.panelFrame, in: screens()) ?? currentScreen() else { return }
        var frame = surface.panelFrame
        frame.origin = PanelPlacement.clamp(frame.origin, panelSize: frame.size, visible: screen.visibleFrame)
        if frame != surface.panelFrame { surface.setPanelFrame(frame) }
        store.save(frame, for: screen.id)
        if env.settings.panelDisplay != screen.id { env.settings.panelDisplay = screen.id }
        // Whatever changed during the drag (money switched off, a display) applies now.
        apply()
    }

    private func currentScreen() -> PanelScreen? {
        PanelPlacement.resolve(screens(), preferredID: env.settings.panelDisplay)
    }

    // MARK: Observation

    private func observe() {
        guard started else { return }
        // The panel's dots follow the accounts in use while it is on (P814): the watch starts here, before the panel
        // shows and outside the tracking below, so its first make adds nothing to what that tracking follows.
        env.watchAccountsInUse(shown)
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }
}
