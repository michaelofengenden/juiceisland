import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P89: the closed pill at its 20 frames a second. `P-pill-frames`: the real pill (one running Claude session, the
/// reference notch, Pill edge line on), six consecutive frames 1/20 s apart down each column, one column per Glyph
/// style, so the step between frames can be judged. The glyphs draw from a `GlyphClock` set to each moment. No ref;
/// nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct PerfRenders {
    @Test func pillFramesAtTwentyASecond() throws {
        let start = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let rows = [DStub.row("r1", .claude, .running)]
        let sheet = HStack(alignment: .top, spacing: 16) {
            ForEach(GlyphStyle.allCases, id: \.self) { style in
                VStack(spacing: 6) {
                    Text(verbatim: "\(style)").font(.system(size: 11, weight: .medium)).foregroundStyle(IslandTheme.ink3)
                    ForEach(0..<6, id: \.self) { frame in
                        pill(style: style, rows: rows, at: start.addingTimeInterval(Double(frame) * ClosedPillView.frameInterval))
                    }
                }
            }
        }
        .padding(16)
        .background(Color(hex: 0x2A3932))
        try RenderHarness.render(sheet, "P-pill-frames")
    }

    private func pill(style: GlyphStyle, rows: [SessionRow], at date: Date) -> some View {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = style
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        return ClosedPillView()
            .environment(env)
            .environment(\.glyphClock, GlyphClock(date: date))
    }
}
