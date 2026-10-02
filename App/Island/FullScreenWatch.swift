import AppKit
import CoreGraphics

/// Whether the frontmost app is in full screen on the island's display (P330), from what the window server lists of the
/// windows on screen: each one's owner, level and bounds, which need no permission (their titles would, and are never
/// read). Full screen is a normal-level window of the frontmost app across the display's whole width, down to its bottom
/// edge, and up to its top edge, or on a display with a notch up to the notch's lower edge (macOS keeps a full-screen app
/// below the camera housing unless the app asks otherwise). A zoomed window stops at the menu bar's lower edge, which is
/// lower than the notch's, and above the Dock when it shows, so it never counts; where the menu bar is no taller than the
/// notch, a window stopping there is left out too, so the pill shows rather than hides when in doubt.
enum FullScreenProbe {
    /// One on-screen window as the window server lists it. `bounds` are Core Graphics' global coordinates: y down from
    /// the top of the primary display.
    struct Window: Equatable, Sendable {
        var pid: pid_t
        var layer: Int
        var bounds: CGRect
        var alpha: Double = 1
    }

    /// Edges within this of each other meet.
    static let slop: CGFloat = 1

    /// `screen` (AppKit's coordinates) in Core Graphics' coordinates, the primary display `primaryHeight` tall.
    static func cgFrame(of screen: IslandScreen, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    static func isFullScreen(frontmost: pid_t?, windows: [Window], screen: IslandScreen, primaryHeight: CGFloat) -> Bool {
        guard let frontmost else { return false }
        let display = cgFrame(of: screen, primaryHeight: primaryHeight)
        return windows.contains { window in
            window.pid == frontmost && window.layer == 0 && window.alpha > 0
                && abs(window.bounds.minX - display.minX) <= slop && abs(window.bounds.maxX - display.maxX) <= slop
                && abs(window.bounds.maxY - display.maxY) <= slop
                && reachesTop(inset: window.bounds.minY - display.minY, screen: screen)
        }
    }

    /// A window whose top edge is `inset` below the display's reaches as high as a full-screen one does.
    static func reachesTop(inset: CGFloat, screen: IslandScreen) -> Bool {
        // Over the menu bar's row: only full screen (or a menu bar the owner hides) gets there.
        if inset <= 0.5 { return true }
        guard screen.safeAreaTop > 0, inset <= screen.safeAreaTop + 0.5 else { return false }
        // Down to the notch's lower edge: full screen, unless a zoomed window reaches as high (a menu bar that is no
        // taller than the notch). With the menu bar hidden, it is not in the way.
        guard let menuBar = screen.menuBarHeight else { return true }
        return inset < menuBar - 0.5
    }

    /// The windows on screen now, front to back: owner, level, bounds and alpha only.
    static func onScreenWindows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer] as? NSNumber)?.intValue,
                  let dictionary = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return Window(pid: pid, layer: layer, bounds: bounds, alpha: (info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1)
        }
    }
}

/// Hears when full screen on the island's display may have begun or ended (P330): an app became active, the active Space
/// changed (entering and leaving full screen both move to another Space), or the displays changed. Each notice reads
/// `probe` at once and once more `settle` later, when the Space's slide has ended and the window server lists its
/// windows where they rest. Notifications only, never an event monitor or tap; nothing polls, and nothing runs while
/// Hide in full screen is off (the island makes a watch only while it is on). Tests hand it centers of their own.
@MainActor
final class FullScreenWatch {
    /// How long after a notice the probe is read again.
    static let settle: TimeInterval = 0.6

    private(set) var isFullScreen: Bool
    private let probe: @MainActor () -> Bool
    private let changed: @MainActor (Bool) -> Void
    private let settle: TimeInterval?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var again: StrictTimer?

    /// `settle` nil reads each notice once only.
    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter, local: NotificationCenter = .default,
         settle: TimeInterval? = FullScreenWatch.settle, probe: @escaping @MainActor () -> Bool,
         changed: @escaping @MainActor (Bool) -> Void) {
        self.probe = probe
        self.changed = changed
        self.settle = settle
        isFullScreen = probe()
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noticed() }
            }
            observers.append((workspace, observer))
        }
        let screens = local.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noticed() }
        }
        observers.append((local, screens))
    }

    /// A notice: the probe now, and once more when things have settled (a later notice starts that wait again).
    func noticed() {
        check()
        guard let settle else { return }
        again?.cancel()
        again = StrictTimer(after: settle) { [weak self] in
            self?.again = nil
            self?.check()
        }
    }

    /// Reads the probe, and says so when the answer changed.
    func check() {
        let now = probe()
        guard now != isFullScreen else { return }
        isFullScreen = now
        changed(now)
    }

    func stop() {
        again?.cancel()
        again = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    isolated deinit { stop() }
}
