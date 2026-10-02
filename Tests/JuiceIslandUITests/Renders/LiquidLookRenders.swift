import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion: Liquid with the glass look and Glass's card controls, to look at (P650): the liquid beats (open, close,
/// hover, the card's bud and its merge back) in Black and Glass with State tint on, Glass's pointer-lit rim on the
/// union, and the glass controls in a budding card. SwiftUI's outline every 1/60 s of model time (`LiquidRenders`'
/// harness: the system glass through `CARenderer`); Core Animation's outline (the default) from the live rig, drawn at
/// the render server's clock as it plays. Written to `$JI_LIQUID_OUT/look`; skipped unless it is set.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JI_LIQUID_OUT"] != nil))
struct LiquidLookRenders {
    typealias Model = IslandChoreography

    static var beats: [LiquidRenders.Motion] {
        let all = LiquidRenders.motions
        return ["open", "close", "hover", "bud", "merge"].compactMap { name in all.first { $0.name == name } }
    }

    enum Look: String, CaseIterable {
        case black, glass, glassBusy
        var theme: JuiceTheme { self == .black ? .black : .glass }
        var backdrop: GlassBackdrop { self == .glass ? .white : .busy }
    }

    /// The pointer for the lit rim: by the pill's right end on a hover, over the bud's lower right on a card, the open
    /// island's lower right otherwise (the canvas's space, y down).
    static func pointer(_ motion: LiquidRenders.Motion, _ model: Model, at t: TimeInterval, midX: CGFloat) -> CGPoint {
        let body = model.surface(at: t)
        if let hit = model.budState.hit { return CGPoint(x: midX + hit.right - 30, y: hit.height - 20) }
        return motion.name == "hover" ? CGPoint(x: midX + body.right - 8, y: body.height - 4) : CGPoint(x: midX + body.right - 40, y: body.height - 16)
    }

    /// SwiftUI's outline: each beat, each look, State tint on; Glass's also with the pointer's light:
    /// `look/su-<beat>-<look>[-lit].png`.
    @Test func swiftUIsOutline() throws {
        let scene = LiquidRenders.scene()
        for motion in Self.beats {
            let budding = motion.cardID != nil
            let canvas = budding ? LiquidRenders.budCanvas : LiquidRenders.canvas
            for look in Look.allCases {
                for lit in look == .black ? [false] : [false, true] {
                    var sheet: [(String, CGImage)] = []
                    var t = motion.from
                    while t <= motion.to + 1e-9 {
                        let start = Model(metrics: .init(targets: SurfaceTargets(notch: motion.notch, pill: scene.pill),
                                                         layout: budding ? LiquidRenders.cardLayout : scene.layout, tuning: LiquidRenders.liquid),
                                          surface: motion.surface, presentation: motion.presentation)
                        let model = Model.replay(start, motion.events, until: t).model
                        let ui = IslandUIState()
                        IslandMotionDirector.snap(ui, to: model, at: t)
                        ui.presentation = model.presentation
                        if budding { ui.card = model.cardMounted.flatMap { scene.env.sessions.card(for: $0) } }
                        ui.islandLive = false
                        ui.pillLive = false
                        if lit {
                            let midX = canvas.width / 2
                            let place = RimLight.place(pointer: Self.pointer(motion, model, at: t, midX: midX),
                                                       extent: model.budState.hit ?? model.surface(at: t).extent, midX: midX)
                            ui.rimLight.set(.init(centre: place.centre, radius: place.radius))
                        }
                        let root = ZStack(alignment: .top) {
                            look.backdrop.view
                            Rectangle().fill(Color.black.opacity(0.12)).frame(height: LiquidRenders.menuBar)
                            IslandRootView(ui: ui, notch: motion.notch, canvas: canvas, actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                            if let notch = motion.notch { DScene.hardwareNotch(notch) }
                        }
                        .frame(width: canvas.width, height: canvas.height, alignment: .top)
                        .environment(scene.env)
                        .environment(\.juiceTheme, look.theme)
                        .environment(\.islandStateTint, true)
                        .environment(\.glassRendering, .live)
                        .environment(\.sessionGlyphsAnimated, false)
                        let image = try LiquidRenders.hostedRender(AnyView(root), size: canvas,
                                                                   crop: budding ? LiquidRenders.budIslandCrop : LiquidRenders.islandCrop)
                        let ms = Int(((t - motion.zero) * 1000).rounded())
                        if motion.name == "bud", t >= motion.to - 1e-9 {
                            try LiquidRenders.write(image, "look/pick-su-bud-\(look.rawValue)\(lit ? "-lit" : "")")
                        }
                        sheet.append(("\(ms)", LiquidRenders.half(image)))
                        t += LiquidRenders.dt * 2
                    }
                    try LiquidRenders.write(LiquidRenders.sheet(sheet, columns: 8), "look/su-\(motion.name)-\(look.rawValue)\(lit ? "-lit" : "")")
                }
            }
        }
    }

    /// Core Animation's outline (the default), the live rig in a window never ordered in, State tint on, over a backdrop
    /// layer: each beat drawn at the render server's clock while it plays (as often as a render allows), and its rest;
    /// Glass also with the pointer's light at its rest: `look/ca-<beat>-<look>.png`.
    @Test func coreAnimationsOutline() async throws {
        _ = NSApplication.shared
        let card: IslandPresentation = .card(sessionID: LiquidRenders.cardID)
        let beats: [(String, @MainActor (FramePerf.IslandRig) -> Void, (@MainActor (FramePerf.IslandRig) -> Void)?)] = [
            ("open", { $0.open() }, nil),
            ("close", { $0.director.send(.close(.fold)) }, { $0.open() }),
            ("hover", { $0.director.send(.swell(true)) }, nil),
            ("bud", { $0.present(card) }, { $0.open() }),
            ("merge", { $0.present(.list) }, { $0.open(card) }),
            ("opencard", { $0.open(card) }, nil),
        ]
        for look in Look.allCases {
            for (name, beat, setup) in beats {
                let rig = FramePerf.IslandRig(style: .clean, glyph: .pixel, glyphsMove: false, outline: .coreAnimation,
                                              tuning: LiquidRenders.liquid, theme: look.theme)
                await rig.start()
                rig.canvas.setStateTint(true)
                if let setup {
                    setup(rig)
                    await FramePerf.wait(1.6)
                }
                // The backdrop: the look's, drawn once, under the island.
                let content = try #require(rig.window.contentView)
                let size = content.bounds.size
                let backdrop = try Self.backdrop(look.backdrop, size: size)
                var sheet: [(String, CGImage)] = []
                let t0 = CACurrentMediaTime()
                beat(rig)
                while CACurrentMediaTime() - t0 < 0.9 {
                    await FramePerf.wait(0.012)
                    let now = CACurrentMediaTime()
                    sheet.append(("\(Int(((now - t0) * 1000).rounded()))", LiquidRenders.half(try Self.render(content, backdrop: backdrop, at: now))))
                }
                await FramePerf.wait(0.8)
                if name == "hover" {
                    rig.director.send(.swell(false))
                    let t1 = CACurrentMediaTime()
                    while CACurrentMediaTime() - t1 < 0.6 {
                        await FramePerf.wait(0.012)
                        let now = CACurrentMediaTime()
                        sheet.append(("u\(Int(((now - t1) * 1000).rounded()))", LiquidRenders.half(try Self.render(content, backdrop: backdrop, at: now))))
                    }
                    await FramePerf.wait(0.6)
                }
                let rest = try Self.render(content, backdrop: backdrop, at: CACurrentMediaTime())
                sheet.append(("rest", LiquidRenders.half(rest)))
                try LiquidRenders.write(rest, "look/pick-ca-\(name)-\(look.rawValue)")
                if look != .black, let hit = rig.ui.budHit ?? Optional(rig.director.model.restGeometry.extent) {
                    let midX = rig.canvas.layers.canvas.width / 2
                    let model = rig.director.model
                    let pointer = model.budState.hit != nil ? CGPoint(x: midX + hit.right - 30, y: hit.height - 20)
                        : CGPoint(x: midX + hit.right - 40, y: hit.height - 16)
                    let place = RimLight.place(pointer: pointer, extent: hit, midX: midX)
                    rig.ui.rimLight.set(.init(centre: place.centre, radius: place.radius))
                    rig.canvas.setRimLight(.init(centre: place.centre, radius: place.radius))
                    await FramePerf.wait(0.5)
                    let lit = try Self.render(content, backdrop: backdrop, at: CACurrentMediaTime())
                    sheet.append(("lit", LiquidRenders.half(lit)))
                    try LiquidRenders.write(lit, "look/pick-ca-\(name)-\(look.rawValue)-lit")
                    rig.ui.rimLight.set(nil)
                    rig.canvas.setRimLight(nil)
                    await FramePerf.wait(0.5)
                }
                try LiquidRenders.write(LiquidRenders.sheet(sheet, columns: 8), "look/ca-\(name)-\(look.rawValue)")
                rig.stop()
            }
        }
    }

    /// The look's backdrop at `size` (points), at 2x.
    static func backdrop(_ backdrop: GlassBackdrop, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: backdrop.view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// The window's content with the backdrop under it, through `CARenderer` at media time `time`: its layer borrowed
    /// into a stage for the frame, then put back.
    static func render(_ content: NSView, backdrop: CGImage, at time: CFTimeInterval) throws -> CGImage {
        guard let layer = content.layer else { throw RenderHarness.RenderError.noImage("layer") }
        let size = content.bounds.size
        let stage = CALayer()
        stage.frame = CGRect(origin: .zero, size: size)
        stage.isGeometryFlipped = layer.superlayer?.isGeometryFlipped ?? false
        let ground = CALayer()
        ground.frame = stage.bounds
        ground.contents = backdrop
        ground.contentsGravity = .resize
        stage.addSublayer(ground)
        let parent = layer.superlayer, index = parent?.sublayers?.firstIndex(of: layer), frame = layer.frame
        stage.addSublayer(layer)
        layer.frame = stage.bounds
        defer {
            layer.removeFromSuperlayer()
            layer.frame = frame
            if let parent { parent.insertSublayer(layer, at: UInt32(index ?? 0)) }
        }
        return try LiquidRenders.render(stage, size: size, crop: CGRect(origin: .zero, size: size), at: time)
    }
}
