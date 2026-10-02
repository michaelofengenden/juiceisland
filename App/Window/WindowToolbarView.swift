import SwiftUI

/// The toolbar line, in the title bar on the traffic lights' line: the brand glyph and the Demo/Live badge after the
/// lights, then (when there is no room for the usage on this line) nothing but the trailing buttons: Update (only when
/// newer commits exist), Show as island, the gear. The usage header puts the batteries between the two ends when
/// they fit (`UsageHeaderView`). Owner: stream A.
struct WindowToolbarView: View {
    /// Headless renders draw the traffic lights; the real window shows AppKit's own in the same place.
    var drawsTrafficLights = false
    @Environment(\.windowChrome) private var chrome

    init(drawsTrafficLights: Bool = false) {
        self.drawsTrafficLights = drawsTrafficLights
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolbarLeading(drawsTrafficLights: drawsTrafficLights)
            Spacer(minLength: 16)
            ToolbarTrailing()
        }
        .frame(height: chrome.lineHeight)
        .background(TitleLineDragArea())
    }
}

/// The line's leading end: room for the traffic lights, the brand glyph, the Demo/Live badge. The glyph takes the
/// window's look as the island's does: Black's glow where it is dark, Glass's finish (the orange at full strength inside
/// its edge) where it is light (P762).
struct ToolbarLeading: View {
    var drawsTrafficLights = false
    @Environment(\.windowChrome) private var chrome
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            PixelGlyphView(glyph: .brand, colour: IslandTheme.brand, pixel: 2, animated: false, finish: GlyphFinish(theme))
                .help(Product.name)
                .accessibilityLabel(Product.name)
            SessionSourceBadge(quietLive: true)
        }
        .padding(.leading, chrome.contentLeading)
        .overlay(alignment: .leading) {
            if drawsTrafficLights { TrafficLightsPreview(diameter: 14, gap: 9).padding(.leading, chrome.lightsLeading) }
        }
    }
}

/// The line's trailing end: Update (only while there is one), Show as island (⌘⇧I), and the gear, whose menu is the
/// island's (`GearMenu`): Mute Sounds, the snooze, Settings… and Quit.
struct ToolbarTrailing: View {
    @Environment(AppEnvironment.self) private var env
    @State private var menuActions = MenuActions()

    var body: some View {
        HStack(spacing: 2) {
            UpdateToolbarButton().padding(.trailing, 6)
            ToolbarIconButton(help: ToolbarText.showAsIsland) {
                env.actions.setShowAs(.island)
            } label: {
                SVGIcon(svg: ChromeIcon.notch, size: CGSize(width: 17, height: 12), colour: WindowTheme.iconButton)
            }
            ToolbarIconButton(help: ToolbarText.gear) {
                GearMenu.popUp(env: env, showing: .window, actions: menuActions)
            } label: {
                CogIcon(size: 15, colour: WindowTheme.iconButton)
            }
        }
        .padding(.trailing, WindowTheme.Metrics.toolbarTrailing)
    }
}

/// A 30 × 30 icon button (radius 8, `#B3B3B3`; hover or expanded `#141414`).
struct ToolbarIconButton<Label: View>: View {
    let help: String
    var expanded = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: WindowTheme.Metrics.iconButton, height: WindowTheme.Metrics.iconButton)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering || expanded ? WindowTheme.iconButtonHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Toolbar words (tooltips only; the line itself has no text but the Demo/Live badge and an update's step).
enum ToolbarText {
    static let showAsIsland = "Show as island  ⌘⇧I"
    /// The island's gear says the same.
    static let gear = "Settings"
}
