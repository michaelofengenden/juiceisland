import AppKit
import CoreGraphics
import Observation

/// What else quiets the island beside the clock, the lock, full screen and a snooze (P1004 to P1007): the screen mirrored
/// onto another display, and a Focus whose filter says Quiet. Either holds attention as Quiet hours do (`QuietMode`): no
/// sounds, and nothing opens the island by itself; the pill still shows what waits.
struct QuietScene: Equatable, Sendable {
    /// A display is in a mirror set now (`DisplayMirroring`); it quiets only with Quiet while presenting on.
    var mirrored = false
    /// A Focus is on whose filter for this app says Quiet (`FocusFilterState`).
    var focus = false

    static let none = QuietScene()
}

/// The app's scenes, read at the moment a sound, a card, a reminder or a banner would come (never on a timer, never
/// observed): the display list only while Quiet while presenting is on, the Focus filter's last word always. Renders,
/// tests and the demo have none (`QuietScene.none`).
@MainActor
final class QuietScenes {
    private let settings: AppSettings
    private let focus: FocusFilterState
    private let mirrored: @MainActor () -> Bool

    init(settings: AppSettings, focus: FocusFilterState = .shared, mirrored: @escaping @MainActor () -> Bool = DisplayMirroring.isMirrored) {
        self.settings = settings
        self.focus = focus
        self.mirrored = mirrored
    }

    func now() -> QuietScene {
        QuietScene(mirrored: settings.quietWhilePresenting && mirrored(), focus: focus.quiet)
    }

    /// A Focus with the filter quiets the island now: Settings says so under Quiet during Focus.
    var focusQuiet: Bool { focus.quiet }
}

/// System Settings › Focus, where a Focus's filters are set: opened only on the owner's click.
@MainActor
enum FocusSettings {
    static let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")

    static func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Quiet while presenting (P1005): whether any display online is in a mirror set, as when the screen is mirrored to a
/// projector, to a TV over AirPlay or to a Sidecar iPad. Public CoreGraphics (`CGGetOnlineDisplayList`,
/// `CGDisplayIsInMirrorSet`), no permission; it reads the display configuration only, never what is on a screen. One
/// display, or any doubt, is not mirrored: it fails open, to the island as it is without the switch.
enum DisplayMirroring {
    static let maxDisplays: UInt32 = 32

    @MainActor static func isMirrored() -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        guard CGGetOnlineDisplayList(maxDisplays, &ids, &count) == .success else { return false }
        return anyMirrored(Array(ids.prefix(Int(count)))) { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// Two displays or more, one of them in a mirror set.
    static func anyMirrored(_ displays: [CGDirectDisplayID], inMirrorSet: (CGDirectDisplayID) -> Bool) -> Bool {
        displays.count > 1 && displays.contains(where: inMirrorSet)
    }
}

/// What the app's Focus filter last said (P1006, P1007). The filter (`QuietFocusFilter`, in the app targets: the one
/// public way an app hears a Focus without the Communication Notifications entitlement, `SetFocusFilterIntent`) is added
/// by the owner to a Focus in System Settings › Focus, with Quiet on. macOS calls its `perform()` with Quiet on when that
/// Focus turns on, and with its default (off) when it ends; at launch the app asks for the filter in force
/// (`launchRead`). Memory only: nothing is stored, and a Focus macOS never reports leaves the island as it is (fails
/// open).
@MainActor
@Observable
public final class FocusFilterState {
    public static let shared = FocusFilterState()

    /// A Focus with the filter, Quiet on, is on now.
    public private(set) var quiet = false
    /// The filter spoke since launch: the launch read is older and gives way.
    @ObservationIgnored private var heard = false

    public init() {}

    /// The filter's `perform()`: macOS's word of now.
    public func apply(quiet: Bool) {
        heard = true
        self.quiet = quiet
    }

    /// The launch's read of the filter in force (`QuietFocusFilter.current`), unless `perform()` came first.
    public func launchRead(quiet: Bool) {
        guard !heard else { return }
        self.quiet = quiet
    }
}
