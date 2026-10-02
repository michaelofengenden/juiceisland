import SwiftUI

/// The one view every session glyph goes through (rows, the Needs you check, the Clean footer's marks, the closed pill's
/// lead): it draws `glyph` in Settings › Island › Glyph style. Pixel is `PixelGlyphView` exactly as before; Liquid and
/// Sand hand the glyph's `GlyphMood` to their engines, which draw in a square of `engineSide` (the pixel glyph's own
/// `pixel × 7` when nil). Its frame is always that square, so a row's layout never moves when the style changes. The
/// brand glyph (About, the toolbar, the island header, the idle top bar) is not a session glyph and stays Pixel.
struct StateGlyphView: View {
    let glyph: PixelGlyph
    var colour: Color = .white
    var pixel: CGFloat = 2
    var dimmed = false
    var glow = true
    var animated = true
    /// Pixel's equalizer offset; Liquid and Sand shift their clocks by it the same way.
    var frameOffset = 0
    /// nil follows Settings; renders and the Settings preview pass one.
    var style: GlyphStyle? = nil
    /// The square Liquid and Sand draw in; nil is `pixel × 7`, the square Pixel takes.
    var engineSide: CGFloat? = nil
    /// Liquid's running look; nil follows Settings (the preview and renders pass one).
    var liquidRunning: LiquidRunningLook? = nil

    @Environment(AppEnvironment.self) private var env: AppEnvironment?
    /// Glass finishes the glyph for the glass (`GlyphFinish`); every other theme draws it as it always was.
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        let style = style ?? env?.settings.glyphStyle ?? .pixel
        let side = Self.side(style: style, pixel: pixel, engineSide: engineSide)
        let finish = GlyphFinish(theme)
        switch style {
        case .pixel:
            PixelGlyphView(glyph: glyph, colour: colour, pixel: pixel, dimmed: dimmed, glow: glow, animated: animated, frameOffset: frameOffset,
                           finish: finish)
        case .liquid:
            LiquidGlyphView(mood: GlyphMood(glyph), colour: colour, side: side, dimmed: dimmed, glow: glow, animated: animated,
                            frameOffset: frameOffset, running: liquidRunning ?? env?.settings.liquidRunning ?? .slim, finish: finish)
                .frame(width: side, height: side)
        case .sand:
            SandGlyphView(mood: GlyphMood(glyph), colour: colour, side: side, dimmed: dimmed, glow: glow, animated: animated,
                          frameOffset: frameOffset, finish: finish)
                .frame(width: side, height: side)
        }
    }

    /// The square a glyph takes up in `style`: Pixel's 7 pixels, or the engine's side.
    nonisolated static func side(style: GlyphStyle, pixel: CGFloat, engineSide: CGFloat?) -> CGFloat {
        style == .pixel ? pixel * 7 : engineSide ?? pixel * 7
    }
}

/// How much of the closed pill's edge line shows from each end before the notch hides all but its last point: the two
/// wings (the whole line in the no-notch top bar). The rims taper each end within its own, so a narrow wing's segment
/// still reads whole.
struct RimEnds: Equatable, Sendable {
    var left: CGFloat
    var right: CGFloat
}

/// The closed pill's edge line in `style`: nothing for Pixel, the engine's own line for Liquid and Sand. It lives in the
/// body's lowest points (`IslandTheme.Metrics.pillEdgeLine`, `height` tall, `width` long): full along both wings, only
/// its last point under the notch (P72), while a session runs, and drains away when none does.
struct PillRimView: View {
    var style: GlyphStyle
    var running: Bool
    var colour: Color
    /// The line's length, from corner to corner of the body's bottom edge.
    var width: CGFloat
    /// The band the line draws in.
    var height: CGFloat = IslandTheme.Metrics.pillEdgeLine
    /// How much of it shows from each end (nil: all of it).
    var ends: RimEnds?
    var animated = true

    var body: some View {
        switch style {
        case .pixel:
            EmptyView()
        case .liquid:
            LiquidRimView(running: running, colour: colour, width: width, height: height, ends: ends, animated: animated)
                .frame(width: width, height: height)
        case .sand:
            SandRimView(running: running, colour: colour, width: width, height: height, ends: ends, animated: animated)
                .frame(width: width, height: height)
        }
    }
}
