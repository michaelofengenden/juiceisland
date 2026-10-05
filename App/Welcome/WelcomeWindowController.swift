import AppKit
import SwiftUI

/// The welcome's window (P950): small, dark or in Glass's look, below the island so the island answers above it on every
/// step. Hello's demo plays on the island while Hello shows (`LiveSessions.show`, P963); First session watches the
/// island's sessions for the first real one (P961). Closing it ends the welcome as Later does.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: WelcomeModel
    private let env: AppEnvironment
    private let hosting = NSHostingView(rootView: AnyView(Color.clear))
    /// The shell's: the welcome ended (the look applies, the island or the window shows as chosen).
    var onFinish: @MainActor (WelcomeModel.Outcome) -> Void = { _ in }
    private var watching = false
    /// The window is closing (its close button): it is not closed again.
    private var closing = false

    /// `firstRun`: shown by itself at launch (Pick a look starts from the notch); else Show welcome's (from the settings).
    init(env: AppEnvironment, services: any WelcomeServices, step: WelcomeModel.Step = .hello, firstRun: Bool = false) {
        self.env = env
        model = WelcomeModel(env: env, services: services, step: step, firstRun: firstRun)
        model.animates = true
        let size = WelcomeView.size
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Welcome to \(Product.name)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = WindowLook.background(env.settings.juiceTheme)
        window.appearance = WindowLook.appearance(env.settings.juiceTheme)
        window.delegate = self
        // Only the close button: the welcome is one small screen, not a window to keep.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        hosting.safeAreaRegions = []
        hosting.rootView = AnyView(WelcomeView(model: model).environment(env))
        window.contentView = hosting
        window.setContentSize(size)
        model.onFinish = { [weak self] outcome in self?.finished(outcome) }
        model.onStep = { [weak self] step in self?.stepBegan(step) }
    }

    func show() {
        place()
        window.makeKeyAndOrderFront(nil)
        stepBegan(model.step)
    }

    /// Centred on the island's screen, its top far enough below the menu bar that the island's card shows above it, and
    /// never under the Dock.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { IslandScreen($0).hasNotch }) ?? NSScreen.main else { return window.center() }
        let visible = screen.visibleFrame, size = window.frame.size
        let top = max(min(visible.maxY - 250, visible.maxY), visible.minY + 12 + size.height)
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: min(top, visible.maxY) - size.height))
    }

    // MARK: Steps

    private func stepBegan(_ step: WelcomeModel.Step) {
        if step == .hello { startHello() } else { stopHello() }
        if step == .start { watchSessions() }
    }

    /// Hello's demo takes the island a moment after the window shows, so the island has arrived to open on its card.
    private func startHello() {
        guard model.hello == nil, let live = env.liveSessions else { return }
        let demo = HelloDemo(chime: { [weak self] in self?.model.services.chime() })
        model.hello = demo
        live.show(demo.model, as: .hello)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard self?.model.step == .hello else { return }
            demo.start()
        }
    }

    private func stopHello() {
        guard model.hello != nil else { return }
        model.hello = nil
        if env.liveSessions?.showcaseKind == .hello { env.liveSessions?.show(nil, as: nil) }
    }

    /// First session: every change of the island's sessions is offered to the model until the welcome ends.
    private func watchSessions() {
        guard !watching else { return }
        watching = true
        observe()
    }

    private func observe() {
        withObservationTracking { _ = env.sessions.rows } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.model.finished else { return }
                self.model.sessionsChanged(self.env.sessions.rows.map(\.id))
                if !self.model.finished { self.observe() }
            }
        }
    }

    // MARK: Ending

    private func finished(_ outcome: WelcomeModel.Outcome) {
        stopHello()
        if !closing, window.isVisible { window.close() }
        onFinish(outcome)
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        model.finish(.closed)
    }
}
