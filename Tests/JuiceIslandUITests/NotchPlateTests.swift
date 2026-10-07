import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Solid's notch plate (P790 to P797): the hardware notch's own shape (its bottom corners rounder than the notch's,
/// half a point inside its rect each side and at its foot), pure #000 over the State tint's veil, the pill's edge line and
/// everything else of the surface, on both outlines, closed and opened, light and dark.
@MainActor
@Suite(.serialized)
struct NotchPlateTests {
    static let notch = IslandTheme.Metrics.referenceNotch

    /// The hardware notch as public measurements give it, in the notch rect's own space (y down, its left at 0): the
    /// auxiliary areas' gap wide, concave flares into the screen's top edge outside it, and bottom corners `radius`
    /// (about 8 pt at 32: NotchBay, measured on the hardware), scaled with its height (`NotchPlateRenders.hardwareNotch`).
    static func hardware(_ notch: CGSize, radius: CGFloat? = nil) -> CGPath {
        let flare = 4 * notch.height / 32, r = radius ?? 8 * notch.height / 32
        return NotchSurfaceShape.path(SurfaceGeometry(width: notch.width + 2 * flare, height: notch.height, ear: flare, radius: r),
                                      originX: -flare, top: 0).cgPath
    }

    /// The plate in the same space.
    static func plate(_ notch: CGSize) -> CGPath {
        SolidNotchPlate(notch: notch).path(in: CGRect(origin: .zero, size: notch)).cgPath
    }

    /// The plate is the notch's shape: half a point inside its rect each side and at its foot, its bottom corners 3/8 of
    /// the notch's height (12 pt at 32, rounder than the hardware's 8 and the renders' 9), its top corners square into the
    /// screen's edge; and on the 14-inch's 32 pt and the 16-inch's 38 pt it lies wholly under the hardware notch, so on
    /// the built-in display none of its black shows beside the notch's curve or under it (P790, P791, P796).
    @Test(arguments: [CGSize(width: 185, height: 32), CGSize(width: 220, height: 38), CGSize(width: 200, height: 37)])
    func theSolidPlateIsTheNotchsShape(_ notch: CGSize) {
        let radius = SolidLook.plateRadius(notch)
        #expect(abs(radius - notch.height * 3 / 8) < 1e-9)
        #expect(radius >= 8 * notch.height / 32 * 1.25, "rounder than the hardware's, with room")
        if notch == Self.notch {
            #expect(radius == 12 && radius >= IslandTheme.Metrics.referenceNotchRadius && radius >= IslandTheme.Metrics.idleRadius)
        }
        #expect(SolidLook.plateInset == 0.5)
        let plate = Self.plate(notch), box = plate.boundingBoxOfPath
        #expect(abs(box.minX - 0.5) < 1e-6 && abs(box.maxX - (notch.width - 0.5)) < 1e-6, "\(box)")
        #expect(abs(box.minY) < 1e-6 && abs(box.maxY - (notch.height - 0.5)) < 1e-6, "nothing at the notch's foot or below: \(box)")
        // Square at the top, round at the bottom.
        #expect(plate.contains(CGPoint(x: 0.75, y: 0.25)) && plate.contains(CGPoint(x: notch.width - 0.75, y: 0.25)))
        #expect(!plate.contains(CGPoint(x: 1.5, y: notch.height - 1.5)) && !plate.contains(CGPoint(x: notch.width - 1.5, y: notch.height - 1.5)))
        #expect(plate.contains(CGPoint(x: notch.width / 2, y: notch.height - 0.75)) && !plate.contains(CGPoint(x: notch.width / 2, y: notch.height - 0.25)))
        // Under the hardware, on a quarter-point grid: every point of the plate is the notch's, as measured and as round
        // as the plate itself (the half point's inset is the margin).
        for hardware in [Self.hardware(notch), Self.hardware(notch, radius: radius)] {
            var outside = 0
            for row in 0..<Int(notch.height * 4) {
                for column in 0..<Int(notch.width * 4) {
                    let p = CGPoint(x: (CGFloat(column) + 0.5) / 4, y: (CGFloat(row) + 0.5) / 4)
                    if plate.contains(p), !hardware.contains(p) { outside += 1 }
                }
            }
            #expect(outside == 0, "\(outside) quarter points of the plate beside or under the hardware notch")
        }
    }

    // MARK: Pixels

    /// RGBA bytes of an image (sRGB, premultiplied), row by row from its top.
    struct Bitmap {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let (w, h) = (width, height)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }

        init(bytes: [UInt8], width: Int) {
            self.width = width
            height = bytes.count / 4 / max(1, width)
            self.bytes = bytes
        }

        /// The pixel at `(x, y)` points, 2x, from the top-left.
        func at(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            let px = min(width - 1, max(0, Int(x * 2))), py = min(height - 1, max(0, Int(y * 2)))
            let i = (py * width + px) * 4
            return Array(bytes[i ..< i + 4])
        }
    }

    static func isBlack(_ p: [UInt8]) -> Bool { p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 255 }
    static func isDark(_ p: [UInt8]) -> Bool { max(p[0], p[1], p[2]) <= 24 && p[3] > 128 }

    /// What both outlines must show around a notch whose rect starts `minX` in: pure black through the plate; the
    /// half point beside it and the corners outside its curve the ground; no black below it (the closed pill's last
    /// point, the opened island's header); the ground beside it under the delegate's teal veil.
    static func check(_ bitmap: Bitmap, minX: CGFloat, open: Bool, _ label: String) {
        let n = notch, maxX = minX + n.width, mid = minX + n.width / 2
        let inside: [(CGFloat, CGFloat)] = [(mid, n.height / 2), (mid, 0.25), (minX + 1.5, n.height / 2), (maxX - 1.5, n.height / 2),
                                            (mid, n.height - 0.75), (minX + 13, n.height - 0.75), (maxX - 13, n.height - 0.75)]
        for (x, y) in inside {
            #expect(isBlack(bitmap.at(x, y)), "\(label): \(bitmap.at(x, y)) at \(x - minX), \(y): the plate is pure #000")
        }
        for (x, y) in [(minX + 0.25, n.height / 2), (maxX - 0.25, n.height / 2), (minX + 1.25, n.height - 1.25), (maxX - 1.25, n.height - 1.25)] {
            #expect(!isDark(bitmap.at(x, y)), "\(label): \(bitmap.at(x, y)) at \(x - minX), \(y): the ground, not the plate")
        }
        // Below the notch: the closed pill's half point over its hairline, the opened island's first 3 pt.
        var black = 0
        for y in stride(from: n.height + 0.25, to: n.height + (open ? 3 : 0.5), by: 0.5) {
            for x in stride(from: minX + 0.25, to: maxX, by: 0.5) where isDark(bitmap.at(x, y)) { black += 1 }
        }
        #expect(black == 0, "\(label): \(black) dark pixels below the notch")
        let beside = bitmap.at(maxX + 2, 3)
        #expect(Int(beside[1]) > Int(beside[0]) + 6, "\(label): \(beside) beside the notch: the teal veil over the ground")
    }

    /// SwiftUI's outline: the root drawn offscreen (the ground's stand-in, the veil, the hairline, the plate).
    @Test(arguments: [ColorScheme.light, .dark])
    func swiftUIsPlateIsPureBlackOverTheVeil(_ look: ColorScheme) throws {
        let env = NotchPlateRenders.environment()
        #expect(PillLead.make(rows: env.sessions.rows, recentlyFinished: nil)?.state == .delegating)
        let canvas = CGSize(width: IslandSize.standard.canvasWidth, height: 250)
        for open in [false, true] {
            let ui = IslandGlassRenders.state(env, surface: open ? .island : .closed)
            let view = IslandRootView(ui: ui, notch: Self.notch, canvas: canvas, actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                .environment(\.juiceTheme, .solid)
                .environment(\.islandStateTint, true)
                .environment(\.sessionGlyphsAnimated, false)
            let bytes = try AppearanceRenders.bitmap(view, size: canvas, env: env, scheme: look)
            Self.check(Bitmap(bytes: bytes, width: Int(canvas.width * 2)), minX: canvas.width / 2 - Self.notch.width / 2, open: open,
                       "SwiftUI's, \(look), \(open ? "open" : "closed")")
        }
    }

    /// Core Animation's outline: the live rig (a window never ordered in) drawn by `CARenderer` as the render server
    /// composites it, the window material, the content's veil and the plate over it; the glass view holds no plate of
    /// its own, which lay under the content's veil and took its teal (the owner's screenshot, P793).
    @Test(arguments: [ColorScheme.light, .dark])
    func coreAnimationsPlateIsPureBlackOverTheVeil(_ look: ColorScheme) async throws {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: .pixel, placement: .headerStrip, scenario: .empty, glyphsMove: false,
                                      outline: .coreAnimation, theme: .solid, stateTint: true,
                                      prepare: { NotchPlateRenders.feed($0.engine, now: Date()) })
        rig.window.appearance = NSAppearance(named: look == .light ? .aqua : .darkAqua)
        await rig.start()
        #expect(rig.ui.pill.lead?.state == .delegating)
        #expect((rig.canvas.glassView?.marksLayer.sublayers ?? []).isEmpty, "no plate under the content")
        let clear = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for open in [false, true] {
            if open {
                rig.open()
                await FramePerf.rest(rig)
            }
            let content = try #require(rig.window.contentView)
            let image = try LiquidLookRenders.render(content, backdrop: clear, at: CACurrentMediaTime())
            // The canvas's middle (the notch's) in the window, from the canvas's own views: the window a rig never orders
            // in may round its frame to whole points where the panel asked for a half.
            let minX = try #require(rig.canvas.surfaceView).frame.midX - Self.notch.width / 2
            Self.check(Bitmap(image), minX: minX, open: open, "Core Animation's, \(look), \(open ? "open" : "closed")")
        }
        rig.stop()
    }

    // MARK: The pill's edge line

    /// A pixel of the edge line: the delegate's teal, at least 34 levels between its channels (38 to 114 drawn over the
    /// ground), where the ground under the teal veil has 26 at most.
    static func isLine(_ p: [UInt8]) -> Bool { Int(max(p[0], p[1], p[2])) - Int(min(p[0], p[1], p[2])) >= 34 && p[3] > 128 }

    /// How far the tests lift the line, as the plan does while the island opens (`IslandChoreography`'s rim lift).
    static let lift: CGFloat = 4

    /// With Liquid's glyphs and Pill edge line on (its default), the line passes under the plate as it passes under the
    /// hardware (P797): at rest the plate stays pure #000 through the line's band and the line shows beside the notch;
    /// lifted (the island opening, its surface taller), the line's top rows show under the notch's middle as they do
    /// beside it, the plate's cut staying where the notch is while the line rides down (a cut that rode with it would hide
    /// those rows under the notch: it reaches half a point above the notch's foot plus the lift).
    static func checkLine(_ bitmap: Bitmap, minX: CGFloat, lifted: Bool, _ label: String) {
        let n = notch, mid = minX + n.width / 2, maxX = minX + n.width
        let foot = n.height + 1 + (lifted ? lift : 0)
        let there = stride(from: n.height - 2.75, to: foot, by: 0.5).filter { isLine(bitmap.at(maxX + 2, $0)) }.count
        #expect(there >= 2, "\(label): the line beside the notch (\(there) pixels)")
        for (x, y) in [(mid, n.height / 2), (mid, n.height - 0.75), (minX + 13, n.height - 0.75), (maxX - 13, n.height - 0.75)] {
            #expect(isBlack(bitmap.at(x, y)), "\(label): \(bitmap.at(x, y)) at \(x - minX), \(y): the plate is pure #000 over the line")
        }
        guard lifted else { return }
        let rows = [n.height + lift - 1.5, n.height + lift - 1]
        func covered(_ columns: [CGFloat]) -> Double {
            Double(columns.filter { x in rows.contains { isLine(bitmap.at(x, $0)) } }.count) / Double(columns.count)
        }
        let under = covered(Array(stride(from: mid - 40, to: mid + 40, by: 0.5)))
        let beside = covered(Array(stride(from: minX - 12, to: minX - 2, by: 0.5)))
        #expect(under >= 0.9 && beside >= 0.9, "\(label): the line's top under the notch in \(under) of the columns, beside it \(beside)")
    }

    /// SwiftUI's outline: the line is content, over the plate, cut by the plate's shape outside its lift.
    @Test(arguments: [ColorScheme.light, .dark])
    func swiftUIsEdgeLinePassesUnderThePlate(_ look: ColorScheme) throws {
        let env = NotchPlateRenders.environment(glyph: .liquid)
        let canvas = CGSize(width: IslandSize.standard.canvasWidth, height: 120)
        for lifted in [false, true] {
            let ui = IslandGlassRenders.state(env, surface: .closed)
            #expect(ui.pill.showsEdgeLine)
            if lifted {
                var g = ui.live.surface.value
                g.height += Self.lift
                ui.live.surface.write(g, .snap)
                ui.live.rimLift.write(Double(Self.lift), .snap)
            }
            let view = IslandRootView(ui: ui, notch: Self.notch, canvas: canvas, actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                .environment(\.juiceTheme, .solid)
                .environment(\.islandStateTint, true)
                .environment(\.sessionGlyphsAnimated, false)
            let bitmap = Bitmap(bytes: try AppearanceRenders.bitmap(view, size: canvas, env: env, scheme: look), width: Int(canvas.width * 2))
            let minX = canvas.width / 2 - Self.notch.width / 2, label = "SwiftUI's, \(look), \(lifted ? "lifted" : "at rest")"
            if !lifted { Self.check(bitmap, minX: minX, open: false, label) }
            Self.checkLine(bitmap, minX: minX, lifted: lifted, label)
        }
    }

    /// Core Animation's outline: the line rides in its carrier, whose sublayers the render server moves down by the plan's
    /// lift; the plate's cut is the carrier's mask, which Core Animation moves with them, so the cut takes the lift back.
    /// Lifted here as a plan lifts it (the carrier down, the cut up by as much, the content's mask as tall as the surface
    /// then is), then by the plan itself as the island opens.
    @Test(arguments: [ColorScheme.light, .dark])
    func coreAnimationsEdgeLinePassesUnderThePlate(_ look: ColorScheme) async throws {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: .liquid, placement: .headerStrip, scenario: .empty, glyphsMove: false,
                                      outline: .coreAnimation, theme: .solid, stateTint: true,
                                      prepare: { NotchPlateRenders.feed($0.engine, now: Date()) })
        rig.window.appearance = NSAppearance(named: look == .light ? .aqua : .darkAqua)
        await rig.start()
        // At rest before the line is lifted by hand: a job still to come (the pill's arrival, late under a full run's
        // load) put the plan's own transform back over the lift before the render (P1258).
        await FramePerf.rest(rig)
        #expect(rig.ui.pill.showsEdgeLine)
        let carrier = try #require(rig.canvas.rimCarrier?.layer)
        #expect(carrier.mask === rig.canvas.rimCarrier?.cut, "Solid cuts the line's carrier")
        let clear = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for lifted in [false, true] {
            if lifted {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                var g = rig.director.model.restGeometry
                g.height += Self.lift
                rig.canvas.layers.clip.removeAllAnimations()
                rig.canvas.layers.clip.path = rig.canvas.layers.path(g)
                carrier.removeAllAnimations()
                carrier.sublayerTransform = CATransform3DMakeTranslation(0, Self.lift, 0)
                let cut = try #require(rig.canvas.rimCarrier?.cut)
                cut.removeAllAnimations()
                cut.transform = CATransform3DMakeTranslation(0, -Self.lift, 0)
                CATransaction.commit()
                // The panel, as the director grows it for the taller surface, laid out and committed at once.
                rig.director.applyPanel(g.extent)
                FramePerf.frame(rig)
            }
            let content = try #require(rig.window.contentView)
            let bitmap = Bitmap(try LiquidLookRenders.render(content, backdrop: clear, at: CACurrentMediaTime()))
            let minX = try #require(rig.canvas.surfaceView).frame.midX - Self.notch.width / 2
            let label = "Core Animation's, \(look), \(lifted ? "lifted" : "at rest")"
            if !lifted { Self.check(bitmap, minX: minX, open: false, label) }
            Self.checkLine(bitmap, minX: minX, lifted: lifted, label)
        }
        // The plan: opened, the line rides down to the island's foot and the cut comes back up by as much.
        rig.open()
        await FramePerf.rest(rig)
        let down = carrier.sublayerTransform.m42, up = try #require(rig.canvas.rimCarrier?.cut).transform.m42
        #expect(down > 100 && abs(down + up) < 0.001, "the carrier down \(down), its cut \(up)")
        rig.stop()
    }

    /// Black, Smoke and Glass draw no plate and cut nothing: the carrier keeps no mask (P797).
    @Test(arguments: [JuiceTheme.black, .smoke, .glass])
    func onlySolidCutsTheLinesCarrier(_ theme: JuiceTheme) async throws {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: .liquid, placement: .headerStrip, scenario: .empty, glyphsMove: false,
                                      outline: .coreAnimation, theme: .solid, stateTint: true,
                                      prepare: { NotchPlateRenders.feed($0.engine, now: Date()) })
        await rig.start()
        #expect(rig.canvas.rimCarrier?.layer?.mask === rig.canvas.rimCarrier?.cut)
        rig.canvas.setTheme(theme)
        #expect(rig.canvas.rimCarrier?.layer?.mask == nil, "\(theme): no cut")
        rig.canvas.setTheme(.solid)
        #expect(rig.canvas.rimCarrier?.layer?.mask === rig.canvas.rimCarrier?.cut, "Solid again: the cut")
        rig.canvas.setNotch(nil)
        #expect(rig.canvas.rimCarrier?.layer?.mask == nil, "no notch: no cut")
        #expect(rig.canvas.ensure())
        rig.stop()
    }
}
