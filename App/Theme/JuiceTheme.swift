import SwiftUI

/// Settings › Island › Theme: what the island, the desktop panel and the widget are made of. Black, the default, is the
/// pure black they always were, token for token (`IslandPalette.black` is `IslandTheme`'s own values, `PanelPalette.black`
/// `Theme`'s). Glass is the system's glass with no black of ours anywhere: no floor, no notch plate, no dark fills; the
/// content sits inside the glass (`inGlass`), so the glass's own light or dark adaptation reaches it, and every ink has
/// a light and a dark twin (`IslandPalette.glass`, P560 to P563). Smoke is the dark smoked glass Glass was until
/// 2026-09-29: the real glass under a dark floor heavy enough that every token keeps its contrast over any wallpaper or
/// window behind it, white included (P521, P522), the notch met by a black plate (P550). Solid is opaque, not glass: the
/// system's window background, light or dark with Settings › General › Appearance and tinted by the wallpaper as macOS
/// tints its own windows, in Glass's ink twins (P770 to P779).
///
/// Stored choices keep their word: "glass" (written by a build of the smoked glass) now reads as the Glass the owner
/// asked for, without black; "smoke" is new, and a build before it reads "smoke" as Black, as it does any word it does
/// not know (P564). "solid" is newer still, and an older build reads it as Black the same way.
///
/// A surface opts in by reading `\.juiceTheme` and drawing its surface with `themedSurface(_:style:)`; a view takes its
/// tokens from the theme it read (`private var palette: IslandPalette { theme.island }`, `theme.panel`), never from a
/// computed environment key, which SwiftUI reads again and compares, every colour of it, for each reading view whenever
/// anything in the environment changes (P559). The roots set the value from the setting (`juiceThemeFromSettings()`),
/// the widget from its snapshot (`WidgetSnapshot.juiceTheme`). A view that reads nothing stays black whatever the
/// setting says.
enum JuiceTheme: String, CaseIterable, Codable, Sendable {
    case black, glass, smoke, solid

    /// A stored or written choice; anything else (an older build's, a later build's) reads as Black.
    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .black }

    var title: String {
        switch self {
        case .black: "Black"
        case .glass: "Glass"
        case .smoke: "Smoke"
        case .solid: "Solid"
        }
    }

    /// Every theme but Black: the surface is not a colour of ours (a glass shows what is behind it; Solid is the system's
    /// window material, tinted by the wallpaper), so what used to paint the black to hide something (a cut, a cover, a
    /// fade) knocks it out instead (P526, P772).
    var knocksOut: Bool { self != .black }

    /// Glass and Solid: Glass's ink twins, each drawn in the look of Settings › General › Appearance (Glass: no floor,
    /// the content inside the system's glass, P560; Solid: the window material, P770). Black and Smoke are dark by name.
    var adapts: Bool { self == .glass || self == .solid }

    /// The island's, the rows' and the cards' tokens in this theme.
    var island: IslandPalette {
        switch self {
        case .black: .black
        case .glass, .solid: .glass
        case .smoke: .smoke
        }
    }

    /// Juice's own tokens (the desktop panel, the batteries, the money rows) in this theme.
    var panel: PanelPalette {
        switch self {
        case .black: .black
        case .glass, .solid: .glass
        case .smoke: .smoke
        }
    }
}

extension EnvironmentValues {
    /// The theme every surface under this view draws in. Black unless a root sets it (`juiceThemeFromSettings()`, the
    /// widget's entry view), so renders, previews and the window stay black until they ask.
    @Entry var juiceTheme: JuiceTheme = .black
}

extension View {
    /// Sets `\.juiceTheme` from Settings › Island › Theme, and the look's refinements with it: State tint
    /// (`\.islandStateTint`), Glass's Frost (`\.glassFrost`, `GlassLook`) and Glass look (`\.glassLook`, `GlassFace`); and
    /// Needs you colour (`\.needsYouColour`). It reads `AppEnvironment` from the
    /// environment, so it goes inside `.environment(env)`: `Root().juiceThemeFromSettings().environment(env)`. Observation
    /// follows those settings, so a new theme redraws the surface and nothing else changes it.
    func juiceThemeFromSettings() -> some View { modifier(JuiceThemeFromSettings()) }
}

private struct JuiceThemeFromSettings: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content
            .environment(\.juiceTheme, env.settings.juiceTheme)
            .environment(\.islandStateTint, env.settings.islandStateTint)
            .environment(\.glassFrost, env.settings.glassFrost)
            .environment(\.glassLook, env.settings.glassLook)
            .environment(\.needsYouColour, env.settings.needsYouColour)
    }
}
