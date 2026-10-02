import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The real Settings window, chrome included: `SettingsWindowController` builds its `NSWindow`, which is never ordered
/// on screen; the theme frame (the content view's superview, where AppKit draws the traffic lights) is cached into a
/// bitmap. Proves the sidebar runs from the window's top edge with the traffic lights inside it and no empty band.
/// `zsh scripts/render-all.sh ARenders` runs it with the pane renders.
@MainActor
@Suite(.serialized)
struct ARendersSettingsChrome {
    @Test func settingsWindowChrome() throws {
        let (rep, _) = try Self.chrome(.general, name: "A-settings-window-chrome")
        let sidebarX = Int(SettingsTheme.Metrics.sidebarWidth / 2)
        let detailX = Int(SettingsTheme.Metrics.sidebarWidth + 200)
        // Just under the top edge, the sidebar's colour differs from the detail's: no band spans the window's width.
        let sidebarTop = try #require(Self.colour(rep, x: sidebarX, y: 3))
        let detailTop = try #require(Self.colour(rep, x: detailX, y: 3))
        #expect(!Self.close(sidebarTop, detailTop), "the sidebar starts at the top edge")
        // The sidebar's colour is the same at the top and near the bottom: one full-height column.
        let sidebarBottom = try #require(Self.colour(rep, x: sidebarX, y: Int(rep.size.height) - 12))
        #expect(Self.close(sidebarTop, sidebarBottom), "the sidebar runs full height")
    }

    @Test func settingsWindowChromeAbout() throws {
        _ = try Self.chrome(.about, name: "A-settings-window-chrome-about")
    }

    /// The window in Appearance Light (P763): AppKit's own chrome and traffic lights in the light look, the sidebar and
    /// the detail in their light twins.
    @Test func settingsWindowChromeLight() throws {
        let (rep, _) = try Self.chrome(.general, name: "ap-settings-window-chrome-light", appearance: .aqua)
        let detail = try #require(Self.colour(rep, x: Int(SettingsTheme.Metrics.sidebarWidth + 200), y: 3))
        #expect(detail.redComponent > 0.9, "a light window: \(detail)")
    }

    @Test func trafficLightsSitInTheSidebarOnTheTitleLine() throws {
        let controller = SettingsWindowController(env: .demo(), onClose: {})
        let window = controller.window
        let close = try #require(window.standardWindowButton(.closeButton))
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let closeFrame = close.convert(close.bounds, to: frameView)
        let zoomFrame = zoom.convert(zoom.bounds, to: frameView)
        // Inside the sidebar column, horizontally.
        #expect(zoomFrame.maxX < SettingsTheme.Metrics.sidebarWidth)
        // Centred on the 52 pt title line, where the detail's title sits.
        let top = frameView.isFlipped ? closeFrame.midY : frameView.bounds.height - closeFrame.midY
        #expect(abs(top - SettingsTheme.Metrics.titleBarHeight / 2) <= 3)
    }

    /// Builds the Settings window on `pane` and caches its theme frame into `renders/<name>.png`. The window takes the
    /// app's appearance (Settings › General › Appearance), which a render pins: dark unless asked, whatever this Mac's.
    static func chrome(_ pane: SettingsPane, name: String, appearance: NSAppearance.Name = .darkAqua) throws -> (NSBitmapImageRep, URL) {
        _ = NSApplication.shared
        // `cacheDisplay` skips the ScrollView's layer-backed content, so the pane is laid out without one here.
        let controller = SettingsWindowController(env: .demo(), scrolls: false, onClose: {})
        controller.select(pane)
        let window = controller.window
        window.appearance = NSAppearance(named: appearance)
        // As tall as the pane, like the pane renders, so nothing overflows the window.
        let fitting = ARenders.fittingHeight(SettingsRootView(navigation: SettingsNavigation(pane: pane), scrolls: false), env: .demo())
        window.setContentSize(NSSize(width: SettingsTheme.Metrics.width, height: max(SettingsTheme.Metrics.defaultHeight, fitting)))
        let frameView = try #require(window.contentView?.superview)
        window.layoutIfNeeded()
        frameView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // At 2x, like the other renders (a window that was never on a screen reports 1x).
        let size = frameView.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try FileManager.default.createDirectory(at: RenderHarness.directory, withIntermediateDirectories: true)
        let url = RenderHarness.directory.appendingPathComponent(name + ".png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return (rep, url)
    }

    /// The pixel at (x, y) in points from the top-left.
    static func colour(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB)
    }

    static func close(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}
