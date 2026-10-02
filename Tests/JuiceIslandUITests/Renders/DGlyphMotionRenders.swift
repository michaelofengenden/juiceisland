import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream D: the glyphs' motion as frame strips, at pixel 4 on the island's black. `D-eq-frames`: the old equalizer's
/// eight 150 ms frames, then 16 consecutive frames of the moving one at 1/30 s (offset 0, then the second equalizer's
/// offset 3), then the needs-you glow over one breath. No ref; nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct DGlyphMotionRenders {
    @Test func equalizerFrames() throws {
        let start = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let step = PixelGlyph.motionInterval
        let colour = IslandTheme.run
        let strip = VStack(alignment: .leading, spacing: 14) {
            label("Before: 8 frames, one every 150 ms")
            HStack(spacing: 10) {
                ForEach(0..<8, id: \.self) { frame in
                    PixelGlyphView(glyph: .eq, colour: colour, pixel: 4, glow: false, animated: false, frameOffset: frame)
                }
            }
            label("After: 16 frames at 1/30 s")
            HStack(spacing: 10) {
                ForEach(0..<16, id: \.self) { i in
                    PixelGlyphView(glyph: .eq, colour: colour, pixel: 4, glow: false)
                        .moment(at: start.addingTimeInterval(Double(i) * step))
                }
            }
            label("After, a second equalizer (offset 3), same 16 moments")
            HStack(spacing: 10) {
                ForEach(0..<16, id: \.self) { i in
                    PixelGlyphView(glyph: .eq, colour: colour, pixel: 4, glow: false, frameOffset: 3)
                        .moment(at: start.addingTimeInterval(Double(i) * step))
                }
            }
            label("After, with glow, every 4th frame over 2 s")
            HStack(spacing: 10) {
                ForEach(0..<16, id: \.self) { i in
                    PixelGlyphView(glyph: .eq, colour: colour, pixel: 4)
                        .moment(at: start.addingTimeInterval(Double(i) * 4 * step))
                }
            }
            label("Needs-you glow over one 3.2 s breath (every 0.2 s)")
            HStack(spacing: 10) {
                ForEach(0..<16, id: \.self) { i in
                    PixelGlyphView(glyph: .bang, colour: NeedsYouColour.pink.wait, pixel: 4)
                        .moment(at: start.addingTimeInterval(Double(i) * PixelGlyph.pulsePeriod / 16))
                }
            }
        }
        .padding(18)
        .background(IslandTheme.bg)
        try RenderHarness.render(strip, "D-eq-frames")
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11, weight: .medium)).foregroundStyle(IslandTheme.ink3)
    }
}
