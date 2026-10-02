import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P89: glyphs move only while someone can see them. The pause rules are pure functions of the visibility state; the
/// timeline test hosts a real glyph in a window that is never ordered on screen, where a running timeline would redraw
/// as fast as the run loop turns.
@MainActor
@Suite(.serialized)
struct SurfaceMotionTests {
    // MARK: The pause rules

    @Test func glyphsMoveOnlyWhileTheSurfaceCanBeSeen() {
        #expect(SurfaceVisibility.shown.glyphsMove)
        #expect(!SurfaceVisibility.hidden.glyphsMove)
        var asleep = SurfaceVisibility.shown
        asleep.displaysAwake = false
        #expect(!asleep.glyphsMove)
        var locked = SurfaceVisibility.shown
        locked.sessionActive = false
        #expect(!locked.glyphsMove)
        var screenSaver = SurfaceVisibility.shown
        screenSaver.screenSaverRunning = true
        #expect(!screenSaver.glyphsMove)
        #expect(SurfaceMotion(.shown).moves && !SurfaceMotion(.hidden).moves)
    }

    /// Ordered out (Window mode's island, the idle pill hidden, a closed window), in the Dock or fully covered: still.
    @Test func aWindowIsOnScreenOnlyOrderedInNotMinimisedAndPartlyVisible() {
        #expect(SurfaceVisibility.onScreen(isVisible: true, isMiniaturized: false, occlusion: .visible))
        #expect(!SurfaceVisibility.onScreen(isVisible: false, isMiniaturized: false, occlusion: .visible))
        #expect(!SurfaceVisibility.onScreen(isVisible: true, isMiniaturized: true, occlusion: .visible))
        #expect(!SurfaceVisibility.onScreen(isVisible: true, isMiniaturized: false, occlusion: []))
    }

    /// The island panel shows over full-screen apps, on every Space, so no full-screen app may still the pill: the
    /// watch reads nothing about one.
    @Test func thePillShowsOverFullScreenApps() {
        #expect(IslandPanelController.behaviour.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
    }

    @Test func aRowScrolledAwayHoldsStill() {
        #expect(!RowGlyphView.paused(surfaceHidden: false, scrolledAway: false))
        #expect(RowGlyphView.paused(surfaceHidden: false, scrolledAway: true))
        #expect(RowGlyphView.paused(surfaceHidden: true, scrolledAway: false))
    }

    /// A row that starts below the fold of the window's list holds still from the start: SwiftUI tells each row its
    /// visibility as it first appears, in a scroll view or not, so no row moves unseen and none outside a scroll view
    /// (the island's cards) is stilled.
    /// Counted on the app's own timelines, so debug only (`GlyphFrames.countsTimelines`): a release build counts no frame.
    @Test(.enabled(if: GlyphFrames.countsTimelines)) func aRowBelowTheFoldHoldsStillFromTheStart() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let row = try #require(env.sessions.rows.first { $0.bucket == .running })
        let belowTheFold = frames(ScrollView { VStack(spacing: 0) { Color.clear.frame(height: 400); RowGlyphView(row: row) } }, env: env)
        let inView = frames(ScrollView { RowGlyphView(row: row) }, env: env)
        let unscrolled = frames(RowGlyphView(row: row), env: env)
        #expect(belowTheFold <= 2, "a row below the fold drew \(belowTheFold) frames")
        #expect(inView > 4 && unscrolled > 4, "rows in view drew \(inView) and \(unscrolled) frames")
    }

    /// The pill draws 20 frames a second, the rows 30.
    @Test func thePillDrawsFewerFramesThanTheRows() {
        #expect(ClosedPillView.frameInterval == 1.0 / 20)
        #expect(PixelGlyph.motionInterval == 1.0 / 30 && LiquidGlyph.motionInterval == 1.0 / 30 && SandGlyph.motionInterval == 1.0 / 30)
    }

    // MARK: Timelines

    /// A running equalizer in a window that is not on screen draws once while its surface is hidden; told it shows,
    /// the same timeline runs (there, with no display to pace it, flat out: the reason nothing may run unseen). Debug only,
    /// as above.
    @Test(.enabled(if: GlyphFrames.countsTimelines)) func aHiddenSurfaceDrawsNoGlyphFrames() {
        for style in GlyphStyle.allCases {
            let hidden = frames(style: style, motion: SurfaceMotion(.hidden))
            let shown = frames(style: style, motion: SurfaceMotion(.shown))
            #expect(hidden <= 2, "\(style) drew \(hidden) frames while hidden")
            #expect(shown > 4, "\(style) drew \(shown) frames while shown")
        }
    }

    /// A window made and never shown is still; closed, it drops its content, and gets it back before it shows again.
    @Test func theAppWindowIsStillUntilShownAndDropsItsContentWhenClosed() {
        let controller = MainWindowController(env: .demo(sessions: .prototype))
        #expect(!controller.motion.moves)
        #expect(controller.hasContent)
        controller.close()
        #expect(!controller.hasContent)
        #expect(!controller.motion.moves)
        controller.fillContent()
        #expect(controller.hasContent)
    }

    /// Settings holds its content from the start (renders cache it unshown) and drops it once closed.
    @Test func settingsDropsItsContentWhenClosed() async {
        let controller = SettingsWindowController(env: .demo(), onClose: {})
        #expect(controller.hasContent)
        controller.window.close()
        for _ in 0..<20 where controller.hasContent { await Task.yield() }
        #expect(!controller.hasContent)
    }

    @Test func aWatchedWindowThatIsNeverShownIsStill() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let motion = SurfaceMotion(.shown)
        let watch = SurfaceMotionWatch(window: window, motion: motion, island: true)
        #expect(!motion.moves)
        #expect(!motion.visibility.onScreen)
        watch.stop()
    }

    private func frames(style: GlyphStyle, motion: SurfaceMotion) -> Int {
        frames(StateGlyphView(glyph: .eq, colour: .blue, pixel: 3, style: style, engineSide: 24).glyphMotion(motion))
    }

    private func frames(_ view: some View, env: AppEnvironment) -> Int {
        frames(view.environment(env).glyphMotion(SurfaceMotion(.shown)))
    }

    /// The glyph frames `view` draws in 0.5 s, hosted 40 pt square in a window that is never ordered on screen.
    private func frames(_ view: some View) -> Int {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let before = GlyphFrames.count
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let drawn = GlyphFrames.count - before
        window.contentView = nil
        window.close()
        return drawn
    }
}
