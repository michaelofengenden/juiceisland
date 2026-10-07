import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Theme Smoke on the island (P550 to P555; Glass's own checks are `GlassThemeTests`): the live island (`FramePerf.IslandRig`, in a window never ordered in) in
/// both outline engines, and the notch plate. What cannot be seen headless is the live glass itself (the window server
/// composites it); what is checked is everything the app draws and every mask it relies on.
@MainActor
@Suite(.serialized)
struct IslandGlassTests {
    typealias Model = IslandChoreography

    static func rig(_ outline: IslandOutline, theme: JuiceTheme = .smoke, tuning: MotionTuning = MotionTuning()) async -> FramePerf.IslandRig {
        let rig = FramePerf.IslandRig(style: .clean, glyph: .pixel, glyphsMove: false, outline: outline, tuning: tuning, theme: theme)
        await rig.start()
        return rig
    }

    /// The glass view's mask drawn from its own layer (`CALayer.render(in:)`, y up) against `expected`'s outline at 2×:
    /// pixels it lets through beyond the outline (more than a pixel from its edge) and inside it, in the canvas's top
    /// 400 pt.
    static func maskOutside(_ glass: GlassSurfaceNSView, canvas: CGSize, expected: SurfaceGeometry) -> (outside: Int, inside: Int) {
        let scale: CGFloat = 2, top = min(canvas.height, 400)
        let w = Int(canvas.width * scale), h = Int(top * scale)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // The layer is y up: its top `top` points land in the context.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: -(canvas.height - top))
        glass.maskLayer.render(in: ctx)
        let path = NotchSurfaceShape.path(expected, originX: canvas.width / 2 - expected.left, top: 0).cgPath
        var outside = 0, inside = 0
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 128 {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                let near = [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1), .zero]
                    .contains { path.contains(CGPoint(x: p.x + $0.x * 0.75, y: p.y + $0.y * 0.75)) }
                if near { inside += 1 } else { outside += 1 }
            }
        }
        return (outside, inside)
    }

    static var canvasSize: CGSize { CGSize(width: IslandPanelSizing.canvasWidth, height: FramePerf.IslandRig.screen.height) }

    // MARK: Core Animation's outline

    /// Glass on Core Animation's outline: the glass view sits between the black's view (its fill clear now) and the
    /// content, masked by its own layer's mask, which is exactly the model's outline at rest, closed and open; the notch
    /// plate and the shade are among its marks, inside the mask; its layers draw at the display's scale.
    @Test func theGlassTakesTheBlacksPlaceInsideTheOutline() async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(.coreAnimation)
        let canvas = rig.canvas
        let glass = try #require(canvas.glassView)
        let surface = try #require(canvas.surfaceView), masked = try #require(canvas.maskedView)
        let views = try #require(rig.window.contentView?.subviews)
        #expect(views.firstIndex(of: surface)! < views.firstIndex(of: glass)! && views.firstIndex(of: glass)! < views.firstIndex(of: masked)!)
        #expect(glass.layer?.mask === glass.maskLayer && glass.isSound)
        #expect(canvas.layers.fill.fillColor == nil && canvas.layers.glass === glass)
        let marks = glass.marksLayer.sublayers?.compactMap(\.name) ?? []
        #expect(marks.contains("island.glass.notchPlate") && marks.contains("island.glass.shade"))
        #expect(glass.frame == surface.frame)
        #expect(glass.pathLayers.allSatisfy { $0.contentsScale == rig.window.backingScaleFactor })
        for step in [{}, { rig.open() }] as [@MainActor () -> Void] {
            step()
            await FramePerf.wait(1.6)
            let rest = rig.director.model.restGeometry
            #expect(glass.maskLayer.path == canvas.layers.path(rest, yDown: false))
            #expect(glass.floorLayer.path == glass.maskLayer.path && glass.rimStroke.path == glass.maskLayer.path)
            let outside = Self.maskOutside(glass, canvas: Self.canvasSize, expected: rest)
            #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
        }
        rig.stop()
    }

    /// The glass moves on the plan's keyframes (its three path layers, the black's and the content's mask on the same
    /// plan) and, once the motion is over, holds no animation: nothing ticks at rest.
    @Test func theGlassPlaysThePlanAndRestsWithNothingRunning() async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(.coreAnimation)
        let glass = try #require(rig.canvas.glassView), layers = rig.canvas.layers
        // The plan is installed in the open's own turn: read there, whatever the machine's load.
        rig.open()
        for layer in glass.pathLayers {
            let playing = try #require(layer.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
            let clip = try #require(layers.clip.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
            #expect(playing.values?.count == clip.values?.count && abs(playing.beginTime - clip.beginTime) < 0.001 && playing.duration == clip.duration)
        }
        await FramePerf.wait(1.8)
        #expect(glass.pathLayers.allSatisfy { $0.animationKeys() == nil })
        #expect(layers.fill.animationKeys() == nil && layers.clip.animationKeys() == nil)
        #expect(!rig.director.model.inMotion)
        #expect(glass.maskLayer.path == layers.path(rig.director.model.restGeometry, yDown: false))
        rig.director.send(.close(.fold))
        await FramePerf.wait(1.8)
        #expect(glass.pathLayers.allSatisfy { $0.animationKeys() == nil })
        #expect(glass.maskLayer.path == layers.path(rig.director.model.restGeometry, yDown: false))
        rig.stop()
    }

    /// A lost mask, the glass taken out of the canvas or its place: the next snap's check puts it back, masked by the
    /// outline, before the turn commits. A glass whose mask cannot be put back sends the canvas to SwiftUI's outline,
    /// which draws the glass itself (never a glass with no outline).
    @Test func aLostGlassMaskComesBackAndOneThatCannotFallsBack() async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(.coreAnimation)
        let canvas = rig.canvas
        let glass = try #require(canvas.glassView)
        var sound: [Bool] = []
        rig.afterSnap = { _, ok in sound.append(ok) }
        glass.layer?.mask = nil
        glass.removeFromSuperview()
        let repairs = canvas.repairs
        rig.open()
        await FramePerf.wait(1.2)
        #expect(!sound.isEmpty && sound.allSatisfy { $0 })
        #expect(canvas.repairs > repairs)
        #expect(glass.superview === rig.window.contentView && glass.layer?.mask === glass.maskLayer)
        let outside = Self.maskOutside(glass, canvas: Self.canvasSize, expected: rig.director.model.restGeometry)
        #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
        var fell = false
        canvas.fellBack = { fell = true }
        glass.layer = CoreAnimationOutlineLiveTests.RefusingLayer()
        #expect(!canvas.ensure())
        #expect(fell && canvas.outline == .swiftUI && rig.ui.outline == .swiftUI)
        #expect(canvas.glassView == nil && glass.superview == nil && canvas.layers.glass == nil)
        rig.stop()
    }

    /// The theme switched mid-open and back: the glass comes in on the plan where it is (its animation the plan's), and
    /// goes again, the black back, with nothing left of it.
    @Test func switchingTheThemeMidMotion() async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(.coreAnimation, theme: .black)
        let canvas = rig.canvas
        #expect(canvas.glassView == nil && canvas.layers.fill.fillColor == CGColor(gray: 0, alpha: 1))
        // Mid-open: in the open's own turn, its plan just begun (a wait could outlast it on a loaded machine).
        rig.open()
        canvas.setTheme(.smoke)
        let glass = try #require(canvas.glassView)
        // What the canvas had: once, in a whole run at a load average near 100, the glass came with no animation, and
        // never alone or in 200 runs beside a build (P1277).
        let plan = canvas.layers.plan
        let seen = "plan of \(plan?.surface.count ?? -1) samples, \(plan.map { $0.end - $0.start } ?? -1) s, begun "
            + "\(plan.map { ProcessInfo.processInfo.systemUptime - $0.start } ?? -1) s ago; plays \(canvas.layers.plays), "
            + "skipped \(canvas.layers.skipped); open \(rig.director.model.isOpen), in motion \(rig.director.model.inMotion)"
        let playing = try #require(glass.maskLayer.animation(forKey: IslandSurfaceLayers.key), "\(seen)")
        let clip = try #require(canvas.layers.clip.animation(forKey: IslandSurfaceLayers.key), "\(seen)")
        #expect(abs(playing.beginTime - clip.beginTime) < 0.001 && playing.duration == clip.duration)
        #expect(canvas.layers.fill.fillColor == nil)
        await FramePerf.wait(1.6)
        #expect(glass.maskLayer.path == canvas.layers.path(rig.director.model.restGeometry, yDown: false))
        canvas.setTheme(.black)
        #expect(canvas.glassView == nil && glass.superview == nil && canvas.layers.glass == nil)
        #expect(canvas.layers.fill.fillColor == CGColor(gray: 0, alpha: 1))
        let outside = CoreAnimationOutlineLiveTests.blackOutside(canvas: canvas, expected: rig.director.model.restGeometry)
        #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
        // Reduce Transparency or Increase Contrast: a new glass, masked and on the outline.
        canvas.setTheme(.smoke)
        let first = try #require(canvas.glassView)
        canvas.rebuildGlass()
        let rebuilt = try #require(canvas.glassView)
        #expect(rebuilt !== first && first.superview == nil && rebuilt.isSound)
        #expect(rebuilt.maskLayer.path == canvas.layers.path(rig.director.model.restGeometry, yDown: false))
        rig.stop()
    }

    // MARK: SwiftUI's outline

    /// SwiftUI's outline in Glass (the glass live: offscreen it draws nothing, the floor, rim, shade and plate do):
    /// nothing is drawn beyond the outline at rest, closed and open, and in the frames of an open and a close; and the
    /// rim rides the edge: in every frame the brightest row of the island's middle column near its bottom lies within a
    /// point of the outline's bottom, however the width and the height move on their two curves.
    @Test(arguments: [MotionTuning(), MotionTuning(motion: .refined, hover: .quick)])
    func swiftUIsGlassStaysInsideAndItsRimRidesTheEdge(_ tuning: MotionTuning) async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(.swiftUI, tuning: tuning)
        var worstOutside = 0, worstRim: CGFloat = 0, frames = 0
        func look() throws {
            // What SwiftUI drew last (the island's own outline probe), not the box's target.
            guard let geometry = rig.outlines.paths.last?.geometry else { return }
            guard geometry.height > 4, geometry.width > 40 else { return }
            let bitmap = try Self.snapshot(rig)
            let origin = rig.host.frame.origin
            // The canvas's window-space rect: the host's origin in the (unflipped) container.
            let result = Self.inspect(bitmap, canvas: Self.canvasSize, hostOrigin: origin, windowHeight: rig.window.contentView?.bounds.height ?? 0,
                                      geometry: geometry)
            worstOutside = max(worstOutside, result.outside)
            if let rim = result.rimOffset { worstRim = max(worstRim, rim) }
            frames += 1
        }
        try look()
        rig.open()
        for _ in 0..<14 {
            await FramePerf.wait(0.03)
            try look()
        }
        await FramePerf.wait(1.2)
        try look()
        rig.director.send(.close(.fold))
        for _ in 0..<12 {
            await FramePerf.wait(0.03)
            try look()
        }
        print("glass, SwiftUI's outline, \(tuning.motion): \(frames) frames, outside \(worstOutside) px, rim off the edge by \(worstRim) pt at most")
        #expect(frames > 10)
        #expect(worstOutside == 0)
        #expect(worstRim <= 1)
        rig.stop()
    }

    /// The window's content at 2× as it is drawn now (the hosting view's layer tree, SwiftUI's animation at this frame).
    static func snapshot(_ rig: FramePerf.IslandRig) throws -> NSBitmapImageRep {
        let view = try #require(rig.window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pixels drawn beyond the outline `geometry` (more than half covered, more than a pixel from it), and how far the
    /// rim's light (the brightest pixel of a column's last 6 pt, along the flat of the bottom edge) lies from the
    /// outline's bottom edge, in points.
    static func inspect(_ rep: NSBitmapImageRep, canvas: CGSize, hostOrigin: CGPoint, windowHeight: CGFloat,
                        geometry: SurfaceGeometry) -> (outside: Int, rimOffset: CGFloat?) {
        let scale = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        guard let data = rep.bitmapData, rep.samplesPerPixel == 4, rep.bitsPerSample == 8 else { return (-1, nil) }
        let alphaFirst = rep.bitmapFormat.contains(.alphaFirst), premultiplied = !rep.bitmapFormat.contains(.alphaNonpremultiplied)
        let row = rep.bytesPerRow
        /// Alpha and the red channel's light (premultiplied), 0 to 1.
        func pixel(_ x: Int, _ y: Int) -> (alpha: CGFloat, light: CGFloat) {
            let p = data + y * row + x * 4
            let alpha = CGFloat(alphaFirst ? p[0] : p[3]) / 255, red = CGFloat(alphaFirst ? p[1] : p[0]) / 255
            return (alpha, premultiplied ? red : red * alpha)
        }
        // Window points (y down from the window's top) of the canvas's top-left.
        let canvasTop = windowHeight - (hostOrigin.y + canvas.height), canvasLeft = hostOrigin.x
        let path = NotchSurfaceShape.path(geometry, originX: canvasLeft + canvas.width / 2 - geometry.left, top: canvasTop).cgPath
        var outside = 0
        for py in 0..<rep.pixelsHigh {
            for px in 0..<rep.pixelsWide where pixel(px, py).alpha > 0.5 {
                // More than half covered, as the black's checks count (an edge's anti-aliasing is not a spill).
                let p = CGPoint(x: (CGFloat(px) + 0.5) / scale, y: (CGFloat(py) + 0.5) / scale)
                let near = [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1), .zero]
                    .contains { path.contains(CGPoint(x: p.x + $0.x * 0.75, y: p.y + $0.y * 0.75)) }
                if !near { outside += 1 }
            }
        }
        // The rim: along the flat of the bottom edge, left of the notch plate, right of the corner.
        let reach = max(NotchPlate(notch: IslandTheme.Metrics.referenceNotch).size.width / 2 + 1,
                        geometry.left - geometry.ear - geometry.radius - 4)
        let x = canvasLeft + canvas.width / 2 - reach, bottom = canvasTop + geometry.height
        let px = Int(x * scale)
        guard px >= 0, px < rep.pixelsWide else { return (outside, nil) }
        // The window follows the island's extent: on a loaded machine the last outline drawn can be a frame taller than
        // the window already is (a close's end), its edge below the bitmap: no rim to read there.
        let rows = max(0, Int((bottom - 6) * scale)), end = min(rep.pixelsHigh, Int((bottom + 1) * scale))
        guard rows < end else { return (outside, nil) }
        var best: (y: CGFloat, light: CGFloat)?
        for py in rows..<end {
            let light = pixel(px, py).light
            if best == nil || light > best!.light { best = ((CGFloat(py) + 0.5) / scale, light) }
        }
        guard let best, best.light > 0.1 else { return (outside, nil) }
        return (outside, abs(bottom - 0.5 - best.y))
    }

    // MARK: The notch plate

    /// The plate is black over the notch and the pill's point under it, falls to nothing `side` beside it and `drop`
    /// below it, never steps, and its image is what `alpha` says.
    @Test func theNotchPlateFallsSmoothlyFromTheNotch() throws {
        let plate = NotchPlate(notch: IslandTheme.Metrics.referenceNotch)
        let n = plate.notch, s = NotchPlate.side, d = NotchPlate.drop
        #expect(plate.alpha(x: s + 1, y: 1) == 1 && plate.alpha(x: s + n.width - 1, y: n.height + NotchPlate.below - 0.1) == 1)
        #expect(plate.alpha(x: 0, y: 5) == 0 && plate.alpha(x: plate.size.width, y: 5) == 0)
        #expect(plate.alpha(x: s + n.width / 2, y: n.height + NotchPlate.below + d) == 0)
        var last = 1.0, worst = 0.0
        for i in 0...200 {
            let a = plate.alpha(x: s - CGFloat(i) * s / 200, y: 10)
            worst = max(worst, abs(a - last))
            last = a
        }
        #expect(worst < 0.02)
        let image = try #require(plate.image(scale: 2))
        #expect(image.width == Int(plate.size.width * 2) && image.height == Int((plate.size.height * 2).rounded(.up)))
        // The shade: `shade` at the top, nothing past its reach.
        #expect(abs(plate.shadeAlpha(y: 0) - NotchPlate.shade) < 1e-9 && plate.shadeAlpha(y: plate.shadeHeight) == 0)
        #expect(plate.shadeStops.first?.alpha == NotchPlate.shade && plate.shadeStops.last?.alpha == 0)
    }
}

/// Legibility of the island's own glass, in Smoke (P550 to P555): the cards' tokens the island lane added (`IslandPalette`'s
/// Cards section) on their fills over a white window, the worst backdrop; and the real opened island in Glass on the
/// three judged backdrops, its surface never brighter than the foundation's worst case (the shade and the notch plate
/// only darken it).
@MainActor
struct IslandGlassContrastTests {
    typealias C = GlassContrast

    @Test func theCardsTokensHoldOnTheirFillsOverAWhiteWindow() {
        let p = IslandPalette.smoke, floor = GlassStyle.island.floor
        // Text on the fill it sits on (4:1 on a fill), and on the card's hover under that (the card lifts).
        let onFills: [(String, Color, [Color])] = [
            ("optionBadgeText", p.optionBadgeText, [p.optionBadge]), ("optionSub", p.optionSub, [p.optionBg]),
            ("optionSub selected", p.optionSub, [p.optionSelected]), ("optionSub hovered", p.optionSub, [p.rowHover, p.optionHover]),
            ("cardKbd", p.cardKbd, [p.optionBg]), ("cardKbd on a button", p.cardKbd, [p.button]),
            ("reason", p.reason, []), ("reason hovered", p.reason, [p.rowHover]), ("diffContext", p.diffContext, [p.codeBg]),
            ("ink on a hovered button", p.ink, [p.buttonHover]), ("ink2 option", p.ink2, [p.optionBg]),
            ("codeComment", p.codeComment, [p.codeBg]), ("message", p.message, [p.codeBg]),
            // A Done card's message (wave 6): its code box, a table's header and a link.
            ("code in a Done card's box", p.codeText, [p.codeBg, p.messageCodeBox]), ("a table's header", MessageTheme.header, [p.codeBg]),
            ("a link", MessageTheme.link, [p.codeBg]),
        ]
        for (name, colour, fills) in onFills {
            let ratio = C.worstRatio(colour, floor: floor, fills: fills)
            #expect(ratio >= (fills.isEmpty ? C.text : C.textOnFill), "\(name): \(ratio)")
        }
        #expect(C.worstRatio(p.optionChevron, floor: floor, fills: [p.optionHover]) >= C.mark)
        // The fills stay veils: the glass shows through them.
        for fill in [p.buttonHover, p.sendHover, p.optionBg, p.optionHover, p.optionSelected, p.optionBadge, p.messageCodeBox, p.messageRule] {
            #expect(C.components(fill).a < 0.2)
        }
    }

    /// The real opened island in Glass (the stand-in), with its shade, plate and rim: inside its body, clear of the rim,
    /// nothing is brighter than the floor over a white window, on any of the three backdrops.
    @Test func theIslandsSurfaceIsNeverBrighterThanTheWorstCase() throws {
        let env = IslandGlassRenders.environment()
        let ui = IslandGlassRenders.state(env, surface: .island)
        let size = CGSize(width: 540, height: 330)
        let geometry = ui.live.surface.value
        var report: [String] = []
        for backdrop in GlassBackdrop.judged {
            // The surface alone (the canvas's background, clipped as the root clips it), without the rows' text.
            let view = GlassStage(backdrop: backdrop) {
                IslandGlassBody(ui: ui, notch: IslandGlassRenders.notch)
                    .frame(width: IslandPanelSizing.canvasWidth, height: size.height)
                    .modifier(IslandSurfaceClip(surface: ui.live.surface))
                    .frame(width: size.width, height: size.height, alignment: .top)
            }
            .environment(\.juiceTheme, .smoke)
            let pixels = try ThemeTests.pixels(view, size: size)
            let left = size.width / 2 - geometry.left + geometry.ear + 4, right = size.width / 2 + geometry.right - geometry.ear - 4
            var brightest = 0.0
            for y in stride(from: 2 * 40, to: Int(2 * (geometry.height - IslandTheme.Metrics.bottomRadius)), by: 1) {
                for x in stride(from: Int(2 * left), to: Int(2 * right), by: 1) {
                    let p = pixels.rgba(x, y)
                    brightest = max(brightest, C.luminance(r: p.r, g: p.g, b: p.b))
                }
            }
            report.append("\(backdrop): \(brightest)")
            #expect(brightest <= C.worstSurface(floor: GlassStyle.island.floor) + 0.002, "\(backdrop) \(brightest)")
        }
        print("island glass, brightest inside:", report.joined(separator: "; "))
    }
}
