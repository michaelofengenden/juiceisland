import AppKit
import Observation
import SwiftUI

// Glass look Widget follows macOS's desktop widgets (the owner's "widget setting look doesn't actually look like the glass
// of the widget at all" of 2026-10-03; P1204 to P1212). macOS draws a desktop widget in one of two looks: full colour while
// the desktop is in front (Finder is the frontmost app), and dimmed, its content tinted white on a deeper glass, while
// another app is (Apple Support, "Add and customize widgets on Mac": System Settings › Desktop & Dock › Dim widgets on
// desktop, Automatically, Always or Never; WWDC25 "What's new in widgets": accented rendering). Both are readable without
// any permission: the frontmost app from `NSWorkspace`, the setting from macOS's own preferences
// (`com.apple.widgets` › `widgetAppearance`). So the desktop panel and its chip, which sit on the wallpaper beside the
// widgets, take the widgets' look of the moment; the island, which hangs over the apps' windows and moves, keeps Widget
// as it was, the ground that holds its ink over a white window. Nothing is sampled and nothing polls.

/// Where Glass look Widget draws, and so its ground: on the desktop in one of macOS's two desktop-widget looks, or over
/// the apps' windows.
enum WidgetGlassState: String, Sendable {
    /// On the desktop, the desktop in front: the widgets in full colour. The regular glass's dark face with nothing of
    /// ours inside it, the wallpaper's own colour (the closest public glass to the widgets', P1205), white ink lifted by
    /// a soft shadow (`WidgetInkLift`, P1206); Frost lays the dark ground only as far as the owner asks.
    case fullColour
    /// On the desktop, an app in front: the widgets dimmed. The same glass a tenth deeper
    /// (`GlassFrost.widgetDimmedFloor`), the wallpaper's colour still through it, the same lifted ink (P1214).
    case dimmed
    /// Over the apps' windows: the island, and whatever does not say (the Settings preview, the renders). Widget as it
    /// was (P870 to P879): the dark face under Frost's dark ground from its floor, which holds white ink over a white
    /// window (P874).
    case overApps

    /// On the desktop beside the widgets (the panel and its chip), in either of their looks.
    var onDesktop: Bool { self != .overApps }
}

extension EnvironmentValues {
    /// Where Glass look Widget draws. Over the apps unless a root sets it (the desktop panel's, from
    /// `DesktopWidgetWatch`; its chip at each show), so the island, the Settings preview and every render stay as they were.
    @Entry var widgetGlassState: WidgetGlassState = .overApps
}

/// System Settings › Desktop & Dock › Dim widgets on desktop, as macOS keeps it: `widgetAppearance` in the
/// `com.apple.widgets` domain, written only once the owner picks one (absent, it is Automatically). System Settings' own
/// type for it has the cases recessed, original and automatic, in that order, with integer raw values (P1208).
enum DimWidgetsSetting: Equatable, Sendable {
    /// Monochrome while an app is in front, full colour while the desktop is (macOS's default).
    case automatically
    /// Always dimmed (`recessed`).
    case always
    /// Never dimmed: always full colour (`original`).
    case never

    static let domain = "com.apple.widgets"
    static let key = "widgetAppearance"

    /// A stored value: 0 recessed (Always), 1 original (Never), 2 automatic; the case's name as a word too. Anything
    /// else, or nothing, is Automatically, the system's default.
    init(stored: Any?) {
        switch stored {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            self = [0: .always, 1: .never][number.intValue] ?? .automatically
        case let word as String:
            self = ["recessed": .always, "original": .never][word.lowercased()] ?? .automatically
        default:
            self = .automatically
        }
    }

    /// The owner's setting now. A read of macOS's own preferences (no permission, no file opened by us), synchronised
    /// first so a change made in System Settings since the last read is seen.
    static func read() -> DimWidgetsSetting {
        CFPreferencesAppSynchronize(domain as CFString)
        return DimWidgetsSetting(stored: CFPreferencesCopyAppValue(key as CFString, domain as CFString))
    }
}

/// The desktop widgets' look now, as macOS chooses it.
enum DesktopWidgets {
    /// The app whose being in front is the desktop being in front.
    static let finder = "com.apple.finder"

    /// The widgets' look with `frontmost` in front under `setting`.
    static func state(frontmost: String?, setting: DimWidgetsSetting) -> WidgetGlassState {
        switch setting {
        case .always: .dimmed
        case .never: .fullColour
        case .automatically: frontmost == finder ? .fullColour : .dimmed
        }
    }
}

/// Follows the desktop widgets' look for the desktop panel: `NSWorkspace`'s notice that an app became active (the
/// window's own kind of notice, like `WindowAttentionWatch`'s; no event monitor, nothing polls), at which it reads the
/// frontmost app and Dim widgets on desktop again. `state` changes only when the look does, so the panel redraws once
/// per switch between the desktop and an app, and never for a switch between two apps.
@MainActor
@Observable
final class DesktopWidgetWatch {
    private(set) var state: WidgetGlassState
    @ObservationIgnored private let frontmost: @MainActor () -> String?
    @ObservationIgnored private let setting: @MainActor () -> DimWidgetsSetting
    @ObservationIgnored private var observer: (NotificationCenter, NSObjectProtocol)?

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmost: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         setting: @escaping @MainActor () -> DimWidgetsSetting = DimWidgetsSetting.read) {
        self.frontmost = frontmost
        self.setting = setting
        state = DesktopWidgets.state(frontmost: frontmost(), setting: setting())
        let token = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observer = (workspace, token)
    }

    /// Reads the frontmost app and the setting again; `state` moves only if the look did.
    func refresh() {
        let now = DesktopWidgets.state(frontmost: frontmost(), setting: setting())
        if now != state { state = now }
    }

    func stop() {
        if let (center, token) = observer { center.removeObserver(token) }
        observer = nil
    }
}

/// Glass look Widget's ink on the desktop (P1206, P1214): the glass has no ground of ours there in full colour and only a
/// tenth dimmed, so over a pale wallpaper its dark face is a light grey (#B4B2AF over #F7F5F2), where white alone is
/// 2.1:1. macOS lifts the white words and icons
/// on its desktop (the icons' labels) with a soft dark shadow; the panel's ink takes one too: a tight shadow that edges
/// each stroke and a wider, fainter one that darkens the ground just around it. Only the ink casts it, never a veil:
/// the shadow is cast by a copy of the content drawn under it with its veils left out (`\.inkShadowPass`: a battery's
/// track, a stale fill, the divider), so no grey gathers under them, and a knocked-out digit's hole casts nothing, so
/// the fill's shadow falls into it and deepens it. The copy takes no pointer and says nothing to VoiceOver; the opaque
/// ink over it hides it. Over the owner's lavender it reads as the widgets' depth; over a pale wallpaper the white
/// holds 4.8:1 against the ground half a point to a point off each stroke over #B4B4B4, where the bare white is 2.1:1
/// (`WidgetFullColourTests.theLiftedInkHoldsOverThePalestGlass`). Over the apps (the island) and Light and dark draw
/// none of it, pixel for pixel as before.
struct WidgetInkLift: ViewModifier {
    @Environment(\.glassLook) private var glassLook
    @Environment(\.widgetGlassState) private var widgetState

    /// The tight shadow and the wide one: black at `opacity`, blurred over `radius`, `y` down.
    static let tight = (opacity: 0.9, radius: 0.8 as CGFloat, y: 0.3 as CGFloat)
    static let wide = (opacity: 0.45, radius: 2.6 as CGFloat, y: 0.6 as CGFloat)

    func body(content: Content) -> some View {
        if glassLook == .widget, widgetState.onDesktop {
            content.background {
                content
                    .environment(\.inkShadowPass, true)
                    .environment(\.hoverReporter) { _ in }
                    .compositingGroup()
                    .shadow(color: .black.opacity(Self.tight.opacity), radius: Self.tight.radius, y: Self.tight.y)
                    .shadow(color: .black.opacity(Self.wide.opacity), radius: Self.wide.radius, y: Self.wide.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Drawing `WidgetInkLift`'s copy, the one that casts the ink's shadow: veils (a battery's track, a stale fill, the
    /// divider) draw nothing there. False everywhere else.
    @Entry var inkShadowPass = false
}
