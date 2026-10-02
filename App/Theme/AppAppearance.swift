import AppKit
import SwiftUI

/// Settings › General › Appearance (P760 to P769): System follows macOS's light or dark mode, live; Light and Dark pin
/// it. Dark is today's look exactly. Settings follows it in every theme. On Glass and Solid the window, the island, the
/// desktop panel, its chip and the usage overlay follow it too, the glass included: Glass's look is the Appearance's,
/// never the wallpaper's or the menu bar's behind it (P764), unless Glass look is Widget, which keeps Glass's island,
/// panel and chip dark in both (P870). Black and Smoke stay dark: the closed pill meets the black
/// hardware notch, and those themes are dark by name (P760).
enum AppearanceChoice: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The app's own appearance: none for System (macOS's, which AppKit hands every window live), or the pinned one.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    var nsAppearance: NSAppearance? { appearanceName.flatMap(NSAppearance.init(named:)) }

    /// The look this choice gives where macOS's mode is `system`.
    func scheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: system
        case .light: .light
        case .dark: .dark
        }
    }
}

extension NSAppearance {
    /// Light or dark, as SwiftUI names it (the high-contrast and vibrant variants count as their base).
    var colorScheme: ColorScheme { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light }

    /// The appearance AppKit draws `scheme` in.
    static func named(_ scheme: ColorScheme) -> NSAppearance? { NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) }
}

/// Puts Settings › General › Appearance on the app (`NSApp.appearance`). Every window and view that sets none of its
/// own inherits it, and SwiftUI takes its colour scheme from that: the system's own propagation, so a change of macOS's
/// mode (System) or of the setting reaches every open surface at once, with nothing polled and nothing ticking (P766).
/// It acts only when the setting changes. `target` is the app, or a stand-in for it in tests.
@MainActor
final class AppAppearance {
    private let settings: AppSettings
    private let target: any NSAppearanceCustomization

    init(settings: AppSettings, target: any NSAppearanceCustomization) {
        self.settings = settings
        self.target = target
        apply()
        observe()
    }

    /// The setting's appearance on the target, when it is not there yet.
    func apply() {
        let wanted = settings.appearance.nsAppearance
        if target.appearance?.name != wanted?.name { target.appearance = wanted }
    }

    private func observe() {
        withObservationTracking {
            _ = settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
    }
}

extension JuiceTheme {
    /// The tokens for a view on an opaque ground of ours that follows the Appearance (the window on Glass and Solid, and
    /// what floats over it), in `scheme`: Black's where it is dark, exactly as they always were; Solid's (Glass's light
    /// twins, the keys as Black draws them, no glass of their own) where it is light, which hold their ratios on the light
    /// glass's worst surface (#BFBFBF) and so on any lighter ground (P762).
    static func opaque(_ scheme: ColorScheme) -> JuiceTheme { scheme == .light ? .solid : .black }
}

/// The app window's look (Window mode) and what floats over it (the account list, the usage chip), P762: on Glass and
/// Solid the Appearance's look, its rows and cards in `JuiceTheme.opaque`; on Black and Smoke the dark look it always
/// had. The window is the same on Glass and Solid: white where it is light, today's black where it is dark.
enum WindowLook {
    /// The window's own appearance: none on Glass and Solid (the app's, the Appearance), dark on Black and Smoke.
    static func appearance(_ theme: JuiceTheme) -> NSAppearance? { theme.adapts ? nil : NSAppearance(named: .darkAqua) }

    /// The look the window takes with `theme`, where the app's appearance is `app`.
    static func scheme(_ theme: JuiceTheme, app: ColorScheme) -> ColorScheme { theme.adapts ? app : .dark }

    /// The tokens the window's views read with `theme` in `scheme`.
    static func tokens(_ theme: JuiceTheme, scheme: ColorScheme) -> JuiceTheme {
        theme.adapts ? JuiceTheme.opaque(scheme) : .black
    }

    /// The window's own background, which shows where SwiftUI has not drawn yet: black, or white where it is light.
    static func background(_ theme: JuiceTheme) -> NSColor { theme.adapts ? .adaptive(light: .white, dark: .black) : .black }
}

extension View {
    /// The window's look from Settings (`WindowLook`): on Glass and Solid, the look of the window it is in (the
    /// Appearance), its tokens `JuiceTheme.opaque` of it; on Black and Smoke, the dark scheme and Black's tokens, as it
    /// always was; and Needs you colour (`\.needsYouColour`). Goes inside `.environment(env)`.
    func windowLookFromSettings() -> some View { modifier(WindowLookFromSettings()) }
}

extension View {
    /// `\.juiceTheme` from the colour scheme this view is drawn in (`JuiceTheme.opaque`): the tokens of the shared
    /// views (a battery, the hook lines) on an opaque ground that follows the Appearance in every theme (Settings).
    func opaqueTokensForLook() -> some View { modifier(OpaqueTokensForLook()) }
}

private struct OpaqueTokensForLook: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View { content.environment(\.juiceTheme, JuiceTheme.opaque(scheme)) }
}

private struct WindowLookFromSettings: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = env.settings.juiceTheme
        let look = WindowLook.scheme(theme, app: scheme)
        content
            .environment(\.juiceTheme, WindowLook.tokens(theme, scheme: look))
            .environment(\.colorScheme, look)
            .environment(\.needsYouColour, env.settings.needsYouColour)
    }
}

extension NSColor {
    /// A colour AppKit resolves in the appearance it draws in: `light` where it is light, `dark` where it is dark (a
    /// window's background, which shows where SwiftUI has not drawn yet).
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.colorScheme == .dark ? dark : light }
    }
}
