import AppKit
import SwiftUI

/// The Settings window, 780 wide and at least 560 tall, in the look of Settings › General › Appearance: it sets no
/// appearance of its own, so it takes the app's (`AppAppearance`), live, in every theme (P763). The sidebar runs the
/// window's full height with AppKit's traffic lights inside it; the content ignores the title bar's safe area, so no
/// band sits under them. Space-aware (P32): it opens on the current Space, in front, even over a full-screen app.
/// Owner: stream A.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Internal so a render can cache its theme frame without ordering it on screen.
    let window: NSWindow
    private let navigation = SettingsNavigation()
    private let onClose: @MainActor () -> Void
    private(set) var isOpen = false
    /// The Island pane's glyph previews pause while nobody can see the window (minimised, covered; P89). Closed, it
    /// draws nothing at all: its SwiftUI content goes until `show(_:)` (the pane it was on stays in `navigation`).
    private let motion = SurfaceMotion(.hidden)
    private var motionWatch: SurfaceMotionWatch?
    private let env: AppEnvironment
    private let scrolls: Bool
    private let hosting = NSHostingView(rootView: AnyView(Color.clear))
    /// Whether the window holds its SwiftUI content (dropped while it is closed).
    private(set) var hasContent = false

    /// `scrolls: false` lays the pane out without a ScrollView, for the offscreen chrome render only.
    init(env: AppEnvironment, scrolls: Bool = true, onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
        self.env = env
        self.scrolls = scrolls
        let size = NSSize(width: SettingsTheme.Metrics.width, height: SettingsTheme.Metrics.defaultHeight)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "\(Product.name) Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = SettingsTheme.windowBackground
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // An empty unified toolbar makes the title bar 52 pt, so AppKit centres the traffic lights on the detail's
        // title line; the toolbar itself draws nothing.
        let toolbar = NSToolbar(identifier: "JuiceIslandSettingsToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.contentMinSize = NSSize(width: SettingsTheme.Metrics.width, height: SettingsTheme.Metrics.minHeight)
        window.contentMaxSize = NSSize(width: SettingsTheme.Metrics.width, height: .greatestFiniteMagnitude)
        window.delegate = self
        fillContent()
        // The content starts at the window's top edge, under the (transparent) title bar, not below it.
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        motionWatch = SurfaceMotionWatch(window: window, motion: motion)
    }

    /// Selects `pane` without showing the window.
    func select(_ pane: SettingsPane) {
        navigation.pane = pane
    }

    func show(_ pane: SettingsPane) {
        select(pane)
        isOpen = true
        fillContent()
        window.makeKeyAndOrderFront(nil)
        motionWatch?.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        onClose()
        // Once the window is ordered out.
        Task { @MainActor [weak self] in
            guard let self, !self.window.isVisible, !self.isOpen else { return }
            self.hosting.rootView = AnyView(Color.clear)
            self.hasContent = false
        }
    }

    private func fillContent() {
        guard !hasContent else { return }
        hosting.rootView = AnyView(SettingsRootView(navigation: navigation, scrolls: scrolls).environment(env).glyphMotion(motion))
        hasContent = true
    }
}
