import AppKit
import CoreGraphics

/// Settings › Island › Display (P940 to P944): Automatic (the screen with the notch, else the main one), Follow focus (the
/// screen with the active window), or one screen by its display UUID, which stays the same across reboots and replugs.
/// Stored in `AppSettings.islandDisplay`: nil, `followFocusID`, or the UUID, so a choice from an older build still reads.
enum IslandDisplayChoice: Hashable, Sendable {
    case automatic
    case followFocus
    case screen(String)

    /// Never a display UUID or a `display-<n>` id.
    static let followFocusID = "follow-focus"
    /// What the old pop-up's made-up screens stored (P943): no screen has these ids, so they read as Automatic.
    static let madeUpIDs: Set<String> = ["built-in", "studio"]

    /// The stored choice as this build reads it: a made-up screen from an older build is Automatic.
    static func reading(_ stored: String?) -> String? {
        stored.flatMap { madeUpIDs.contains($0) ? nil : $0 }
    }

    init(stored: String?) {
        switch stored {
        case nil: self = .automatic
        case Self.followFocusID?: self = .followFocus
        case let id?: self = .screen(id)
        }
    }

    var stored: String? {
        switch self {
        case .automatic: nil
        case .followFocus: Self.followFocusID
        case let .screen(id): id
        }
    }
}

/// A connected display as Settings lists it.
struct DisplayInfo: Equatable, Sendable {
    var id: String
    var name: String
}

/// The Display pop-up's list. Renders and tests list `fixture`; the app swaps in the connected screens at launch
/// (`AppDelegate`), so no render shows this Mac's display names and the app never shows made-up ones (P940).
@MainActor
enum IslandDisplays {
    static let fixture = [DisplayInfo(id: "built-in", name: "Built-in Display"), DisplayInfo(id: "studio", name: "Studio Display")]
    static var provider: @MainActor () -> [DisplayInfo] = { fixture }

    static func connected() -> [DisplayInfo] { provider() }

    /// This Mac's screens, the primary first, by the names macOS gives them.
    static func live() -> [DisplayInfo] {
        NSScreen.screens.map { DisplayInfo(id: IslandScreen.displayID(of: $0), name: $0.localizedName) }
    }

    /// Automatic, Follow focus, then each screen by name (a second screen of the same name numbered "2"), then a chosen
    /// screen that is not connected now, so the choice still shows (the island is on Automatic's screen meanwhile, P944).
    static func choices(_ displays: [DisplayInfo], stored: String?) -> [(String?, String)] {
        var options: [(String?, String)] = [(nil, "Automatic"), (IslandDisplayChoice.followFocusID, "Follow focus")]
        var seen: [String: Int] = [:]
        for display in displays {
            let count = (seen[display.name] ?? 0) + 1
            seen[display.name] = count
            options.append((display.id, count == 1 ? display.name : "\(display.name) \(count)"))
        }
        if case let .screen(id) = IslandDisplayChoice(stored: stored), !displays.contains(where: { $0.id == id }) {
            options.append((id, "Display not connected"))
        }
        return options
    }

    /// The row's one line, where the choice needs one.
    static func subtitle(_ displays: [DisplayInfo], stored: String?) -> String? {
        switch IslandDisplayChoice(stored: stored) {
        case .automatic: nil
        case .followFocus: "The screen with the active window."
        case let .screen(id): displays.contains { $0.id == id } ? nil : "On Automatic until it is back."
        }
    }

    /// The row shows only with two screens or more, or while a chosen screen is away.
    static func showsRow(_ displays: [DisplayInfo], stored: String?) -> Bool {
        displays.count > 1 || IslandDisplayChoice(stored: stored) != .automatic
    }
}

/// Which screen holds the active window (Follow focus, P941): the frontmost app's frontmost normal window, from what the
/// window server lists of the windows on screen (owner, level, bounds and alpha, which need no permission; titles are
/// never read), on the screen that holds most of it. nil when the app shows no such window (the island stays put).
enum FocusScreenProbe {
    /// Smaller than this on either side is a palette or a helper's window, not where the owner works.
    static let minimumSide: CGFloat = 64

    static func screenID(frontmost: pid_t?, windows: [FullScreenProbe.Window], screens: [IslandScreen],
                         primaryHeight: CGFloat) -> String? {
        guard let frontmost,
              let window = windows.first(where: {
                  $0.pid == frontmost && $0.layer == 0 && $0.alpha > 0
                      && $0.bounds.width >= minimumSide && $0.bounds.height >= minimumSide
              }) else { return nil }
        var best: (id: String, area: CGFloat)?
        for screen in screens {
            let shared = FullScreenProbe.cgFrame(of: screen, primaryHeight: primaryHeight).intersection(window.bounds)
            guard !shared.isNull else { continue }
            let area = shared.width * shared.height
            if area > (best?.area ?? 0) { best = (screen.id, area) }
        }
        return best?.id
    }

    /// Where Follow focus puts the island (P942): the screen `heard` (the active window's), unless the island is `held`
    /// (open, or the pointer on it) on a screen still connected, so it never moves out from under the owner; it follows at the fold
    /// or when the pointer leaves. Before any window is heard, the island stays on `current`.
    static func target(heard: String?, current: String?, held: Bool, screens: [IslandScreen]) -> String? {
        if let current, held, screens.contains(where: { $0.id == current }) { return current }
        return heard ?? current
    }

    /// This Mac's answer now.
    @MainActor static func now() -> String? {
        let screens = NSScreen.screens.map(IslandScreen.init)
        return screenID(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, windows: FullScreenProbe.onScreenWindows(),
                        screens: screens, primaryHeight: screens.first?.frame.height ?? 0)
    }
}

/// Hears when the active window may have gone to another screen (P941): an app became active, the active Space changed,
/// or the displays changed. Each notice reads `probe` at once and once more `settle` later, when a Space's slide has
/// ended, as `FullScreenWatch` does. Notifications only, never an event monitor or tap; nothing polls, and the island
/// makes one only while Follow focus is chosen. A window moved to another screen inside the same app is heard at the
/// next of these notices.
@MainActor
final class FocusScreenWatch {
    private(set) var screenID: String?
    private let probe: @MainActor () -> String?
    private let changed: @MainActor (String?) -> Void
    private let settle: TimeInterval?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var again: StrictTimer?

    /// `settle` nil reads each notice once only.
    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter, local: NotificationCenter = .default,
         settle: TimeInterval? = FullScreenWatch.settle, probe: @escaping @MainActor () -> String?,
         changed: @escaping @MainActor (String?) -> Void) {
        self.probe = probe
        self.changed = changed
        self.settle = settle
        screenID = probe()
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

    func noticed() {
        check()
        guard let settle else { return }
        again?.cancel()
        again = StrictTimer(after: settle) { [weak self] in
            self?.again = nil
            self?.check()
        }
    }

    /// Reads the probe; a window on no screen we know, or none, keeps the last answer.
    func check() {
        guard let now = probe(), now != screenID else { return }
        screenID = now
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
