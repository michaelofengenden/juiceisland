import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Dock icon in the Glyph style (`DockIcon`, `AppIconArt`): which tile each style shows, that it draws only while
/// the app has a Dock tile and only when the style changed, that Glyph colour and the other settings never redraw it,
/// that a tile that comes back is set again a moment later and once at the next activation, and that the drawing is a
/// Dock-sized icon whose pour comes out of the island. Each test keeps its `DockIcon` alive to its end (its observation
/// holds it weakly), so a check that nothing was drawn or set can never pass because the icon was already gone.
@MainActor
struct DockIconTests {
    /// Records what the icon was set to and counts the drawings, in place of `NSApp` and `ImageRenderer`.
    @MainActor
    final class Recorder {
        var sets: [GlyphStyle?] = []
        var draws: [GlyphStyle] = []
        /// The app's activation, private to the test.
        let center = NotificationCenter()
        private var images: [ObjectIdentifier: GlyphStyle] = [:]

        func dockIcon(_ settings: AppSettings) -> DockIcon {
            DockIcon(settings: settings, setIcon: { [unowned self] image in
                sets.append(image.flatMap { images[ObjectIdentifier($0)] })
            }, draw: { [unowned self] style in
                draws.append(style)
                let image = NSImage(size: NSSize(width: 1, height: 1))
                images[ObjectIdentifier(image)] = style
                return image
            }, center: center, settleDelay: DockIconTests.settleDelay)
        }

        func becomeActive() { center.post(name: NSApplication.didBecomeActiveNotification, object: nil) }
    }

    nonisolated static let settleDelay: Duration = .milliseconds(5)

    /// Lets the settings observation, the next-turn set and the set after `settleDelay` run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: Self.settleDelay * 8)
        for _ in 0..<20 { await Task.yield() }
    }

    private func settings(_ style: GlyphStyle) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = style
        return settings
    }

    @Test func pixelKeepsTheBundlesIconAndLiquidAndSandAreDrawn() {
        #expect(DockIcon.tile(for: .pixel) == .bundle)
        #expect(DockIcon.tile(for: .liquid) == .drawn(.liquid))
        #expect(DockIcon.tile(for: .sand) == .drawn(.sand))
    }

    @Test func nothingIsDrawnOrSetWhileTheAppHasNoDockTile() async {
        let recorder = Recorder()
        let settings = settings(.liquid)
        let icon = recorder.dockIcon(settings)
        icon.update(hasTile: false)
        settings.glyphStyle = .sand
        await settle()
        #expect(recorder.draws.isEmpty && recorder.sets.isEmpty)
        // The tile comes back: the style chosen meanwhile is drawn once and set.
        icon.update(hasTile: true)
        await settle()
        #expect(recorder.draws == [.sand])
        #expect(recorder.sets.last == .sand)
        withExtendedLifetime(icon) {}
    }

    @Test func aPixelAppNeverTouchesItsIcon() async {
        let recorder = Recorder()
        let settings = settings(.pixel)
        let icon = recorder.dockIcon(settings)
        icon.update(hasTile: true)
        icon.update(hasTile: false)
        icon.update(hasTile: true)
        settings.glyphColour = .byAgent
        await settle()
        recorder.becomeActive()
        #expect(recorder.draws.isEmpty && recorder.sets.isEmpty)
        withExtendedLifetime(icon) {}
    }

    @Test func aStyleChangeDrawsTheNewStyleOnceAndPixelTakesTheDrawingBack() async {
        let recorder = Recorder()
        let settings = settings(.liquid)
        let icon = recorder.dockIcon(settings)
        icon.update(hasTile: true)
        await settle()
        #expect(recorder.draws == [.liquid] && recorder.sets.last == .liquid)

        settings.glyphStyle = .sand
        await settle()
        #expect(recorder.draws == [.liquid, .sand] && recorder.sets.last == .sand)

        // The same style again changes nothing.
        let setsBefore = recorder.sets.count
        settings.glyphStyle = .sand
        await settle()
        #expect(recorder.draws == [.liquid, .sand] && recorder.sets.count == setsBefore)

        settings.glyphStyle = .pixel
        await settle()
        #expect(recorder.draws == [.liquid, .sand])
        #expect(recorder.sets.last == .some(nil))

        // Pixel let the drawing go: Liquid is drawn again.
        settings.glyphStyle = .liquid
        await settle()
        #expect(recorder.draws == [.liquid, .sand, .liquid] && recorder.sets.last == .liquid)
        withExtendedLifetime(icon) {}
    }

    @Test func aTileThatComesBackIsSetAgainFromTheKeptDrawing() async {
        let recorder = Recorder()
        let settings = settings(.sand)
        let icon = recorder.dockIcon(settings)
        icon.update(hasTile: true)
        await settle()
        let setsBefore = recorder.sets.count
        icon.update(hasTile: false)
        icon.update(hasTile: true)
        await settle()
        #expect(recorder.draws == [.sand])
        #expect(recorder.sets.count > setsBefore && recorder.sets.dropFirst(setsBefore).allSatisfy { $0 == .sand })
        // The policy set again with no change (Window mode's second pass) sets nothing more.
        let setsAfter = recorder.sets.count
        icon.update(hasTile: true)
        await settle()
        #expect(recorder.sets.count == setsAfter)
        withExtendedLifetime(icon) {}
    }

    /// The Dock builds a tile that comes back on its own schedule: the kept drawing is set at once, on the next turn,
    /// after the settle delay and once when the app next becomes active, never drawn again; a later activation sets
    /// nothing, and neither does one after the tile went.
    @Test func aTileThatComesBackIsSetUntilTheDockHasBuiltIt() async {
        let recorder = Recorder()
        let settings = settings(.liquid)
        let icon = recorder.dockIcon(settings)
        icon.update(hasTile: true)
        #expect(recorder.sets == [.liquid])
        await settle()
        #expect(recorder.sets == [.liquid, .liquid, .liquid])
        recorder.becomeActive()
        #expect(recorder.sets.count == 4 && recorder.sets.last == .liquid)
        recorder.becomeActive()
        #expect(recorder.sets.count == 4 && recorder.draws == [.liquid])

        icon.update(hasTile: false)
        icon.update(hasTile: true)
        icon.update(hasTile: false)
        await settle()
        let sets = recorder.sets.count
        recorder.becomeActive()
        #expect(recorder.sets.count == sets && recorder.draws == [.liquid])
        withExtendedLifetime(icon) {}
    }

    @Test func glyphColourAndTheOtherSettingsNeverRedraw() async {
        let recorder = Recorder()
        let settings = settings(.liquid)
        let icon = recorder.dockIcon(settings)
        icon.update(hasTile: true)
        await settle()
        let setsBefore = recorder.sets.count
        settings.glyphColour = .byAgent
        settings.glyphEdgeLine = false
        settings.dockIconInIslandMode = true
        settings.islandStyle = .detailed
        await settle()
        #expect(recorder.draws == [.liquid] && recorder.sets.count == setsBefore)
        withExtendedLifetime(icon) {}
    }

    // MARK: The drawing

    @Test(arguments: [GlyphStyle.liquid, .sand])
    func theDrawingIsADockSizedIconOnAClearGround(_ style: GlyphStyle) throws {
        let image = try #require(DockIcon.draw(style)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(image.width == DockIcon.pixels && image.height == DockIcon.pixels)
        let pixels = try Pixels(image)
        // Outside the squircle is clear; the body's ground is opaque.
        #expect(pixels.alpha(2, 2) == 0 && pixels.alpha(509, 2) == 0 && pixels.alpha(2, 509) == 0)
        #expect(pixels.alpha(256, 88) == 255 && pixels.alpha(80, 256) == 255)
    }

    @Test func eachStyleDrawsItsOwnArt() throws {
        let liquid = try Pixels(#require(DockIcon.draw(.liquid)?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let sand = try Pixels(#require(DockIcon.draw(.sand)?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        #expect(liquid.bytes != sand.bytes)
    }

    /// The pour runs unbroken from the pill down to the pool or the pile: every row between them has a lit pixel
    /// near the middle (the stream's grains wander a little), so the island is what pours.
    @Test(arguments: [GlyphStyle.liquid, .sand])
    func thePourComesOutOfTheIsland(_ style: GlyphStyle) throws {
        let pixels = try Pixels(#require(DockIcon.draw(style)?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let scale = CGFloat(DockIcon.pixels) / 1024
        let from = Int((AppIconArt.pill.maxY + 4) * scale), to = Int(620 * scale)
        let dark = (from...to).filter { y in !(240...272).contains { x in pixels.brightness(x, y) > 0.6 } }
        #expect(dark.isEmpty, "dark rows in the \(style.rawValue) pour: \(dark)")
    }

    /// An image's RGBA bytes, row 0 at the top.
    struct Pixels {
        let width: Int
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            self.bytes = bytes
        }

        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

        /// The brightest channel, 0…1.
        func brightness(_ x: Int, _ y: Int) -> Double {
            let i = (y * width + x) * 4
            return Double(max(bytes[i], bytes[i + 1], bytes[i + 2])) / 255
        }
    }
}
