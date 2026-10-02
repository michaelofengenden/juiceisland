import AppKit
import SwiftUI

/// Where the window's title line is: the toolbar line shares the traffic lights' line, so the window has no band
/// between them. The main window measures AppKit's own buttons once (`measure`); renders keep the defaults, which are
/// what macOS 26 gives a compact unified title bar (40 pt; lights 14 pt, 9 apart, from x 12, centred 20 from the top).
struct WindowChromeMetrics: Equatable, Sendable {
    /// The toolbar line's height: twice the lights' centre from the top, so its content centres on them.
    var lineHeight: CGFloat
    /// The close button's leading edge (where renders draw their stand-in lights).
    var lightsLeading: CGFloat
    /// Where the line's own content starts: the zoom button's trailing edge plus `gapAfterLights`.
    var contentLeading: CGFloat

    static let gapAfterLights: CGFloat = 14
    static let standard = WindowChromeMetrics(lineHeight: 40, lightsLeading: 12, contentLeading: 72 + gapAfterLights)

    /// The metrics from the close and zoom buttons' frames in a frame view `height` tall (AppKit's y goes up).
    static func from(close: CGRect, zoom: CGRect, frameHeight height: CGFloat) -> WindowChromeMetrics {
        let centreFromTop = height - close.midY
        return WindowChromeMetrics(lineHeight: (2 * centreFromTop).rounded(), lightsLeading: close.minX,
                                   contentLeading: (zoom.maxX + gapAfterLights).rounded())
    }

    /// The window's own buttons, after its title bar is laid out; `standard` when it has none.
    @MainActor
    static func measure(_ window: NSWindow) -> WindowChromeMetrics {
        guard let frameView = window.contentView?.superview,
              let close = window.standardWindowButton(.closeButton), let zoom = window.standardWindowButton(.zoomButton) else { return .standard }
        frameView.layoutSubtreeIfNeeded()
        let metrics = from(close: close.convert(close.bounds, to: frameView), zoom: zoom.convert(zoom.bounds, to: frameView),
                           frameHeight: frameView.bounds.height)
        // A title bar that was not laid out yet reports nothing useful.
        return metrics.lineHeight >= 28 && metrics.contentLeading > 40 ? metrics : .standard
    }
}

private struct WindowChromeKey: EnvironmentKey { static let defaultValue = WindowChromeMetrics.standard }

extension EnvironmentValues {
    var windowChrome: WindowChromeMetrics {
        get { self[WindowChromeKey.self] }
        set { self[WindowChromeKey.self] = newValue }
    }
}

/// The toolbar line's empty background: drags the window, and a double-click does what the title bar's would
/// (zoom, minimise or nothing, per System Settings), since the line now sits in the title bar.
struct TitleLineDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                TitleLineDragArea.doubleClick(window, action: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
            } else {
                window.performDrag(with: event)
            }
        }
    }

    /// The title bar's double-click, per the global `AppleActionOnDoubleClick` (Minimize, None; anything else zooms).
    @MainActor
    static func doubleClick(_ window: NSWindow, action: String?) {
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}
