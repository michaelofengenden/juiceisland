import AppKit
import SwiftUI

/// What the controller needs from the panel's window, so its wiring is testable without creating one.
@MainActor
protocol DesktopPanelSurface: AnyObject {
    /// The visible panel in screen coordinates (the window less its shadow margin).
    var panelFrame: CGRect { get }
    func setPanelFrame(_ frame: CGRect)
    var isShown: Bool { get }
    func show()
    func hide()
    /// Unlocked: pressing anywhere on the panel and moving moves it (`PanelDrag`).
    var movesByDragging: Bool { get set }
    /// The owner's drag is under way, the button still down: where the panel is now is not yet where it was left.
    var isDragging: Bool { get }
    /// Called at each step of the owner's drag: the panel moved without `setPanelFrame`.
    var onUserMove: (@MainActor () -> Void)? { get set }
    /// Called when the owner lets go of a drag: the panel is where it was left (P1215).
    var onUserDrop: (@MainActor () -> Void)? { get set }
}

/// Juice spec §2.6: a non-activating panel just above the desktop icons, on every Space, that never takes focus, never
/// animates and stays on the desktop when the app is hidden.
final class DesktopPanelWindow: NSPanel, DesktopPanelSurface {
    static let panelLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    static let behaviour: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    static let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

    var onUserMove: (@MainActor () -> Void)?
    var onUserDrop: (@MainActor () -> Void)?
    private var moveObserver: NSObjectProtocol?
    /// The owner's drag (`PanelDrag`, P1200): the press it holds, or the move under way.
    private var drag = PanelDrag<NSEvent>()
    /// Where the pointer is, in screen points: the system's, read at each press and step (tests set their own).
    var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: PanelGeometry.windowSize(for: Theme.Panel.size)),
                   styleMask: Self.style, backing: .buffered, defer: false)
        level = Self.panelLevel
        collectionBehavior = Self.behaviour
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        // Never AppKit's or the window server's background drag, which never moved this window (P1200): it drags
        // itself (`sendEvent`).
        isMovableByWindowBackground = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        title = "\(Product.name) panel"
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var panelFrame: CGRect { frame.insetBy(dx: PanelGeometry.margin, dy: PanelGeometry.margin) }

    func setPanelFrame(_ panel: CGRect) {
        let window = panel.insetBy(dx: -PanelGeometry.margin, dy: -PanelGeometry.margin)
        if window != frame { setFrame(window, display: true, animate: false) }
    }

    var isShown: Bool { isVisible }
    func show() { if !isVisible { orderFrontRegardless() } }
    func hide() {
        hoverController?.dismiss()
        abandonDrag()
        if isVisible { orderOut(nil) }
    }

    var movesByDragging = false {
        didSet { if !movesByDragging { abandonDrag() } }
    }

    /// A press or a drag cut short (Lock position came on, or the panel hid, with the button still down): the press is
    /// forgotten, and a panel already moved stays where it is, a move of the owner's like any (`onUserMove`, which the
    /// controller saves once nothing holds it, P1215). No drop follows: its release goes on as it comes.
    private func abandonDrag() {
        let moved = drag.isMoving
        drag.cancel()
        if moved { onUserMove?() }
    }

    /// The owner's drag is under way: the hover chip waits until it ends.
    var isDragging: Bool { drag.isMoving }

    /// Any move takes the hover chip away, since it was placed beside the panel's old frame. Only the owner's drag is
    /// remembered (`handle`); a move macOS makes by itself (a display that went away) is not, and the controller places
    /// the panel again when the displays change.
    private func moved() {
        hoverController?.dismiss()
    }

    // MARK: The drag (P1200 to P1203)

    override func sendEvent(_ event: NSEvent) {
        for forwarded in handle(event) { super.sendEvent(forwarded) }
    }

    /// The owner's drag, unlocked, from the window's own events (no monitor): a left press on the panel is held; once
    /// the pointer has gone past `PanelDragRule.threshold` the window follows it, each step the owner's move
    /// (`onUserMove`), and the release is the drop (`onUserDrop`, where the controller saves it per display, P1215); a
    /// press that never went that far reaches the content at its release, with the release, as the click it was. Locked, a press outside the panel (its shadow's margin), a
    /// Control-click (the right-click menu) and every other event go on as they came. Nothing here takes focus or
    /// activates the app. Returns what goes on to the content, in order.
    func handle(_ event: NSEvent) -> [NSEvent] {
        switch event.type {
        case .leftMouseDown:
            let point = pointer()
            guard movesByDragging, !event.modifierFlags.contains(.control), panelFrame.contains(point) else {
                drag.cancel()
                return [event]
            }
            drag.press(event, at: point, origin: frame.origin)
            return []
        case .leftMouseDragged:
            guard drag.isHolding else { return [event] }
            let starts = !drag.isMoving
            if let origin = drag.drag(to: pointer()) {
                if starts { hoverController?.dismiss() }
                setFrameOrigin(origin)
                onUserMove?()
            }
            return []
        case .leftMouseUp:
            switch drag.release() {
            case .click(let press): return [press, event]
            case .drop:
                onUserDrop?()
                return []
            case .none: return [event]
            }
        default:
            return [event]
        }
    }

    /// The real window with the panel view and its hover chip.
    static func make(env: AppEnvironment) -> DesktopPanelWindow {
        let window = DesktopPanelWindow()
        let widgets = DesktopWidgetWatch()
        let hover = PanelHoverController(panel: window, theme: { env.settings.juiceTheme }, frost: { env.settings.glassFrost },
                                         look: { env.settings.glassLook }, widgets: { widgets.state })
        let root = DesktopPanelRootView(actions: .desktop(env: env), hover: { [weak hover] target in hover?.pointer(over: target) },
                                        widgets: widgets)
            .juiceThemeFromSettings().environment(env)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.hoverController = hover
        window.widgets = widgets
        return window
    }

    /// Kept alive with the window.
    private var hoverController: PanelHoverController?
    /// The desktop widgets' look the panel follows under Glass look Widget (P1204), kept alive with the window.
    private(set) var widgets: DesktopWidgetWatch?
}

// MARK: Hover labels

/// The label's origin (Juice spec §2.5): on the roomiest side of the panel the chip actually fits, 12 pt away, centred
/// along the panel's edge and kept on screen. If it fits nowhere, the roomiest side still wins and the clamp keeps it
/// on screen.
enum PanelHoverPlacement {
    static let gap: CGFloat = 12

    static func origin(labelSize: CGSize, panelFrame p: CGRect, visibleFrame v: CGRect) -> CGPoint {
        let room: [(side: String, space: CGFloat, needed: CGFloat)] = [
            ("above", v.maxY - p.maxY, labelSize.height + gap),
            ("left", p.minX - v.minX, labelSize.width + gap),
            ("right", v.maxX - p.maxX, labelSize.width + gap),
            ("below", p.minY - v.minY, labelSize.height + gap),
        ]
        let fitting = room.filter { $0.space >= $0.needed }
        let side = (fitting.isEmpty ? room : fitting).max { $0.space < $1.space }?.side ?? "above"
        var origin: CGPoint
        switch side {
        case "left": origin = CGPoint(x: p.minX - gap - labelSize.width, y: p.midY - labelSize.height / 2)
        case "right": origin = CGPoint(x: p.maxX + gap, y: p.midY - labelSize.height / 2)
        case "below": origin = CGPoint(x: p.midX - labelSize.width / 2, y: p.minY - gap - labelSize.height)
        default: origin = CGPoint(x: p.midX - labelSize.width / 2, y: p.maxY + gap)
        }
        origin.x = min(max(origin.x, v.minX + 4), v.maxX - labelSize.width - 4)
        origin.y = min(max(origin.y, v.minY + 4), v.maxY - labelSize.height - 4)
        return origin
    }
}

/// Juice's hover timing: 350 ms of rest before the first label, 100 ms to move to the next target, 100 ms of grace
/// on leaving. It shows saved text and never starts a read.
@MainActor
final class PanelHoverController {
    private weak var panel: DesktopPanelWindow?
    private let label: PanelHoverLabelWindow
    /// The panel's theme (Settings › Island › Theme) and Glass's Frost, read at each show: the chip's window has no
    /// environment of its own.
    private let theme: @MainActor () -> JuiceTheme
    private let frost: @MainActor () -> Double
    /// Glass look (P870), read at each show as the theme is.
    private let look: @MainActor () -> GlassLookChoice
    /// The desktop widgets' look the panel is in (P1204), read at each show.
    private let widgets: @MainActor () -> WidgetGlassState
    private var current: HoverTarget?
    /// The target the pointer rests on, if any (tests).
    var resting: HoverTarget? { current }
    private var dwell: Task<Void, Never>?
    private var isShown = false

    init(panel: DesktopPanelWindow, theme: @escaping @MainActor () -> JuiceTheme = { .black },
         frost: @escaping @MainActor () -> Double = { 0 }, look: @escaping @MainActor () -> GlassLookChoice = { .lightAndDark },
         widgets: @escaping @MainActor () -> WidgetGlassState = { .overApps }) {
        self.panel = panel
        self.theme = theme
        self.frost = frost
        self.look = look
        self.widgets = widgets
        label = PanelHoverLabelWindow(above: panel.level)
    }

    /// Called on every enter and leave: an enter names the target, an exit names the target it left. Nothing shows while
    /// the owner drags the panel (P1202): the next target after the drop starts a fresh rest.
    func pointer(over target: HoverTarget?) {
        guard panel?.isDragging != true else { return }
        if let target, target.isExit {
            // A late exit: the pointer already entered another target.
            guard target.id == current?.id else { return }
            rest(on: nil)
            return
        }
        guard target != current else { return }
        rest(on: target)
    }

    private func rest(on target: HoverTarget?) {
        dwell?.cancel()
        current = target
        let delay: Duration = target == nil || isShown ? .milliseconds(100) : .milliseconds(350)
        dwell = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.current == target else { return }
            if let target { self.show(target.label) } else { self.hide() }
        }
    }

    private func show(_ text: String) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        label.setText(text, theme: theme(), frost: frost(), look: look(), widgets: widgets())
        // The chip view pads itself by 10 on each side for its shadow.
        let chip = CGSize(width: label.frame.width - 20, height: label.frame.height - 20)
        let origin = PanelHoverPlacement.origin(labelSize: chip, panelFrame: panel.panelFrame, visibleFrame: screen.visibleFrame)
        label.setFrameOrigin(CGPoint(x: origin.x - 10, y: origin.y - 10))
        if !isShown {
            label.orderFrontRegardless()
            label.fade(to: 1, duration: 0.1)
            isShown = true
        }
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        label.fade(to: 0, duration: 0.08)
    }

    /// The panel hid or moved: the chip goes at once, and the next target starts a fresh 350 ms rest.
    func dismiss() {
        dwell?.cancel()
        current = nil
        guard isShown else { return }
        isShown = false
        label.fade(to: 0, duration: 0)
    }
}

/// The chip's window: above the panel, on every Space, transparent to the mouse.
final class PanelHoverLabelWindow: NSPanel {
    private let host = NSHostingView(rootView: PanelHoverChip(text: "", theme: .black))

    init(above panelLevel: NSWindow.Level) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: DesktopPanelWindow.style,
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: panelLevel.rawValue + 1)
        collectionBehavior = DesktopPanelWindow.behaviour
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = 0
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    func setText(_ text: String, theme: JuiceTheme = .black, frost: Double = 0, look: GlassLookChoice = .lightAndDark,
                 widgets: WidgetGlassState = .overApps) {
        host.rootView = PanelHoverChip(text: text, theme: theme, frost: frost, look: look, widgets: widgets)
        setContentSize(host.fittingSize)
    }

    /// The theme the chip draws in now, its Frost, its Glass look and the desktop widgets' look it takes.
    var theme: JuiceTheme { host.rootView.theme }
    var frost: Double { host.rootView.frost }
    var look: GlassLookChoice { host.rootView.look }
    var widgets: WidgetGlassState { host.rootView.widgets }

    /// The label's fades are the panel's only motion; Reduce Motion removes them.
    func fade(to alpha: CGFloat, duration: TimeInterval) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : duration
            animator().alphaValue = alpha
        }
    }
}

/// The chip's window content: the label in the panel's theme, dark as the panel is (Glass: in the glass's own
/// adaptation, as the panel), with the panel's Frost, Glass look and desktop widgets' look.
struct PanelHoverChip: View {
    let text: String
    let theme: JuiceTheme
    var frost: Double = 0
    var look: GlassLookChoice = .lightAndDark
    var widgets: WidgetGlassState = .overApps

    var body: some View {
        PanelHoverLabelView(text: text)
            .environment(\.juiceTheme, theme)
            .environment(\.glassFrost, frost)
            .environment(\.glassLook, look)
            .environment(\.widgetGlassState, widgets)
            .modifier(PanelInkScheme(theme: theme))
    }
}

/// The panel's ink scheme: dark, as it always was; Glass and Solid, none of ours: the window's, the Appearance's (P764),
/// picks each ink's twin (Glass look Widget's dark one is said where the glass is, `inGlass`, P870).
struct PanelInkScheme: ViewModifier {
    let theme: JuiceTheme

    func body(content: Content) -> some View {
        if theme.adapts { content } else { content.environment(\.colorScheme, .dark) }
    }
}

/// The one-line chip (Juice spec §2.5), black or glass as the panel is (`PanelSurface`): the first part in ink, the rest
/// in ink2; the tail truncates.
struct PanelHoverLabelView: View {
    static let maxTextWidth: CGFloat = 480

    let text: String
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        let parts = text.components(separatedBy: " · ")
        HStack(spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text(part)
                    .font(index == 0 ? Theme.labelFont.weight(.medium) : Theme.labelFont)
                    .foregroundStyle(index == 0 ? theme.panel.ink : theme.panel.ink2)
                    .layoutPriority(Double(parts.count - index))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: Self.maxTextWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .modifier(PanelSurface(radius: 10))
        .padding(10)
    }
}
