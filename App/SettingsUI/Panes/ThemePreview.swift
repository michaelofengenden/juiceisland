import SwiftUI

/// Theme's live preview, under its choice (as Glyph style's): a closed pill hanging over a slice of wallpaper, in the
/// chosen theme, holding an approval's "!" (in Needs you colour), a running glyph and a count, so the glass, the state
/// colours and the ink can be seen on it; with State tint on, in the approval's tint (Glass's and Solid's veil, Black's edge), and in
/// Glass's Frost. Glass and Solid show the look they take now, Settings › General › Appearance's (Settings' own), and
/// Glass under Glass look Widget the widgets' dark one; Black and Smoke are dark (P779, P870). The glass is the real one (it blurs the wallpaper drawn under it in this window), and
/// Solid the window material; a render draws the stand-ins. Its glyphs stand still. No labels.
struct ThemePreview: View {
    var theme: JuiceTheme
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 168, height: 44)
    static let pill = CGSize(width: 96, height: 26)

    /// The look the island takes in `theme` (and Glass look `glass`) while Settings is in `scheme` (the Appearance's):
    /// Glass under Widget dark whatever Settings is (P870).
    static func look(_ theme: JuiceTheme, glass: GlassLookChoice = .lightAndDark, settings scheme: ColorScheme) -> ColorScheme {
        theme == .glass ? glass.scheme(appearance: scheme) : theme.adapts ? scheme : .dark
    }

    var body: some View {
        let look = Self.look(theme, glass: env.settings.glassLook, settings: scheme)
        GlassStage(backdrop: .preview, look: look) {
            pill.frame(width: Self.size.width, alignment: .top)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .environment(\.juiceTheme, theme)
        .environment(\.glassFrost, env.settings.glassFrost)
        .environment(\.glassLook, env.settings.glassLook)
        .environment(\.colorScheme, look)
        .accessibilityHidden(true)
    }

    /// The pill's tint: its lead is an approval's "!", so what needs you (`StateTint`), while State tint is on.
    private var tint: StateTint? { env.settings.islandStateTint && theme != .smoke ? .needsYou : nil }

    private var pill: some View {
        let palette = theme.island
        return HStack(spacing: 6) {
            StateGlyphView(glyph: .bang, colour: env.settings.needsYouColour.wait, pixel: 2, animated: false, style: env.settings.glyphStyle,
                           engineSide: 16, liquidRunning: env.settings.liquidRunning)
            StateGlyphView(glyph: .eq, colour: IslandTheme.run, pixel: 2, animated: false, style: env.settings.glyphStyle,
                           engineSide: 16, liquidRunning: env.settings.liquidRunning)
            Spacer(minLength: 0)
            Text(verbatim: "2").font(IslandTheme.TypeScale.pillCount).foregroundStyle(palette.ink)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.pill.width, height: Self.pill.height)
        // Glass and Solid: the tint's veil in the glass or over the ground, under the content.
        .background { if let tint, theme.adapts { PillShape().fill(tint.veil(needsYou: env.settings.needsYouColour)) } }
        .themedSurface(PillShape())
        // Black: the tint's edge just inside the outline, over the #000.
        .overlay {
            if let tint, theme == .black {
                GlassRim(shape: PillShape(), edge: StateTint.blackEdge, colour: tint.colour(env.settings.needsYouColour))
                    .clipShape(PillShape())
            }
        }
    }
}

/// Frost (`GlassFrost`): a 4 pt track, blue up to the switch's white knob, dragged or clicked anywhere along it, as Volume's;
/// ← → step it by a tenth for VoiceOver. Left is today's Glass, right frosted.
struct FrostSlider: View {
    @Binding var value: Double

    static let width: CGFloat = 150

    var body: some View {
        let knob = SettingsTheme.Metrics.switchKnob
        let x = CGFloat(GlassFrost.stored(value)) * (Self.width - knob)
        ZStack(alignment: .leading) {
            Capsule().fill(SettingsTheme.switchOff).frame(height: 4)
            Capsule().fill(SettingsTheme.accent).frame(width: x + knob / 2, height: 4)
            Circle().fill(.white).frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .offset(x: x)
        }
        .frame(width: Self.width, height: SettingsTheme.Metrics.switchSize.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in value = Self.value(at: drag.location.x, knob: knob) })
        .accessibilityElement()
        .accessibilityLabel("Frost")
        .accessibilityValue("\(Int((GlassFrost.stored(value) * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = GlassFrost.stored(value + 0.1)
            case .decrement: value = GlassFrost.stored(value - 0.1)
            @unknown default: break
            }
        }
    }

    /// The frost under the pointer at `x` along the track, the knob's centre following it, in hundredths.
    static func value(at x: CGFloat, knob: CGFloat) -> Double {
        GlassFrost.stored(Double((x - knob / 2) / (width - knob)))
    }
}
