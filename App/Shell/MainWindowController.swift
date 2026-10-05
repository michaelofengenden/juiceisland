import AppKit
import SwiftUI

/// The 1200 × 760 app window (Window mode): black, or on Glass and Solid in the look of Settings › General › Appearance
/// (`WindowLook`, P762), switched live with the theme. Its hosting view hands every key to `WindowKeyRouter` first
/// (focus-local keys, P39). The content runs under the title bar and ignores its safe area, so the toolbar line sits on
/// the traffic lights' line (measured from AppKit's own buttons) with no band under them. Owner: stream A.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    let window: NSWindow
    private let hosting = KeyRoutingHostingView(rootView: AnyView(Color.clear))
    private var chrome = WindowChromeMetrics.standard
    /// Whether anyone can see the window: its glyphs pause while it is minimised, covered, on another Space, on a
    /// sleeping or locked display (P89). Ordered out (closed, or folded into the island) it draws nothing at all.
    let motion = SurfaceMotion(.hidden)
    private var motionWatch: SurfaceMotionWatch?
    /// Tells the engine which requests' cards the window shows the owner (P1050): a Codex request held for its card is
    /// answered from the window as from the island.
    private var attentionWatch: WindowAttentionWatch?
    /// The fold into the island while it plays.
    private var foldInFlight: WindowFold.Handle?

    init(env: AppEnvironment) {
        self.env = env
        let size = WindowTheme.Metrics.defaultSize
        let window = KeyRoutingWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: true)
        window.onEditingKey = { [env] event in WindowKeyRouter.handleWhileEditing(event, env: env) }
        window.onListKey = { [env] event in WindowKeyRouter.handleListKey(event, env: env) }
        self.window = window
        super.init()
        window.title = Product.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = WindowLook.background(env.settings.juiceTheme)
        window.appearance = WindowLook.appearance(env.settings.juiceTheme)
        window.isReleasedWhenClosed = false
        window.minSize = WindowTheme.Metrics.minSize
        window.collectionBehavior = [.fullScreenPrimary]
        // An empty compact toolbar makes the title bar 40 pt and centres the traffic lights 20 pt from the top; our
        // toolbar line is drawn by the content, under the (transparent, click-through) title bar, on that line. The
        // title bar is no taller than the line, so the session list never scrolls under it.
        let toolbar = NSToolbar(identifier: "JuiceIslandMainToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.delegate = self
        window.setContentSize(size)
        chrome = WindowChromeMetrics.measure(window)
        hosting.onKeyDown = { [env] event in WindowKeyRouter.handle(event, env: env) }
        // No safe area: the header starts at the window's top edge, not under the title bar.
        hosting.safeAreaRegions = []
        hosting.rootView = content
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("JuiceIslandMainWindow")
        motionWatch = SurfaceMotionWatch(window: window, motion: motion)
        attentionWatch = WindowAttentionWatch(env: env, motion: motion)
        observeTheme()
    }

    /// The window's own appearance and background follow the theme (`WindowLook`): set again only when it changes.
    private func observeTheme() {
        withObservationTracking {
            _ = env.settings.juiceTheme
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let theme = self.env.settings.juiceTheme
                let appearance = WindowLook.appearance(theme)
                if self.window.appearance?.name != appearance?.name { self.window.appearance = appearance }
                self.window.backgroundColor = WindowLook.background(theme)
                self.observeTheme()
            }
        }
    }

    private var content: AnyView {
        AnyView(WindowRootView(chrome: chrome).environment(env).glyphMotion(motion))
    }

    func show() {
        // Back before the fold into the island finished: its ghost goes at once.
        foldInFlight?.cancel()
        foldInFlight = nil
        fillContent()
        window.makeKeyAndOrderFront(nil)
        motionWatch?.refresh()
    }

    func close() {
        window.orderOut(nil)
        dropContent()
    }

    /// Show as Island: fold into the pill at `pill` (the island's frame; nil folds to the top centre of the window's
    /// screen), or just go, under Reduce Motion or when not on screen. `landing` runs as the island takes over (70 % of
    /// the fold), `completion` once the ghost is gone.
    func fold(into pill: CGRect? = nil, landing: @escaping @MainActor () -> Void = {}, completion: @escaping @MainActor () -> Void = {}) {
        foldInFlight = WindowFold.fold(window, into: pill, landing: landing) { [weak self] in
            self?.foldInFlight = nil
            self?.dropContent()
            completion()
        }
    }

    /// The owner came to the window: what it shows now is looked at, and no reminder comes for it (P410).
    func windowDidBecomeKey(_ notification: Notification) {
        env.followUps?.looked()
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.dropContent() }
    }

    /// A window that is ordered out draws nothing: its SwiftUI content goes until `show()` brings it back (the list's
    /// filter lives in the environment and stays). A clear stand-in, flexible both ways, leaves the window's frame alone.
    private func dropContent() {
        motionWatch?.refresh()
        guard !window.isVisible, hasContent else { return }
        hosting.rootView = AnyView(Color.clear)
        hasContent = false
    }

    /// Brings back the content `dropContent()` let go (`show()` does, before the window orders in).
    func fillContent() {
        guard !hasContent else { return }
        hosting.rootView = content
        hasContent = true
    }

    /// Whether the window holds its SwiftUI content (dropped while it is ordered out).
    private(set) var hasContent = true
}

/// The app window. While a text field is edited its field editor takes every key before the hosting view, so the keys
/// that act "always" (⌃G, and ⌃1-⌃4 on a question; spec §4.4) are offered to the router here first. ⌃A and ⌃D stay
/// the field's own line-start and delete-forward keys, so typing an answer never approves a command. Outside a field,
/// ↑, ↓ and Return are offered here first too, so they move and open the keys' row whichever view has the focus (the
/// list's scroll view would scroll on them, P321).
final class KeyRoutingWindow: NSWindow {
    var onEditingKey: (@MainActor (NSEvent) -> Bool)?
    var onListKey: (@MainActor (NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, firstResponder is NSText, onEditingKey?(event) == true { return }
        if event.type == .keyDown, !(firstResponder is NSText), onListKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// An `NSHostingView` that offers each key to a router before SwiftUI and the menu see it.
final class KeyRoutingHostingView: NSHostingView<AnyView> {
    var onKeyDown: (@MainActor (NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
