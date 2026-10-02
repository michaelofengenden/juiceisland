import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion: Liquid with the glass look and Glass's card controls (P650): State tint's Black line and Glass's pointer-lit
/// rim ride the liquid union (the open's belly, the close's drop, the card's bud) on both outlines, and Glass's
/// interactive glass controls live in a budding card, every backdrop under the outline's cut, mid-bud included.
@MainActor
@Suite(.serialized)
struct LiquidLookTests {
    typealias Model = IslandChoreography
    static let liquid = MotionTuning(motion: .liquid, hover: .quick)
    static let cardID = FixtureSessionFeed.ID.approval

    static func rig(_ outline: IslandOutline, theme: JuiceTheme) async -> FramePerf.IslandRig {
        let rig = FramePerf.IslandRig(style: .clean, glyph: .pixel, glyphsMove: false, outline: outline, tuning: liquid, theme: theme)
        await rig.start()
        return rig
    }

    /// A card at rest in its bud (list → card, `LiquidRenders.budMotions`), its ui snapped there.
    static func budAtRest() -> (Model, IslandUIState) {
        let motion = LiquidRenders.budMotions[0]
        let model = LiquidRenders.model(motion, until: 2)
        let ui = IslandUIState()
        IslandMotionDirector.snap(ui, to: model, at: 2)
        return (model, ui)
    }

    static let canvas = CGSize(width: IslandPanelSizing.canvasWidth, height: 560)

    /// `view` drawn at 2x on clear, framed at the canvas.
    static func pixels<V: View>(_ view: V) throws -> (bytes: [UInt8], w: Int, h: Int) {
        let renderer = ImageRenderer(content: view.frame(width: canvas.width, height: canvas.height, alignment: .top)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }

    /// Drawn pixels (alpha over `floor`) within 1.5 pt of `union` (its line is twice the rim's width on the edge), those
    /// beyond it (but where `stub` says), and those in the bud's band (below `budTop`, points from the top).
    static func census(_ p: (bytes: [UInt8], w: Int, h: Int), union: CGPath, budTop: CGFloat, floor: UInt8 = 12,
                       stub: (CGPoint) -> Bool = { _ in false }) -> (near: Int, beyond: Int, inBud: Int) {
        var near = 0, beyond = 0, inBud = 0
        let reach: [CGPoint] = [.zero, CGPoint(x: 1.5, y: 0), CGPoint(x: -1.5, y: 0), CGPoint(x: 0, y: 1.5), CGPoint(x: 0, y: -1.5),
                                CGPoint(x: 1.1, y: 1.1), CGPoint(x: -1.1, y: 1.1), CGPoint(x: 1.1, y: -1.1), CGPoint(x: -1.1, y: -1.1)]
        for y in 0..<p.h {
            for x in 0..<p.w where p.bytes[(y * p.w + x) * 4 + 3] > floor {
                // The image's first row is its top.
                let pt = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                if reach.contains(where: { union.contains(CGPoint(x: pt.x + $0.x, y: pt.y + $0.y)) }) { near += 1 } else if !stub(pt) { beyond += 1 }
                if pt.y > budTop { inBud += 1 }
            }
        }
        return (near, beyond, inBud)
    }

    // MARK: State tint's Black line on the union

    /// The gap's band on the centre line, where the neck's stubs lie collapsed with the card at rest in its bud.
    static func stub(_ body: SurfaceGeometry) -> (CGPoint) -> Bool {
        { abs($0.x - canvas.width / 2) < 2 && $0.y > body.height - 2 && $0.y < body.height + LiquidMotion.restGap + 2 }
    }

    /// SwiftUI's outline: Black's tint line (`IslandStateEdge`) is drawn on the union, around the card's bud, never past
    /// it; the same line with Liquid's values withheld draws the body alone (nothing in the bud's band).
    @Test func blacksLineRidesTheBudOnSwiftUIsOutline() throws {
        let (model, ui) = Self.budAtRest()
        #expect(ui.tuning.liquid && ui.liquid.params?.budShows == true && model.budding)
        let body = model.surface(at: 2), params = model.liquid(at: 2)
        let union = LiquidPath.cgPath(body, params, centreX: Self.canvas.width / 2)
        let budTop = body.height + LiquidMotion.restGap
        let tint = StateTint.needsYou
        let rim = IslandTintRim(surface: ui.live.surface, continuous: true, edge: StateTint.blackEdge, tint: tint, liquid: ui.liquid)
        // Unclipped, the line strays from the union only on the neck's collapsed stubs (a zero-width sliver its stroke
        // draws as a hairline across the gap, P650), which the outline's clip removes, as it does in the island.
        let raw = Self.census(try Self.pixels(rim), union: union, budTop: budTop, stub: Self.stub(body))
        #expect(raw.beyond == 0, "\(raw)")
        let on = Self.census(try Self.pixels(rim.mask { Path(union) }), union: union, budTop: budTop)
        #expect(on.beyond == 0 && on.inBud > 400 && on.near > on.inBud, "\(on)")
        let bare = try Self.pixels(IslandTintRim(surface: ui.live.surface, continuous: true, edge: StateTint.blackEdge, tint: tint, liquid: nil)
            .mask { Path(union) })
        let off = Self.census(bare, union: union, budTop: budTop)
        #expect(off.inBud == 0 && off.near > 400, "Liquid's values withheld: the body's line alone, \(off)")
    }

    /// Core Animation's outline, Black with State tint on: the edge's mask and line take the fill's very keyframes (the
    /// same union paths, key times, begin and length) through the open's belly, the close's drop, the card's bud and its
    /// merge back; at rest they draw the fill's path (the bud out included) with nothing left on them; switched on
    /// mid-bud, the edge joins the plan where it is, on the same keyframes.
    @Test func blacksEdgeTakesTheUnionsKeyframesOnCoreAnimation() async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(.coreAnimation, theme: .black)
        let canvas = rig.canvas, layers = canvas.layers
        canvas.setStateTint(true)
        let edge = try #require(canvas.edgeLayers)
        func sameKeyframes(_ beat: String) {
            guard let fill = layers.fill.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation else {
                Issue.record("\(beat): the fill plays nothing")
                return
            }
            let values = (fill.values as? [CGPath]) ?? []
            for layer in edge.pathLayers {
                let a = layer.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation
                let theirs = (a?.values as? [CGPath]) ?? []
                #expect(theirs.count == values.count && zip(theirs, values).allSatisfy { $0 === $1 }, "\(beat): the edge carries other paths")
                #expect(a?.keyTimes == fill.keyTimes && a?.beginTime == fill.beginTime && a?.duration == fill.duration, "\(beat)")
            }
        }
        var liquidBeats = 0
        let beats: [(String, @MainActor () -> Void, Double)] = [
            ("open", { rig.open() }, 1.6), ("card", { rig.present(.card(sessionID: Self.cardID)) }, 1.8),
            ("merge", { rig.present(.list) }, 1.8), ("close", { rig.director.send(.close(.fold)) }, 1.8),
            ("opencard", { rig.open(.card(sessionID: Self.cardID)) }, 1.8), ("closebud", { rig.director.send(.close(.fold)) }, 1.8),
        ]
        for (beat, step, wait) in beats {
            step()
            if (layers.plan?.drawsLiquid ?? false) { liquidBeats += 1 }
            sameKeyframes(beat)
            await FramePerf.wait(wait)
            // Swept with the fill once the plan has ended (a loaded run's wake comes late, so look again for a while).
            let swept = await GlassLookTests.within(3) {
                ([layers.fill] + edge.pathLayers).allSatisfy { $0.animationKeys() == nil }
            }
            #expect(swept, "\(beat): an animation left on the edge")
            #expect(edge.mask.path == layers.fill.path && edge.stroke.path == layers.fill.path, "\(beat): the edge rests off the fill")
        }
        #expect(liquidBeats >= 4, "\(liquidBeats) liquid plans")
        // Mid-bud, State tint switched off and on: the edge comes back on the plan now playing.
        rig.open(.card(sessionID: Self.cardID))
        await FramePerf.wait(0.4)
        rig.present(.list)
        await FramePerf.wait(0.02)
        rig.present(.card(sessionID: Self.cardID))
        canvas.setStateTint(false)
        #expect(canvas.edgeLayers == nil)
        canvas.setStateTint(true)
        let again = try #require(canvas.edgeLayers)
        let fill = try #require(layers.fill.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
        let joined = try #require(again.mask.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
        #expect(joined.values?.count == fill.values?.count && joined.keyTimes == fill.keyTimes && abs(joined.beginTime - fill.beginTime) < 0.001)
        await FramePerf.wait(1.8)
        #expect(again.mask.path == layers.fill.path && rig.director.model.budding)
        rig.stop()
    }

    // MARK: Glass's pointer-lit rim on the union

    /// The pointer over the card's bud lights the bud's own rim: placed over the whole union (`IslandUIState.budHit`),
    /// the light sits by the bud; SwiftUI's rim (its light inside the same line) draws around the bud and never past
    /// the union.
    @Test func glasssRimLightsTheBud() throws {
        let (model, ui) = Self.budAtRest()
        let hit = try #require(model.budState.hit)
        let body = model.surface(at: 2), params = model.liquid(at: 2)
        let midX = Self.canvas.width / 2
        let pointer = CGPoint(x: midX + hit.right - 30, y: hit.height - 20)
        let place = RimLight.place(pointer: pointer, extent: hit, midX: midX)
        #expect(place.centre.y > body.height + LiquidMotion.restGap && place.centre.x > midX, "\(place)")
        #expect(RimLight.place(pointer: pointer, target: body, midX: midX) == RimLight.place(pointer: pointer, extent: body.extent, midX: midX))
        ui.rimLight.set(.init(centre: place.centre, radius: place.radius))
        let union = LiquidPath.cgPath(body, params, centreX: midX)
        let edge = GlassStyle.island.edge(.standard)
        func rim(_ light: IslandRimLight?) throws -> (bytes: [UInt8], w: Int, h: Int) {
            try Self.pixels(IslandGlassRim(surface: ui.live.surface, continuous: true, edge: edge, colour: .white, light: light, liquid: ui.liquid))
        }
        let lit = try rim(ui.rimLight), plain = try rim(nil)
        let a = Self.census(lit, union: union, budTop: body.height + LiquidMotion.restGap, stub: Self.stub(body))
        #expect(a.beyond == 0 && a.inBud > 400, "\(a)")
        // Brighter by the pointer, on the bud's rim.
        func light(_ p: (bytes: [UInt8], w: Int, h: Int)) -> Int {
            var sum = 0
            for y in Int((hit.height - 60) * 2)..<min(p.h, Int(hit.height * 2) + 4) {
                for x in Int((midX + hit.right - 80) * 2)..<min(p.w, Int((midX + hit.right) * 2) + 4) { sum += Int(p.bytes[(y * p.w + x) * 4 + 3]) }
            }
            return sum
        }
        #expect(light(lit) > light(plain) + 2000, "lit \(light(lit)), plain \(light(plain))")
    }

    /// Core Animation's outline in Glass: the rim's light lives in the rim, whose mask takes the union's keyframes with
    /// the glass's own; with the card in its bud at rest, the rim's line and the glass's mask are one union.
    @Test func glasssRimRidesTheUnionOnCoreAnimation() async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(.coreAnimation, theme: .glass)
        let glass = try #require(rig.canvas.glassView)
        #expect(glass.lightHost.superlayer === glass.rimLayer && glass.rimLayer.mask === glass.rimStroke)
        rig.open(.card(sessionID: Self.cardID))
        let mask = try #require(glass.maskLayer.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
        let line = try #require(glass.rimStroke.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
        #expect(rig.canvas.layers.plan?.drawsLiquid == true && line.values?.count == mask.values?.count && line.keyTimes == mask.keyTimes)
        await FramePerf.wait(1.8)
        #expect(rig.director.model.budding && glass.rimStroke.path == glass.maskLayer.path)
        let hit = try #require(rig.ui.budHit)
        let place = RimLight.place(pointer: CGPoint(x: IslandPanelSizing.canvasWidth / 2 + hit.right - 30, y: hit.height - 20), extent: hit,
                                   midX: IslandPanelSizing.canvasWidth / 2)
        rig.canvas.setRimLight(.init(centre: place.centre, radius: place.radius))
        #expect(glass.isLit)
        // The light's centre on the bud's side of the union (the layer is y up).
        let bounds = try #require(glass.rimStroke.path?.boundingBox)
        #expect(glass.lightLayer.position.y < bounds.maxY - (hit.height - rig.director.model.restGeometry.height), "\(glass.lightLayer.position) \(bounds)")
        rig.canvas.setRimLight(nil)
        rig.stop()
    }

    // MARK: Glass buttons in a budding card

    /// Glass's card controls in the card's bud, on both outlines: while the bud grows and at rest, every glass backdrop
    /// (the island's and each control's) lies under the outline's cut; at rest the approval's three controls are the
    /// system's glass (one tinted), they sit in the bud below the list, where the island takes clicks, and nothing
    /// animates.
    @Test(arguments: [IslandOutline.swiftUI, .coreAnimation])
    func glassButtonsLiveInTheBud(_ outline: IslandOutline) async throws {
        _ = NSApplication.shared
        let rig = await Self.rig(outline, theme: .glass)
        let root = try #require(rig.host.layer)
        rig.open(.card(sessionID: Self.cardID))
        var sampled = 0
        for _ in 0..<12 {
            await FramePerf.wait(0.05)
            let mid = GlassButtonTests.Glassware(root)
            #expect(mid.uncut == 0, "mid-bud: \(mid)")
            sampled += 1
        }
        await FramePerf.wait(1.4)
        let model = rig.director.model
        #expect(model.budding && sampled == 12)
        let rest = GlassButtonTests.Glassware(root)
        #expect(rest.roundedShapes == 3 && rest.tints == 1 && rest.backdrops == 4 && rest.uncut == 0, "\(rest)")
        #expect(rest.animating.isEmpty, "\(rest.animating)")
        // The controls' glass in the bud (the canvas's space, y down from its top) and inside the island's hit shape.
        let controls = Self.controlFrames(root, host: rig.host)
        let hit = try #require(rig.ui.budHit)
        let top = model.restGeometry.height + LiquidMotion.restGap
        let shape = IslandHitShape(geometry: rig.ui.target, hit: hit).path(in: CGRect(origin: .zero, size: rig.host.bounds.size))
        // One element a control (the key's tint has its own element on the same frame).
        #expect(Set(controls.map { "\($0)" }).count == 3, "\(controls)")
        for frame in controls {
            #expect(frame.minY > top && frame.maxY < hit.height, "\(frame) below \(top), above \(hit.height)")
            #expect(shape.contains(CGPoint(x: frame.midX, y: frame.midY)), "\(frame)")
        }
        rig.stop()
    }

    /// The rounded glass shapes' frames (the controls'), in the hosting view's space, y down.
    static func controlFrames(_ root: CALayer, host: NSView) -> [CGRect] {
        var frames: [CGRect] = []
        func walk(_ layer: CALayer) {
            let kind = String(describing: type(of: layer))
            if kind.contains("SDFElement"), layer.cornerRadius > 0, layer.superlayer?.superlayer?.name == "@0" {
                let r = layer.convert(layer.bounds, to: root)
                frames.append(root.isGeometryFlipped || host.isFlipped ? r : CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height))
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
        return frames
    }
}
