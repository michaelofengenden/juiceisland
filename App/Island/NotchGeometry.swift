import AppKit

/// A display as the island sees it: plain values, so placement is testable without real screens.
struct IslandScreen: Equatable, Sendable {
    var id: String
    /// AppKit global coordinates (origin at the bottom-left of the primary display, y up).
    var frame: CGRect
    /// `safeAreaInsets.top`: the notch height, 0 on a display without one.
    var safeAreaTop: CGFloat
    /// Widths of `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`: the menu bar left and right of the notch.
    var auxiliaryLeftWidth: CGFloat?
    var auxiliaryRightWidth: CGFloat?
    /// The menu bar's height (`frame.maxY - visibleFrame.maxY`); nil while it is hidden or cannot be read.
    var menuBarHeight: CGFloat? = nil
    /// Its backing scale factor: the pill's lead is drawn on its pixel grid (a no-notch display may be 1×).
    var scale: CGFloat = 2
    /// What the Dock takes at the bottom (`visibleFrame.minY - frame.minY`): the island never reaches into it.
    var dockHeight: CGFloat = 0

    var hasNotch: Bool { NotchGeometry.notchRect(on: self) != nil }
}

extension IslandScreen {
    /// Reads a real screen. The id is the display's UUID (stable across reboots), else its number.
    @MainActor init(_ screen: NSScreen) {
        let id = Self.displayID(of: screen)
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        self.init(id: id, frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                  auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width, auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
                  menuBarHeight: menuBar > 0 ? menuBar : nil, scale: screen.backingScaleFactor,
                  dockHeight: max(0, screen.visibleFrame.minY - screen.frame.minY))
    }

    /// A screen's id: its display's UUID (the same display after a reboot or a replug), else its number.
    @MainActor static func displayID(of screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            return text
        }
        return number.map { "display-\($0.uint32Value)" } ?? screen.localizedName
    }
}

/// Where the pill and the island sit (P37): the notch comes from the screen's safe area and auxiliary top areas, never
/// from fixed numbers; everything centres on the notch's own midX, so a screen with a non-zero origin still centres.
/// A display without a notch gets the top bar, centred on the screen and hanging from its top edge.
enum NotchGeometry {
    /// The physical notch in AppKit global coordinates; nil without one.
    static func notchRect(on screen: IslandScreen) -> CGRect? {
        guard screen.safeAreaTop > 0, let left = screen.auxiliaryLeftWidth, let right = screen.auxiliaryRightWidth else { return nil }
        let width = screen.frame.width - left - right
        guard width > 0 else { return nil }
        return CGRect(x: screen.frame.minX + left, y: screen.frame.maxY - screen.safeAreaTop, width: width, height: screen.safeAreaTop)
    }

    static func notchSize(on screen: IslandScreen) -> CGSize? { notchRect(on: screen)?.size }

    /// The centre line every surface shares: the notch's midX, or the screen's without a notch.
    static func centreX(on screen: IslandScreen) -> CGFloat { notchRect(on: screen)?.midX ?? screen.frame.midX }

    /// The closed pill's body height: one point taller than the notch, so no hardware edge shows under it, but never
    /// below the menu bar (the owner's Safari page starts there): `menuBar` when that is less. Without a measured menu
    /// bar, the notch + 1.
    static func pillBodyHeight(notch: CGSize, menuBar: CGFloat?) -> CGFloat {
        min(notch.height + 1, menuBar ?? notch.height + 1)
    }

    /// The no-notch top bar's height: its screen's menu bar (28 at most), or 24 when that cannot be measured.
    static func topBarHeight(menuBar: CGFloat?) -> CGFloat {
        min(IslandTheme.Metrics.topBarHeight, menuBar ?? IslandTheme.Metrics.topBarFallbackHeight)
    }

    /// A surface's frame hanging from `top`, reaching `extent.left` and `extent.right` either side of `centreX`.
    static func frame(_ extent: IslandExtent, centreX: CGFloat, top: CGFloat) -> CGRect {
        CGRect(x: originX(centreX: centreX, left: extent.left), y: top - extent.height, width: extent.width, height: extent.height)
    }

    /// The same on `screen`: centred on its notch (or its own middle), from its top edge.
    static func frame(_ extent: IslandExtent, on screen: IslandScreen) -> CGRect {
        frame(extent, centreX: centreX(on: screen), top: screen.frame.maxY)
    }

    /// A surface's left edge `left` before `centreX`, on the half-point grid: a notch often starts at a half point (an
    /// odd notch width on an even screen), and whole-point rounding would push a wing 0.5 pt under it.
    static func originX(centreX: CGFloat, left: CGFloat) -> CGFloat {
        ((centreX - left) * 2).rounded() / 2
    }

    /// A surface's left edge centred on `centreX`, on the half-point grid: a notch often starts at a half point (an odd
    /// notch width on an even screen), and whole-point rounding would push a wing 0.5 pt under it.
    static func originX(centreX: CGFloat, width: CGFloat) -> CGFloat {
        ((centreX - width / 2) * 2).rounded() / 2
    }
}

/// A rect hanging from the top edge, as reaches either side of the centre line (the notch's midX, or the screen's)
/// and a height: the closed pill is not symmetric about the notch (its lead's wing is wider than its count's).
struct IslandExtent: Equatable, Sendable {
    var left: CGFloat
    var right: CGFloat
    var height: CGFloat

    static let zero = IslandExtent(left: 0, right: 0, height: 0)

    init(left: CGFloat, right: CGFloat, height: CGFloat) {
        self.left = left
        self.right = right
        self.height = height
    }

    /// Centred: `width` wide.
    init(width: CGFloat, height: CGFloat) {
        self.init(left: width / 2, right: width / 2, height: height)
    }

    var width: CGFloat { left + right }

    /// Both, with nothing cut off either.
    func union(_ other: IslandExtent) -> IslandExtent {
        IslandExtent(left: max(left, other.left), right: max(right, other.right), height: max(height, other.height))
    }

    /// `margin` more each side and below.
    func grown(by margin: CGFloat) -> IslandExtent {
        IslandExtent(left: left + margin, right: right + margin, height: height + margin)
    }

    /// Whether `other` lies inside this one, allowing `tolerance`.
    func contains(_ other: IslandExtent, tolerance: CGFloat = 0) -> Bool {
        other.left <= left + tolerance && other.right <= right + tolerance && other.height <= height + tolerance
    }
}

/// Which display the island uses (P38): the preferred one while it exists, else the first with a notch, else the
/// first display; nil with no display at all. Never crashes on 0 screens or a display that went away.
enum IslandScreenResolver {
    /// `preferredID`: Settings › Island › Display as stored (`IslandDisplayChoice`). Follow focus takes `focusID`, the
    /// screen with the active window; a chosen screen that is gone, or no focus heard yet, is Automatic: the screen with
    /// the notch, else the first (P38, P941).
    static func resolve(_ screens: [IslandScreen], preferredID: String?, focusID: String? = nil) -> IslandScreen? {
        let wanted = preferredID == IslandDisplayChoice.followFocusID ? focusID : preferredID
        if let wanted, let preferred = screens.first(where: { $0.id == wanted }) { return preferred }
        return screens.first(where: \.hasNotch) ?? screens.first
    }
}

/// AppKit's global space (y up from the primary display's bottom) against the top-left space of CGEvent and
/// CGDisplay (y down from the primary display's top). The flip always uses the primary display, `NSScreen.screens[0]`,
/// never `NSScreen.main` (the key window's screen), so a display above or left of the primary lands right (P36).
enum ScreenSpace {
    static func topLeft(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKit(fromTopLeft rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func topLeft(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

/// The opened island's header in content coordinates (the island minus its 10 pt side padding: 444 pt wide at the
/// standard width, `IslandSize.contentWidth`), centred on the notch: nothing is drawn over the notch. Its two wings are
/// the only room beside it: the left one holds the brand glyph (and, in Header strip placement, the Claude pair), the
/// right one the Codex pair and the gear. A hover label spans both wings: its name ends at the notch on the left, its
/// details start after it on the right.
struct IslandHeaderLayout: Equatable, Sendable {
    /// The gap between a wing and the notch.
    static let slotGap: CGFloat = 4.5
    /// Each wing's outer padding.
    static let edgeInset: CGFloat = 4

    var notch: CGSize
    var contentWidth: CGFloat = IslandTheme.Metrics.contentWidth

    /// The notch's height + 2 (30 at least), so the wings line up with the menu bar beside the notch.
    var height: CGFloat { max(IslandTheme.Metrics.headerHeight, notch.height + 2) }
    var notchMinX: CGFloat { contentWidth / 2 - notch.width / 2 }
    var notchMaxX: CGFloat { contentWidth / 2 + notch.width / 2 }
    var notchRect: CGRect { CGRect(x: notchMinX, y: 0, width: notch.width, height: notch.height) }

    /// Left of the notch: x 4 → 125 with the reference notch.
    var leftSlot: CGRect {
        CGRect(x: Self.edgeInset, y: 0, width: max(0, notchMinX - Self.slotGap - Self.edgeInset), height: height)
    }

    /// Right of the notch: x 319 → 440 with the reference notch.
    var rightSlot: CGRect {
        let start = notchMaxX + Self.slotGap
        return CGRect(x: start, y: 0, width: max(0, contentWidth - Self.edgeInset - start), height: height)
    }
}
