import Observation
import SwiftUI

/// The one clock every moving glyph and edge line draws from: a `TimelineView` of at most one frame an `interval` (30
/// a second; the closed pill asks for 20 through `glyphFrameInterval`), paused while the glyph rests (a
/// settled done or idle mood, a drained line) and while nobody can see its surface (`glyphMotionPaused`: the window or
/// panel ordered out, minimised or covered, the displays asleep, the screen saver on, the screen locked;
/// `SurfaceVisibility`). A paused timeline draws once and stops. It must: in a window that is not on a display, a
/// running `TimelineView` redraws as fast as the run loop turns, a whole core (the UI measurements, P89).
///
/// Measurements (`UIPerfMeasurements`) put a `GlyphClock` in the environment instead: the glyph then draws the moment
/// that clock gives it, at the rate the measurement ticks it, exactly as a timeline on a display would.
struct GlyphTimeline<Content: View>: View {
    /// The glyph's own frame interval; the environment's `glyphFrameInterval` may only lengthen it.
    var interval: TimeInterval
    /// The glyph's own rest: nothing it draws changes until something else does.
    var resting = false
    @ViewBuilder var content: (Date) -> Content

    @Environment(\.glyphMotionPaused) private var hidden
    @Environment(\.glyphFrameInterval) private var frameInterval
    @Environment(\.glyphClock) private var clock

    var body: some View {
        if let clock {
            let date = resting || hidden ? clock.start : clock.date
            let _ = GlyphFrames.drew()
            content(date)
        } else {
            TimelineView(.animation(minimumInterval: max(interval, frameInterval ?? 0), paused: resting || hidden)) { context in
                #if DEBUG
                let _ = GlyphFrames.drew()
                #endif
                content(context.date)
            }
        }
    }
}

extension View {
    /// A moving drawing that lays out nothing around it: it is the overlay of a still `width` × `height` box, so a new
    /// frame re-lays out the drawing alone. Laid out in place, each glyph frame dirtied the layout of every view above
    /// it, the whole island a glyph frame (about 2 ms of a 4 ms frame, P102). The box is the drawing's own size, so
    /// nothing moves.
    func glyphFrame(width: CGFloat, height: CGFloat) -> some View {
        Color.clear.frame(width: width, height: height).overlay { self }
    }
}

/// A clock a measurement ticks by hand; the glyphs under it draw its `date` (never used by the app).
@MainActor
@Observable
final class GlyphClock {
    var date: Date
    /// What a resting or hidden glyph draws: a fixed moment, so it never redraws.
    @ObservationIgnored let start: Date

    /// `start`: the moment a resting or hidden glyph holds (the moment its clock stopped); `date` if not given.
    init(date: Date = Date(), start: Date? = nil) {
        self.date = date
        self.start = start ?? date
    }
}

/// How many glyph frames were drawn (the UI tests and measurements read it): one add a frame, counted on a
/// measurement's clock and, in debug builds only, on the app's own timelines.
@MainActor
enum GlyphFrames {
    private(set) static var count = 0
    static func drew() { count &+= 1 }

    /// Whether the app's own timelines count their frames: a debug build's. A release build draws the same frames and
    /// counts none, so a test of how many a timeline draws can only run in a debug build.
    nonisolated static var countsTimelines: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

private struct GlyphMotionPausedKey: EnvironmentKey { static let defaultValue = false }
private struct GlyphsStillKey: EnvironmentKey { static let defaultValue = false }
private struct GlyphFrameIntervalKey: EnvironmentKey { static let defaultValue: TimeInterval? = nil }
private struct GlyphClockKey: EnvironmentKey { static let defaultValue: GlyphClock? = nil }

extension EnvironmentValues {
    /// True while nobody can see the surface: every glyph timeline under it pauses (`SurfaceMotion`).
    var glyphMotionPaused: Bool {
        get { self[GlyphMotionPausedKey.self] }
        set { self[GlyphMotionPausedKey.self] = newValue }
    }

    /// True where every glyph under it draws its still frame, as `animated: false` does: the live island's views while
    /// it is closed (`IslandUIState.islandLive`). Set in the environment, a close or an open re-evaluates the glyphs
    /// alone, never the rows and cards above them (P102).
    var glyphsStill: Bool {
        get { self[GlyphsStillKey.self] }
        set { self[GlyphsStillKey.self] = newValue }
    }

    /// A longer frame interval for the glyphs under it (the closed pill's `ClosedPillView.frameInterval`).
    var glyphFrameInterval: TimeInterval? {
        get { self[GlyphFrameIntervalKey.self] }
        set { self[GlyphFrameIntervalKey.self] = newValue }
    }

    /// Measurements only: the clock the glyphs under it draw from, in place of their timelines.
    var glyphClock: GlyphClock? {
        get { self[GlyphClockKey.self] }
        set { self[GlyphClockKey.self] = newValue }
    }
}
