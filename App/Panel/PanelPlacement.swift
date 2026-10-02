import AppKit

/// A display as the desktop panel sees it: plain values, so placement is testable without real screens.
struct PanelScreen: Equatable, Sendable {
    /// The display's UUID (the same display after a reboot or a replug), else its number.
    var id: String
    var name: String
    /// AppKit global coordinates.
    var frame: CGRect
    /// Below the menu bar and above the Dock.
    var visibleFrame: CGRect
}

extension PanelScreen {
    @MainActor init(_ screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        var id = number.map { "display-\($0.uint32Value)" } ?? screen.localizedName
        if let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            id = text
        }
        self.init(id: id, name: screen.localizedName, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// The connected displays, the primary one first.
    @MainActor static func connected() -> [PanelScreen] { NSScreen.screens.map(PanelScreen.init) }
}

/// Settings › Desktop Panel › Corner: where the panel starts, and where Reset Position puts it back.
enum PanelCorner: String, CaseIterable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft

    var title: String {
        switch self {
        case .bottomRight: "Bottom right"
        case .bottomLeft: "Bottom left"
        case .topRight: "Top right"
        case .topLeft: "Top left"
        }
    }
}

/// Where the panel sits (Juice spec §2.6): 24 pt inside the usable area of its display, in the chosen corner, until the
/// owner drags it; then where it was left, per display. It moves to the primary display only while its own display is
/// gone, and it is always whole on one display.
enum PanelPlacement {
    static let edgeInset: CGFloat = 24

    static func defaultOrigin(corner: PanelCorner, panelSize: CGSize, visible v: CGRect) -> CGPoint {
        let left = v.minX + edgeInset, right = v.maxX - edgeInset - panelSize.width
        let bottom = v.minY + edgeInset, top = v.maxY - edgeInset - panelSize.height
        switch corner {
        case .bottomRight: return CGPoint(x: right, y: bottom)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .topRight: return CGPoint(x: right, y: top)
        case .topLeft: return CGPoint(x: left, y: top)
        }
    }

    /// Keeps the whole panel inside the usable area.
    static func clamp(_ origin: CGPoint, panelSize: CGSize, visible v: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, v.minX), v.maxX - panelSize.width),
                y: min(max(origin.y, v.minY), v.maxY - panelSize.height))
    }

    /// P38: the chosen display while it is connected, else the primary display; nil with no display at all.
    static func resolve(_ screens: [PanelScreen], preferredID: String?) -> PanelScreen? {
        if let preferredID, let preferred = screens.first(where: { $0.id == preferredID }) { return preferred }
        return screens.first
    }

    /// The display a frame covers most of (a drag can leave the panel hanging over an edge); nil when it covers none.
    static func screen(bestFor frame: CGRect, in screens: [PanelScreen]) -> PanelScreen? {
        func overlap(_ screen: PanelScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
        return best
    }

    /// The origin of a panel that changes size: it keeps its bottom edge in the lower half of the screen and its top
    /// edge in the upper half, so it grows away from the screen edge it sits against.
    static func origin(keeping frame: CGRect, newSize: CGSize, visible v: CGRect) -> CGPoint {
        frame.midY > v.midY ? CGPoint(x: frame.minX, y: frame.maxY - newSize.height) : frame.origin
    }

    /// Where the panel belongs now: on the resolved display, at the frame saved for it (adjusted to the panel's size),
    /// else in the corner; always whole on that display. nil with no display.
    @MainActor
    static func desiredFrame(panelSize: CGSize, screens: [PanelScreen], preferredID: String?, corner: PanelCorner,
                             store: PanelPositionStore) -> CGRect? {
        guard let screen = resolve(screens, preferredID: preferredID) else { return nil }
        let v = screen.visibleFrame
        let start = store.frame(for: screen.id).map { origin(keeping: $0, newSize: panelSize, visible: v) }
            ?? defaultOrigin(corner: corner, panelSize: panelSize, visible: v)
        return CGRect(origin: clamp(start, panelSize: panelSize, visible: v), size: panelSize)
    }
}

/// The panel's frame per display, where the owner last left it (`ji.panel.frame.<display id>`). Only a drag saves one;
/// Reset Position and a new corner forget them. `defaults` nil keeps them in memory (tests).
@MainActor
final class PanelPositionStore {
    private let defaults: UserDefaults?
    private var memory: [String: CGRect] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    static func key(_ displayID: String) -> String { "ji.panel.frame." + displayID }
    private static let prefix = "ji.panel.frame."

    func frame(for displayID: String) -> CGRect? {
        guard let defaults else { return memory[displayID] }
        guard let text = defaults.string(forKey: Self.key(displayID)) else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    func save(_ frame: CGRect, for displayID: String) {
        guard let defaults else { memory[displayID] = frame; return }
        let text = [frame.minX, frame.minY, frame.width, frame.height].map { "\(Double($0))" }.joined(separator: ",")
        defaults.set(text, forKey: Self.key(displayID))
    }

    func forget(_ displayID: String) {
        memory[displayID] = nil
        defaults?.removeObject(forKey: Self.key(displayID))
    }

    func forgetAll() {
        memory.removeAll()
        guard let defaults else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) { defaults.removeObject(forKey: key) }
    }
}

/// Settings › Desktop Panel › Display. Renders and tests list the fixture names; the app's panel controller swaps in
/// the connected displays when it starts, so no render ever shows this Mac's display names.
@MainActor
enum PanelDisplays {
    static var provider: @MainActor () -> [(String?, String)] = { DisplayChoices.panel }

    static func choices() -> [(String?, String)] { provider() }

    /// The pop-up's value: the chosen display while it is listed, else the first (the primary display, where the
    /// panel actually is).
    static func selection(stored: String?, in choices: [(String?, String)]) -> String? {
        choices.contains { $0.0 == stored } ? stored : (choices.first?.0 ?? stored)
    }
}
