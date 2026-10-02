import CoreGraphics

/// The island panel's geometry, pure (spec §7): a still SwiftUI canvas whose place on the screen never changes while a
/// display stays, inside a panel that only ever snaps between sizes the choreography asks for. The canvas is the
/// island's 480 pt and `canvasMargin` each side, the display's height tall, centred on the notch and hanging from the
/// screen's top edge; the panel shows the part of it the surface needs, and the hosting view's origin inside the panel
/// is re-set with every snap, so SwiftUI never sees a size change and never re-lays anything out. The island's width is
/// Settings › Island › Width's (`IslandSize`, P401): a new one builds the canvas again, as a new display does.
enum IslandPanelSizing {
    /// The standard size's canvas (renders and tests).
    static var canvasWidth: CGFloat { IslandSize.standard.canvasWidth }

    /// The canvas's screen rect (AppKit coordinates, y up) for an island of `size`.
    static func canvasRect(centreX: CGFloat, top: CGFloat, screenHeight: CGFloat, size: IslandSize = .standard) -> CGRect {
        let width = size.canvasWidth
        return CGRect(x: NotchGeometry.originX(centreX: centreX, width: width), y: top - screenHeight, width: width, height: screenHeight)
    }

    /// The tallest the opened island may be on `screen`: from the top edge down to `screenMargin` above the Dock (or the
    /// bottom edge). Show all scrolls inside it rather than run off the display (P133).
    static func maxIslandHeight(_ screen: IslandScreen) -> CGFloat {
        screen.frame.height - screen.dockHeight - IslandTheme.Metrics.screenMargin
    }

    /// Where the hosting view sits inside a panel at `panel` so the canvas stays at `canvas` on the screen.
    static func hostingOrigin(canvas: CGRect, panel: CGRect) -> CGPoint {
        CGPoint(x: canvas.minX - panel.minX, y: canvas.minY - panel.minY)
    }
}

/// Whether the pointer is over the island (P35, P36): the target shape's screen rect (not the panel's, and not the
/// shape in flight), `band` more around it while the landed island is open, and anything above the screen's top edge
/// within its span counts as inside (the pointer pressed against the top edge is on the pill).
enum IslandHitRegion {
    static func contains(_ point: CGPoint, target: IslandExtent, centreX: CGFloat, top: CGFloat, band: CGFloat = 0) -> Bool {
        guard target.width > 0 else { return false }
        let rect = NotchGeometry.frame(target, centreX: centreX, top: top).insetBy(dx: -band, dy: -band)
        return point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY
    }
}
