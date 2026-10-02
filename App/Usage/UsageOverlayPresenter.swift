import AppKit
import SwiftUI

/// Floats the header's account list and hover chip over the window (both reach below the header, over the session
/// list) as borderless child windows of the window the header is in. Points are SwiftUI `.global` coordinates, which
/// are the window's hosting content view's own (top-left). No event monitors: the account list closes when it stops
/// being key (a click anywhere else) or on Esc, and gives key back to the window. No `NSViewRepresentable` either, so
/// `ImageRenderer` draws the header. Never used by renders or tests, which draw `AccountListView` and `HoverChipView`.
@MainActor
final class UsageOverlayPresenter {
    private weak var host: NSWindow?
    private var list: UsageFloatingPanel?
    private var chip: UsageFloatingPanel?
    private var listDelegate: ListDelegate?

    var isShowingList: Bool { list != nil }

    /// Shows `content` with its top-left at `origin` (global coordinates). The list takes key; the chip never does.
    func showList<V: View>(_ content: V, at origin: CGPoint, env: AppEnvironment, onClose: @escaping @MainActor () -> Void) {
        closeList()
        guard let panel = makePanel(content, env: env, key: true, at: origin) else { return }
        let delegate = ListDelegate { [weak self] in self?.closeList(); onClose() }
        panel.delegate = delegate
        panel.onCancel = { [weak self] in self?.closeList(); onClose() }
        listDelegate = delegate
        list = panel
        panel.makeKey()
    }

    func closeList() {
        guard let panel = list else { return }
        list = nil
        panel.delegate = nil
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    func showChip<V: View>(_ content: V, at origin: CGPoint, env: AppEnvironment) {
        hideChip()
        chip = makePanel(content, env: env, key: false, at: origin)
    }

    func hideChip() {
        guard let panel = chip else { return }
        chip = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// The size `content` takes, for placing it before it shows.
    func fittingSize<V: View>(_ content: V, env: AppEnvironment) -> CGSize {
        NSHostingView(rootView: content.windowLookFromSettings().environment(env)).fittingSize
    }

    /// The window the header is in: the key (or main) window whose content is a hosting view, never one of ours.
    private var hostWindow: NSWindow? {
        [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { !($0 is UsageFloatingPanel) && $0.contentView is NSHostingView<AnyView> }
    }

    private func makePanel<V: View>(_ content: V, env: AppEnvironment, key: Bool, at origin: CGPoint) -> UsageFloatingPanel? {
        guard let window = hostWindow, let root = window.contentView else { return nil }
        // The window's look (`WindowLook`, P768): dark on Black and Smoke, the Appearance's on Glass and Solid.
        let hosting = NSHostingView(rootView: content.windowLookFromSettings().environment(env))
        let size = hosting.fittingSize
        // Global (the hosting view's flipped, top-left space) → window → screen; AppKit wants the bottom-left corner.
        let topLeft = window.convertPoint(toScreen: root.convert(origin, to: nil))
        let panel = UsageFloatingPanel(contentRect: NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                                       styleMask: [.borderless], backing: .buffered, defer: true)
        panel.allowsKey = key
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = key
        panel.ignoresMouseEvents = !key
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.appearance = WindowLook.appearance(env.settings.juiceTheme)
        panel.contentView = hosting
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        return panel
    }

    @MainActor private final class ListDelegate: NSObject, NSWindowDelegate {
        let resigned: @MainActor () -> Void
        init(resigned: @escaping @MainActor () -> Void) { self.resigned = resigned }
        func windowDidResignKey(_ notification: Notification) { resigned() }
    }
}

/// A borderless child panel that may take key (the account list, for Esc and its buttons) or not (the chip).
final class UsageFloatingPanel: NSPanel {
    var allowsKey = false
    var onCancel: (@MainActor () -> Void)?
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
